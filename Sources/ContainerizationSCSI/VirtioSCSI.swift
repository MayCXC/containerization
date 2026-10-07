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
import Synchronization

/// A descriptor chain a virtio device took from one of its queues: bytes the
/// driver wrote for the device to read, then buffers for the device to write.
public protocol VirtioDescriptorChain: AnyObject {
    /// The readable bytes the device has not consumed.
    var readableByteCount: Int { get }
    /// The writable bytes the device has not written.
    var writableByteCount: Int { get }
    /// Consumes exactly `buffer.count` readable bytes into `buffer`.
    func read(into buffer: UnsafeMutableRawBufferPointer) -> Bool
    /// Consumes the remaining readable bytes and hands them over where they
    /// lie, readable from any thread until the chain completes.
    func takeReadable() -> any VirtioReadableData
    /// Writes `bytes` into the next writable bytes.
    func write(_ bytes: UnsafeRawBufferPointer) -> Bool
    /// Returns the chain to the driver, with what the device wrote.
    func complete()
}

/// Bytes a driver wrote for the device, left where they lie in its buffers.
public protocol VirtioReadableData: Sendable {
    /// Calls `body` with the buffers, in order.
    func withBuffers<Result>(_ body: ([UnsafeRawBufferPointer]) throws -> Result) rethrows -> Result
}

/// The buffers a virtio-scsi driver keeps on the event queue for the device
/// to report events in.
public protocol VirtioEventQueue: AnyObject {
    /// The next buffer the driver made available, or nil when none is.
    func nextChain() -> (any VirtioDescriptorChain)?
}

/// A virtio SCSI host adapter: the device side of the virtio-scsi transport
/// over a bus of disk logical units.
///
/// The transport follows the virtio specification, section 5.6:
/// https://docs.oasis-open.org/virtio/virtio/v1.3/csd01/virtio-v1.3-csd01.html
/// What the adapter answers on each queue, and when its events go out, are
/// QEMU's virtio-scsi device, hw/scsi/virtio-scsi.c at d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/scsi/virtio-scsi.c
///
/// Commands run as QEMU's do. The adapter takes every request a queue holds
/// and prepares each, then submits them all (virtio_scsi_handle_cmd_vq): a
/// command that completes without the image is answered as it is submitted,
/// and one that waits on the image completes when its operation has, in
/// whatever order the operations finish.
///
/// The adapter is driven from one serial queue, and its state is touched
/// only there. Its executor runs the operations elsewhere and completes them
/// back on that queue.
public final class VirtioSCSIController: @unchecked Sendable {
    public static let deviceID: UInt16 = 8
    /// The control and event queues, ahead of the request queues
    /// (VIRTIO_SCSI_VQ_NUM_FIXED).
    public static let fixedQueueCount: UInt16 = 2
    public static let controlQueue: UInt16 = 0
    public static let eventQueue: UInt16 = 1
    /// The entries a queue holds, which the segment limit is sized by: the
    /// size of the queues of a device on Virtualization's custom virtio
    /// device interface, and QEMU's virtqueue_size default.
    public static let virtqueueSize = 256
    /// The most segments a command takes: its queue's size less the request
    /// and response headers, the seg_max QEMU reports with seg_max_adjust
    /// (virtio_scsi_get_config).
    static let segmentMaximum = virtqueueSize - 2
    /// The most queues a virtio device has (VIRTIO_QUEUE_MAX in
    /// include/hw/virtio/virtio.h).
    static let maximumQueues = 1024

    /// The request queues of a device in a machine of `cpus` vCPUs: one per
    /// vCPU, as QEMU's virtio-scsi-pci gives a device by default
    /// (VIRTIO_SCSI_AUTO_NUM_QUEUES, virtio_pci_optimal_num_queues in
    /// hw/virtio/virtio-pci.c), within the queues a device can have.
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/virtio/virtio-scsi-pci.c
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/virtio/virtio-pci.c
    public static func requestQueueCount(cpus: Int) -> Int {
        min(max(cpus, 1), maximumQueues - Int(fixedQueueCount))
    }
    /// VIRTIO_SCSI_F_HOTPLUG: logical units come and go, reported as events.
    public static let hotplugFeature: UInt64 = 1 << 1
    /// VIRTIO_SCSI_F_CHANGE: a logical unit's parameters change, reported as
    /// events. QEMU reports a disk resized with it; a disk here keeps the
    /// size it was attached with, so there is never a change to report.
    public static let parameterChangeFeature: UInt64 = 1 << 2
    /// The features QEMU's virtio-scsi offers by default, its hotplug and
    /// param_change properties.
    public static let offeredFeatures = hotplugFeature | parameterChangeFeature
    /// The highest target and LUN a virtio-scsi LUN address can name
    /// (section 5.6.6.1): 256 targets of 16384 LUNs.
    public static let maximumTarget: UInt8 = 255
    public static let maximumLUN: UInt16 = 16383

