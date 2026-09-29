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
import Darwin
import Foundation

/// The process Virtualization runs a machine in, which holds the guest's RAM
/// and is the one macOS charges for it.
struct VirtualMachineHelper {
    static let executable = "com.apple.Virtualization.VirtualMachine"

    let pid: pid_t

    /// Every machine's helper running now, this suite's and any other's.
    static func running() throws -> Set<pid_t> {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", executable]
        let output = Pipe()
        pgrep.standardOutput = output
        try pgrep.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return Set(text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// The helper that appeared since `before` was taken, or nil when none did
    /// or when other tests started machines at the same time and it cannot be
    /// told apart.
    static func started(after before: Set<pid_t>, timeout: Duration = .seconds(10)) async throws -> VirtualMachineHelper? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let new = try running().subtracting(before)
            if new.count == 1, let pid = new.first {
                return VirtualMachineHelper(pid: pid)
            }
            guard new.isEmpty else {
                return nil
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// The helper's physical footprint in bytes, the figure Activity Monitor
    /// shows and memory pressure decisions use.
    func footprint() throws -> UInt64 {
        try usage().ri_phys_footprint
    }

    func usage() throws -> rusage_info_v2 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else {
            throw IntegrationError.assert(msg: "proc_pid_rusage(\(pid)) failed: errno \(errno)")
        }
        return usage
    }

    /// What the helper holds, in MiB: its whole footprint, and the part of it
    /// in RAM rather than compressed or swapped.
    func describe() throws -> String {
        let usage = try usage()
        return "footprint=\(usage.ri_phys_footprint >> 20) resident=\(usage.ri_resident_size >> 20)"
    }
}

extension UInt64 {
    /// How far this reading has fallen below `later`, or zero if it has not.
    func saturatingSubtract(_ later: UInt64) -> UInt64 {
        self > later ? self - later : 0
    }
}
#endif
