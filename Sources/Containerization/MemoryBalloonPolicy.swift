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
import Logging

#if canImport(Darwin)
import Darwin
#endif

/// How much memory a machine's balloon should leave it, and how fast to get
/// there: a line-by-line translation of `MemoryBalloonPolicy.rules`, the
/// policy written in the language of oVirt's Memory Overcommitment Manager.
/// MoM's own engine runs that file to record the decisions the unit tests
/// hold this translation to (scripts/memory-balloon-policy-decisions.py).
///
/// The target is Hyper-V Dynamic Memory's: what the guest needs plus a buffer
/// of `buffer` times that, whether the host is short or not, so a machine
/// gives back what its guest does not need and takes back what it comes to
/// need:
/// https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/hh831766(v=ws.11)
/// That page's formula for the buffer divides where its worked example
/// multiplies (1000 MB committed with a 20% buffer is 1200 MB); this follows
/// the example. What the guest needs is measured the way Linux reports it to
/// Hyper-V (`Sample.init(hostFree:size:info:)`), and the balloon never takes
/// the guest's available memory below the floor that measure includes, which
/// Linux's Hyper-V balloon refuses to do itself.
///
/// When the host is short, Hyper-V gives up the buffer first and then relies
/// on the guest's own paging, without publishing by how much. oVirt's Memory
/// Overcommitment Manager publishes that for a balloon that takes only a
/// target size, and its rules decide it here:
/// https://github.com/oVirt/mom/blob/master/doc/balloon.rules
/// Below `pressureThreshold` of the host's memory free, the buffer narrows in
/// proportion to what is free; at or below `pressureCritical` it goes negative,
/// so the machine is held under what its guest needs and the guest pages rather
/// than grows, though the balloon still takes nothing below the floor. A
/// machine shrinks by at most `maxShrink` of what it holds per decision and
/// grows to its target at once, as MoM grows a guest short of its desired free
/// memory, and changes under `minChange` are skipped.
public struct MemoryBalloonPolicy: Sendable, Equatable {
    /// Hyper-V's memory buffer, as a fraction of what the guest needs, the
    /// policy's `memory_buffer`.
    public var buffer: Double = 0.20
    /// The host free fraction below which the buffer narrows,
    /// `pressure_threshold`.
    public var pressureThreshold: Double = 0.20
    /// The host free fraction at or below which the guest is held under what
    /// it needs, `pressure_critical`.
    public var pressureCritical: Double = 0.05
    /// The largest shrink in one decision, as a fraction of what the machine
    /// holds, `max_balloon_change_percent`.
    public var maxShrink: Double = 0.05
    /// Changes smaller than this fraction of what the machine holds are
    /// skipped, `min_balloon_change_percent`.
    public var minChange: Double = 0.0025
    /// The least a machine is asked to hold, Hyper-V's minimum memory and the
    /// policy's `balloon_min`.
    public var minimum: UInt64 = 0
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
        /// The fraction of the host's memory that is free.
        public var hostFree: Double
        /// What the machine holds now: its size less what its balloon holds.
        public var current: UInt64
        /// What the machine needs, in the same terms as `current`.
        public var needs: UInt64
        /// What the guest can still allocate, `MemAvailable`.
        public var available: UInt64
        /// The least the guest keeps available, hv_balloon's floor for the
        /// memory it holds.
        public var floor: UInt64

        public init(hostFree: Double, current: UInt64, needs: UInt64, available: UInt64, floor: UInt64) {
            self.hostFree = hostFree
            self.current = current
            self.needs = needs
            self.available = available
            self.floor = floor
        }

