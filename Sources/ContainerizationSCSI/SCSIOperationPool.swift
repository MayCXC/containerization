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
import Synchronization

/// Where a host adapter runs the image operations its commands wait on.
public protocol SCSIOperationExecutor: AnyObject, Sendable {
    /// Runs `operation` away from the queue the adapter is driven on, then
    /// `completion` on that queue.
    func submit(_ operation: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void)
    /// Returns once every operation submitted so far has run, so that none
    /// reaches an image or a buffer after it returns. Their completions may
    /// still be on their way to the adapter's queue.
    func waitForRunningOperations()
}

/// Runs operations on a pool of threads, at most `maximumWorkers` at once,
/// the rest waiting their turn in the order they came, and completes the
/// ones that have run together on the completion queue, as QEMU's thread
/// pool runs a file-backed disk's I/O: util/thread-pool.c, sized by
/// THREAD_POOL_MAX_THREADS_DEFAULT in include/block/thread-pool.h, at
/// d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/util/thread-pool.c
public final class SCSIOperationPool: SCSIOperationExecutor {
    public static let maximumWorkers = 64

    private struct Job: Sendable {
        let operation: @Sendable () -> Void
        let completion: @Sendable () -> Void
    }

    private struct State: Sendable {
        var running = 0
        var waiting: [Job] = []
        /// The next waiting job, which the first worker to finish takes.
        var next = 0
        /// The completions of the jobs that have run, in the order they
        /// finished.
        var finished: [@Sendable () -> Void] = []
        /// Whether a pass over `finished` is queued or running on the
        /// completion queue: the scheduled state of QEMU's completion_bh.
        var completing = false
    }

    private let workers = DispatchQueue(label: "com.apple.containerization.scsi.operations", qos: .userInitiated, attributes: .concurrent)
    private let completionQueue: DispatchQueue
    private let state = Mutex(State())
    private let outstanding = DispatchGroup()

    /// A pool whose completions run on `completionQueue`.
    public init(completionQueue: DispatchQueue) {
        self.completionQueue = completionQueue
    }

    public func submit(_ operation: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
        outstanding.enter()
        let job = Job(operation: operation, completion: completion)
        let starts = state.withLock { state in
            guard state.running < Self.maximumWorkers else {
                state.waiting.append(job)
                return false
            }
            state.running += 1
            return true
        }
        if starts {
            workers.async { self.work(from: job) }
        }
    }

    /// Runs `job`, then the jobs that wait, until none does. A job that has
    /// run joins the finished ones, and queues a pass over them unless one is
    /// queued already, as QEMU's worker_thread schedules the pool's
    /// completion bottom half.
    private func work(from job: Job) {
        var job = job
        while true {
            job.operation()
            let queuesPass = state.withLock { state in
                state.finished.append(job.completion)
                guard !state.completing else {
                    return false
                }
                state.completing = true
                return true
            }
            if queuesPass {
                completionQueue.async { self.completeFinished() }
            }
            outstanding.leave()
            let next = state.withLock { state -> Job? in
                guard state.next < state.waiting.count else {
                    state.waiting.removeAll(keepingCapacity: true)
                    state.next = 0
                    state.running -= 1
                    return nil
                }
                let next = state.waiting[state.next]
                state.next += 1
                // Taken jobs leave the queue a batch at a time, so that a
                // queue never drained keeps no run of them.
                if state.next >= Self.maximumWorkers && state.next * 2 >= state.waiting.count {
                    state.waiting.removeFirst(state.next)
                    state.next = 0
                }
                return next
            }
            guard let next else {
                return
            }
            job = next
        }
    }

    /// Runs the completions of every job that has run, and of those that run
    /// meanwhile, in one pass on the completion queue, as QEMU completes in
    /// one bottom half every request its pool has run, rescanning after each
    /// (thread_pool_completion_bh). Once none is left, the next job to finish
    /// queues the next pass.
    private func completeFinished() {
        while true {
            let completions = state.withLock { state in
                var completions: [@Sendable () -> Void] = []
                swap(&completions, &state.finished)
                if completions.isEmpty {
                    state.completing = false
                }
                return completions
            }
            guard !completions.isEmpty else {
                return
            }
            for completion in completions {
                completion()
            }
        }
    }

    public func waitForRunningOperations() {
        outstanding.wait()
    }
}
