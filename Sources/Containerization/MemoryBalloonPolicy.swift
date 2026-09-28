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
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// When to move a machine's balloon, as oVirt's Memory Overcommitment Manager
/// decides it for a balloon that takes only a target size:
/// https://github.com/oVirt/mom/blob/master/doc/balloon.rules
///
/// While the host has less free memory than `pressureThreshold`, each machine
/// shrinks toward what its guest uses plus a free share that narrows as the
/// host gets shorter, at most `maxChange` of its size per decision; once the
/// host is below `pressureCritical` the free share goes negative and the guest
/// is pushed into its own swap. While the host has enough, each machine grows
/// back by the same step, at once to its used memory plus `minGuestFree` when
/// it has less. A released page only leaves the host when the host needs
/// memory, so shrinking outside pressure would cost the guest and give the
/// host nothing.
public struct MemoryBalloonPolicy: Sendable, Equatable {
    /// The host free fraction below which machines shrink.
    public var pressureThreshold: Double = 0.20
    /// The host free fraction below which guests are pushed into swap.
    public var pressureCritical: Double = 0.05
    /// The free fraction a guest keeps while the host is not short.
    public var minGuestFree: Double = 0.20
    /// The largest change in one decision, as a fraction of the machine's size.
    public var maxChange: Double = 0.05
    /// Changes smaller than this fraction of the machine's size are skipped.
    public var minChange: Double = 0.0025
    /// The least a machine is asked to hold, MoM's `min_guarantee`.
    public var guaranteed: UInt64 = 0
    /// How often the guest and host are sampled, and how many samples are
    /// averaged, `guest-monitor-interval` and `sample-history-length` of
    /// https://github.com/oVirt/mom/blob/master/doc/mom-balloon.conf
    public var sampleInterval: Duration = .seconds(5)
    public var sampleHistory: Int = 10
    /// How often a decision is made, `policy-engine-interval`.
    public var decisionInterval: Duration = .seconds(10)

    public init() {}

    /// One reading of a machine and its host.
    public struct Sample: Sendable, Equatable {
        /// The fraction of the host's memory that is free, caches included.
        public var hostFree: Double
        /// The memory the machine holds now, `balloon_cur`.
        public var current: UInt64
        /// The guest's free memory, caches excluded, `mem_unused`.
        public var unused: UInt64

        public init(hostFree: Double, current: UInt64, unused: UInt64) {
            self.hostFree = hostFree
            self.current = current
            self.unused = unused
        }
    }

    /// The size to ask the machine to hold next, or nil to leave it.
    /// - Parameters:
    ///   - samples: The latest readings, oldest first; MoM averages the host's
    ///     free memory and the guest's used memory over them.
    ///   - maximum: The size the machine was created with, `balloon_max`.
    public func nextTarget(samples: [Sample], maximum: UInt64) -> UInt64? {
        guard let latest = samples.last else {
            return nil
        }
        let count = Double(samples.count)
        let hostFree = samples.map(\.hostFree).reduce(0, +) / count
        let used = samples.map { Double($0.current) }.reduce(0, +) / count - samples.map { Double($0.unused) }.reduce(0, +) / count
        let current = Double(latest.current)
        var size: Double
        if hostFree < pressureThreshold {
            let guestFree =
                hostFree <= pressureCritical
                ? -0.05 + hostFree
                : minGuestFree * (hostFree / pressureThreshold)
            let floor = max(Double(guaranteed), used + guestFree * current)
            size = max(current * (1 - maxChange), floor)
            guard size <= current else {
                return nil
            }
        } else {
            guard latest.current < maximum else {
                return nil
            }
            let floor = max(Double(guaranteed), used + minGuestFree * current)
            size = min(max(current * (1 + maxChange), floor), Double(maximum))
        }
        guard abs(size - current) > minChange * current else {
            return nil
        }
        return UInt64(max(size, 0))
    }

    /// The fraction of the host's memory that is free, caches included: on
    /// macOS the kernel's own figure (`kern.memorystatus_level`, what
    /// `memory_pressure` prints), on Linux MoM's `(MemFree + Buffers + Cached)
    /// / MemTotal` (mom/Collectors/HostMemory.py).
    public static func hostFree() throws -> Double {
        #if canImport(Darwin)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else {
            throw ContainerizationError(.internalError, message: "reading kern.memorystatus_level failed: errno \(errno)")
        }
        return Double(level) / 100
        #else
        let meminfo = try String(contentsOfFile: "/proc/meminfo", encoding: .utf8)
        var fields: [Substring: Double] = [:]
        for line in meminfo.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let value = Double(parts[1]) else { continue }
            fields[parts[0].dropLast()] = value
        }
        guard let total = fields["MemTotal"], total > 0 else {
            throw ContainerizationError(.internalError, message: "/proc/meminfo has no MemTotal")
        }
        return ((fields["MemFree"] ?? 0) + (fields["Buffers"] ?? 0) + (fields["Cached"] ?? 0)) / total
        #endif
    }
}

/// Drives one machine's balloon by `MemoryBalloonPolicy`.
public actor MemoryBalloonController {
    /// What the controller has done, for logs and tests.
    public struct Report: Sendable {
        public var samples = 0
        public var decisions = 0
        public var applied = 0
        public var failures = 0
        public var lastSample: MemoryBalloonPolicy.Sample?
        public var lastTarget: UInt64?
    }

    private let policy: MemoryBalloonPolicy
    private var samples: [MemoryBalloonPolicy.Sample] = []
    private var report = Report()

    public init(policy: MemoryBalloonPolicy) {
        self.policy = policy
    }

    public func currentReport() -> Report {
        report
    }

    /// Sample on the policy's cadence and decide on its own until cancelled.
    /// A failed sample or change is counted and the loop goes on.
    public func run(
        hostFree: @Sendable () throws -> Double = MemoryBalloonPolicy.hostFree,
        statistics: @Sendable () async throws -> VirtualMachineMemoryStatistics,
        apply: @Sendable (_ target: UInt64, _ current: UInt64) async throws -> Void
    ) async {
        let clock = ContinuousClock()
        var nextDecision = clock.now + policy.decisionInterval
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: policy.sampleInterval)
            } catch {
                return
            }
            let stats: VirtualMachineMemoryStatistics
            do {
                stats = try await statistics()
                let current = stats.memorySize - min(stats.balloonSize, stats.memorySize)
                guard let unused = stats.guest?.freeMemory else {
                    continue
                }
                record(.init(hostFree: try hostFree(), current: current, unused: unused))
            } catch {
                report.failures += 1
                continue
            }
            guard clock.now >= nextDecision else {
                continue
            }
            nextDecision = clock.now + policy.decisionInterval
            report.decisions += 1
            guard let current = samples.last?.current, let target = policy.nextTarget(samples: samples, maximum: stats.memorySize) else {
                continue
            }
            do {
                try await apply(target, current)
                report.applied += 1
                report.lastTarget = target
            } catch {
                report.failures += 1
            }
        }
    }

    private func record(_ sample: MemoryBalloonPolicy.Sample) {
        samples.append(sample)
        if samples.count > policy.sampleHistory {
            samples.removeFirst(samples.count - policy.sampleHistory)
        }
        report.samples += 1
        report.lastSample = sample
    }
}