        /// The reading of a machine of `size` bytes whose guest reports `info`.
        ///
        /// What the machine needs is what Linux reports to Hyper-V as
        /// committed, the guest's committed memory plus a floor for the
        /// kernel's own use that grows with the memory it holds
        /// (hv_balloon's `get_pages_committed` and `compute_balloon_floor`),
        /// with what the guest's kernel set aside at boot added, since
        /// `MemTotal` leaves it out and the machine holds it all the same:
        /// https://github.com/torvalds/linux/blob/v6.18/drivers/hv/hv_balloon.c
        ///
        /// hv_balloon also counts the pages its balloon holds, which the host
        /// knows from the guest's balloon responses as well. What the machine
        /// holds already leaves the balloon out, so its pages are not counted
        /// as need. The floor is of the memory the guest holds, as
        /// hv_balloon's is, whose ballooned pages leave the kernel's total; a
        /// balloon that may give pages back on out-of-memory leaves them in
        /// `MemTotal` (virtio_balloon's `fill_balloon`), so they are taken
        /// out here.
        public init(hostFree: Double, size: UInt64, info: LinuxMemoryInfo) throws {
            guard let balloon = info.balloonBytes else {
                throw ContainerizationError(.unsupported, message: "the guest does not report what its balloon holds")
            }
            let floor = MemoryBalloonPolicy.balloonFloor(info.totalBytes - min(balloon, info.totalBytes))
            self.init(
                hostFree: hostFree,
                current: size - min(balloon, size),
                needs: info.committedBytes + floor + (size - min(info.totalBytes, size)),
                available: info.availableBytes,
                floor: floor
            )
        }
    }

    /// The size to ask the machine to hold next, or nil to leave it: the
    /// policy's main script and `balloon_guest`.
    /// - Parameters:
    ///   - samples: The latest readings, oldest first, the statistics MoM
    ///     averages with `StatAvg` and reads the last of with `Stat`. A latest
    ///     need above the average is taken as it is, as Kubernetes' autoscaler
    ///     scales up with no stabilization window and smooths only its scaling
    ///     down:
    ///     https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/#stabilization-window
    ///   - maximum: The size the machine was created with, `balloon_max`.
    public func nextTarget(samples: [Sample], maximum: UInt64) -> UInt64? {
        guard let latest = samples.last else {
            return nil
        }
        let count = Double(samples.count)
        let hostFreePercent = samples.map(\.hostFree).reduce(0, +) / count
        let balloonCur = Double(latest.current)

        let guestNeeds = max(samples.map { Double($0.needs) }.reduce(0, +) / count, Double(latest.needs))
        var balloonSize = min(max(guestNeeds * (1 + bufferShare(hostFreePercent)), Double(minimum)), Double(maximum))
        if balloonSize < balloonCur {
            // hv_balloon's balloon_up refuses to take the guest's available
            // memory below its floor; virtio_balloon leaves that to the host.
            let spare = Double(latest.available - min(latest.floor, latest.available))
            balloonSize = max(balloonSize, balloonCur * (1 - maxShrink), balloonCur - spare)
        }
        guard changeBigEnough(balloonSize, balloonCur: balloonCur) else {
            return nil
        }
        return UInt64(balloonSize)
    }

    /// The policy's `buffer_share`: the buffer, scaled back according to host
    /// pressure as MoM scales a guest's free memory, and made negative to hold
    /// the guest under its needs when the pressure is critical.
    func bufferShare(_ hostFreePercent: Double) -> Double {
        if hostFreePercent >= pressureThreshold {
            return buffer
        } else if hostFreePercent > pressureCritical {
            return buffer * (hostFreePercent / pressureThreshold)
        } else {
            return -0.05 + hostFreePercent
        }
    }

    /// The policy's `change_big_enough`.
    func changeBigEnough(_ newValue: Double, balloonCur: Double) -> Bool {
        abs(newValue - balloonCur) > minChange * balloonCur
    }

    /// hv_balloon's `compute_balloon_floor` for a kernel holding `bytes`: a
    /// continuous piecewise linear function, 16 MiB at 16 MiB, 360 MiB at
    /// 2 GiB and 1512 MiB at 32 GiB.
    public static func balloonFloor(_ bytes: UInt64) -> UInt64 {
        let mib: UInt64 = 1 << 20
        switch bytes {
        case ..<(128 * mib):
            return 8 * mib + (bytes >> 1)
        case ..<(512 * mib):
            return 40 * mib + (bytes >> 2)
        case ..<(2048 * mib):
            return 104 * mib + (bytes >> 3)
        case ..<(8192 * mib):
            return 232 * mib + (bytes >> 4)
        default:
            return 488 * mib + (bytes >> 5)
        }
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
        let fields = LinuxMemoryInfo.fields(meminfo: try String(contentsOfFile: "/proc/meminfo", encoding: .utf8))
        guard let total = fields["MemTotal"], total > 0 else {
            throw ContainerizationError(.internalError, message: "/proc/meminfo has no MemTotal")
        }
        return Double((fields["MemFree"] ?? 0) + (fields["Buffers"] ?? 0) + (fields["Cached"] ?? 0)) / Double(total)
        #endif
    }
}

/// Drives one machine's balloon by `MemoryBalloonPolicy`.
public actor MemoryBalloonController {
    /// What the controller has done, for logs and tests.
    public struct Report: Sendable {
        public var samples = 0
        public var decisions = 0
        public var shrinks = 0
        public var grows = 0
        public var failures = 0
        public var lastSample: MemoryBalloonPolicy.Sample?
        public var lastTarget: UInt64?
    }

    private let policy: MemoryBalloonPolicy
    private let maximum: UInt64
    private let logger: Logger?
    private var samples: [MemoryBalloonPolicy.Sample] = []
    private var report = Report()

    /// - Parameters:
    ///   - policy: The policy to follow.
    ///   - maximum: The size the machine was created with.
    ///   - logger: Where to log each change of size.
    public init(policy: MemoryBalloonPolicy, maximum: UInt64, logger: Logger? = nil) {
        self.policy = policy
        self.maximum = maximum
        self.logger = logger
    }

    public func currentReport() -> Report {
        report
    }

    /// Sample on the policy's cadence and decide on its own until cancelled.
    /// A failed sample or change is counted and the loop goes on.
    /// - Parameters:
    ///   - hostFree: The fraction of the host's memory that is free.
    ///   - memoryInfo: The guest's account of its memory.
    ///   - apply: Ask the machine to hold `target` bytes, from `current`.
    public func run(
        hostFree: @Sendable () throws -> Double = MemoryBalloonPolicy.hostFree,
        memoryInfo: @Sendable () async throws -> LinuxMemoryInfo,
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
            do {
                record(try MemoryBalloonPolicy.Sample(hostFree: try hostFree(), size: maximum, info: try await memoryInfo()))
            } catch {
                report.failures += 1
                logger?.debug("memory balloon sample failed", metadata: ["error": "\(error)"])
                continue
            }
            guard clock.now >= nextDecision else {
                continue
            }
            nextDecision = clock.now + policy.decisionInterval
            report.decisions += 1
            guard let latest = samples.last, let target = policy.nextTarget(samples: samples, maximum: maximum) else {
                continue
            }
            do {
                try await apply(target, latest.current)
                if target < latest.current {
                    report.shrinks += 1
                } else {
                    report.grows += 1
                }
                report.lastTarget = target
                logger?.info(
                    "memory balloon target",
                    metadata: [
                        "target": "\(target >> 20) MiB",
                        "current": "\(latest.current >> 20) MiB",
                        "needs": "\(latest.needs >> 20) MiB",
                        "hostFree": "\(latest.hostFree)",
                    ])
            } catch {
                report.failures += 1
                logger?.warning("memory balloon target failed", metadata: ["target": "\(target >> 20) MiB", "error": "\(error)"])
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
