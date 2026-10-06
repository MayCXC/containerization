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

import Foundation
import Testing

@testable import ContainerizationSCSI

/// A host adapter with disks attached, and the requests a driver sends it.
/// Its operations run as they are submitted unless the fixture is given an
/// executor that holds them.
final class ControllerFixture {
    let controller: VirtioSCSIController
    private(set) var deviceErrors: [String] = []
    private var images: [TemporaryImage] = []

    init(executor: any SCSIOperationExecutor = InlineExecutor(), requestQueues: Int = 1) {
        controller = VirtioSCSIController(requestQueues: requestQueues, executor: executor)
        controller.onDeviceError = { [weak self] reason in
            self?.deviceErrors.append(reason)
        }
    }

    @discardableResult
    func attach(target: UInt8 = 0, lun: UInt16 = 0, blocks: Int = 16) throws -> TemporaryImage {
        let image = try TemporaryImage(blocks: blocks)
        images.append(image)
        try controller.attach(SCSIDisk(image: SCSIDiskImage(path: image.path, readOnly: false)), target: target, lun: lun)
        return image
    }

    /// Attaches a disk and takes the reset its first command reports.
    @discardableResult
    func attachReady(target: UInt8 = 0, lun: UInt16 = 0, blocks: Int = 16) throws -> TemporaryImage {
        let image = try attach(target: target, lun: lun, blocks: blocks)
        send(target: target, lun: lun, cdb: testUnitReady)
        return image
    }

    /// Sends a command request with the data the driver writes and room for
    /// `dataIn` bytes the device returns, and returns its chain.
    @discardableResult
    func send(target: UInt8 = 0, lun: UInt16 = 0, tag: UInt64 = 0, cdb: [UInt8], dataOut: [[UInt8]] = [], dataIn: Int = 0) -> MemoryChain {
        let chain = request(target: target, lun: lun, tag: tag, cdb: cdb, dataOut: dataOut, dataIn: dataIn)
        controller.handleRequest(chain)
        return chain
    }

    /// A command request's chain, not yet sent.
    func request(target: UInt8 = 0, lun: UInt16 = 0, tag: UInt64 = 0, cdb: [UInt8], dataOut: [[UInt8]] = [], dataIn: Int = 0) -> MemoryChain {
        MemoryChain(readable: [commandRequest(target: target, lun: lun, tag: tag, cdb: cdb)] + dataOut, writable: 108 + dataIn)
    }

    /// Sends `chains` as a request queue holds them, all taken in one pass.
    func send(_ chains: [MemoryChain]) {
        var remaining = chains[...]
        controller.handleRequests { remaining.popFirst() }
    }

    func response(target: UInt8 = 0, lun: UInt16 = 0, cdb: [UInt8], dataOut: [[UInt8]] = [], dataIn: Int = 0) throws -> CommandResponse {
        try CommandResponse(send(target: target, lun: lun, cdb: cdb, dataOut: dataOut, dataIn: dataIn).written)
    }

    func control(_ request: [UInt8], responseLength: Int) -> MemoryChain {
        let chain = MemoryChain(request, writable: responseLength)
        controller.handleControl(chain)
        return chain
    }
}

/// struct virtio_scsi_ctrl_tmf: the type, the function, the LUN and a tag.
func taskManagement(_ function: UInt32, target: UInt8 = 0, lun: UInt16 = 0, addressing: UInt8 = 1, tag: UInt64 = 0x1234) -> [UInt8] {
    var request = [UInt8]()
    request.appendLittleEndian(UInt32(0))
    request.appendLittleEndian(function)
    request += [addressing, target] + SCSIBus.encode(lun: lun) + [0, 0, 0, 0]
    request.appendLittleEndian(tag)
    return request
}

/// struct virtio_scsi_ctrl_an: the type, the LUN and the events asked for.
private func asynchronousNotification(_ type: UInt32) -> [UInt8] {
    var request = [UInt8]()
    request.appendLittleEndian(type)
    request += [1, 0, 0, 0, 0, 0, 0, 0]
    request.appendLittleEndian(UInt32(0x10))
    return request
}

/// struct virtio_scsi_event: the event, the LUN and the reason.
private func event(_ event: UInt32, lun: [UInt8], reason: UInt32) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.appendLittleEndian(event)
    bytes += lun
    bytes.appendLittleEndian(reason)
    return bytes
}

private let transportReset: UInt32 = 1
private let eventsMissed: UInt32 = 0x8000_0000
private let rescan: UInt32 = 1
private let removed: UInt32 = 2

