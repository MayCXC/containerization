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

import ContainerizationError

/// A Linux kernel's own account of its memory, as its `/proc/meminfo` prints
/// it: https://docs.kernel.org/filesystems/proc.html#meminfo
public struct LinuxMemoryInfo: Sendable, Equatable {
    /// `MemTotal`, the memory the kernel manages. A balloon that may give its
    /// pages back on out-of-memory leaves them counted here.
    public var totalBytes: UInt64
    /// `MemFree`.
    public var freeBytes: UInt64
    /// `MemAvailable`, what can still be allocated without swapping.
    public var availableBytes: UInt64
    /// `Committed_AS`, what the kernel has promised its processes, whether or
    /// not they have touched it.
    public var committedBytes: UInt64
    /// `Balloon`, what balloon drivers hold, or nil when the kernel does not
    /// print it.
    public var balloonBytes: UInt64?

    public init(totalBytes: UInt64, freeBytes: UInt64, availableBytes: UInt64, committedBytes: UInt64, balloonBytes: UInt64?) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.committedBytes = committedBytes
        self.balloonBytes = balloonBytes
    }

    /// Read the figures from the text of `/proc/meminfo`.
    public init(meminfo: String) throws {
        let fields = Self.fields(meminfo: meminfo)
        func field(_ name: String) throws -> UInt64 {
            guard let value = fields[name] else {
                throw ContainerizationError(.invalidArgument, message: "/proc/meminfo has no \(name)")
            }
            return value
        }
        self.init(
            totalBytes: try field("MemTotal"),
            freeBytes: try field("MemFree"),
            availableBytes: try field("MemAvailable"),
            committedBytes: try field("Committed_AS"),
            balloonBytes: fields["Balloon"]
        )
    }

    /// Every size in `/proc/meminfo`, in bytes. A line is a name, a colon and
    /// a size in kB, which the kernel means as 1024 bytes (`show_val_kb` in
    /// fs/proc/meminfo.c); the counts with no unit, like `HugePages_Total`,
    /// are left out.
    static func fields(meminfo: String) -> [String: UInt64] {
        var fields: [String: UInt64] = [:]
        for line in meminfo.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let value = line[line.index(after: colon)...].split(separator: " ")
            guard value.count == 2, value[1] == "kB", let kibibytes = UInt64(value[0]) else {
                continue
            }
            fields[String(line[..<colon])] = kibibytes * 1024
        }
        return fields
    }
}
