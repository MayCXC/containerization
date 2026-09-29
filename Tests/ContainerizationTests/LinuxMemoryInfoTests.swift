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

struct LinuxMemoryInfoTests {
    /// Lines of a 6.18 guest's /proc/meminfo, the balloon holding most of it.
    private let meminfo = """
        MemTotal:       12369100 kB
        MemFree:          330360 kB
        MemAvailable:     397276 kB
        Buffers:            9412 kB
        Cached:           213968 kB
        CommitLimit:    31350368 kB
        Committed_AS:    2859380 kB
        VmallocTotal:   135288315904 kB
        Balloon:        10616832 kB
        HugePages_Total:       0
        Hugepagesize:       2048 kB
        """

    @Test func readsTheFiguresInBytes() throws {
        let info = try LinuxMemoryInfo(meminfo: meminfo)
        #expect(
            info
                == LinuxMemoryInfo(
                    totalBytes: 12_369_100 * 1024,
                    freeBytes: 330_360 * 1024,
                    availableBytes: 397_276 * 1024,
                    committedBytes: 2_859_380 * 1024,
                    balloonBytes: 10_616_832 * 1024
                ))
    }

    @Test func leavesOutCountsWithoutAUnit() {
        let fields = LinuxMemoryInfo.fields(meminfo: meminfo)
        #expect(fields["HugePages_Total"] == nil)
        #expect(fields["Hugepagesize"] == 2048 * 1024)
        #expect(fields["VmallocTotal"] == 135_288_315_904 * 1024)
    }

    @Test func hasNoBalloonWhenTheKernelPrintsNone() throws {
        let lines = meminfo.split(separator: "\n").filter { !$0.hasPrefix("Balloon:") }
        let info = try LinuxMemoryInfo(meminfo: lines.joined(separator: "\n"))
        #expect(info.balloonBytes == nil)
    }

    @Test func requiresCommittedMemory() {
        #expect(throws: ContainerizationError.self) {
            try LinuxMemoryInfo(meminfo: "MemTotal: 1024 kB\nMemFree: 512 kB\nMemAvailable: 512 kB\n")
        }
    }
}
