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
import ContainerizationOS
import Foundation
import Synchronization
import Testing

@testable import Containerization

/// Hyper-V's target moved by oVirt MoM's rules, worked by hand.
struct MemoryBalloonPolicyTests {
    private let policy = MemoryBalloonPolicy()
    private let maximum: UInt64 = 12 * 1024.mib()

    /// A reading whose guest has everything it holds available unless told
    /// otherwise.
    private func sample(hostFree: Double = 0.5, current: UInt64, needs: UInt64, available: UInt64? = nil, floor: UInt64 = 0) -> MemoryBalloonPolicy.Sample {
        .init(hostFree: hostFree, current: current, needs: needs, available: available ?? current, floor: floor)
    }

    private func target(_ samples: MemoryBalloonPolicy.Sample..., policy: MemoryBalloonPolicy? = nil) -> UInt64? {
        (policy ?? self.policy).nextTarget(samples: samples, maximum: maximum)
    }

    /// Whether `value` is within a byte of `expected`, which the policy's
    /// floating point arithmetic needs.
    private func near(_ value: UInt64?, _ expected: Double) -> Bool {
        guard let value else {
            return false
        }
        return abs(Double(value) - expected) <= 1
    }

    @Test func holdsWhatTheGuestNeedsPlusTheBuffer() {
        // Hyper-V's example, 1000 MB committed with a 20% buffer is 1200 MB,
        // with the host far from short.
        #expect(near(target(sample(current: 1250.mib(), needs: 1000.mib())), Double(1200.mib())))
    }

    @Test func shrinksByAtMostTheLargestStep() {
        let current: UInt64 = 8 * 1024.mib()
        #expect(near(target(sample(current: current, needs: 1024.mib())), Double(current) * 0.95))
    }

    @Test func growsToTheTargetAtOnce() {
        // 3 GiB needed wants 3.6 GiB, reached in one step from 1 GiB.
        #expect(near(target(sample(current: 1024.mib(), needs: 3072.mib())), Double(3072.mib()) * 1.2))
    }

    @Test func growsNoFurtherThanTheMachine() {
        #expect(target(sample(current: 8 * 1024.mib(), needs: 11 * 1024.mib())) == maximum)
    }

    @Test func narrowsTheBufferAsTheHostRunsShort() {
        // At 10% free the buffer is 20% * (10% / 20%) = 10%.
        #expect(near(target(sample(hostFree: 0.10, current: 1120.mib(), needs: 1000.mib())), Double(1000.mib()) * 1.1))
    }

    @Test func holdsTheGuestUnderItsNeedsWhenThePressureIsCritical() {
        // At 3% free the buffer is -5% + 3% = -2%.
        #expect(near(target(sample(hostFree: 0.03, current: 1000.mib(), needs: 1000.mib())), Double(1000.mib()) * 0.98))
    }

    @Test func averagesTheHostAndTheGuestButMovesFromWhatTheMachineHoldsNow() {
        // Averaged, the guest needs 1000 MiB and the host has 30% free, so the
        // whole buffer applies, and the step is from the last sample's size.
        let next = target(
            sample(hostFree: 0.10, current: 2000.mib(), needs: 1100.mib()),
            sample(hostFree: 0.50, current: 1250.mib(), needs: 900.mib())
        )
        #expect(near(next, Double(1000.mib()) * 1.2))
    }

    @Test func growsForARisingNeedWithoutWaitingForTheAverage() {
        // The average of these needs is 1500 MiB; the last, 3000 MiB, decides.
        let next = target(
            sample(current: 1250.mib(), needs: 1000.mib()),
            sample(current: 1250.mib(), needs: 1000.mib()),
            sample(current: 1250.mib(), needs: 1000.mib()),
            sample(current: 1250.mib(), needs: 3000.mib())
        )
        #expect(near(next, Double(3000.mib()) * 1.2))
    }

    @Test func skipsChangesTooSmallToBeWorthIt() {
        // 1 MiB is under 0.25% of 1201 MiB.
        #expect(target(sample(current: 1201.mib(), needs: 1000.mib())) == nil)
    }

    @Test func keepsTheMinimum() {
        var policy = self.policy
        policy.minimum = 2048.mib()
        #expect(target(sample(current: 2100.mib(), needs: 1000.mib()), policy: policy) == 2048.mib())
    }

    @Test func takesNothingBelowTheGuestsFloor() {
        // The guest has 30 MiB available above its floor, less than the 5% step.
        #expect(near(target(sample(current: 1000.mib(), needs: 500.mib(), available: 280.mib(), floor: 250.mib())), Double(970.mib())))
    }

    @Test func holdsAGuestWithNothingAvailableAboveItsFloor() {
        #expect(target(sample(current: 1000.mib(), needs: 500.mib(), available: 200.mib(), floor: 250.mib())) == nil)
    }

