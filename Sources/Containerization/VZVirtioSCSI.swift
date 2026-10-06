//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import ContainerizationError
import ContainerizationSCSI
import Foundation
import Logging
@preconcurrency import Virtualization

/// A virtio SCSI host adapter the host implements, carrying disk images as
/// logical units that can come and go while the machine runs.
///
/// The guest drives it with the stock Linux `virtio_scsi` driver. The device
/// is a custom Virtio device: Virtualization hands it the queues, and calls
/// it on the one serial device queue, as the custom device interface does
/// for all of a device's operations (VZCustomVirtioDevice.h, VZVirtioQueue.h
/// and VZVirtioQueueElement.h in the macOS 27 SDK). Elements are taken,
/// written and returned there; the image operations of the commands they
/// carry run on a pool of threads.
@available(macOS 27, *)
final class VZVirtioSCSI: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    let configuration: VZCustomVirtioDeviceConfiguration
    private let deviceQueue: DispatchQueue
    private let logger: Logger?

    // Touched only on `deviceQueue`.
    private let controller: VirtioSCSIController
    private var device: VZCustomVirtioDevice?

    /// A host adapter for a machine of `cpus` vCPUs, with a request queue
    /// for each.
    init(cpus: Int, logger: Logger?) {
        self.logger = logger
        let deviceQueue = DispatchQueue(label: "com.apple.containerization.vzscsi.\(UUID().uuidString)")
        self.deviceQueue = deviceQueue
        let controller = VirtioSCSIController(
            requestQueues: VirtioSCSIController.requestQueueCount(cpus: cpus),
            executor: SCSIOperationPool(completionQueue: deviceQueue)
        )
        self.controller = controller

        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = VirtioSCSIController.deviceID
        // QEMU's virtio-scsi-pci reports PCI_CLASS_STORAGE_SCSI, hw/virtio/virtio-scsi-pci.c at d7a65d1793d6:
        // https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/virtio/virtio-scsi-pci.c
        configuration.pciClassID = 0x01
        configuration.pciSubclassID = 0x00
        configuration.virtioQueueCount = controller.queueCount
        configuration.optionalFeatures.subset0 = UInt32(truncatingIfNeeded: VirtioSCSIController.offeredFeatures)
        configuration.optionalFeatures.subset1 = UInt32(truncatingIfNeeded: VirtioSCSIController.offeredFeatures >> 32)
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: Data(controller.configurationSpace)
        )
        self.configuration = configuration
        super.init()
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: deviceQueue, delegate: self)
        controller.onDeviceError = { [weak self] reason in
            self?.logger?.error("virtio-scsi device needs a reset", metadata: ["reason": "\(reason)"])
            self?.device?.requestReset()
        }
    }

    /// Attaches the disk image `mount` names as the logical unit at
    /// `target` and `lun`. It takes the options a virtio-blk attachment of
    /// the same mount takes, and refuses the ones that one refuses.
    func attach(mount: Mount, options: [String], target: UInt8, lun: UInt16) throws {
        let modes = try VZDiskImageStorageDeviceAttachment.diskImageModes(options: options)
        let image = try SCSIDiskImage(
            path: mount.source,
            readOnly: mount.readonly,
            caching: Self.caching(modes.caching),
            synchronization: Self.synchronization(modes.synchronization)
        )
        let disk = try SCSIDisk(image: image)
        try deviceQueue.sync {
            try controller.attach(disk, target: target, lun: lun)
        }
    }

    /// Detaches the logical unit at `target` and `lun`, which closes its
    /// image and lets go of the image's lock.
    func detach(target: UInt8, lun: UInt16) {
        deviceQueue.sync {
            controller.detach(target: target, lun: lun)?.image.close()
        }
    }

    /// A disk image attachment's caching mode in QEMU's terms: cache.direct,
    /// which QEMU's file driver turns into the image's open flags,
    /// block/file-posix.c at d7a65d1793d6:
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/block/file-posix.c
    private static func caching(_ mode: VZDiskImageCachingMode) -> SCSIDiskImage.Caching {
        switch mode {
        case .cached:
            // cache.direct=off: the host page cache holds the data.
            return .cached
        case .uncached:
            // cache.direct=on, which on macOS opens the image O_DSYNC.
            return .uncached
        case .automatic:
            // Virtualization's own choice. Mapping it to the cached mode is
            // ours.
            return .cached
        @unknown default:
            return .cached
        }
    }

    /// A disk image attachment's synchronization mode as what a flush
    /// reaches in QEMU's terms: its file driver's flush (handle_aiocb_flush
    /// in block/file-posix.c), or nothing with cache.no-flush (bdrv_co_flush
    /// in block/io.c), at d7a65d1793d6:
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/block/file-posix.c
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/block/io.c
    private static func synchronization(_ mode: VZDiskImageSynchronizationMode) -> SCSIDiskImage.Synchronization {
        switch mode {
        case .fsync:
            // QEMU's flush on macOS, fsync(2): qemu_fdatasync has no
            // fdatasync to call there (util/osdep.c).
            return .fsync
        case .none:
            // QEMU's cache.no-flush: a flush syncs nothing.
            return .none
        case .full:
            // F_FULLFSYNC. QEMU has no flush that reaches permanent storage
            // on macOS; this one keeps the attachment's meaning.
            return .full
        @unknown default:
            return .fsync
        }
    }

    // MARK: - VZCustomVirtioDeviceConfigurationDelegate

    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        deviceQueue.sync {
            device.delegate = self
            self.device = device
        }
    }

    // MARK: - VZCustomVirtioDeviceDelegate

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        // The segment limit the device reported is sized for queues of
        // `virtqueueSize` entries; Virtualization sizes them.
        for index in 0..<controller.queueCount {
            if let queue = device.queue(at: index), Int(queue.queueSize) < VirtioSCSIController.virtqueueSize {
                logger?.error(
                    "virtio-scsi queue is smaller than its segment limit assumes",
                    metadata: ["queue": "\(index)", "size": "\(queue.queueSize)", "assumed": "\(VirtioSCSIController.virtqueueSize)"]
                )
            }
        }
        guard let queue = device.queue(at: VirtioSCSIController.eventQueue) else {
            logger?.error("virtio-scsi device has no event queue after DRIVER_OK")
            return
        }
        let negotiated = device.negotiatedFeatures
        let features = UInt64(negotiated?.subset0 ?? 0) | UInt64(negotiated?.subset1 ?? 0) << 32
        controller.driverReady(negotiatedFeatures: features, eventQueue: EventQueue(queue))
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        guard !controller.needsReset else {
            return
        }
        switch queue.queueIndex {
        case VirtioSCSIController.controlQueue:
            while !controller.needsReset, let element = queue.nextElement() {
                controller.handleControl(Chain(element))
            }
        case VirtioSCSIController.eventQueue:
            // The event queue's buffers stay with the driver until an event
            // takes one.
            controller.eventBuffersAvailable()
        default:
            controller.handleRequests { queue.nextElement().map { Chain($0) } }
        }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        controller.reset()
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        controller.stop()
    }

    /// A queue element as the controller's descriptor chain.
    private final class Chain: VirtioDescriptorChain {
        private let element: VZVirtioQueueElement

        init(_ element: VZVirtioQueueElement) {
            self.element = element
        }

        var readableByteCount: Int { Int(element.readBuffersAvailableByteCount) }
        var writableByteCount: Int { Int(element.writeBuffersAvailableByteCount) }

        func read(into buffer: UnsafeMutableRawBufferPointer) -> Bool {
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                return true
            }
            do {
                try element.readBytes(intoBuffer: base, exactLength: buffer.count)
                return true
            } catch {
                return false
            }
        }

        func takeReadable() -> any VirtioReadableData {
            GuestData(pieces: element.readBuffers())
        }

        func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                return true
            }
            do {
                try element.writeBuffer(UnsafeMutableRawPointer(mutating: base), exactLength: bytes.count)
                return true
            } catch {
                return false
            }
        }

        func complete() {
            element.returnToQueue()
        }
    }

    /// The driver's buffers an element hands over, as data that references
    /// guest memory in place. Data lends its bytes only inside a scope of its
    /// own; an NSData's stay where they are for as long as the object lives,
    /// so every buffer is had at once.
    private struct GuestData: VirtioReadableData {
        let pieces: [Data]

        func withBuffers<Result>(_ body: ([UnsafeRawBufferPointer]) throws -> Result) rethrows -> Result {
            let buffers = pieces.map { $0 as NSData }
            return try withExtendedLifetime(buffers) {
                try body(buffers.map { UnsafeRawBufferPointer(start: $0.bytes, count: $0.length) })
            }
        }
    }

    /// The event queue as the controller's source of event buffers.
    private final class EventQueue: VirtioEventQueue {
        private let queue: VZVirtioQueue

        init(_ queue: VZVirtioQueue) {
            self.queue = queue
        }

        func nextChain() -> (any VirtioDescriptorChain)? {
            queue.nextElement().map { Chain($0) }
        }
    }
}
#endif