/// READ (10) and WRITE (10) of one block.
private func read10(_ lba: UInt8) -> [UInt8] {
    [0x28, 0, 0, 0, 0, lba, 0, 0, 1, 0]
}

private func write10(_ lba: UInt8) -> [UInt8] {
    [0x2a, 0, 0, 0, 0, lba, 0, 0, 1, 0]
}

/// The order chains complete in, by name.
private final class CompletionOrder {
    private(set) var names: [String] = []

    func watch(_ chain: MemoryChain, as name: String) {
        chain.onComplete = { [weak self] in
            self?.names.append(name)
        }
    }
}

/// The transport, held against QEMU's virtio-scsi device (hw/scsi/virtio-scsi.c
/// at d7a65d1793d6) and the virtio specification's section 5.6.
struct VirtioSCSITests {
    @Test func configurationSpace() {
        // virtio_scsi_get_config with QEMU's defaults: the request queues,
        // seg_max sized by the queue (256 - 2), max_sectors 0xFFFF,
        // cmd_per_lun 128, a 16-byte event, 96 bytes of sense, a 32-byte CDB,
        // channel 0, target 255 and LUN 16383.
        let controller = VirtioSCSIController(requestQueues: 4, executor: InlineExecutor())
        #expect(
            controller.configurationSpace == [
                4, 0, 0, 0, 254, 0, 0, 0, 0xff, 0xff, 0, 0, 128, 0, 0, 0, 16, 0, 0, 0, 96, 0, 0, 0, 32, 0, 0, 0, 0, 0, 255, 0, 0xff, 0x3f, 0, 0,
            ])
        #expect(VirtioSCSIController.deviceID == 8)
        // The control and event queues, then the request queues.
        #expect(controller.queueCount == 6)
        // VIRTIO_SCSI_F_HOTPLUG and VIRTIO_SCSI_F_CHANGE, as QEMU's hotplug
        // and param_change properties default.
        #expect(VirtioSCSIController.offeredFeatures == 1 << 1 | 1 << 2)
    }

    @Test func aRequestQueueForEachVCPU() {
        // virtio_pci_optimal_num_queues: one per vCPU, within the 1024
        // queues a device can have.
        #expect(VirtioSCSIController.requestQueueCount(cpus: 1) == 1)
        #expect(VirtioSCSIController.requestQueueCount(cpus: 8) == 8)
        #expect(VirtioSCSIController.requestQueueCount(cpus: 4096) == 1022)
        #expect(VirtioSCSIController(requestQueues: 8, executor: InlineExecutor()).configurationSpace.littleEndian32(at: 0) == 8)
    }

    // MARK: Request queue

    @Test func theFirstCommandReportsTheReset() throws {
        let fixture = ControllerFixture()
        try fixture.attach()
        let chain = fixture.send(cdb: testUnitReady)
        let response = try CommandResponse(chain.written)
        #expect(response.response == 0)
        #expect(response.status == 2)
        #expect(response.senseLength == 18)
        #expect(response.sense == SCSISense.reset.fixed)
        #expect(response.residual == 0)
        #expect(chain.written.count == 108)
        #expect(chain.completions == 1)
        #expect(try fixture.response(cdb: testUnitReady).status == 0)
    }

    @Test func aReadReturnsItsData() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        let chain = fixture.send(cdb: [0x28, 0, 0, 0, 0, 2, 0, 0, 2, 0], dataIn: 1024)
        let response = try CommandResponse(chain.written)
        #expect(response.response == 0)
        #expect(response.status == 0)
        #expect(response.senseLength == 0)
        #expect(response.residual == 0)
        #expect(response.data == [UInt8](repeating: 2, count: 512) + [UInt8](repeating: 3, count: 512))
        #expect(chain.completions == 1)
    }

    @Test func aWriteTakesItsDataFromEveryBuffer() throws {
        let fixture = ControllerFixture()
        let image = try fixture.attachReady()
        let block = (0..<512).map { UInt8(truncatingIfNeeded: $0) }
        let response = try fixture.response(cdb: [0x2a, 0, 0, 0, 0, 4, 0, 0, 1, 0], dataOut: [Array(block[..<100]), Array(block[100...])])
        #expect(response.status == 0)
        #expect(response.residual == 0)
        #expect(response.data.isEmpty)
        #expect(try image.block(4) == block)
    }

    @Test func aCheckConditionCarriesFixedSense() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        let response = try fixture.response(cdb: [0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0], dataIn: 512)
        #expect(response.response == 0)
        #expect(response.status == 2)
        #expect(response.senseLength == 18)
        #expect(response.sense == SCSISense.lbaOutOfRange.fixed)
        #expect(response.residual == 0)
        #expect(response.data.isEmpty)
    }

    @Test func theResidualCountsFromTheTransferLength() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // REPORT LUNS of 64 bytes, which returns 16.
        let report = try fixture.response(cdb: [0xa0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0], dataIn: 200)
        #expect(report.residual == 48)
        #expect(report.data.count == 16)
        // An emulated command returns its whole allocation length.
        let inquiry = try fixture.response(cdb: [0x12, 0, 0, 0, 96, 0], dataIn: 200)
        #expect(inquiry.residual == 0)
        #expect(inquiry.data.count == 96)
    }

    @Test func flatSpaceAddressingReachesLUNsFrom256() throws {
        let fixture = ControllerFixture()
        try fixture.attach(lun: 0)
        try fixture.attachReady(lun: 300)
        let response = try fixture.response(lun: 300, cdb: [0x28, 0, 0, 0, 0, 5, 0, 0, 1, 0], dataIn: 512)
        #expect(response.data == [UInt8](repeating: 5, count: 512))
    }

    @Test func addressesWithNoDeviceAreBadTargets() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        #expect(try fixture.response(target: 5, cdb: testUnitReady).response == 3)
        // A first byte other than 1, and a LUN in neither addressing method.
        for (index, value) in [(0, UInt8(2)), (2, UInt8(0x80))] {
            var request = commandRequest(cdb: testUnitReady)
            request[index] = value
            let chain = MemoryChain(request, writable: 108)
            fixture.controller.handleRequest(chain)
            let response = try CommandResponse(chain.written)
            #expect(response.response == 3)
            #expect(response.status == 0)
            #expect(chain.completions == 1)
        }
    }

    @Test func overruns() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // Two blocks into room for one.
        #expect(try fixture.response(cdb: [0x28, 0, 0, 0, 0, 0, 0, 0, 2, 0], dataIn: 512).response == 1)
        // Data that goes the other way.
        #expect(try fixture.response(cdb: [0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0], dataOut: [[UInt8](repeating: 0, count: 512)]).response == 1)
        // Less data than the write sends.
        #expect(try fixture.response(cdb: [0x2a, 0, 0, 0, 0, 0, 0, 0, 1, 0], dataOut: [[UInt8](repeating: 0, count: 100)]).response == 1)
        // An allocation length past the room for it.
        #expect(try fixture.response(cdb: [0x12, 0, 0, 0, 96, 0], dataIn: 50).response == 1)
        // A command that transfers nothing takes any buffers.
        #expect(try fixture.response(cdb: testUnitReady, dataIn: 512).status == 0)
    }

    /// A unit attention is taken when the command is routed, before the
    /// transport checks its buffers, as QEMU's bus fetches it when it
    /// allocates the request; a command that then overruns loses it.
    @Test func anOverrunTakesAPendingUnitAttention() throws {
        let fixture = ControllerFixture()
        try fixture.attach()
        #expect(try fixture.response(cdb: [0x28, 0, 0, 0, 0, 0, 0, 0, 2, 0], dataIn: 512).response == 1)
        #expect(try fixture.response(cdb: testUnitReady).status == 0)
    }

    @Test func dataBothWaysFails() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        let chain = fixture.send(cdb: [0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0], dataOut: [[0]], dataIn: 512)
        #expect(try CommandResponse(chain.written).response == 9)
        #expect(chain.completions == 1)
    }

    @Test func malformedRequestsNeedAReset() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // A request header cut short.
        let short = MemoryChain(Array(commandRequest(cdb: testUnitReady)[..<50]), writable: 108)
        fixture.controller.handleRequest(short)
        #expect(short.completions == 0)
        #expect(fixture.deviceErrors.count == 1)
        #expect(fixture.controller.needsReset)
        // Nothing is served until the device resets.
        #expect(fixture.send(cdb: testUnitReady).completions == 0)
        fixture.controller.reset()
        #expect(!fixture.controller.needsReset)
        // The reset reaches the disk.
        #expect(try fixture.response(cdb: testUnitReady).sense == SCSISense.reset.fixed)
        // Less room than the response header takes.
        let cramped = MemoryChain(commandRequest(cdb: testUnitReady), writable: 107)
        fixture.controller.handleRequest(cramped)
        #expect(cramped.completions == 0)
        #expect(fixture.deviceErrors.count == 2)
    }

    // MARK: Control queue

    @Test func logicalUnitReset() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        let chain = fixture.control(taskManagement(5), responseLength: 1)
        #expect(chain.written == [0])
        #expect(chain.completions == 1)
        #expect(try fixture.response(cdb: testUnitReady).sense == SCSISense.reset.fixed)
    }

    @Test func withNothingInFlightAbortsAndQueriesFindNothing() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // ABORT TASK, ABORT TASK SET, CLEAR TASK SET, QUERY TASK and QUERY
        // TASK SET all find nothing and complete.
        for function: UInt32 in [0, 1, 3, 6, 7] {
            #expect(fixture.control(taskManagement(function), responseLength: 1).written == [0])
        }
        // None of them resets the unit.
        #expect(try fixture.response(cdb: testUnitReady).status == 0)
    }

    @Test func taskManagementAddresses() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // A LUN of the target with no device there.
        #expect(fixture.control(taskManagement(5, lun: 4), responseLength: 1).written == [12])
        // A target with no device, and an address not in the LUN format.
        #expect(fixture.control(taskManagement(5, target: 9), responseLength: 1).written == [3])
        #expect(fixture.control(taskManagement(0, addressing: 0), responseLength: 1).written == [3])
    }

    @Test func anITNexusResetResetsTheTarget() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady(lun: 0)
        try fixture.attachReady(lun: 1)
        try fixture.attachReady(target: 1, lun: 0)
        #expect(fixture.control(taskManagement(4), responseLength: 1).written == [0])
        #expect(try fixture.response(lun: 0, cdb: testUnitReady).sense == SCSISense.reset.fixed)
        #expect(try fixture.response(lun: 1, cdb: testUnitReady).sense == SCSISense.reset.fixed)
        #expect(try fixture.response(target: 1, cdb: testUnitReady).status == 0)
        // A target with no device completes too.
        #expect(fixture.control(taskManagement(4, target: 7), responseLength: 1).written == [0])
    }

    @Test func otherFunctionsAreRejected() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // CLEAR ACA, and a function with no meaning.
        #expect(fixture.control(taskManagement(2), responseLength: 1).written == [11])
        #expect(fixture.control(taskManagement(99), responseLength: 1).written == [11])
    }

    // MARK: Commands in flight

    @Test func commandsCompleteAsTheirOperationsFinish() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady()
        let first = fixture.request(tag: 1, cdb: read10(1), dataIn: 512)
        let second = fixture.request(tag: 2, cdb: read10(2), dataIn: 512)
        let order = CompletionOrder()
        order.watch(first, as: "first")
        order.watch(second, as: "second")
        fixture.send([first, second])
        // Both are in flight at once.
        #expect(executor.submitted == 2)
        #expect(order.names.isEmpty)
        executor.complete(1)
        #expect(order.names == ["second"])
        #expect(try CommandResponse(second.written).data == [UInt8](repeating: 2, count: 512))
        executor.complete(0)
        #expect(order.names == ["second", "first"])
        #expect(try CommandResponse(first.written).data == [UInt8](repeating: 1, count: 512))
    }

    /// A write's data goes to the image from a pool thread, however many
    /// buffers the driver sent it in.
    @Test func aWriteOfManyBuffersRunsOnAPoolThread() throws {
        let queue = DispatchQueue(label: "com.apple.containerization.scsi.test")
        let pool = SCSIOperationPool(completionQueue: queue)
        let fixture = ControllerFixture(executor: pool)
        let image = try queue.sync { try fixture.attachReady(blocks: 1024) }
        // 1000 blocks in 4000 buffers.
        let buffers = (0..<4000).map { [UInt8](repeating: UInt8(truncatingIfNeeded: $0 / 4 + 1), count: 128) }
        let write = queue.sync { fixture.send(cdb: [0x2a, 0, 0, 0, 0, 0, 0, 0x03, 0xe8, 0], dataOut: buffers) }
        pool.waitForRunningOperations()
        queue.sync {}
        #expect(try CommandResponse(write.written).status == 0)
        #expect(try image.block(0) == [UInt8](repeating: 1, count: 512))
        #expect(try image.block(999) == [UInt8](repeating: 232, count: 512))
    }

    /// Every request is prepared before any command runs, and a command that
    /// completes without the image is answered as it is submitted.
    @Test func aBatchIsPreparedThenSubmitted() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady()
        let read = fixture.request(cdb: read10(1), dataIn: 512)
        let inquiry = fixture.request(cdb: [0x12, 0, 0, 0, 96, 0], dataIn: 96)
        fixture.send([read, inquiry])
        #expect(executor.submitted == 1)
        #expect(read.completions == 0)
        #expect(try CommandResponse(inquiry.written).data.count == 96)
        executor.completeAll()
        #expect(try CommandResponse(read.written).status == 0)
    }

    /// A request that breaks the transport leaves every command prepared
    /// with it unrun and unanswered; those the transport refused in their
    /// preparation are answered.
    @Test func aRequestThatBreaksTheTransportLeavesItsBatchUnanswered() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady()
        let read = fixture.request(cdb: read10(1), dataIn: 512)
        let inquiry = fixture.request(cdb: [0x12, 0, 0, 0, 96, 0], dataIn: 96)
        let badTarget = fixture.request(target: 5, cdb: testUnitReady)
        let broken = MemoryChain(Array(commandRequest(cdb: testUnitReady)[..<50]), writable: 108)
        fixture.send([read, inquiry, badTarget, broken])
        #expect(fixture.controller.needsReset)
        #expect(executor.submitted == 0)
        #expect(read.completions == 0)
        #expect(inquiry.completions == 0)
        #expect(broken.completions == 0)
        #expect(try CommandResponse(badTarget.written).response == 3)
    }

    /// ABORT TASK cancels the command, whose request to the image runs to
    /// its end; the command is answered ABORTED, then the function.
    @Test func abortTaskAnswersTheCommandThenItself() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        let image = try fixture.attachReady()
        let block = [UInt8](repeating: 0xab, count: 512)
        let write = fixture.send(tag: 7, cdb: write10(4), dataOut: [block])
        let other = fixture.send(tag: 8, cdb: read10(5), dataIn: 512)
        let abort = MemoryChain(taskManagement(0, tag: 7), writable: 1)
        let order = CompletionOrder()
        order.watch(write, as: "write")
        order.watch(abort, as: "abort")
        fixture.controller.handleControl(abort)
        #expect(abort.completions == 0)
        // A canceled command is out of the task set.
        #expect(fixture.control(taskManagement(6, tag: 7), responseLength: 1).written == [0])
        #expect(fixture.control(taskManagement(6, tag: 8), responseLength: 1).written == [10])
        // A tag with no command in flight is answered at once.
        #expect(fixture.control(taskManagement(0, tag: 9), responseLength: 1).written == [0])
        executor.complete(0)
        #expect(order.names == ["write", "abort"])
        #expect(try CommandResponse(write.written).response == 2)
        #expect(abort.written == [0])
        #expect(try image.block(4) == block)
        #expect(other.completions == 0)
        executor.complete(1)
        #expect(try CommandResponse(other.written).response == 0)
    }

    /// ABORT TASK SET and CLEAR TASK SET cancel every command of the unit,
    /// those whose operation has run but not completed among them, and
    /// leave other units' commands alone.
    @Test func abortTaskSetCancelsTheUnitsCommands() throws {
        for function: UInt32 in [1, 3] {
            let executor = ManualExecutor()
            let fixture = ControllerFixture(executor: executor)
            try fixture.attachReady(lun: 0)
            try fixture.attachReady(lun: 1)
            let ran = fixture.send(lun: 0, tag: 1, cdb: read10(1), dataIn: 512)
            let waiting = fixture.send(lun: 0, tag: 2, cdb: read10(2), dataIn: 512)
            let elsewhere = fixture.send(lun: 1, tag: 3, cdb: read10(3), dataIn: 512)
            executor.run(0)
            let abort = fixture.control(taskManagement(function, lun: 0), responseLength: 1)
            #expect(abort.completions == 0)
            #expect(fixture.control(taskManagement(7, lun: 0), responseLength: 1).written == [0])
            #expect(fixture.control(taskManagement(7, lun: 1), responseLength: 1).written == [10])
            executor.complete(1)
            #expect(abort.completions == 0)
            executor.complete(0)
            #expect(abort.written == [0])
            #expect(try CommandResponse(ran.written).response == 2)
            #expect(try CommandResponse(waiting.written).response == 2)
            #expect(elsewhere.completions == 0)
            executor.complete(2)
            #expect(try CommandResponse(elsewhere.written).response == 0)
        }
    }

    @Test func queriesFindTheCommandsInFlight() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady()
        fixture.send(tag: 5, cdb: read10(1), dataIn: 512)
        #expect(fixture.control(taskManagement(6, tag: 5), responseLength: 1).written == [10])
        #expect(fixture.control(taskManagement(6, tag: 6), responseLength: 1).written == [0])
        #expect(fixture.control(taskManagement(7), responseLength: 1).written == [10])
        executor.completeAll()
        #expect(fixture.control(taskManagement(6, tag: 5), responseLength: 1).written == [0])
        #expect(fixture.control(taskManagement(7), responseLength: 1).written == [0])
    }

    /// A LOGICAL UNIT RESET answers the unit's commands RESET once their
    /// operations have run, then itself, and the unit reports the reset.
    @Test func aLogicalUnitResetAnswersItsCommandsThenItself() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady(lun: 0)
        try fixture.attachReady(lun: 1)
        let command = fixture.send(lun: 0, tag: 1, cdb: read10(1), dataIn: 512)
        let elsewhere = fixture.send(lun: 1, tag: 2, cdb: read10(2), dataIn: 512)
        let reset = MemoryChain(taskManagement(5, lun: 0), writable: 1)
        let order = CompletionOrder()
        order.watch(command, as: "command")
        order.watch(reset, as: "reset")
        fixture.controller.handleControl(reset)
        #expect(reset.completions == 0)
        executor.complete(0)
        #expect(order.names == ["command", "reset"])
        #expect(try CommandResponse(command.written).response == 4)
        #expect(reset.written == [0])
        #expect(try fixture.response(lun: 0, cdb: testUnitReady).sense == SCSISense.reset.fixed)
        executor.complete(1)
        #expect(try CommandResponse(elsewhere.written).response == 0)
        #expect(try fixture.response(lun: 1, cdb: testUnitReady).status == 0)
    }

    /// A command an abort canceled, still running when a reset comes, is
    /// answered RESET, then both functions in turn.
    @Test func aResetAnswersRESETForACommandAnAbortCanceled() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady()
        let command = fixture.send(tag: 1, cdb: read10(1), dataIn: 512)
        let abort = MemoryChain(taskManagement(0, tag: 1), writable: 1)
        let reset = MemoryChain(taskManagement(5), writable: 1)
        let order = CompletionOrder()
        order.watch(command, as: "command")
        order.watch(abort, as: "abort")
        order.watch(reset, as: "reset")
        fixture.controller.handleControl(abort)
        fixture.controller.handleControl(reset)
        #expect(order.names.isEmpty)
        executor.complete(0)
        #expect(order.names == ["command", "abort", "reset"])
        #expect(try CommandResponse(command.written).response == 4)
    }

    @Test func anITNexusResetWaitsForEveryUnitOfTheTarget() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady(lun: 0)
        try fixture.attachReady(lun: 1)
        try fixture.attachReady(target: 1, lun: 0)
        let first = fixture.send(lun: 0, tag: 1, cdb: read10(1), dataIn: 512)
        let second = fixture.send(lun: 1, tag: 2, cdb: read10(2), dataIn: 512)
        let elsewhere = fixture.send(target: 1, tag: 3, cdb: read10(3), dataIn: 512)
        let reset = fixture.control(taskManagement(4), responseLength: 1)
        executor.complete(1)
        #expect(reset.completions == 0)
        executor.complete(0)
        #expect(reset.written == [0])
        #expect(try CommandResponse(first.written).response == 4)
        #expect(try CommandResponse(second.written).response == 4)
        #expect(elsewhere.completions == 0)
        executor.complete(2)
        #expect(try CommandResponse(elsewhere.written).response == 0)
    }

    /// A device reset cancels what is in flight, waits for its requests to
    /// the image, and answers nothing: the queues go with the reset. An
    /// UNMAP canceled before it started runs its first range and no other.
    @Test func aDeviceResetWaitsForItsCommandsAndAnswersNone() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        let image = try fixture.attachReady(blocks: 64)
        var parameters: [UInt8] = [0, 38, 0, 32, 0, 0, 0, 0]
        parameters += [0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0, 0]
        parameters += [0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0, 16, 0, 0, 0, 0]
        let unmap = fixture.send(tag: 1, cdb: [0x42, 0, 0, 0, 0, 0, 0, 0, UInt8(parameters.count), 0], dataOut: [parameters])
        let abort = fixture.control(taskManagement(0, tag: 1), responseLength: 1)
        fixture.controller.reset()
        #expect(executor.pending == 0)
        #if os(macOS)
        #expect(try image.block(8) == [UInt8](repeating: 0, count: 512))
        #endif
        #expect(try image.block(32) == [UInt8](repeating: 32, count: 512))
        executor.completeAll()
        #expect(unmap.completions == 0)
        #expect(abort.completions == 0)
        #expect(try fixture.response(cdb: testUnitReady).sense == SCSISense.reset.fixed)
    }

    /// When the machine stops, what is in flight runs to its end and
    /// nothing is answered.
    @Test func stoppingRunsWhatIsInFlightAndAnswersNothing() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        let image = try fixture.attachReady()
        let block = [UInt8](repeating: 0xcd, count: 512)
        let write = fixture.send(tag: 1, cdb: write10(3), dataOut: [block])
        fixture.controller.stop()
        #expect(executor.pending == 0)
        #expect(try image.block(3) == block)
        executor.completeAll()
        #expect(write.completions == 0)
    }

    /// Detaching a unit answers its commands ABORTED once their requests to
    /// the image have run, before the driver hears the unit is gone.
    @Test func detachAnswersTheUnitsCommandsBeforeTheEvent() throws {
        let executor = ManualExecutor()
        let fixture = ControllerFixture(executor: executor)
        try fixture.attachReady(lun: 0)
        try fixture.attachReady(lun: 3)
        let queue = MemoryEventQueue()
        queue.post(4)
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        let command = fixture.send(lun: 3, tag: 1, cdb: read10(1), dataIn: 512)
        let elsewhere = fixture.send(lun: 0, tag: 2, cdb: read10(2), dataIn: 512)
        let order = CompletionOrder()
        order.watch(command, as: "command")
        let notice = try #require(queue.buffers.first)
        order.watch(notice, as: "removed")
        #expect(fixture.controller.detach(target: 0, lun: 3) != nil)
        #expect(order.names == ["command", "removed"])
        #expect(try CommandResponse(command.written).response == 2)
        #expect(notice.written == event(transportReset, lun: [1, 0, 0, 3, 0, 0, 0, 0], reason: removed))
        #expect(elsewhere.completions == 0)
        executor.completeAll()
        #expect(command.completions == 1)
        #expect(try CommandResponse(elsewhere.written).response == 0)
    }

    @Test func asynchronousNotificationsReportNone() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady()
        // VIRTIO_SCSI_T_AN_QUERY and VIRTIO_SCSI_T_AN_SUBSCRIBE.
        for type: UInt32 in [1, 2] {
            let chain = fixture.control(asynchronousNotification(type), responseLength: 5)
            #expect(chain.written == [0, 0, 0, 0, 0])
            #expect(chain.completions == 1)
        }
    }

    @Test func aControlRequestOfNoKnownTypeGoesBackUnanswered() {
        let fixture = ControllerFixture()
        var request = [UInt8]()
        request.appendLittleEndian(UInt32(7))
        let chain = fixture.control(request + [UInt8](repeating: 0, count: 20), responseLength: 1)
        #expect(chain.written.isEmpty)
        #expect(chain.completions == 1)
        #expect(fixture.deviceErrors.isEmpty)
    }

    @Test func malformedControlRequestsNeedAReset() {
        let fixture = ControllerFixture()
        // A task management request cut short.
        #expect(fixture.control(Array(taskManagement(5)[..<10]), responseLength: 1).completions == 0)
        #expect(fixture.deviceErrors.count == 1)
        fixture.controller.reset()
        // Data both ways past the request and its response.
        #expect(fixture.control(taskManagement(5) + [0], responseLength: 2).completions == 0)
        #expect(fixture.deviceErrors.count == 2)
        fixture.controller.reset()
        // Data one way past them is no error.
        #expect(fixture.control(taskManagement(5) + [0], responseLength: 1).completions == 1)
        // A type cut short.
        #expect(fixture.control([0, 0], responseLength: 1).completions == 0)
        #expect(fixture.deviceErrors.count == 3)
    }

    // MARK: Event queue

    @Test func eventsWaitForTheDriver() throws {
        let fixture = ControllerFixture()
        let queue = MemoryEventQueue()
        queue.post(4)
        try fixture.attach(lun: 1)
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        #expect(queue.taken.isEmpty)
    }

    @Test func attachAndDetachAreReported() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady(lun: 0)
        let queue = MemoryEventQueue()
        queue.post(4)
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)

        try fixture.attach(lun: 3)
        #expect(queue.taken.count == 1)
        #expect(queue.taken.first?.written == event(transportReset, lun: [1, 0, 0, 3, 0, 0, 0, 0], reason: rescan))
        #expect(queue.taken.first?.completions == 1)
        // The bus then reports that its LUNs changed, once.
        #expect(try fixture.response(lun: 0, cdb: testUnitReady).sense == SCSISense.reportedLUNsDataChanged.fixed)
        #expect(try fixture.response(lun: 0, cdb: testUnitReady).status == 0)
        // The new unit reports its reset.
        #expect(try fixture.response(lun: 3, cdb: testUnitReady).sense == SCSISense.reset.fixed)

        #expect(fixture.controller.detach(target: 0, lun: 3) != nil)
        #expect(queue.taken.count == 2)
        #expect(queue.taken.last?.written == event(transportReset, lun: [1, 0, 0, 3, 0, 0, 0, 0], reason: removed))
        #expect(try fixture.response(lun: 0, cdb: testUnitReady).sense == SCSISense.reportedLUNsDataChanged.fixed)
        // Detaching nothing reports nothing.
        #expect(fixture.controller.detach(target: 0, lun: 3) == nil)
        #expect(queue.taken.count == 2)
    }

    @Test func withoutHotplugNothingIsReported() throws {
        let fixture = ControllerFixture()
        try fixture.attachReady(lun: 0)
        let queue = MemoryEventQueue()
        queue.post(4)
        fixture.controller.driverReady(negotiatedFeatures: 0, eventQueue: queue)
        try fixture.attach(lun: 3)
        fixture.controller.detach(target: 0, lun: 3)
        #expect(queue.taken.isEmpty)
        #expect(try fixture.response(lun: 0, cdb: testUnitReady).status == 0)
    }

    @Test func eventsNameLUNsAsReportLUNsLists() throws {
        let fixture = ControllerFixture()
        let queue = MemoryEventQueue()
        queue.post(2)
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        try fixture.attach(target: 2, lun: 255)
        try fixture.attach(target: 2, lun: 300)
        #expect(
            queue.taken.map(\.written) == [
                event(transportReset, lun: [1, 2, 0, 255, 0, 0, 0, 0], reason: rescan),
                event(transportReset, lun: [1, 2, 0x41, 0x2c, 0, 0, 0, 0], reason: rescan),
            ])
    }

    @Test func aLostEventIsReportedAsMissed() throws {
        let fixture = ControllerFixture()
        let queue = MemoryEventQueue()
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        // With no buffer the event is lost.
        try fixture.attach(lun: 1)
        #expect(queue.taken.isEmpty)
        // The next buffers report the loss, naming no unit.
        queue.post(2)
        fixture.controller.eventBuffersAvailable()
        #expect(queue.taken.map(\.written) == [event(eventsMissed, lun: [0, 0, 0, 0, 0, 0, 0, 0], reason: 0)])
        // Once reported, buffers report nothing more.
        fixture.controller.eventBuffersAvailable()
        #expect(queue.taken.count == 1)
    }

    @Test func theNextEventCarriesTheLoss() throws {
        let fixture = ControllerFixture()
        let queue = MemoryEventQueue()
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        try fixture.attach(lun: 1)
        queue.post(1)
        try fixture.attach(lun: 2)
        #expect(queue.taken.map(\.written) == [event(transportReset | eventsMissed, lun: [1, 0, 0, 2, 0, 0, 0, 0], reason: rescan)])
    }

    @Test func aMalformedEventBufferNeedsAReset() throws {
        let fixture = ControllerFixture()
        let queue = MemoryEventQueue()
        queue.post(1, size: 8)
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        try fixture.attach(lun: 1)
        #expect(fixture.deviceErrors.count == 1)
        #expect(queue.taken.first?.completions == 0)
    }

    @Test func aResetForgetsTheDriver() throws {
        let fixture = ControllerFixture()
        let queue = MemoryEventQueue()
        fixture.controller.driverReady(negotiatedFeatures: VirtioSCSIController.hotplugFeature, eventQueue: queue)
        try fixture.attach(lun: 1)
        fixture.controller.reset()
        queue.post(2)
        fixture.controller.eventBuffersAvailable()
        try fixture.attach(lun: 2)
        #expect(queue.taken.isEmpty)
    }

    @Test func attachRefusals() throws {
        let fixture = ControllerFixture()
        try fixture.attach(lun: 1)
        #expect(throws: (any Error).self) { try fixture.attach(lun: 1) }
        #expect(throws: (any Error).self) { try fixture.attach(lun: 16384) }
        #expect(throws: Never.self) { try fixture.attach(lun: 16383) }
    }
}
