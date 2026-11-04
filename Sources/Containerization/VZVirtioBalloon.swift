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
/// macOS charges the guest's memory to Virtualization's helper process from the
/// guest's first touch of a page until the page is freed. This device releases
/// each host page the guest fills with ballooned pages with
/// `MADV_FREE_REUSABLE`, through a mapping of guest memory, the way Cloud
/// Hypervisor's balloon releases what the guest gives it on Linux:
/// https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/virtio-devices/src/balloon.rs
/// A page macOS has already compressed or swapped leaves the machine's
/// footprint at once. A page still in memory is freed, without being
/// compressed, the next time macOS needs memory.
///
/// That second case needs one call per host page. For a range of more than one
/// page, XNU clears the pages' modified state only through the page tables of
/// the process making the call, so the guest's own mapping keeps the modified
/// state its writes left and macOS compresses the pages as live data instead
/// ("If we're deactivating multiple pages, try to perform one bulk pmap
/// operation" in `vm_object_deactivate_pages`):
/// https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.121.6/osfmk/vm/vm_object.c
/// Virtualization's own balloon advises merged ranges, which is why it gives
/// back only what macOS had already compressed.
///
/// The guest drives the device with the stock Linux `virtio_balloon` driver.
/// It follows section 5.5 of the Virtio specification:
/// https://docs.oasis-open.org/virtio/virtio/v1.3/csd01/virtio-v1.3-csd01.html
/// It offers deflate-on-OOM, as Cloud Hypervisor's balloon does. It does not
/// offer free page reporting: the guest reports free pages in buffers the
/// device writes, and a custom Virtio device is not told where those are.
@available(macOS 27, *)
final class VZVirtioBalloon: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    /// VIRTIO_ID_BALLOON, include/uapi/linux/virtio_ids.h.
    static let deviceID: UInt16 = 5
    /// Balloon page frame numbers count 4 KiB pages whatever the page size on
    /// either side (VIRTIO_BALLOON_PFN_SHIFT, include/uapi/linux/virtio_balloon.h).
    static let pfnShift: UInt64 = 12
    static let inflateQueue: UInt16 = 0
    static let deflateQueue: UInt16 = 1
    /// VIRTIO_BALLOON_F_DEFLATE_ON_OOM: the guest takes pages back from the
    /// balloon instead of invoking the OOM killer.
    static let deflateOnOOMFeature: UInt32 = 1 << 2

    let configuration: VZCustomVirtioDeviceConfiguration
    private let deviceQueue: DispatchQueue
    private let memorySize: UInt64
    private let hostPageSize: UInt64
    private let logger: Logger?

    // Touched only on `deviceQueue`.
    private var device: VZCustomVirtioDevice?
    private var partial: PartiallyBalloonedPage?
    private var released = HostPageSet()

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

        mutating func insert(_ page: UInt64) {
            words[page >> 6, default: 0] |= 1 << (page & 63)
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
        configuration.virtioQueueCount = 2
        configuration.optionalFeatures.subset0 = Self.deflateOnOOMFeature
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

    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        deviceQueue.sync {
            device.delegate = self
            self.device = device
        }
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        let index = queue.queueIndex
        while let element = queue.nextElement() {
            let length = element.readBuffersByteCount
            if length > 0, let data = try? element.readBytes(withExactLength: length) {
                switch index {
                case Self.inflateQueue: forEachPFN(data) { inflate(device, pfn: $0) }
                case Self.deflateQueue: forEachPFN(data) { deflate(device, pfn: $0) }
                default: break
                }
            }
            element.returnToQueue()
        }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        for page in released.removeAll() {
            reuse(device, address: page * hostPageSize)
        }
        partial = nil
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
        let address = UInt64(pfn) << Self.pfnShift
        let base = address & ~(hostPageSize - 1)
        if var page = partial, page.address == base {
            page.ballooned &= ~(1 << ((address - base) >> Self.pfnShift))
            partial = page.ballooned == 0 ? nil : page
        }
        if released.remove(base / hostPageSize) {
            reuse(device, address: base)
        }
    }

    /// Hand one whole host page back to macOS. `MADV_FREE_REUSABLE` is
    /// libmalloc's call for memory a process keeps mapped but no longer needs,
    /// paired with `MADV_FREE_REUSE` before the memory is used again.
    private func release(_ device: VZCustomVirtioDevice, address: UInt64) {
        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: Int(hostPageSize)) else {
            logger?.error("balloon page 0x\(String(address, radix: 16)) is not guest memory")
            return
        }
        guard madvise(mapping.mutableBytes, Int(hostPageSize), MADV_FREE_REUSABLE) == 0 else {
            logger?.error("balloon could not release 0x\(String(address, radix: 16)): errno \(errno)")
            return
        }
        released.insert(address / hostPageSize)
    }

    private func reuse(_ device: VZCustomVirtioDevice, address: UInt64) {
        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: Int(hostPageSize)) else {
            return
        }
        _ = madvise(mapping.mutableBytes, Int(hostPageSize), MADV_FREE_REUSE)
    }
}
#endif
