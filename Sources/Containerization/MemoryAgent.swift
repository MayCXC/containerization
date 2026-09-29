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

/// The settings of mem-agent, the guest memory manager of Kata Containers,
/// which vminitd runs beside itself once `Kernel.CommandLine.enableMemoryAgent`
/// asks it to. mem-agent reclaims the cold memory of each cgroup and compacts
/// the guest's free memory, and backs off either while the guest's pressure
/// stall information shows memory or IO under strain.
///
/// The settings are Kata's `mem_agent` configuration, one for one, and a
/// setting left nil keeps mem-agent's own default:
/// https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/src/libs/kata-types/src/config/agent.rs
/// https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/docs/how-to/how-to-use-memory-agent.md
public struct MemoryAgent: Sendable, Codable, Equatable {
    /// Turns off the reclaim of cold memory from cgroups (`memcg_disable`).
    public var memcgDisable: Bool?
    /// Reclaims anonymous pages as well as the file cache (`memcg_swap`).
    public var memcgSwap: Bool?
    /// The most swappiness an eviction uses, out of 200
    /// (`memcg_swappiness_max`).
    public var memcgSwappinessMax: UInt8?
    /// The seconds between reclaim runs (`memcg_period_secs`).
    public var memcgPeriodSecs: UInt64?
    /// A reclaim run waits while memory or IO has stalled for more than this
    /// percentage of the time since the last one
    /// (`memcg_period_psi_percent_limit`).
    public var memcgPeriodPsiPercentLimit: UInt8?
    /// An eviction stops once memory or IO stalls for more than this
    /// percentage of its time (`memcg_eviction_psi_percent_limit`).
    public var memcgEvictionPsiPercentLimit: UInt8?
    /// The aging runs a cgroup goes through before its pages are evicted
    /// (`memcg_eviction_run_aging_count_min`).
    public var memcgEvictionRunAgingCountMin: UInt64?
    /// Turns off compaction (`compact_disable`).
    public var compactDisable: Bool?
    /// The seconds between compaction runs (`compact_period_secs`).
    public var compactPeriodSecs: UInt64?
    /// A compaction run waits while memory or IO has stalled for more than
    /// this percentage of the time since the last one
    /// (`compact_period_psi_percent_limit`).
    public var compactPeriodPsiPercentLimit: UInt8?
    /// A compaction stops once memory or IO stalls for more than this
    /// percentage of a second (`compact_psi_percent_limit`).
    public var compactPsiPercentLimit: UInt8?
    /// The longest one compaction runs, in seconds (`compact_sec_max`).
    public var compactSecMax: Int64?
    /// The order of the free blocks compaction works toward
    /// (`compact_order`).
    public var compactOrder: UInt8?
    /// How far, in pages, the guest's free memory has to move after one
    /// compaction for the next to run (`compact_threshold`).
    public var compactThreshold: UInt64?
    /// The runs without a compaction after which one is forced
    /// (`compact_force_times`).
    public var compactForceTimes: UInt64?

    public init() {}

    /// The flags mem-agent-srv, mem-agent's standalone program, takes for
    /// these settings:
    /// https://github.com/teawater/mem-agent/blob/4a2bed653ab6c0f8f87d99d505a2332c94613479/crates/share/src/option.rs
    public var arguments: [String] {
        var args: [String] = []
        func add(_ flag: String, _ value: (some CustomStringConvertible)?) {
            if let value {
                args.append("--\(flag)=\(value)")
            }
        }
        add("memcg-disabled", memcgDisable)
        add("memcg-swap", memcgSwap)
        add("memcg-swappiness-max", memcgSwappinessMax)
        add("memcg-period-secs", memcgPeriodSecs)
        add("memcg-period-psi-percent-limit", memcgPeriodPsiPercentLimit)
        add("memcg-eviction-psi-percent-limit", memcgEvictionPsiPercentLimit)
        add("memcg-eviction-run-aging-count-min", memcgEvictionRunAgingCountMin)
        add("compact-disabled", compactDisable)
        add("compact-period-secs", compactPeriodSecs)
        add("compact-period-psi-percent-limit", compactPeriodPsiPercentLimit)
        add("compact-psi-percent-limit", compactPsiPercentLimit)
        add("compact-sec-max", compactSecMax)
        add("compact-order", compactOrder)
        add("compact-threshold", compactThreshold)
        add("compact-force-times", compactForceTimes)
        return args
    }
}
