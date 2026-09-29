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

import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Compacts the guest's memory when a ``MemoryCompactionPolicy`` calls for
/// it, as `Compact::work` in Kata's mem-agent does:
/// https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/src/libs/mem-agent/src/compact.rs
///
/// Memory and IO pressure come from the root cgroup, where mem-agent reads
/// them on cgroup v2 (psi.rs), and compaction runs in a child it can kill,
/// since a write to `/proc/sys/vm/compact_memory` returns only once the
/// kernel has compacted every zone, or once the writer is killed.
actor MemoryCompactor {
    private static let cgroup = URL(filePath: "/sys/fs/cgroup")

    private let log: Logger
    /// When the last attempt ended; mem-agent's timer.
    private var lastAttempt: ContinuousClock.Instant?
    /// The reading after the last compaction.
    private var last = MemoryCompactionPolicy.Reading(freeBytes: 0, fragmentedPages: 0)
    /// The stall since the last attempt.
    private var period = PressureStallPeriod()
    private var pressureChecked = false

    init(log: Logger) {
        self.log = log
    }

    func compact(_ policy: MemoryCompactionPolicy) async throws -> MemoryCompactionPolicy.Outcome {
        if !pressureChecked {
            try Self.checkPressure()
            pressureChecked = true
        }
        if let lastAttempt, ContinuousClock.now < lastAttempt + policy.period {
            return .notDue
        }
        let outcome = try await work(policy)
        lastAttempt = .now
        return outcome
    }

    private func work(_ policy: MemoryCompactionPolicy) async throws -> MemoryCompactionPolicy.Outcome {
        let percent = period.percent(total: try Self.pressureTotal(), at: .now)
        if percent > policy.periodPressureLimit {
            log.info("compaction skipped: memory and IO stalled \(percent)% of the time since the last attempt")
            return .underPressure
        }

        let reading = try Self.reading(policy)
        guard policy.worthCompacting(reading, since: last, pageSize: Self.pageSize) else {
            log.info(
                "compaction skipped: memory has not moved far enough since the last compaction",
                metadata: [
                    "fragmented_pages": "\(reading.fragmentedPages)",
                    "fragmented_pages_after_last": "\(last.fragmentedPages)",
                    "threshold_pages": "\(policy.threshold)",
                    "free_bytes": "\(reading.freeBytes)",
                    "free_bytes_after_last": "\(last.freeBytes)",
                ])
            return .notFragmented
        }

        try await runCompaction(policy)
        last = try Self.reading(policy)
        return .compacted
    }

    /// Compact until the kernel is done, `compactionTimeLimit` has passed, or
    /// memory and IO stall for more than `compactionPressureLimit` of a
    /// second (`do_compact`).
    private func runCompaction(_ policy: MemoryCompactionPolicy) async throws {
        var pressure = PressureStallPeriod()
        var remaining = policy.compactionTimeLimit.components.seconds

        sched_yield()
        log.info("compaction start")

        let runner = ProcessSupervisor.default.reaperCommandRunner
        var command = Command("/sbin/vminitd", arguments: ["compact"])
        command.stderr = .standardError
        let subscription = try runner.start(&command)
        let pid = command.pid
        let exit = ExitStatus()
        Task { [command] in
            if let status = try? await runner.wait(command, subscription: subscription) {
                exit.set(status)
            }
        }
        log.debug("compaction pid \(pid)")

        var killed = false
        while true {
            if let status = exit.value {
                log.debug("compaction exited with status \(status)")
                break
            }
            if killed {
                if remaining <= 0 {
                    log.error("compaction was killed but has not exited")
                    break
                }
            } else if remaining <= 0 {
                log.debug("compaction timed out")
                kill(pid, SIGKILL)
                killed = true
            }

            let percent: UInt64
            do {
                percent = pressure.percent(total: try Self.pressureTotal(), at: .now)
            } catch {
                // Left running, the compaction would have no limit at all.
                kill(pid, SIGKILL)
                throw error
            }
            if percent > policy.compactionPressureLimit {
                log.info("compaction stopped: memory and IO stalled \(percent)% of the last second")
                kill(pid, SIGKILL)
                killed = true
            }

            try? await Task.sleep(for: .seconds(1))
            remaining -= 1
        }

        log.info("compaction stop")
    }

    private static var pageSize: UInt64 {
        UInt64(sysconf(Int32(_SC_PAGESIZE)))
    }

    /// Free memory and fragments now. `MemFree` is the kernel's count of free
    /// pages, which sysinfo(2) reports as `freeram`.
    private static func reading(_ policy: MemoryCompactionPolicy) throws -> MemoryCompactionPolicy.Reading {
        var info = sysinfo()
        guard sysinfo(&info) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }
        let pagetypeinfo = try String(contentsOfFile: "/proc/pagetypeinfo", encoding: .utf8)
        return .init(
            freeBytes: UInt64(info.freeram) * UInt64(info.mem_unit),
            fragmentedPages: policy.fragmentedPages(pagetypeinfo: pagetypeinfo)
        )
    }

    /// The microseconds some task stalled on memory and on IO, added together.
    private static func pressureTotal() throws -> UInt64 {
        var total: UInt64 = 0
        for file in ["memory.pressure", "io.pressure"] {
            let text = try String(contentsOf: cgroup.appending(path: file), encoding: .utf8)
            total += try PressureStallPeriod.someTotal(pressure: text)
        }
        return total
    }

    /// Fail unless the kernel reports memory pressure, as mem-agent refuses to
    /// start without it (`psi::check`).
    private static func checkPressure() throws {
        let path = cgroup.appending(path: "memory.pressure").path
        let fd = open(path, O_RDWR)
        guard fd >= 0 else {
            throw ContainerizationError(
                .unsupported,
                message: "compaction needs pressure stall information, which \(path) did not give (errno \(errno)): "
                    + "boot the guest with psi=1 on a kernel built with CONFIG_PSI"
            )
        }
        close(fd)
    }
}

/// The exit status of a child, once the reaper has collected it.
private final class ExitStatus: Sendable {
    private let status = Mutex<Int32?>(nil)

    func set(_ value: Int32) {
        status.withLock { $0 = value }
    }

    var value: Int32? {
        status.withLock { $0 }
    }
}

#endif
