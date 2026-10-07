//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI

/// A filesystem that was attached and able to be mounted inside the runtime environment.
public struct AttachedFilesystem: Sendable {
    /// The type of the filesystem.
    public var type: String
    /// The path to the filesystem within a sandbox.
    public var source: String
    /// Destination when mounting the filesystem inside a sandbox.
    public var destination: String
    /// The options to use when mounting the filesystem.
    public var options: [String]
    /// Where the machine's virtio-scsi host attached the disk, when it did.
    /// The guest finds such a disk by this address, so `source` is empty.
    public var scsiAddress: SCSIAddress?

    public init(mount: Mount, allocator: any AddressAllocator<Character>) throws {
        guard mount.isBlock else {
            try self.init(mount: mount)
            return
        }
        let char = try allocator.allocate()
        self.init(type: mount.type, source: "/dev/vd\(char)", destination: mount.destination, options: mount.options)
    }

    /// The attachment of a mount that takes no device name from its machine:
    /// a directory share, named by its tag, or a mount that keeps its source.
    /// A block device is named as its machine attaches it, through
    /// ``init(mount:allocator:)`` while the machine is configured or the
    /// machine's hotplug once it runs.
    public init(mount: Mount) throws {
        switch mount.runtimeOptions {
        case .virtioblk:
            throw ContainerizationError(
                .invalidArgument,
                message: "block device \(mount.source) is named by the machine it is attached to"
            )
        case .virtiofs:
            self.source = try hashFilePath(path: mount.source)
        case .shared, .any:
            self.source = mount.source
        }
        self.type = mount.type
        self.options = mount.options
        self.destination = mount.destination
    }

    /// The disk `mount` names, attached at `scsiAddress` on the machine's
    /// virtio-scsi host.
    public init(mount: Mount, scsiAddress: SCSIAddress) {
        self.type = mount.type
        self.source = ""
        self.destination = mount.destination
        self.options = mount.options
        self.scsiAddress = scsiAddress
    }

    public init(type: String, source: String, destination: String, options: [String]) {
        self.type = type
        self.source = source
        self.destination = destination
        self.options = options
    }
}
