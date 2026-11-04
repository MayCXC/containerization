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
import Testing

@testable import Containerization

/// mem-agent's compaction, worked by hand.
struct MemoryCompactionTests {
    /// `/proc/pagetypeinfo` from a 6.18 guest with 4 KiB pages.
    private let pagetypeinfo = """
        Page block order: 9
        Pages per block:  512

        Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
        Node    0, zone      DMA, type    Unmovable    157    586    393    245    130     61     37     19      3      0      0
        Node    0, zone      DMA, type      Movable      1      1      1      1      0      0      1      0      0      0     24
        Node    0, zone      DMA, type  Reclaimable      1      1      8      2      6      0      1      2      0      0      0
        Node    0, zone      DMA, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0
        Node    0, zone      DMA, type      Isolate      0      0      0      0      0      0      0      0      0      0      0
        Node    0, zone   Normal, type    Unmovable    926    629    321     54     77     37     14      5      4      0      0
        Node    0, zone   Normal, type      Movable    125      0      0      0      0      0      0      0      0      0      0
        Node    0, zone   Normal, type  Reclaimable     88     74      9     35     27     16      5      5      1      0      0
        Node    0, zone   Normal, type   HighAtomic      0      0      1      1      1      1      1      1      1      0      0
        Node    0, zone   Normal, type      Isolate      0      0      0      0      0      0      0      0      0      0      0

        Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic      Isolate
        Node 0, zone      DMA           44         1106            2            0            0
        Node 0, zone   Normal           51         4992           12            1            0

        """

    @Test func countsTheMovableFragmentsBelowTheOrder() {
        // Orders 0 and 1 of the movable rows: 1 + 1 * 2 in DMA, 125 in Normal.
        #expect(MemoryCompactionPolicy().fragmentedPages(pagetypeinfo: pagetypeinfo) == 128)
    }

    @Test func countsTheBlocksFreePageReportingCannotTakeAtMemAgentsOrder() {
        // Orders 0 through 8: 1 + 2 + 4 + 8 + 64 in DMA, 125 in Normal.
        var policy = MemoryCompactionPolicy()
        policy.order = 9
        #expect(policy.fragmentedPages(pagetypeinfo: pagetypeinfo) == 204)
    }

    @Test func compactsFirstForFragmentsAlone() {
        let policy = MemoryCompactionPolicy()
        let never = MemoryCompactionPolicy.Reading(freeBytes: 0, fragmentedPages: 0)
        #expect(!policy.worthCompacting(.init(freeBytes: 1 << 30, fragmentedPages: 1024), since: never, pageSize: 4096))
        #expect(policy.worthCompacting(.init(freeBytes: 1 << 30, fragmentedPages: 1025), since: never, pageSize: 4096))
    }

    @Test func compactsAgainOnceTheFragmentsGrowPastTheThreshold() {
        let policy = MemoryCompactionPolicy()
        let last = MemoryCompactionPolicy.Reading(freeBytes: 1 << 30, fragmentedPages: 300)
        #expect(!policy.worthCompacting(.init(freeBytes: 1 << 30, fragmentedPages: 1324), since: last, pageSize: 4096))
        #expect(policy.worthCompacting(.init(freeBytes: 1 << 30, fragmentedPages: 1325), since: last, pageSize: 4096))
    }

    @Test func compactsAgainOnceFreeMemoryFallsPastTheThreshold() {
        // 1024 pages of 4 KiB are 4 MiB.
        let policy = MemoryCompactionPolicy()
        let last = MemoryCompactionPolicy.Reading(freeBytes: 1 << 30, fragmentedPages: 300)
        let fallen: UInt64 = 4 << 20
        #expect(!policy.worthCompacting(.init(freeBytes: (1 << 30) - fallen, fragmentedPages: 0), since: last, pageSize: 4096))
        #expect(policy.worthCompacting(.init(freeBytes: (1 << 30) - fallen - 1, fragmentedPages: 0), since: last, pageSize: 4096))
    }

    @Test func readsTheStallTotalFromAPressureFile() throws {
        // mem-agent's own test file.
        let pressure = """
            some avg10=0.00 avg60=0.00 avg300=0.00 total=37820
            full avg10=0.00 avg60=0.00 avg300=0.00 total=28881

            """
        #expect(try PressureStallPeriod.someTotal(pressure: pressure) == 37820)
    }

    @Test func refusesAPressureFileWithNoTotal() {
        #expect(throws: ContainerizationError.self) {
            try PressureStallPeriod.someTotal(pressure: "")
        }
        #expect(throws: ContainerizationError.self) {
            try PressureStallPeriod.someTotal(pressure: "some avg10=0.00 avg60=0.00 avg300=0.00\n")
        }
        #expect(throws: ContainerizationError.self) {
            try PressureStallPeriod.someTotal(pressure: "some avg10=0.00 avg60=0.00 avg300=0.00 total=\n")
        }
    }

    @Test func measuresTheShareOfTimeStalledSinceTheLastReading() {
        var period = PressureStallPeriod()
        let start = ContinuousClock.now
        // Nothing to measure against at first.
        #expect(period.percent(total: 1_000_000, at: start) == 0)
        // 50 ms stalled in a second is 5%.
        #expect(period.percent(total: 1_050_000, at: start + .seconds(1)) == 5)
        // 9.99 ms in a second rounds down to nothing.
        #expect(period.percent(total: 1_059_990, at: start + .seconds(2)) == 0)
        // The time between is taken in whole milliseconds, so 10.005 ms in
        // 1000.9 ms counts as 1%.
        #expect(period.percent(total: 1_069_995, at: start + .seconds(3) + .microseconds(900)) == 1)
        // 30 ms in the second since the reading before is 3%.
        #expect(period.percent(total: 1_099_995, at: start + .seconds(4) + .microseconds(900)) == 3)
    }

    @Test func measuresNothingWhenTheTotalHasNotGrown() {
        var period = PressureStallPeriod()
        let start = ContinuousClock.now
        _ = period.percent(total: 5000, at: start)
        #expect(period.percent(total: 5000, at: start + .seconds(1)) == 0)
        #expect(period.percent(total: 4000, at: start + .seconds(2)) == 0)
        // Measured from the lower total now.
        #expect(period.percent(total: 24000, at: start + .seconds(3)) == 2)
    }
}
