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
import Foundation
import Logging
import Synchronization
@preconcurrency import Virtualization

/// Attaches block devices and directory shares to a running virtual machine.
///
/// Virtualization's storage devices are fixed once a machine boots, but its USB
/// controller takes devices while it runs, and mass storage is one of the
/// devices it takes. A block device attached this way appears to the guest as a
/// SCSI disk, so it is named from a separate run of letters to the virtio-blk
/// devices the machine booted with.
/// https://developer.apple.com/documentation/virtualization/vzusbcontroller
///
/// Directory shares ride the machine's one virtiofs device, whose share is
/// replaceable while the machine runs, so a directory is exported by setting a
/// share that carries it alongside the ones already exported.
/// https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice/share
///
/// The guest names a SCSI disk with the lowest letter free when the disk
/// enumerates, and the letters allocated here follow the guest only while
/// nothing overlaps: disks are attached and detached one at a time, and a
/// detached disk's letter is given back only once the guest has let go of the
/// device, so the next disk takes the name the guest will give it. Every disk
/// Virtualization attaches this way looks the same to the guest (one vendor,
/// one model, no serial), so the name is the one handle there is.
@available(macOS 15.0, *)
final class VZHotplugProvider: HotplugProvider, @unchecked Sendable {
    /// A disk attached to the running machine, kept so it can be detached.
    ///
    /// The device is a Virtualization object, which is safe to touch on the
    /// machine's own queue and nowhere else. Every use of it here is inside a
    /// block dispatched to that queue.
    private struct HotplugRecord: @unchecked Sendable {
        let device: VZUSBMassStorageDevice
        let letter: Character
    }

    /// What the guest answers when asked whether it still holds a device.
    enum GuestDevice: Sendable {
        /// The device node is there: the guest has not let go of the disk.
        case held
        /// The node is gone: the guest has let go.
        case gone
        /// The guest cannot be asked, as when its machine is on its way down.
        case unreachable
    }

    /// How long the guest is given to let go of a detached disk.
    static let releaseSettleTimeout: Duration = .seconds(5)

    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    /// Names for the disks attached while the machine runs, which the guest
    /// numbers apart from the ones it booted with.
    private let allocator: any AddressAllocator<Character>
    /// Disks are attached and detached one at a time, so that the order the
    /// letters are taken and given back in is the order the guest sees.
    private let serial = AsyncLock()
    /// How the guest is asked whether it still holds a device node, by the
    /// path the node has in the guest. The machine sets it once its agent
    /// answers; until then a release gives its letter back at once.
    private let _guestDevice: Mutex<(@Sendable (String) async -> GuestDevice)?>
    private let _storage: Mutex<MachineAttachments>
    private let _records: Mutex<[String: [HotplugRecord]]>
    /// The virtiofs tags exported for each container while the machine runs.
    /// The machine keeps what it booted with; what these record leaves with
    /// the containers that asked for it.
    private let _shareRecords: Mutex<[String: Set<String>]>
    private let logger: Logger?

    init(
        vm: VZVirtualMachine,
        queue: DispatchQueue,
        initialStorage: MachineAttachments,
        logger: Logger?
    ) {
        self.vm = vm
        self.queue = queue
        self.allocator = Character.blockDeviceTagAllocator()
        self._guestDevice = Mutex(nil)
        self._storage = Mutex(initialStorage)
        self._records = Mutex([:])
        self._shareRecords = Mutex([:])
        self.logger = logger
    }

    /// Give the provider a way to ask the guest whether it still holds a
    /// device node.
    func setGuestDeviceProbe(_ probe: @escaping @Sendable (String) async -> GuestDevice) {
        _guestDevice.withLock { $0 = probe }
    }

