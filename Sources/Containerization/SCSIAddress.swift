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

import ContainerizationExtras

/// A disk's address on a machine's virtio-scsi host: its target and logical
/// unit, on channel 0.
public struct SCSIAddress: Sendable, Hashable, CustomStringConvertible {
    /// The target the disk is a logical unit of.
    public var target: UInt8
    /// The disk's logical unit number on its target.
    public var lun: UInt16

    public init(target: UInt8, lun: UInt16) {
        self.target = target
        self.lun = lun
    }

    public var description: String {
        "\(target):\(lun)"
    }
}

extension SCSIAddress {
    /// The addresses a machine gives the disks it attaches, as Kata Containers
    /// gives them to a virtio-scsi controller: the disk at index n is target
    /// n / 256, LUN n % 256. Kata keeps LUNs below 256 because LUNs above
    /// 255 do not follow consistent SCSI addressing (GetSCSIIdLun).
    /// https://github.com/kata-containers/kata-containers/blob/87c7b0211862/src/runtime/virtcontainers/utils/utils.go
    public static func allocator() -> any AddressAllocator<SCSIAddress> {
        IndexedAddressAllocator(
            size: Self.targets * Self.lunsPerTarget,
            addressToIndex: { address in
                guard Int(address.lun) < Self.lunsPerTarget else {
                    return nil
                }
                return Int(address.target) * Self.lunsPerTarget + Int(address.lun)
            },
            indexToAddress: { index in
                SCSIAddress(target: UInt8(index / Self.lunsPerTarget), lun: UInt16(index % Self.lunsPerTarget))
            }
        )
    }

    private static let targets = 256
    private static let lunsPerTarget = 256
}