    /// The CDB and sense sizes of the device configuration, the defaults of
    /// section 5.6.4, which the Linux driver also writes back.
    static let cdbSize = 32
    static let senseSize = 96
    static let requestHeaderLength = 19 + cdbSize
    static let responseHeaderLength = 12 + senseSize
    static let eventLength = 16

    enum Response: UInt8 {
        case ok = 0
        case overrun = 1
        case aborted = 2
        case badTarget = 3
        case reset = 4
        case failure = 9
        case functionSucceeded = 10
        case functionRejected = 11
        case incorrectLUN = 12
    }

    enum ControlType: UInt32 {
        case taskManagement = 0
        case asynchronousNotificationQuery = 1
        case asynchronousNotificationSubscribe = 2
    }

    enum TaskManagementFunction: UInt32 {
        case abortTask = 0
        case abortTaskSet = 1
        case clearACA = 2
        case clearTaskSet = 3
        case iTNexusReset = 4
        case logicalUnitReset = 5
        case queryTask = 6
        case queryTaskSet = 7
    }

    static let noEvent: UInt32 = 0
    static let transportReset: UInt32 = 1
    static let eventsMissed: UInt32 = 0x8000_0000
    static let rescan: UInt32 = 1
    static let removed: UInt32 = 2

    /// The device's request queues.
    public let requestQueueCount: Int
    /// The control queue, the event queue and the request queues.
    public var queueCount: UInt16 { Self.fixedQueueCount + UInt16(requestQueueCount) }

    /// struct virtio_scsi_config: the request queues, the segments their
    /// size allows, QEMU's max_sectors and cmd_per_lun, and the largest
    /// targets and LUNs.
    public var configurationSpace: [UInt8] {
        var space = [UInt8]()
        space.appendLittleEndian(UInt32(requestQueueCount))
        space.appendLittleEndian(UInt32(Self.segmentMaximum))
        space.appendLittleEndian(UInt32(0xffff))
        space.appendLittleEndian(UInt32(128))
        space.appendLittleEndian(UInt32(Self.eventLength))
        space.appendLittleEndian(UInt32(Self.senseSize))
        space.appendLittleEndian(UInt32(Self.cdbSize))
        space.appendLittleEndian(UInt16(0))
        space.appendLittleEndian(UInt16(Self.maximumTarget))
        space.appendLittleEndian(UInt32(Self.maximumLUN))
        return space
    }

    /// Called when the driver broke the transport, with what it did: the
    /// device needs a reset (virtio_error), and takes nothing from its
    /// queues until it has one. The chain that broke it is not returned, as
    /// QEMU detaches it without a used element.
    public var onDeviceError: ((String) -> Void)?
    /// Whether the device stopped serving its queues until a reset.
    public private(set) var needsReset = false

    private let bus = SCSIBus()
    private let executor: any SCSIOperationExecutor
    /// The commands whose operations were submitted and that are not yet
    /// answered, by the order they were submitted in.
    private var inFlight: [UInt64: InFlight] = [:]
    private var submitted: UInt64 = 0
    /// Data-in buffers commands have given back, for the next ones.
    private var spareBuffers: [SCSIDataBuffer] = []
    /// The event queue, from the moment the driver is ready (DRIVER_OK).
    private var events: (any VirtioEventQueue)?
    private var hotplugNegotiated = false
    /// Whether an event was lost for want of a buffer since the last one
    /// went out.
    private var eventsDropped = false

    /// An adapter with `requestQueues` request queues, whose image
    /// operations `executor` runs.
    public init(requestQueues: Int = 1, executor: any SCSIOperationExecutor) {
        self.requestQueueCount = min(max(requestQueues, 1), Self.maximumQueues - Int(Self.fixedQueueCount))
        self.executor = executor
    }

