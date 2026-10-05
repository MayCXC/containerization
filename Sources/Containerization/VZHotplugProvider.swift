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
/// Virtualization's storage devices are fixed once a machine boots. Its one
/// virtiofs device, though, takes a replacement share while the machine runs,
/// so a directory is exported by setting a share that carries it alongside the
/// ones already exported, and a block device reaches the running machine the
/// same way: the directory holding its image is exported, and the guest mounts
/// the image through a loop device, mount(8)'s `loop` option, with a direct
/// backing so the image's blocks are cached once and its discards reach the
/// file on the host. The guest's own devices never change, so nothing is
/// enumerated, named or detached on either side.
/// https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice/share
/// https://man7.org/linux/man-pages/man8/mount.8.html
@available(macOS 15.0, *)
final class VZHotplugProvider: HotplugProvider, @unchecked Sendable {
    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    /// Names for virtio-blk mounts registered for a container, which the
    /// guest numbers in one run with the ones the machine booted with.
    private let allocator: any AddressAllocator<Character>
    private let _storage: Mutex<MachineAttachments>
    /// The virtiofs tags exported for each container while the machine runs,
    /// the directories of its images among them. The machine keeps what it
    /// booted with; what these record leaves with the containers that asked
    /// for it.
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
        self._storage = Mutex(initialStorage)
        self._shareRecords = Mutex([:])
        self.logger = logger
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

    /// Where the machine's share is mounted in the guest, under which every
    /// exported directory appears by its tag.
    static let guestSharePath = "/run/virtiofs"

    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        guard block.isBlock else {
            throw ContainerizationError(
                .invalidArgument,
                message: "only a block device can be attached to a running machine"
            )
        }
        let image = URL(fileURLWithPath: block.source)
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw ContainerizationError(.notFound, message: "disk image \(image.path) does not exist")
        }

        // The image reaches the guest through the directory holding it,
        // exported writable whatever the mount asks, since a read-only mount
        // is the mount's own and the directory may hold images other mounts
        // write to.
        let directory = image.deletingLastPathComponent().path
        let tag = try hashFilePath(path: directory)
        try await mergeShare([tag: DirectoryExport(path: directory, readOnly: false)])
        _ = _shareRecords.withLock { $0[id, default: []].insert(tag) }

        var options = block.options
        options.append("loop")
        return AttachedFilesystem(
            type: block.type,
            source: "\(Self.guestSharePath)/\(tag)/\(image.lastPathComponent)",
            destination: block.destination,
            options: options
        )
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

    /// Give back what a container's block devices took: the registry entry
    /// alone, since an image rides the machine's share, which releaseVirtioFS
    /// withdraws with the container's other exports once the guest has
    /// unmounted it and the loop device has let the file go.
    func releaseHotplug(id: String) async throws {
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
