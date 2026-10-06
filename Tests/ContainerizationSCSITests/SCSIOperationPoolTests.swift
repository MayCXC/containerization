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

import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ContainerizationSCSI

/// What a pool's operations and completions did, from whichever thread
/// they ran on.
private final class Record: Sendable {
    private struct State {
        var running = 0
        var most = 0
        var ran: Set<Int> = []
        var completed = 0
        var completedFirst = 0
        var met = 0
        var notes: [String] = []
    }

    private let state = Mutex(State())

    func run(_ index: Int) {
        state.withLock { state in
            state.running += 1
            state.most = max(state.most, state.running)
        }
        Thread.sleep(forTimeInterval: 0.001)
        state.withLock { state in
            state.running -= 1
            state.ran.insert(index)
        }
    }

    func complete(_ index: Int) {
        state.withLock { state in
            if !state.ran.contains(index) {
                state.completedFirst += 1
            }
            state.completed += 1
        }
    }

    func meet() {
        state.withLock { $0.met += 1 }
    }

    func note(_ name: String) {
        state.withLock { $0.notes.append(name) }
    }

    var ran: Int { state.withLock { $0.ran.count } }
    var most: Int { state.withLock { $0.most } }
    var completed: Int { state.withLock { $0.completed } }
    var completedFirst: Int { state.withLock { $0.completedFirst } }
    var met: Int { state.withLock { $0.met } }
    var notes: [String] { state.withLock { $0.notes } }
}

/// The pool against QEMU's thread pool, util/thread-pool.c at d7a65d1793d6.
struct SCSIOperationPoolTests {
    @Test func operationsRunAtOnce() {
        let pool = SCSIOperationPool(completionQueue: DispatchQueue(label: "com.apple.containerization.scsi.test"))
        let arrivals = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let record = Record()
        // Each operation arrives, then waits for the other to: both get there
        // only if they run at once.
        for index in 0..<2 {
            pool.submit(
                {
                    arrivals[index].signal()
                    if arrivals[1 - index].wait(timeout: .now() + 10) == .success {
                        record.meet()
                    }
                }, completion: {})
        }
        pool.waitForRunningOperations()
        #expect(record.met == 2)
    }

    /// An operation that finishes while a pass over the finished ones is
    /// queued completes in that pass: one hop to the completion queue for all
    /// of them, as QEMU's pool completes every request it has run in one
    /// bottom half (thread_pool_completion_bh).
    @Test func finishedOperationsCompleteInOnePass() {
        let queue = DispatchQueue(label: "com.apple.containerization.scsi.test")
        let pool = SCSIOperationPool(completionQueue: queue)
        let record = Record()
        queue.suspend()
        pool.submit({}, completion: { record.note("first") })
        pool.waitForRunningOperations()
        // Behind the pass the first operation queued.
        queue.async { record.note("marker") }
        pool.submit({}, completion: { record.note("second") })
        pool.waitForRunningOperations()
        queue.resume()
        queue.sync {}
        #expect(record.notes == ["first", "second", "marker"])
    }

    /// More operations than run at once: each runs, at most the pool's
    /// workers at a time, and its completion runs after it on the
    /// completion queue, which the wait does not wait for.
    @Test func completionsRunOnTheirQueueAfterTheOperations() {
        let queue = DispatchQueue(label: "com.apple.containerization.scsi.test")
        let pool = SCSIOperationPool(completionQueue: queue)
        let record = Record()
        let count = 3 * SCSIOperationPool.maximumWorkers
        queue.suspend()
        for index in 0..<count {
            pool.submit({ record.run(index) }, completion: { record.complete(index) })
        }
        pool.waitForRunningOperations()
        #expect(record.ran == count)
        #expect(record.most <= SCSIOperationPool.maximumWorkers)
        #expect(record.completed == 0)
        queue.resume()
        queue.sync {}
        #expect(record.completed == count)
        #expect(record.completedFirst == 0)
    }
}
