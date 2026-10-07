#!/usr/bin/env python3
# Copyright © 2026 Apple Inc. and the Containerization project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Record the decisions oVirt MoM's own policy engine makes for
Sources/Containerization/MemoryBalloonPolicy.rules, which the unit tests hold
MemoryBalloonPolicy.swift to.

Usage:
    memory-balloon-policy-decisions.py <MoM checkout> \\
        > Tests/ContainerizationTests/Resources/MemoryBalloonPolicyDecisions.json

MoM is https://github.com/oVirt/mom; the recorded decisions came from commit
08744b98efb892a9c4416e92b24821cdea1fb249. Each case is a window of readings,
oldest first, as the controller hands its history to the policy, built into
MoM entities the way its monitors build them (mom/Entity.py).
"""

import json
import logging
import os
import random
import sys

MIB = 1 << 20


class Monitor:
    """What an Entity reads from the monitor that made it."""

    def __init__(self, fields):
        self.valid_fields = fields
        self.logger = logging.getLogger("monitor")


def entity(fields, rows):
    from mom.Entity import Entity

    e = Entity(monitor=Monitor(fields))
    e._set_statistics(rows)
    e._finalize()
    return e


def decide(policy, case):
    host = entity({"free_percent"}, [{"free_percent": s["hostFree"]} for s in case["samples"]])
    guest = entity(
        {"balloon_cur", "balloon_min", "balloon_max", "needs", "available", "floor"},
        [
            {
                "balloon_cur": s["current"],
                "balloon_min": case["minimum"],
                "balloon_max": case["maximum"],
                "needs": s["needs"],
                "available": s["available"],
                "floor": s["floor"],
            }
            for s in case["samples"]
        ],
    )
    if not policy.evaluate(host, [guest]):
        sys.exit("MoM could not evaluate the policy")
    target = guest.GetControl("balloon_target")
    return None if target is None else int(target)


def sample(host_free, current, needs, available=None, floor=0):
    return {
        "hostFree": host_free,
        "current": current,
        "needs": needs,
        "available": current if available is None else available,
        "floor": floor,
    }


def cases():
    maximum = 12 * 1024 * MIB
    # Every regime at hand-picked points: the host far from short, narrowing
    # the buffer, and critical; shrinking within and past the largest step;
    # growing, capped by the machine; the dead band; the minimum; the floor.
    for host_free in (0.5, 0.25, 0.2, 0.15, 0.1, 0.06, 0.05, 0.03, 0.0):
        for current, needs in ((1250, 1000), (8192, 1024), (1024, 3072), (8192, 11264), (1201, 1000), (2100, 1000)):
            yield {"minimum": 0, "maximum": maximum, "samples": [sample(host_free, current * MIB, needs * MIB)]}
        yield {"minimum": 2048 * MIB, "maximum": maximum, "samples": [sample(host_free, 2100 * MIB, 1000 * MIB)]}
        for available, floor in ((280, 250), (200, 250), (250, 250), (1000, 100)):
            yield {
                "minimum": 0,
                "maximum": maximum,
                "samples": [sample(host_free, 1000 * MIB, 500 * MIB, available * MIB, floor * MIB)],
            }
    # Windows: needs and host free averaged, a need above the average taken
    # as it is, and the step taken from the last reading's size.
    yield {
        "minimum": 0,
        "maximum": maximum,
        "samples": [sample(0.10, 2000 * MIB, 1100 * MIB), sample(0.50, 1250 * MIB, 900 * MIB)],
    }
    yield {
        "minimum": 0,
        "maximum": maximum,
        "samples": [sample(0.5, 1250 * MIB, 1000 * MIB)] * 3 + [sample(0.5, 1250 * MIB, 3000 * MIB)],
    }
    # Everything else from a fixed seed, so a slip in how the pieces combine
    # has no hand-picked gap to hide in.
    rng = random.Random(20260929)
    for _ in range(200):
        maximum = rng.choice((2, 4, 12, 32)) * 1024 * MIB
        minimum = rng.choice((0, 0, 0, 512 * MIB))
        window = []
        for _ in range(rng.randint(1, 10)):
            current = rng.randint(64 * MIB, maximum)
            floor = rng.randint(0, 512 * MIB)
            window.append(
                sample(
                    round(rng.uniform(0.0, 0.6), 4),
                    current,
                    rng.randint(16 * MIB, maximum),
                    rng.randint(0, current),
                    floor,
                )
            )
        yield {"minimum": minimum, "maximum": maximum, "samples": window}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.path.insert(0, sys.argv[1])
    from mom.Policy.Policy import Policy

    rules = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "Containerization", "MemoryBalloonPolicy.rules")
    policy = Policy()
    with open(rules) as f:
        if not policy.set_policy("memory-balloon", f.read()):
            sys.exit("MoM could not load " + rules)
    lines = []
    for case in cases():
        case["target"] = decide(policy, case)
        lines.append(json.dumps(case, separators=(",", ":")))
    sys.stdout.write('{"cases":[\n' + ",\n".join(lines) + "\n]}\n")


main()
