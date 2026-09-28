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

import Foundation

/// A virtual machine's memory as its balloon sees it.
public struct VirtualMachineMemoryStatistics: Sendable, Equatable {
    /// The memory the machine was created with.
    public var memorySize: UInt64
    /// The memory in the balloon, which the guest cannot use.
    public var balloonSize: UInt64
    /// The part of the balloon the host has given back, or can take the next
    /// time it needs memory.
    public var reclaimableSize: UInt64
    /// The guest's latest report, once it has sent one.
    public var guest: GuestMemoryStatistics?

    public init(memorySize: UInt64, balloonSize: UInt64, reclaimableSize: UInt64, guest: GuestMemoryStatistics?) {
        self.memorySize = memorySize
        self.balloonSize = balloonSize
        self.reclaimableSize = reclaimableSize
        self.guest = guest
    }
}

/// What a Linux guest's balloon driver reports about its memory, in bytes or
/// counts, one field per statistic of section 5.5.6.3 of the Virtio
/// specification (`VIRTIO_BALLOON_S_*`, include/uapi/linux/virtio_balloon.h).
public struct GuestMemoryStatistics: Sendable, Equatable {
    public var swapIn: UInt64?
    public var swapOut: UInt64?
    public var majorFaults: UInt64?
    public var minorFaults: UInt64?
    /// Memory holding nothing, page cache excluded.
    public var freeMemory: UInt64?
    public var totalMemory: UInt64?
    /// The guest's estimate of what it could use without swapping, the
    /// `MemAvailable` of /proc/meminfo.
    public var availableMemory: UInt64?
    public var diskCaches: UInt64?

    public init(
        swapIn: UInt64? = nil,
        swapOut: UInt64? = nil,
        majorFaults: UInt64? = nil,
        minorFaults: UInt64? = nil,
        freeMemory: UInt64? = nil,
        totalMemory: UInt64? = nil,
        availableMemory: UInt64? = nil,
        diskCaches: UInt64? = nil
    ) {
        self.swapIn = swapIn
        self.swapOut = swapOut
        self.majorFaults = majorFaults
        self.minorFaults = minorFaults
        self.freeMemory = freeMemory
        self.totalMemory = totalMemory
        self.availableMemory = availableMemory
        self.diskCaches = diskCaches
    }

    /// Parse the buffer the guest sends on the statistics queue: packed
    /// `struct virtio_balloon_stat` entries, a 16-bit tag then a 64-bit value,
    /// both little-endian. Tags this type has no field for are skipped and a
    /// buffer holding a partial entry is refused, as Cloud Hypervisor's
    /// `parse_balloon_stats` does.
    public init?(virtioStatistics data: Data) {
        let entry = 10
        guard data.count % entry == 0 else {
            return nil
        }
        self.init()
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: entry) {
                let tag = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let value = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2, as: UInt64.self))
                switch tag {
                case 0: swapIn = value
                case 1: swapOut = value
                case 2: majorFaults = value
                case 3: minorFaults = value
                case 4: freeMemory = value
                case 5: totalMemory = value
                case 6: availableMemory = value
                case 7: diskCaches = value
                default: break
                }
            }
        }
    }
}