    /// A command waiting on its image operation, from the moment the
    /// operation is submitted until the command is answered. The operation
    /// writes `result` on its own thread before the command's completion is
    /// queued, and reads `canceled`; everything else is touched only on the
    /// adapter's queue.
    private final class InFlight: @unchecked Sendable {
        let chain: any VirtioDescriptorChain
        /// The driver's tag for the command, which task management names it by.
        let tag: UInt64
        let request: SCSIBus.Request
        let dataIn: SCSIDataBuffer
        let operation: SCSIOperation
        /// Set when a task management function, an unplug or a reset cancels
        /// the command. The operation reads it between its requests to the
        /// image, and issues no more once it is set.
        let canceled = Atomic(false)
        /// How the operation completed, or nil when the cancel stopped it:
        /// set by the operation, read once it has run.
        var result: SCSICompletion?
        /// What a canceled command is answered with: ABORTED, or RESET when a
        /// reset canceled it (virtio_scsi_request_cancelled).
        var cancellation: Response?
        /// The task management functions waiting for the command to be
        /// answered.
        var waiting: [PendingFunction] = []
        var answered = false
        var position: UInt64 = 0

        var disk: SCSIDisk { request.device.disk }

        init(chain: any VirtioDescriptorChain, tag: UInt64, request: SCSIBus.Request, dataIn: SCSIDataBuffer, operation: SCSIOperation) {
            self.chain = chain
            self.tag = tag
            self.request = request
            self.dataIn = dataIn
            self.operation = operation
        }

        func cancel(_ response: Response) {
            cancellation = response
            canceled.store(true, ordering: .releasing)
        }
    }

    /// A task management function waiting for the commands it canceled to
    /// be answered, and answered after the last of them (the remaining count
    /// of virtio_scsi_tmf_dec_remaining).
    private final class PendingFunction {
        let chain: any VirtioDescriptorChain
        var remaining = 0

        init(chain: any VirtioDescriptorChain) {
            self.chain = chain
        }
    }

    // MARK: - Device life cycle

    /// The driver is ready (DRIVER_OK) with the features it accepted.
    ///
    /// QEMU knows the features from the moment the driver sets them, and a
    /// unit attached between then and DRIVER_OK raises the bus's REPORTED
    /// LUNS DATA HAS CHANGED there. The custom Virtio device interface
    /// reports them at DRIVER_OK, so until then units attach as they do
    /// before any driver, each reporting its own reset.
    public func driverReady(negotiatedFeatures: UInt64, eventQueue: any VirtioEventQueue) {
        hotplugNegotiated = negotiatedFeatures & Self.hotplugFeature != 0
        events = eventQueue
    }

    /// The device resets: every logical unit with it, and what the driver
    /// negotiated (virtio_scsi_reset). Each unit's reset cancels its commands
    /// and waits for their operations, and the queues go with the device's
    /// reset, so none of the commands is answered.
    public func reset() {
        let commands = Array(inFlight.values)
        for command in commands {
            command.cancel(.reset)
        }
        drop(commands)
        bus.reset()
        events = nil
        hotplugNegotiated = false
        eventsDropped = false
        needsReset = false
    }

    /// The machine stops: the commands in flight run to their end, and none
    /// is answered, as the queues stop with the machine (QEMU drains the
    /// block layer as a machine stops, bdrv_drain_all).
    public func stop() {
        drop(Array(inFlight.values))
    }

    /// Waits for the operations of `commands`, then lets go of the commands
    /// without answering them.
    private func drop(_ commands: [InFlight]) {
        guard !commands.isEmpty else {
            return
        }
        executor.waitForRunningOperations()
        for command in commands {
            command.answered = true
            inFlight[command.position] = nil
            giveBack(command.dataIn)
        }
    }

    private func deviceError(_ reason: String) {
        needsReset = true
        onDeviceError?(reason)
    }

    // MARK: - Logical units

    /// Attaches `disk` at `target` and `lun`. It starts reset, as a device
    /// plugged in does, and once the driver is ready an event reports it.
    public func attach(_ disk: SCSIDisk, target: UInt8, lun: UInt16) throws {
        guard lun <= Self.maximumLUN else {
            throw ContainerizationError(.invalidArgument, message: "LUN \(lun) is past the highest a virtio-scsi address names, \(Self.maximumLUN)")
        }
        let address = SCSIBus.Address(target: target, lun: lun)
        guard bus.attach(disk, at: address) else {
            throw ContainerizationError(.exists, message: "a logical unit is already attached at target \(target) LUN \(lun)")
        }
        disk.reset()
        if hotplugNegotiated {
            pushEvent(Self.transportReset, reason: Self.rescan, address: address)
            bus.raiseUnitAttention(.reportedLUNsDataChanged)
        }
    }

