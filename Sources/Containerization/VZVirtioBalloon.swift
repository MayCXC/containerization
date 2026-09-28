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
import Darwin
import Foundation
import Logging
@preconcurrency import Virtualization

/// A virtio memory balloon implemented by the host, so that memory the guest
/// puts in it goes back to macOS.
///
/// Virtualization's own balloon takes pages from the guest but leaves them
/// charged to the virtual machine, and compresses them as live data when the
/// host runs short. This device releases each ballooned page itself through a
/// mapping of guest memory, the way Cloud Hypervisor's balloon does on Linux:
/// https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/virtio-devices/src/balloon.rs
/// A released page macOS has already compressed or swapped leaves the
/// machine's footprint at once; one still in memory is marked reusable and is
/// discarded, rather than compressed, the next time the host needs memory.
///
/// The guest drives it with the stock Linux `virtio_balloon` driver. The device
/// follows section 5.5 of the Virtio specification:
/// https://docs.oasis-open.org/virtio/virtio/v1.3/csd01/virtio-v1.3-csd01.html
/// It offers the statistics queue and deflate-on-OOM that Cloud Hypervisor's
/// balloon offers. It does not offer free page reporting: the guest reports
/// free pages in buffers the device writes, and a custom Virtio device is not
/// told where those are.
@available(macOS 27, *)
final class VZVirtioBalloon: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    /// VIRTIO_ID_BALLOON, include/uapi/linux/virtio_ids.h.
    static let deviceID: UInt16 = 5
    /// Balloon page frame numbers count 4 KiB pages whatever the page size on
    /// either side (VIRTIO_BALLOON_PFN_SHIFT, include/uapi/linux/virtio_balloon.h).
    static let pfnShift: UInt64 = 12
    static let inflateQueue: UInt16 = 0
    static let deflateQueue: UInt16 = 1
    static let statisticsQueue: UInt16 = 2
    /// VIRTIO_BALLOON_F_STATS_VQ.
    static let statisticsFeature: UInt32 = 1 << 1
    /// VIRTIO_BALLOON_F_DEFLATE_ON_OOM: the guest takes pages back from the
    /// balloon instead of invoking the OOM killer.
    static let deflateOnOOMFeature: UInt32 = 1 << 2

    let configuration: VZCustomVirtioDeviceConfiguration
    private let deviceQueue: DispatchQueue
    private let memorySize: UInt64
    private let hostPageSize: UInt64
    private let logger: Logger?
    private let task = mach_port_t(task_self_trap())

    // Touched only on `deviceQueue`.
    private var device: VZCustomVirtioDevice?
    private var partial: PartiallyBalloonedPage?
    private var released = HostPageSet()
    private var balloonedPages: UInt64 = 0
    private var reclaimableBytes: UInt64 = 0
    private var guest: GuestMemoryStatistics?
    private var statisticsElement: VZVirtioQueueElement?

    /// A host page the guest has only partly ballooned. Guest pages are 4 KiB
    /// and host pages 16 KiB, so a host page is released once all of its guest
    /// pages are in the balloon, as Cloud Hypervisor's `PartiallyBalloonedPage`
    /// does for hosts with large pages.
    private struct PartiallyBalloonedPage {
        var address: UInt64
        var ballooned: UInt64
    }

    /// The host pages released to macOS, one bit each, so that each can be
    /// taken back with `MADV_FREE_REUSE` when the guest deflates or resets.
    private struct HostPageSet {
        private var words: [UInt64: UInt64] = [:]

        mutating func insert(_ page: UInt64) -> Bool {
            let word = words[page >> 6, default: 0]
            let bit: UInt64 = 1 << (page & 63)
            words[page >> 6] = word | bit
            return word & bit == 0
        }

        mutating func remove(_ page: UInt64) -> Bool {
            guard let word = words[page >> 6] else {
                return false
            }
            let bit: UInt64 = 1 << (page & 63)
            let rest = word & ~bit
            words[page >> 6] = rest == 0 ? nil : rest
            return word & bit != 0
        }

        mutating func removeAll() -> [UInt64] {
            var pages: [UInt64] = []
            for (index, word) in words {
                for bit in 0..<64 where word & (1 << bit) != 0 {
                    pages.append(index << 6 | UInt64(bit))
                }
            }
            words.removeAll()
            return pages
        }
    }

    init(memorySize: UInt64, logger: Logger?) {
        self.memorySize = memorySize
        self.hostPageSize = UInt64(getpagesize())
        self.logger = logger
        self.deviceQueue = DispatchQueue(label: "com.apple.containerization.vzballoon.\(UUID().uuidString)")

        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = Self.deviceID
        // QEMU's virtio-balloon-pci reports PCI_CLASS_OTHERS (hw/virtio/virtio-balloon-pci.c).
        configuration.pciClassID = 0x00
        configuration.pciSubclassID = 0xff
        configuration.virtioQueueCount = 3
        configuration.optionalFeatures.subset0 = Self.statisticsFeature | Self.deflateOnOOMFeature
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: Self.configurationData(pages: 0)
        )
        self.configuration = configuration
        super.init()
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: deviceQueue, delegate: self)
    }

    /// `struct virtio_balloon_config`: the pages the host wants in the balloon,
    /// then the pages the guest reports it holds, both little-endian.
    private static func configurationData(pages: UInt32) -> Data {
        var data = Data(count: 8)
        withUnsafeBytes(of: pages.littleEndian) { data.replaceSubrange(0..<4, with: $0) }
        return data
    }

    /// Ask the guest to leave the machine `bytes` of memory and put the rest in
    /// the balloon.
    func setTargetMemorySize(_ bytes: UInt64) async throws {
        let pages = UInt32((memorySize - min(bytes, memorySize)) >> Self.pfnShift)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            deviceQueue.async {
                guard let device = self.device else {
                    cont.resume(throwing: ContainerizationError(.invalidState, message: "the balloon device was never created"))
                    return
                }
                let configuration = VZVirtioDeviceSpecificConfiguration(configurationData: Self.configurationData(pages: pages))
                device.update(configuration) { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    /// The balloon's size and the guest's latest statistics. Handing the guest
    /// back its statistics buffer asks it for the next report, which a later
    /// call returns.
    func statistics() -> VirtualMachineMemoryStatistics {
        deviceQueue.sync {
            if let element = statisticsElement {
                statisticsElement = nil
                element.returnToQueue()
            }
            return VirtualMachineMemoryStatistics(
                memorySize: memorySize,
                balloonSize: balloonedPages << Self.pfnShift,
                reclaimableSize: reclaimableBytes,
                guest: guest
            )
        }
    }

    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        deviceQueue.sync {
            device.delegate = self
            self.device = device
        }
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        drain(device, queue)
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        // Linux primes the statistics queue with its first report while it is
        // still probing, before the queues exist, so that notification never
        // arrives; the buffer is waiting once the driver is ready.
        if let queue = device.queue(at: Self.statisticsQueue) {
            drain(device, queue)
        }
    }

    private func drain(_ device: VZCustomVirtioDevice, _ queue: VZVirtioQueue) {
        let index = queue.queueIndex
        while let element = queue.nextElement() {
            let length = element.readBuffersByteCount
            let data = length > 0 ? try? element.readBytes(withExactLength: length) : nil
            switch index {
            case Self.inflateQueue, Self.deflateQueue:
                if let data {
                    forEachPFN(data) { index == Self.inflateQueue ? inflate(device, pfn: $0) : deflate(device, pfn: $0) }
                }
                element.returnToQueue()
            case Self.statisticsQueue:
                if let data, let report = GuestMemoryStatistics(virtioStatistics: data) {
                    guest = report
                }
                // The guest refills the buffer when it comes back, which is how
                // the host asks for the next report.
                statisticsElement?.returnToQueue()
                statisticsElement = element
            default:
                element.returnToQueue()
            }
        }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        for page in released.removeAll() {
            reuse(device, address: page * hostPageSize)
        }
        partial = nil
        balloonedPages = 0
        reclaimableBytes = 0
        statisticsElement = nil
        guest = nil
    }

    private func forEachPFN(_ data: Data, _ body: (UInt32) -> Void) {
        let stride = MemoryLayout<UInt32>.size
        data.withUnsafeBytes { raw in
            for offset in Swift.stride(from: 0, to: raw.count - raw.count % stride, by: stride) {
                body(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
    }

    private func inflate(_ device: VZCustomVirtioDevice, pfn: UInt32) {
        balloonedPages += 1
        let address = UInt64(pfn) << Self.pfnShift
        let base = address & ~(hostPageSize - 1)
        var page = partial ?? PartiallyBalloonedPage(address: base, ballooned: 0)
        if page.address != base {
            page = PartiallyBalloonedPage(address: base, ballooned: 0)
        }
        page.ballooned |= 1 << ((address - base) >> Self.pfnShift)
        let full: UInt64 = (1 << (hostPageSize >> Self.pfnShift)) - 1
        if page.ballooned == full {
            release(device, address: base)
            partial = nil
        } else {
            partial = page
        }
    }

    private func deflate(_ device: VZCustomVirtioDevice, pfn: UInt32) {
        balloonedPages -= min(balloonedPages, 1)
        let address = UInt64(pfn) << Self.pfnShift
        let base = address & ~(hostPageSize - 1)
        if var page = partial, page.address == base {
            page.ballooned &= ~(1 << ((address - base) >> Self.pfnShift))
            partial = page.ballooned == 0 ? nil : page
        }
        if released.remove(base / hostPageSize) {
            reclaimableBytes -= min(reclaimableBytes, hostPageSize)
            reuse(device, address: base)
        }
    }

    /// Hand a whole host page back to macOS. `MADV_FREE_REUSABLE` is libmalloc's
    /// call for memory a process keeps mapped but no longer needs, paired with
    /// `MADV_FREE_REUSE` before the memory is used again.
    private func release(_ device: VZCustomVirtioDevice, address: UInt64) {
        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: Int(hostPageSize)) else {
            logger?.error("balloon page 0x\(String(address, radix: 16)) is not guest memory")
            return
        }
        guard madvise(mapping.mutableBytes, Int(hostPageSize), MADV_FREE_REUSABLE) == 0 else {
            logger?.error("balloon could not release 0x\(String(address, radix: 16)): errno \(errno)")
            return
        }
        guard released.insert(address / hostPageSize) else {
            return
        }
        // Reclaimable means macOS has already let the page go or will discard
        // it when it needs memory; a resident page it cannot discard is not.
        var disposition: integer_t = 0
        var references: integer_t = 0
        let host = mach_vm_offset_t(UInt(bitPattern: mapping.mutableBytes))
        if mach_vm_page_query(task, host, &disposition, &references) == KERN_SUCCESS,
            disposition & VM_PAGE_QUERY_PAGE_PRESENT == 0 || disposition & VM_PAGE_QUERY_PAGE_REUSABLE != 0
        {
            reclaimableBytes += hostPageSize
        }
    }

    private func reuse(_ device: VZCustomVirtioDevice, address: UInt64) {
        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: Int(hostPageSize)) else {
            return
        }
        _ = madvise(mapping.mutableBytes, Int(hostPageSize), MADV_FREE_REUSE)
    }
}
#endif