    /// Wait for the guest to let go of a detached disk's node.
    ///
    /// Detaching completes on the host before the guest has processed the
    /// disconnect; until it has, the guest still names the disk, and would
    /// name a disk attached next after it. A guest that cannot be asked is one
    /// whose machine is going away, and its letters go with it. A guest that
    /// still holds the node when the time is up keeps the letter: a name the
    /// guest may still be using is never handed to another disk.
    private func guestLetGo(ofDeviceAt path: String) async -> Bool {
        guard let probe = _guestDevice.withLock({ $0 }) else {
            return true
        }
        let deadline = ContinuousClock.now + Self.releaseSettleTimeout
        while true {
            switch await probe(path) {
            case .gone, .unreachable:
                return true
            case .held:
                break
            }
            guard ContinuousClock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    var storage: MachineAttachments {
        _storage.withLock { $0 }
    }

    func withStorage<T: Sendable>(
        _ body: (inout sending MachineAttachments) throws -> sending T
    ) rethrows -> T {
        try _storage.withLock(body)
    }

    // MARK: - HotplugProvider conformance

    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        guard block.isBlock else {
            throw ContainerizationError(
                .invalidArgument,
                message: "only a block device can be attached to a running machine"
            )
        }
        // The controller and the device are Virtualization objects, touched
        // only inside a block dispatched to the machine's own queue.
        guard let first = vm.usbControllers.first else {
            throw ContainerizationError(
                .unsupported,
                message: "the machine has no USB controller to attach to"
            )
        }
        nonisolated(unsafe) let controller = first

        return try await serial.withLock { _ in
            let letter = try self.allocator.allocate()
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(filePath: block.source),
                    readOnly: block.options.contains("ro")
                )
                nonisolated(unsafe) let device = VZUSBMassStorageDevice(
                    configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment)
                )

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    self.queue.async {
                        controller.attach(device: device) { error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            continuation.resume()
                        }
                    }
                }

                self._records.withLock {
                    $0[id, default: []].append(HotplugRecord(device: device, letter: letter))
                }