    /// Detaches the logical unit at `target` and `lun`, and returns it. No
    /// operation reaches the unit's image once it returns.
    ///
    /// The unit's commands are purged as it goes (scsi_qdev_unrealize):
    /// those not already canceled are aborted, and each is answered once its
    /// operation has run, before the driver hears the unit is gone
    /// (virtio_scsi_hotunplug).
    @discardableResult
    public func detach(target: UInt8, lun: UInt16) -> SCSIDisk? {
        let address = SCSIBus.Address(target: target, lun: lun)
        guard let disk = bus.detach(at: address) else {
            return nil
        }
        let commands = self.commands(of: disk)
        for command in commands where command.cancellation == nil {
            command.cancel(.aborted)
        }
        if !commands.isEmpty {
            executor.waitForRunningOperations()
            for command in commands where !command.answered {
                answer(command)
            }
        }
        if hotplugNegotiated {
            pushEvent(Self.transportReset, reason: Self.removed, address: address)
            bus.raiseUnitAttention(.reportedLUNsDataChanged)
        }
        return disk
    }

    // MARK: - Request queue

    /// A request whose command is routed to its unit and ready to run, with
    /// the data the driver sent and a buffer for what the command returns.
    private struct Prepared {
        let chain: any VirtioDescriptorChain
        /// The driver's tag for the command, which task management names it by.
        let tag: UInt64
        let request: SCSIBus.Request
        let dataOut: SCSIDataOut
        let dataIn: SCSIDataBuffer
    }

    /// Serves the requests a request queue holds, taking each from `next`
    /// until it returns nil (virtio_scsi_handle_cmd_vq). Every request is
    /// prepared, then the commands of all of them are submitted.
    public func handleRequests(from next: () -> (any VirtioDescriptorChain)?) {
        var prepared: [Prepared] = []
        while !needsReset, let chain = next() {
            if let command = prepare(chain) {
                prepared.append(command)
            }
        }
        // A request that broke the transport leaves the commands prepared
        // with it unrun and unanswered, as QEMU detaches them
        // (virtqueue_detach_element).
        guard !needsReset else {
            for command in prepared {
                giveBack(command.dataIn)
            }
            return
        }
        for command in prepared {
            submit(command)
        }
    }

    /// Serves one request from a request queue.
    public func handleRequest(_ chain: any VirtioDescriptorChain) {
        var pending: (any VirtioDescriptorChain)? = chain
        handleRequests {
            defer { pending = nil }
            return pending
        }
    }

    /// Prepares a request (virtio_scsi_handle_cmd_req_prepare): answers one
    /// the transport refuses, and routes the command of any other.
    private func prepare(_ chain: any VirtioDescriptorChain) -> Prepared? {
        guard chain.readableByteCount >= Self.requestHeaderLength, chain.writableByteCount >= Self.responseHeaderLength else {
            deviceError("wrong size for virtio-scsi headers")
            return nil
        }
        var header = [UInt8](repeating: 0, count: Self.requestHeaderLength)
        guard header.withUnsafeMutableBytes({ chain.read(into: $0) }) else {
            deviceError("wrong size for virtio-scsi headers")
            return nil
        }
        let dataOutLength = chain.readableByteCount
        let dataInCapacity = chain.writableByteCount - Self.responseHeaderLength
        // VIRTIO_SCSI_F_INOUT is not offered: a request may move data one
        // way only.
        guard dataOutLength == 0 || dataInCapacity == 0 else {
            respond(on: chain, .failure)
            return nil
        }
        let direction: SCSICommand.Direction = dataOutLength > 0 ? .toDevice : dataInCapacity > 0 ? .fromDevice : .none
        guard let address = Self.address(Array(header[0..<8])), let request = bus.prepare(Array(header[19...]), at: address) else {
            respond(on: chain, .badTarget)
            return nil
        }
        // The command must move its data the way the driver's buffers go, and
        // fit them.
        if request.direction != .none && (request.direction != direction || request.transferLength > dataOutLength + dataInCapacity) {
            respond(on: chain, .overrun)
            return nil
        }
        return Prepared(
            chain: chain,
            tag: header.littleEndian64(at: 8),
            request: request,
            dataOut: SCSIDataOut(chain.takeReadable()),
            dataIn: takeBuffer()
        )
    }

