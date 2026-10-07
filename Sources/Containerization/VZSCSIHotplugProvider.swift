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
import ContainerizationExtras
import Synchronization

/// The disks of a machine's virtio-scsi host: the ones it boots with, and the
/// ones a running machine takes on. Virtualization adds no virtio-blk disk to
/// a running machine, so a disk hot-added here becomes a logical unit of the
/// host, the way cloud-hypervisor's provider hot-adds a virtio-blk disk
/// (CHHotplugProvider).
///
/// A logical unit holds its image open, under the lock Virtualization's disk
/// attachment takes, from when it is attached until it is detached: the boot
/// disks from the machine's start to its stop, as Virtualization holds the
/// disks it boots with, and a hot-added disk until its container releases it.
@available(macOS 27, *)
final class VZSCSIHotplugProvider: HotplugProvider {
    let device: VZVirtioSCSI
    private let allocator: any AddressAllocator<SCSIAddress>
    private let state = Mutex(State())

    private struct State {
        /// The disks the machine boots with, in the order they were given.
        var bootDisks: [BootDisk] = []
        /// The disks attached at runtime, by the container they belong to.
        var hotplugged: [String: [SCSIAddress]] = [:]
        /// The addresses with a logical unit attached.
        var attached: Set<SCSIAddress> = []
        /// Records a container's attachments in the machine's storage, or
        /// takes them out of it when given nil.
        var register: (@Sendable (String, ContainerAttachments?) -> Void)?
    }

    private struct BootDisk {
        let mount: Mount
        let options: [String]
        let address: SCSIAddress
    }

    init(device: VZVirtioSCSI) {
        self.device = device
        self.allocator = SCSIAddress.allocator()
    }

    /// Where `register` records the attachments of a container that joins
    /// the running machine, and takes them out again when it is released.
    func setRegistry(_ register: @escaping @Sendable (String, ContainerAttachments?) -> Void) {
        state.withLock { $0.register = register }
    }

    // MARK: - Boot disks

    /// Gives `mount` an address among the disks the machine boots with. Its
    /// image is attached when the machine starts.
    func bootDisk(_ mount: Mount) throws -> AttachedFilesystem {
        let options = try Self.diskOptions(of: mount)
        let address = try allocator.allocate()
        state.withLock { $0.bootDisks.append(BootDisk(mount: mount, options: options, address: address)) }
        return AttachedFilesystem(mount: mount, scsiAddress: address)
    }

    /// Attaches the boot disks before the machine starts, so the guest finds
    /// them when its driver scans the host. A disk that fails leaves none of
    /// them attached.
    func attachBootDisks() throws {
        let disks = state.withLock { state in state.bootDisks.filter { !state.attached.contains($0.address) } }
        var attachedNow: [SCSIAddress] = []
        do {
            for disk in disks {
                try device.attach(mount: disk.mount, options: disk.options, target: disk.address.target, lun: disk.address.lun)
                attachedNow.append(disk.address)
                _ = state.withLock { $0.attached.insert(disk.address) }
            }
        } catch {
            for address in attachedNow {
                device.detach(target: address.target, lun: address.lun)
                _ = state.withLock { $0.attached.remove(address) }
            }
            throw error
        }
    }

    /// Detaches every disk once the machine has stopped, which closes each
    /// image and lets go of its lock.
    func detachAll() {
        let addresses = state.withLock { state in
            let attached = state.attached
            state.attached.removeAll()
            return attached
        }
        for address in addresses {
            device.detach(target: address.target, lun: address.lun)
        }
    }

    // MARK: - HotplugProvider conformance

    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        let options = try Self.diskOptions(of: block)
        let address = try allocator.allocate()
        do {
            try device.attach(mount: block, options: options, target: address.target, lun: address.lun)
        } catch {
            try? allocator.release(address)
            throw error
        }
        state.withLock { state in
            state.hotplugged[id, default: []].append(address)
            state.attached.insert(address)
        }
        return AttachedFilesystem(mount: block, scsiAddress: address)
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, writableLayer: AttachedFilesystem?, additionalMounts: [AttachedFilesystem]) throws {
        let register = state.withLock { $0.register }
        register?(id, ContainerAttachments(rootfs: rootfs, writableLayer: writableLayer, mounts: additionalMounts))
    }

    func releaseHotplug(id: String) async throws {
        let (addresses, register) = state.withLock { state in
            let addresses = state.hotplugged.removeValue(forKey: id) ?? []
            for address in addresses {
                state.attached.remove(address)
            }
            return (addresses, state.register)
        }
        for address in addresses {
            device.detach(target: address.target, lun: address.lun)
            try? allocator.release(address)
        }
        register?(id, nil)
    }

    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        throw ContainerizationError(.unsupported, message: "this machine's hotplug provider attaches disks, not virtiofs shares")
    }

    func releaseVirtioFS(id: String) async throws {
        // No share was added, so none is held for the container.
    }

    func cleanup() {
        detachAll()
    }

    /// The options a disk takes on the host: those of a virtio block device,
    /// which is what the host stands in for.
    private static func diskOptions(of mount: Mount) throws -> [String] {
        switch mount.runtimeOptions {
        case .virtioblk(let options):
            return options
        case .virtiofs, .shared, .any:
            throw ContainerizationError(.unsupported, message: "only a disk can be attached to the virtio-scsi host: \(mount.source)")
        }
    }
}
#endif
