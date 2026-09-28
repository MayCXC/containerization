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
import Foundation
import Testing

@testable import Containerization

/// The cases of oVirt MoM's doc/balloon.rules, worked by hand.
struct MemoryBalloonPolicyTests {
    private let policy = MemoryBalloonPolicy()
    private let maximum: UInt64 = 12 * 1024.mib()

    private func sample(hostFree: Double, current: UInt64, used: UInt64) -> MemoryBalloonPolicy.Sample {
        .init(hostFree: hostFree, current: current, unused: current - used)
    }

    @Test func holdsAFullMachineWhileTheHostHasMemory() {
        let target = policy.nextTarget(samples: [sample(hostFree: 0.5, current: maximum, used: 2048.mib())], maximum: maximum)
        #expect(target == nil)
    }

    @Test func shrinksByTheLargestStepUnderPressure() {
        // Free share 0.20 * (0.10 / 0.20) = 10%, floor 2 GiB + 1 GiB = 3 GiB,
        // so the 5% step from 10 GiB is what decides.
        let current: UInt64 = 10 * 1024.mib()
        let target = policy.nextTarget(samples: [sample(hostFree: 0.10, current: current, used: 2048.mib())], maximum: maximum)
        #expect(target == UInt64(Double(current) * 0.95))
    }

    @Test func shrinksNoFurtherThanUsedPlusTheFreeShare() {
        // Floor 2048 + 10% of 2400 = 2288 MiB lies above the 5% step to 2280.
        let current: UInt64 = 2400.mib()
        let used: UInt64 = 2048.mib()
        let target = policy.nextTarget(samples: [sample(hostFree: 0.10, current: current, used: used)], maximum: maximum)
        let floor = Double(used) + 0.10 * Double(current)
        #expect(target == UInt64(floor))
    }

    @Test func pushesTheGuestBelowWhatItUsesWhenThePressureIsCritical() {
        // At 3% free the share is -0.05 + 0.03 = -2% of the machine.
        let current: UInt64 = 2100.mib()
        let used: UInt64 = 2048.mib()
        let target = policy.nextTarget(samples: [sample(hostFree: 0.03, current: current, used: used)], maximum: maximum)
        #expect(target.map { $0 < used } == true)
    }

    @Test func growsAtOnceToUsedPlusTheFreeShareOnceTheHostRecovers() {
        // Floor 4.5 GiB + 20% of 5 GiB = 5.5 GiB, above the 5% step to 5.25 GiB.
        let current: UInt64 = 5 * 1024.mib()
        let used: UInt64 = 4608.mib()
        let target = policy.nextTarget(samples: [sample(hostFree: 0.5, current: current, used: used)], maximum: maximum)
        #expect(target == UInt64(Double(used) + 0.20 * Double(current)))
    }

    @Test func growsNoFurtherThanTheMachine() {
        let current = maximum - 256.mib()
        let target = policy.nextTarget(samples: [sample(hostFree: 0.5, current: current, used: 1024.mib())], maximum: maximum)
        #expect(target == maximum)
    }

    @Test func skipsChangesTooSmallToBeWorthIt() {
        // 10 MiB is under 0.25% of 10 GiB.
        let current: UInt64 = 10 * 1024.mib()
        let target = policy.nextTarget(samples: [sample(hostFree: 0.5, current: current, used: 1024.mib())], maximum: current + 10.mib())
        #expect(target == nil)
    }

    @Test func averagesTheSamples() {
        // Averaged, the host has 25% free, which is not under the threshold.
        let current: UInt64 = 8 * 1024.mib()
        let samples = [
            sample(hostFree: 0.10, current: current, used: 1024.mib()),
            sample(hostFree: 0.40, current: current, used: 1024.mib()),
        ]
        let target = policy.nextTarget(samples: samples, maximum: current)
        #expect(target == nil)
    }

    @Test func keepsTheGuarantee() {
        var guaranteed = policy
        guaranteed.guaranteed = 4096.mib()
        let current: UInt64 = 4200.mib()
        let target = guaranteed.nextTarget(samples: [sample(hostFree: 0.03, current: current, used: 512.mib())], maximum: maximum)
        #expect(target == 4096.mib())
    }

    @Test func parsesTheGuestsStatistics() throws {
        var data = Data()
        for (tag, value) in [(UInt16(4), UInt64(1 << 30)), (5, 2 << 30), (99, 7), (6, 3 << 29)] {
            withUnsafeBytes(of: tag.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let statistics = try #require(GuestMemoryStatistics(virtioStatistics: data))
        #expect(statistics.freeMemory == 1 << 30)
        #expect(statistics.totalMemory == 2 << 30)
        #expect(statistics.availableMemory == 3 << 29)
        #expect(GuestMemoryStatistics(virtioStatistics: data.dropLast()) == nil)
    }
}
