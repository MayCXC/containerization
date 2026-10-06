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

#if os(Linux)

import ContainerizationError
import Foundation

/// Finds the block device of a disk on the guest's SCSI host by the disk's
/// target and LUN, as Kata's agent finds a SCSI device: every SCSI host is
/// asked to scan for the logical unit, then the disk's block device is awaited
/// at the address `0:0:<target>:<lun>`.
/// https://github.com/kata-containers/kata-containers/blob/87c7b0211862/src/agent/src/device/scsi_device_handler.rs
package struct SCSIDiskFinder: Sendable {
    /// Where sysfs is mounted.
    package let sys: URL
    /// Where the device nodes are.
    package let dev: URL
    /// How long the disk has to appear: the wait Kata's agent gives a
    /// hot-plugged device, DEFAULT_HOTPLUG_TIMEOUT in
    /// https://github.com/kata-containers/kata-containers/blob/87c7b0211862/src/agent/src/config.rs
    package let timeout: Duration
    /// How often the address is looked at while waiting. Kata's agent is woken
    /// by the kernel's uevent for the disk; reading sysfs on an interval is
    /// ours, since this guest has no uevent listener.
    package let interval: Duration

    package init(
        sys: URL = URL(fileURLWithPath: "/sys"),
        dev: URL = URL(fileURLWithPath: "/dev"),
        timeout: Duration = .seconds(3),
        interval: Duration = .milliseconds(10)
    ) {
        self.sys = sys
        self.dev = dev
        self.timeout = timeout
        self.interval = interval
    }

    /// Scans for the logical unit and waits for its block device, returning
    /// the device node's path.
    package func find(target: UInt32, lun: UInt32) async throws -> String {
        try scan(target: target, lun: lun)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let device = blockDevice(target: target, lun: lun) {
                return device
            }
            guard ContinuousClock.now < deadline else {
                throw ContainerizationError(
                    .timeout,
                    message: "no block device appeared for SCSI target \(target) LUN \(lun) within \(timeout)"
                )
            }
            try await Task.sleep(for: interval)
        }
    }

    /// Asks every SCSI host to scan for the logical unit. The channel is always
    /// 0: Kata's agent writes "0 <target> <lun>" to each host's scan file, for
    /// a guest with one SCSI host.
    package func scan(target: UInt32, lun: UInt32) throws {
        let hosts = sys.appendingPathComponent("class/scsi_host")
        for host in try FileManager.default.contentsOfDirectory(atPath: hosts.path) {
            let scan = hosts.appendingPathComponent(host).appendingPathComponent("scan")
            try Data("0 \(target) \(lun)".utf8).write(to: scan)
        }
    }

    /// The disk's block device node at the address, once the disk is
    /// registered and its node exists. Kata matches the uevent whose device
    /// path ends in /0:0:<target>:<lun>/block/<name>, the whole disk rather
    /// than a partition; sysfs keeps the disk at the same path, under the
    /// SCSI device's block directory.
    package func blockDevice(target: UInt32, lun: UInt32) -> String? {
        let block = sys.appendingPathComponent("bus/scsi/devices/0:0:\(target):\(lun)/block")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: block.path), names.count == 1 else {
            return nil
        }
        let node = dev.appendingPathComponent(names[0])
        guard FileManager.default.fileExists(atPath: node.path) else {
            return nil
        }
        return node.path
    }
}

#endif
