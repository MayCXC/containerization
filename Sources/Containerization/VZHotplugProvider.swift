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

/// Attaches disks and directory shares to a running virtual machine.
///
/// Virtualization's storage devices are fixed once a machine boots, so a disk
/// reaches the running machine as a logical unit of its virtio-scsi host,
/// which this process implements and which adds and removes units while the
/// guest runs, as QEMU's virtio-scsi host does for Kata. Its one virtiofs
/// device takes a replacement share while the machine runs, so a directory is
/// exported by setting a share that carries it alongside the ones already
/// exported. The provider holds the machine's registry, seeded with what it
/// booted with, so a container reads one registry either way.
/// https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice/share
/// https://github.com/kata-containers/kata-containers/blob/main/src/runtime/virtcontainers/qemu.go
@available(macOS 15.0, *)
final class VZHotplugProvider: HotplugProvider, @unchecked Sendable {
    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let _storage: Mutex<MachineAttachments>
    /// The virtiofs tags exported for each owner while the machine runs. The
    /// machine keeps what it booted with; what these record leaves with the
    /// owners that asked for it.
    private let _shareRecords: Mutex<[String: Set<String>]>
    /// The machine's virtio-scsi host (`VZSCSIHotplugProvider`), where the
    /// machine has one.
    private let scsi: AnyObject?
    private let logger: Logger?

    init(
        vm: VZVirtualMachine,
        queue: DispatchQueue,
        initialStorage: MachineAttachments,
        scsi: AnyObject?,
        logger: Logger?
    ) {
        self.vm = vm
        self.queue = queue
        self._storage = Mutex(initialStorage)
        self._shareRecords = Mutex([:])
        self.scsi = scsi
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

    /// Attach `block` as a logical unit of the machine's virtio-scsi host,
    /// recorded under `id` so that releasing `id` detaches it.
    func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        guard block.isBlock else {
            throw ContainerizationError(
                .invalidArgument,
                message: "only a block device can be attached to a running machine"
            )
        }
        guard #available(macOS 27, *), let host = scsi as? VZSCSIHotplugProvider else {
            throw ContainerizationError(
                .unsupported,
                message: "a running machine takes \(block.source) only on the virtio-scsi block device driver: Virtualization adds no virtio block device to a running machine"
            )
        }
        return try await host.hotplug(block, id: id)
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, writableLayer: AttachedFilesystem?, additionalMounts: [AttachedFilesystem]) throws {
        let container = ContainerAttachments(rootfs: rootfs, writableLayer: writableLayer, mounts: additionalMounts)
        _storage.withLock {
            $0.containers[id] = container
        }
    }

    /// Detach the disks attached for `id` and take its registration out of
    /// the machine's registry.
    func releaseHotplug(id: String) async throws {
        if #available(macOS 27, *), let host = scsi as? VZSCSIHotplugProvider {
            try await host.releaseHotplug(id: id)
        }
        _ = _storage.withLock { $0.containers.removeValue(forKey: id) }
    }

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

    /// Withdraw the directories exported for `id` that nothing else holds:
    /// another owner's export of the same tag, or a mount the machine's
    /// registry still has.
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

    private struct DirectoryExport: Sendable {
        let path: String
        let readOnly: Bool
    }

    private static func shareDevice(of vm: VZVirtualMachine) -> VZVirtioFileSystemDevice? {
        vm.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDevice }
            .first { $0.tag == "virtiofs" }
    }

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
