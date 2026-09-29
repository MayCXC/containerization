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

/// When a guest compacts its memory, and for how long, decided as the
/// compaction of Kata Containers' mem-agent decides it. The settings are
/// mem-agent's, with its defaults but for `order`:
/// https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/src/libs/mem-agent/src/compact.rs
/// https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/docs/how-to/how-to-use-memory-agent.md
///
/// mem-agent compacts on its timer, for free page reporting to hand the
/// host whole blocks. A machine here compacts before its balloon takes
/// pages, as Virtualization asks of a guest, so that what the guest gives up
/// fills whole host pages:
/// https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice
/// and mem-agent's timer spaces those attempts rather than making them.
/// mem-agent can also force a compaction after a number of skipped
/// attempts; that is off by default, and left out.
public struct MemoryCompactionPolicy: Sendable, Equatable {
    /// The least time from one attempt to the next (`period_secs`), in whole
    /// seconds as mem-agent counts it.
    public var period: Duration = .seconds(10 * 60)
    /// An attempt is skipped when memory and IO stalled for more than this
    /// percentage of the time since the last attempt
    /// (`period_psi_percent_limit`).
    public var periodPressureLimit: UInt64 = 1
    /// A compaction is stopped when memory and IO stall for more than this
    /// percentage of a second while it runs (`compact_psi_percent_limit`).
    public var compactionPressureLimit: UInt64 = 5
    /// A compaction is stopped after this long (`compact_sec_max`), in whole
    /// seconds.
    public var compactionTimeLimit: Duration = .seconds(5 * 60)
    /// The order of the free blocks compaction is for (`compact_order`):
    /// free blocks below it count as fragments. mem-agent's 9 is the order
    /// free page reporting hands over. The balloon hands the host a page once
    /// every guest page in it is ballooned, so here it is 2, a 16 KiB host
    /// page of Apple silicon over the 4 KiB pages of a guest.
    public var order: Int = 2
    /// How far the guest has to move after one compaction for another to be
    /// worth it, in pages (`compact_threshold`): its free memory has to fall
    /// by more than this, or its fragments grow by more.
    public var threshold: UInt64 = 1024

    public init() {}

    /// What became of an attempt to compact.
    public enum Outcome: Sendable, Equatable {
        /// The guest compacted, until done or stopped by its limits.
        case compacted
        /// Less than `period` had passed since the last attempt.
        case notDue
        /// Memory and IO stalled for more than `periodPressureLimit` of the
        /// time since the last attempt.
        case underPressure
        /// The guest's memory had not moved far enough since the last
        /// compaction.
        case notFragmented
    }

    /// What the guest's memory looks like to `threshold`.
    public struct Reading: Sendable, Equatable {
        /// The guest's free memory, `MemFree`.
        public var freeBytes: UInt64
        /// The free movable pages in blocks below `order`, counted in pages.
        public var fragmentedPages: UInt64

        public init(freeBytes: UInt64, fragmentedPages: UInt64) {
            self.freeBytes = freeBytes
            self.fragmentedPages = fragmentedPages
        }
    }

    /// Whether the guest has moved far enough since `last`, the reading
    /// taken after the last compaction, for another to be worth it
    /// (`check_compact_threshold`). Before the first compaction `last` is all
    /// zeros, so only fragments can call for one.
    public func worthCompacting(_ reading: Reading, since last: Reading, pageSize: UInt64) -> Bool {
        if last.freeBytes > reading.freeBytes + threshold * pageSize {
            return true
        }
        return reading.fragmentedPages > threshold + last.fragmentedPages
    }

    /// The free movable pages in blocks below `order`, from the text of
    /// `/proc/pagetypeinfo` (`calculate_free_movable_pages`). Each row whose
    /// type is `Movable` counts a zone's free blocks of each order from 0 up,
    /// and a block of order n is 2^n pages.
    public func fragmentedPages(pagetypeinfo: String) -> UInt64 {
        var pages: UInt64 = 0
        for line in pagetypeinfo.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let type = fields.firstIndex(of: "Movable") else {
                continue
            }
            for (order, count) in fields[(type + 1)...].enumerated() where order < self.order {
                if let count = UInt64(count) {
                    pages += count << order
                }
            }
        }
        return pages
    }
}

/// How much of a stretch of time tasks spent stalled on memory and IO, from
/// Linux's pressure stall information, as mem-agent's `psi::Period` measures
/// it: https://docs.kernel.org/accounting/psi.html
/// https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/src/libs/mem-agent/src/psi.rs
///
/// mem-agent reads the wall clock; this takes a monotonic one, since the host
/// steps a guest's wall clock whenever it resumes.
public struct PressureStallPeriod: Sendable {
    private var lastTotal: UInt64 = 0
    private var lastTime: ContinuousClock.Instant?

    public init() {}

    /// The microseconds some task stalled, in total, from the text of a
    /// pressure file such as `memory.pressure`, whose first line reads
    /// `some avg10=0.00 avg60=0.00 avg300=0.00 total=37820`
    /// (`read_pressure_some_total`).
    public static func someTotal(pressure: String) throws -> UInt64 {
        guard let line = pressure.split(separator: "\n").first else {
            throw ContainerizationError(.invalidArgument, message: "pressure file is empty")
        }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count > 4 else {
            throw ContainerizationError(.invalidArgument, message: "pressure line '\(line)' has no total")
        }
        let total = fields[4].split(separator: "=", omittingEmptySubsequences: false)
        guard total.count > 1, let microseconds = UInt64(total[1]) else {
            throw ContainerizationError(.invalidArgument, message: "pressure line '\(line)' has no total")
        }
        return microseconds
    }

    /// The percentage of the time since the last reading that some task
    /// stalled, given `total`, the stall totals of memory and IO added
    /// together; 0 for the first reading (`get_percent`).
    public mutating func percent(total: UInt64, at now: ContinuousClock.Instant) -> UInt64 {
        var percent: UInt64 = 0
        if let lastTime, lastTotal != 0, lastTotal < total, lastTime < now {
            // Whole milliseconds, as mem-agent takes the elapsed time.
            let elapsed = (now - lastTime).components
            let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            let microseconds = UInt64(milliseconds) * 1000
            if microseconds > 0 {
                percent = (total - lastTotal) * 100 / microseconds
            }
        }
        lastTotal = total
        lastTime = now
        return percent
    }
}