    /// Runs a prepared command (virtio_scsi_handle_cmd_req_submit): answers
    /// it when it completes without the image, and otherwise submits the
    /// operation it waits on and answers it once that has run.
    private func submit(_ prepared: Prepared) {
        let operation: SCSIOperation
        switch bus.execute(prepared.request, dataOut: prepared.dataOut, dataIn: prepared.dataIn) {
        case .completed(let completion):
            respond(on: prepared.chain, to: prepared.request, completion, dataIn: prepared.dataIn)
            giveBack(prepared.dataIn)
            return
        case .waiting(let waiting):
            operation = waiting
        }
        let command = InFlight(chain: prepared.chain, tag: prepared.tag, request: prepared.request, dataIn: prepared.dataIn, operation: operation)
        submitted += 1
        command.position = submitted
        inFlight[submitted] = command
        executor.submit(
            {
                command.result = command.operation.run(until: { command.canceled.load(ordering: .acquiring) })
            },
            completion: { [weak self] in
                guard let self, !command.answered else {
                    return
                }
                self.answer(command)
            })
    }

    /// Answers a command whose operation has run: with how it completed, or
    /// with its cancellation (virtio_scsi_command_complete and
    /// virtio_scsi_request_cancelled). The task management functions waiting
    /// for it hear it was answered.
    private func answer(_ command: InFlight) {
        command.answered = true
        inFlight[command.position] = nil
        if let cancellation = command.cancellation {
            respond(on: command.chain, cancellation)
        } else {
            let completion = bus.finish(command.request, command.result ?? .checkCondition(.ioProcessTerminated), dataIn: command.dataIn)
            respond(on: command.chain, to: command.request, completion, dataIn: command.dataIn)
        }
        giveBack(command.dataIn)
        for function in command.waiting {
            function.remaining -= 1
            if function.remaining == 0 {
                writeControl(function.chain, [Response.ok.rawValue])
            }
        }
    }

    /// Writes a command's response: its status, with its data when it
    /// succeeded and its sense when it did not.
    private func respond(on chain: any VirtioDescriptorChain, to request: SCSIBus.Request, _ completion: SCSICompletion, dataIn: SCSIDataBuffer) {
        if completion.status == .good {
            // The residual counts from the command's own transfer length.
            let transferred = request.direction == .toDevice ? request.transferLength : dataIn.count
            respond(on: chain, .ok, status: .good, residual: UInt32(clamping: request.transferLength - transferred), data: dataIn.content)
        } else {
            respond(on: chain, .ok, status: completion.status, sense: completion.sense?.data(descriptorFormat: false) ?? [])
        }
    }

    /// The commands in flight to `disk`, in the order they were submitted.
    private func commands(of disk: SCSIDisk) -> [InFlight] {
        inFlight.keys.sorted().compactMap { inFlight[$0] }.filter { $0.disk === disk }
    }

    /// A data-in buffer for a command, one a command gave back when there is
    /// one.
    private func takeBuffer() -> SCSIDataBuffer {
        spareBuffers.popLast() ?? SCSIDataBuffer(capacity: 64 * 1024)
    }

    /// Takes back a command's data-in buffer, keeping as many as the most
    /// operations that run at once.
    private func giveBack(_ buffer: SCSIDataBuffer) {
        buffer.clear()
        if spareBuffers.count < SCSIOperationPool.maximumWorkers {
            spareBuffers.append(buffer)
        }
    }

    /// The target and LUN a virtio-scsi LUN address names: 1, the target, a
    /// single-level LUN of up to 16383, then zeros (virtio_scsi_device_get).
    static func address(_ lun: [UInt8]) -> SCSIBus.Address? {
        guard lun[0] == 1, lun[2] == 0 || (0x40..<0x80).contains(lun[2]) else {
            return nil
        }
        return SCSIBus.Address(target: lun[1], lun: (UInt16(lun[2]) << 8 | UInt16(lun[3])) & 0x3fff)
    }