    @Test func readsAMachineFromWhatItsGuestReports() throws {
        // A 2176 MiB machine whose kernel manages 2048 MiB holds 1152 MiB with
        // 1024 MiB in its balloon. Its guest holds 1024 MiB, whose floor is
        // 104 MiB + 1024 MiB / 8, and the machine needs the 128 MiB its kernel
        // set aside at boot as well.
        let info = LinuxMemoryInfo(totalBytes: 2048.mib(), freeBytes: 0, availableBytes: 400.mib(), committedBytes: 300.mib(), balloonBytes: 1024.mib())
        let sample = try MemoryBalloonPolicy.Sample(hostFree: 0.5, size: 2176.mib(), info: info)
        #expect(sample == .init(hostFree: 0.5, current: 1152.mib(), needs: 300.mib() + 232.mib() + 128.mib(), available: 400.mib(), floor: 232.mib()))
    }

    @Test func needsTheGuestToReportItsBalloon() {
        let info = LinuxMemoryInfo(totalBytes: 2048.mib(), freeBytes: 0, availableBytes: 400.mib(), committedBytes: 300.mib(), balloonBytes: nil)
        #expect(throws: ContainerizationError.self) {
            try MemoryBalloonPolicy.Sample(hostFree: 0.5, size: 2176.mib(), info: info)
        }
    }

    @Test func balloonFloorFollowsHvBalloonsTable() {
        // The table in the comment of hv_balloon's compute_balloon_floor, in MiB.
        let table: [(memory: UInt64, floor: UInt64)] = [(16, 16), (32, 24), (128, 72), (512, 168), (2048, 360), (8192, 744), (32768, 1512)]
        for row in table {
            #expect(MemoryBalloonPolicy.balloonFloor(row.memory.mib()) == row.floor.mib())
        }
    }

    /// A machine that holds whatever it was last asked to, whose kernel
    /// manages all of it but `unmanaged` and uses 32 MiB beyond what its
    /// processes have committed.
    private final class Machine: Sendable {
        let size: UInt64
        let unmanaged: UInt64
        let committed: UInt64
        let held: Mutex<UInt64>
        let changes = Mutex<[(target: UInt64, current: UInt64)]>([])

        init(size: UInt64, unmanaged: UInt64, committed: UInt64) {
            self.size = size
            self.unmanaged = unmanaged
            self.committed = committed
            self.held = Mutex(size)
        }

        func memoryInfo() -> LinuxMemoryInfo {
            let total = size - unmanaged
            let balloon = size - held.withLock { $0 }
            let guestHeld = total - min(balloon, total)
            let used = committed + 32.mib()
            return LinuxMemoryInfo(
                totalBytes: total,
                freeBytes: 0,
                availableBytes: guestHeld - min(used, guestHeld),
                committedBytes: committed,
                balloonBytes: balloon
            )
        }

        func apply(_ target: UInt64, from current: UInt64) {
            changes.withLock { $0.append((target, current)) }
            held.withLock { $0 = target }
        }
    }

    @Test func controllerSettlesAMachineAtItsTarget() async throws {
        var policy = MemoryBalloonPolicy()
        policy.sampleInterval = .milliseconds(5)
        policy.decisionInterval = .milliseconds(10)
        policy.sampleHistory = 2
        let machine = Machine(size: 4096.mib(), unmanaged: 64.mib(), committed: 500.mib())
        let controller = MemoryBalloonController(policy: policy, maximum: machine.size)
        let task = Task {
            await controller.run(
                hostFree: { 0.5 },
                memoryInfo: { machine.memoryInfo() },
                apply: { target, current in machine.apply(target, from: current) }
            )
        }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        await task.value

        // The machine settles where what it holds, h, is 1.2 times the
        // 500 MiB committed, the floor of the h - 64 MiB its guest holds
        // (104 MiB + (h - 64 MiB) / 8) and the 64 MiB set aside at boot:
        // h = 1.2 * (660 MiB + h / 8), about 931.8 MiB, which from 4 GiB takes
        // twenty-nine shrinks of at most 5%, with the guest's floor never
        // reached.
        let settled = 1.2 * 660 / 0.85 * Double(1.mib())
        let held = Double(machine.held.withLock { $0 })
        #expect(abs(held - settled) < 0.01 * settled)
        let changes = machine.changes.withLock { $0 }
        #expect(changes.count >= 29)
        for change in changes where change.target < change.current {
            #expect(Double(change.target) >= Double(change.current) * 0.95 - 1)
        }
        let report = await controller.currentReport()
        #expect(report.shrinks == changes.count)
        #expect(report.failures == 0)
    }
}