                return AttachedFilesystem(
                    type: block.type,
                    source: "/dev/sd\(letter)",
                    destination: block.destination,
                    options: block.options
                )
            } catch {
                try? self.allocator.release(letter)
                throw error
            }
        }
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, writableLayer: AttachedFilesystem?, additionalMounts: [Mount]) throws {
        var mounts: [AttachedFilesystem] = []
        for mount in additionalMounts {
            mounts.append(try AttachedFilesystem(mount: mount, allocator: allocator))
        }
        let container = ContainerAttachments(rootfs: rootfs, writableLayer: writableLayer, mounts: mounts)
        _storage.withLock {
            $0.containers[id] = container
        }
    }

    func releaseHotplug(id: String) async throws {
        let popped: [HotplugRecord] = _records.withLock { records in
            defer { records.removeValue(forKey: id) }
            return records[id] ?? []
        }
        guard let first = vm.usbControllers.first else {
            return
        }
        nonisolated(unsafe) let controller = first

        await serial.withLock { _ in
            for record in popped {
                nonisolated(unsafe) let device = record.device
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        self.queue.async {
                            controller.detach(device: device) { error in
                                if let error {
                                    continuation.resume(throwing: error)
                                    return
                                }
                                continuation.resume()
                            }
                        }
                    }
                } catch {
                    self.logger?.error(
                        "failed to detach a disk from the running machine",
                        metadata: ["id": "\(id)", "error": "\(error)"]
                    )
                }
                let path = "/dev/sd\(record.letter)"
                if await self.guestLetGo(ofDeviceAt: path) {
                    try? self.allocator.release(record.letter)
                } else {
                    self.logger?.error(
                        "the guest still holds a detached disk; its name is not given to another",
                        metadata: ["id": "\(id)", "device": "\(path)", "waited": "\(Self.releaseSettleTimeout)"]
                    )
                }
            }
        }

        _ = _storage.withLock { $0.containers.removeValue(forKey: id) }
    }

    /// Export directories to the running machine.
    ///
    /// The machine's virtiofs device takes a replacement share while it runs,
    /// so a directory is exported by setting a share that carries it alongside
    /// the ones already exported. A directory the machine already exports is
    /// taken as it is, the way a booted share is.
    /// https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice/share
    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        let virtiofs = mounts.filter {
            if case .virtiofs = $0.runtimeOptions { return true }
            return false
        }
        guard !virtiofs.isEmpty else { return }

        // Group by tag: several mounts of one source directory share an export.
        var additions: [String: DirectoryExport] = [:]
        for mount in virtiofs {
            guard FileManager.default.fileExists(atPath: mount.source) else {
                throw ContainerizationError(.notFound, message: "directory \(mount.source) does not exist")
            }
            let tag = try hashFilePath(path: mount.source)
            if additions[tag] == nil {
                additions[tag] = DirectoryExport(
                    path: mount.source,
                    readOnly: mount.options.contains("ro")
                )
            }
        }

        try await mergeShare(additions)

        _shareRecords.withLock { $0[id, default: []].formUnion(additions.keys) }
    }

    /// Withdraw the directories exported for a container while the machine
    /// runs, keeping every directory another container still references and
    /// everything the machine booted with.
    func releaseVirtioFS(id: String) async throws {
        let dropped: Set<String> = _shareRecords.withLock { records in
            records.removeValue(forKey: id) ?? []
        }
        guard !dropped.isEmpty else { return }

        let heldByRecords: Set<String> = _shareRecords.withLock { Set($0.values.flatMap { $0 }) }
        let heldByRegistry: Set<String> = _storage.withLock { storage in
            var held = Set(
                storage.containers.filter { $0.key != id }
                    .values.flatMap { $0.all }
                    .filter { $0.type == "virtiofs" }
                    .map { $0.source })
            held.formUnion(
                storage.volumes.values
                    .filter { $0.type == "virtiofs" }
                    .map { $0.source })
            return held
        }
        let removable = dropped.subtracting(heldByRecords).subtracting(heldByRegistry)
        guard !removable.isEmpty else { return }

        do {
            try await withdrawShare(removable)
        } catch {
            logger?.error(
                "failed to withdraw directory shares from the running machine",
                metadata: ["id": "\(id)", "error": "\(error)"]
            )
        }
    }

    /// What a directory export is made from, carried onto the machine's queue
    /// where the Virtualization objects for it are built.
    private struct DirectoryExport: Sendable {
        let path: String
        let readOnly: Bool
    }

    /// The machine's virtiofs device, which every share rides. The device is
    /// a Virtualization object, so this is callable only on the machine's own
    /// queue.
    private static func shareDevice(of vm: VZVirtualMachine) -> VZVirtioFileSystemDevice? {
        vm.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDevice }
            .first { $0.tag == "virtiofs" }
    }

    /// Set a share on the machine's virtiofs device carrying the current
    /// directories plus `additions`, leaving an already-exported tag as it is.
    /// The device is a Virtualization object, touched only inside a block
    /// dispatched to the machine's own queue.
    private func mergeShare(_ additions: [String: DirectoryExport]) async throws {
        nonisolated(unsafe) let vm = self.vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard let device = Self.shareDevice(of: vm) else {
                    continuation.resume(
                        throwing: ContainerizationError(
                            .unsupported,
                            message: "the machine has no directory sharing device to export through"
                        ))
                    return
                }
                let current = (device.share as? VZMultipleDirectoryShare)?.directories ?? [:]
                var updated = current
                for (tag, export) in additions where updated[tag] == nil {
                    updated[tag] = VZSharedDirectory(
                        url: URL(fileURLWithPath: export.path),
                        readOnly: export.readOnly
                    )
                }
                if updated.count != current.count {
                    device.share = VZMultipleDirectoryShare(directories: updated)
                }
                continuation.resume()
            }
        }
    }

    /// Set a share on the machine's virtiofs device carrying the current
    /// directories minus `tags`. The device is a Virtualization object,
    /// touched only inside a block dispatched to the machine's own queue.
    private func withdrawShare(_ tags: Set<String>) async throws {
        nonisolated(unsafe) let vm = self.vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard let device = Self.shareDevice(of: vm) else {
                    continuation.resume(
                        throwing: ContainerizationError(
                            .unsupported,
                            message: "the machine has no directory sharing device to withdraw from"
                        ))
                    return
                }
                let current = (device.share as? VZMultipleDirectoryShare)?.directories ?? [:]
                let updated = current.filter { !tags.contains($0.key) }
                if updated.count != current.count {
                    device.share = VZMultipleDirectoryShare(directories: updated)
                }
                continuation.resume()
            }
        }
    }
}

#endif