    /// Writes struct virtio_scsi_cmd_resp, with its sense buffer, and the
    /// data, and returns the chain.
    private func respond(
        on chain: any VirtioDescriptorChain,
        _ response: Response,
        status: SCSIStatus = .good,
        residual: UInt32 = 0,
        sense: [UInt8] = [],
        data: UnsafeRawBufferPointer? = nil
    ) {
        let senseLength = min(sense.count, Self.senseSize)
        var header = [UInt8]()
        header.appendLittleEndian(UInt32(senseLength))
        header.appendLittleEndian(residual)
        header.appendLittleEndian(UInt16(0))
        header.append(status.rawValue)
        header.append(response.rawValue)
        header += sense.prefix(senseLength)
        header += [UInt8](repeating: 0, count: Self.senseSize - senseLength)
        var written = header.withUnsafeBytes { chain.write($0) }
        if written, let data, !data.isEmpty {
            written = chain.write(data)
        }
        guard written else {
            deviceError("wrong size for virtio-scsi responses")
            return
        }
        chain.complete()
    }

    // MARK: - Control queue

    /// Serves one request from the control queue and returns its chain.
    public func handleControl(_ chain: any VirtioDescriptorChain) {
        guard !needsReset else {
            return
        }
        var typeBytes = [UInt8](repeating: 0, count: 4)
        guard typeBytes.withUnsafeMutableBytes({ chain.read(into: $0) }) else {
            deviceError("wrong size for virtio-scsi headers")
            return
        }
        switch ControlType(rawValue: typeBytes.littleEndian32(at: 0)) {
        case .taskManagement:
            // struct virtio_scsi_ctrl_tmf: subtype, LUN and tag after the
            // type, then the response.
            guard let request = readControl(chain, length: 20, responseLength: 1) else {
                return
            }
            manageTask(subtype: request.littleEndian32(at: 0), lun: Array(request[4..<12]), tag: request.littleEndian64(at: 12), answering: chain)
        case .asynchronousNotificationQuery, .asynchronousNotificationSubscribe:
            // struct virtio_scsi_ctrl_an: the LUN and the events asked for.
            // No asynchronous events are supported.
            guard readControl(chain, length: 12, responseLength: 5) != nil else {
                return
            }
            var response = [UInt8]()
            response.appendLittleEndian(UInt32(0))
            response.append(Response.ok.rawValue)
            writeControl(chain, response)
        case nil:
            // A type with no meaning goes back unanswered.
            chain.complete()
        }
    }

    /// Reads the rest of a control request, which the chain must hold along
    /// with room for its response, and data neither way besides.
    private func readControl(_ chain: any VirtioDescriptorChain, length: Int, responseLength: Int) -> [UInt8]? {
        let fits = chain.readableByteCount >= length && chain.writableByteCount >= responseLength
        let movesBothWays = chain.readableByteCount > length && chain.writableByteCount > responseLength
        var request = [UInt8](repeating: 0, count: length)
        guard fits, !movesBothWays, request.withUnsafeMutableBytes({ chain.read(into: $0) }) else {
            deviceError("wrong size for virtio-scsi headers")
            return nil
        }
        return request
    }

    private func writeControl(_ chain: any VirtioDescriptorChain, _ response: [UInt8]) {
        guard response.withUnsafeBytes({ chain.write($0) }) else {
            deviceError("wrong size for virtio-scsi responses")
            return
        }
        chain.complete()
    }

    /// A task management function (virtio_scsi_do_tmf), answered on `chain`.
    ///
    /// An abort cancels the commands it names that are in flight and not
    /// already canceled, and is answered once they are. A reset cancels every
    /// command its units have in flight, which the reset answers RESET, and
    /// is answered once all of them are, as QEMU's reset drains the unit's
    /// I/O (scsi_device_purge_requests). A query finds the commands in flight
    /// that are not canceled.
    private func manageTask(subtype: UInt32, lun: [UInt8], tag: UInt64, answering chain: any VirtioDescriptorChain) {
        let address = Self.address(lun)
        let device = address.flatMap { bus.device(at: $0) }
        let function = TaskManagementFunction(rawValue: subtype)
        switch function {
        case .abortTask, .abortTaskSet, .clearTaskSet, .queryTask, .queryTaskSet, .logicalUnitReset:
            guard let address, let device else {
                writeControl(chain, [Response.badTarget.rawValue])
                return
            }
            guard device.address == address else {
                writeControl(chain, [Response.incorrectLUN.rawValue])
                return
            }
            let live = commands(of: device.disk).filter { $0.cancellation == nil }
            switch function {
            case .abortTask:
                abort(live.filter { $0.tag == tag }, answering: chain)
            case .abortTaskSet, .clearTaskSet:
                abort(live, answering: chain)
            case .queryTask:
                // FUNCTION SUCCEEDED when the command is in the task set.
                writeControl(chain, [(live.contains { $0.tag == tag } ? Response.functionSucceeded : Response.ok).rawValue])
            case .queryTaskSet:
                writeControl(chain, [(live.isEmpty ? Response.ok : Response.functionSucceeded).rawValue])
            default:
                resetUnits([device.disk], answering: chain)
            }
        case .iTNexusReset:
            resetUnits(bus.units.filter { $0.key.target == lun[1] }.map(\.value), answering: chain)
        case .clearACA, nil:
            writeControl(chain, [Response.functionRejected.rawValue])
        }
    }

    /// Cancels `commands`, which are answered ABORTED once their operations
    /// have run, and answers the function on `chain` after the last of them
    /// (virtio_scsi_tmf_cancel_req).
    private func abort(_ commands: [InFlight], answering chain: any VirtioDescriptorChain) {
        for command in commands {
            command.cancel(.aborted)
        }
        answer(chain, after: commands)
    }

    /// Resets `disks`, which report the reset to their next command, and
    /// cancels everything they have in flight, which is answered RESET; the
    /// function on `chain` is answered once all of it is (scsi_disk_reset).
    private func resetUnits(_ disks: [SCSIDisk], answering chain: any VirtioDescriptorChain) {
        let commands = inFlight.keys.sorted().compactMap { inFlight[$0] }.filter { command in
            disks.contains { $0 === command.disk }
        }
        for command in commands {
            command.cancel(.reset)
        }
        for disk in disks {
            disk.reset()
        }
        answer(chain, after: commands)
    }

    /// Answers a task management function FUNCTION COMPLETE once `commands`
    /// are answered, or at once when there are none.
    private func answer(_ chain: any VirtioDescriptorChain, after commands: [InFlight]) {
        guard !commands.isEmpty else {
            writeControl(chain, [Response.ok.rawValue])
            return
        }
        let function = PendingFunction(chain: chain)
        function.remaining = commands.count
        for command in commands {
            command.waiting.append(function)
        }
    }

    // MARK: - Event queue

    /// The driver made event buffers available. If an event was lost for
    /// want of one, the driver hears that events were missed, so that it
    /// rescans (virtio_scsi_handle_event_vq).
    public func eventBuffersAvailable() {
        guard !needsReset, eventsDropped else {
            return
        }
        pushEvent(Self.noEvent, reason: 0, address: nil)
    }

    /// Reports an event in the next event buffer (virtio_scsi_push_event).
    /// Before the driver is ready nothing is reported; with no buffer the
    /// event is lost, and the next one carries VIRTIO_SCSI_T_EVENTS_MISSED.
    private func pushEvent(_ event: UInt32, reason: UInt32, address: SCSIBus.Address?) {
        guard !needsReset, let events else {
            return
        }
        guard let chain = events.nextChain() else {
            eventsDropped = true
            return
        }
        var event = event
        if eventsDropped {
            event |= Self.eventsMissed
            eventsDropped = false
        }
        guard chain.writableByteCount >= Self.eventLength, chain.readableByteCount == 0 || chain.writableByteCount == Self.eventLength else {
            deviceError("wrong size for virtio-scsi events")
            return
        }
        // struct virtio_scsi_event. Only the missed events notice names no
        // logical unit; the others name theirs as REPORT LUNS lists it.
        var bytes = [UInt8]()
        bytes.appendLittleEndian(event)
        var lun = [UInt8](repeating: 0, count: 8)
        if event != Self.eventsMissed, let address {
            lun[0] = 1
            lun[1] = address.target
            let encoded = SCSIBus.encode(lun: address.lun)
            lun[2] = encoded[0]
            lun[3] = encoded[1]
        }
        bytes += lun
        bytes.appendLittleEndian(reason)
        guard bytes.withUnsafeBytes({ chain.write($0) }) else {
            deviceError("wrong size for virtio-scsi events")
            return
        }
        chain.complete()
    }
}
