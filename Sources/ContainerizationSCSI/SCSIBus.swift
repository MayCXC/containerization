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

/// The logical units behind one host adapter, by target and LUN, and what
/// the bus answers for them itself: REPORT LUNS, commands to a LUN with no
/// device, pending unit attention conditions and the sense REQUEST SENSE
/// returns.
///
/// The routing and those answers are QEMU's SCSI bus, scsi_req_new,
/// scsi_target_send_command and scsi_req_complete in hw/scsi/scsi-bus.c at
/// d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/scsi/scsi-bus.c
final class SCSIBus {
    struct Address: Hashable, Comparable {
        var target: UInt8
        var lun: UInt16

        static func < (lhs: Address, rhs: Address) -> Bool {
            (lhs.target, lhs.lun) < (rhs.target, rhs.lun)
        }
    }

    /// A command on its way to a logical unit.
    struct Request {
        enum Route {
            /// The device reports a pending unit attention condition instead.
            case unitAttention(SCSISense)
            /// The bus answers: REPORT LUNS, deferred sense, or a LUN with no
            /// device.
            case target(SCSICommand)
            case device(SCSICommand)
            case invalidOperationCode
            case invalidField
        }

        let route: Route
        /// The decoded CDB, whose transfer the transport checks its buffers
        /// against; nil when it did not decode.
        let command: SCSICommand?
        /// Where the command was sent.
        let address: Address
        /// The device that answers for that address.
        let device: (address: Address, disk: SCSIDisk)

        var transferLength: Int { command?.transferLength ?? 0 }
        var direction: SCSICommand.Direction { command?.direction ?? .none }
    }

    private(set) var units: [Address: SCSIDisk] = [:]
    /// The attached addresses, the most recently attached first. It is the
    /// order QEMU's bus keeps its devices in, each one added at the head
    /// (bus_add_child in hw/core/qdev.c at d7a65d1793d6:
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/core/qdev.c), and
    /// the order REPORT LUNS lists them and a target's other unit is found in.
    private var attachOrder: [Address] = []
    /// A unit attention condition every logical unit reports until one has.
    private(set) var unitAttention: SCSISense?

    /// The identification INQUIRY gives LUN 0 of a target with no device
    /// there (QEMU's "QEMU TARGET").
    static let targetIdentity = SCSIDisk.Identity(product: "SCSI Target")

    func attach(_ disk: SCSIDisk, at address: Address) -> Bool {
        guard units[address] == nil else {
            return false
        }
        units[address] = disk
        attachOrder.insert(address, at: 0)
        return true
    }

    func detach(at address: Address) -> SCSIDisk? {
        attachOrder.removeAll { $0 == address }
        return units.removeValue(forKey: address)
    }

    /// Makes `sense` the condition every logical unit reports, unless one
    /// ranked before it is already pending (scsi_bus_set_ua).
    func raiseUnitAttention(_ sense: SCSISense) {
        if sense.unitAttentionRank < (unitAttention?.unitAttentionRank ?? Int.max) {
            unitAttention = sense
        }
    }

    /// Resets the logical units of `target`, or of every target.
    func reset(target: UInt8? = nil) {
        for (address, disk) in units where target == nil || address.target == target {
            disk.reset()
        }
    }

    /// The device that answers for `address`: the logical unit there, else
    /// the target's most recently attached one, which answers for the LUNs
    /// the target has no device at (do_scsi_device_find).
    func device(at address: Address) -> (address: Address, disk: SCSIDisk)? {
        if let disk = units[address] {
            return (address, disk)
        }
        guard let other = attachOrder.first(where: { $0.target == address.target }), let disk = units[other] else {
            return nil
        }
        return (other, disk)
    }

    /// Routes a command for `address`, or returns nil when its target has
    /// no device.
    func prepare(_ cdb: [UInt8], at address: Address) -> Request? {
        guard let device = self.device(at: address), let opcode = cdb.first else {
            return nil
        }
        let disk = device.disk
        let decoded = SCSICommand(cdb, blockSize: SCSIDisk.blockSize)
        guard let command = decoded else {
            return Request(route: .invalidOperationCode, command: nil, address: address, device: device)
        }
        guard command.transferLength <= Int(Int32.max) else {
            return Request(route: .invalidField, command: command, address: address, device: device)
        }
        // Inquiries and REPORT LUNS go through ahead of a unit attention.
        let exempt =
            opcode == SCSIOpcode.inquiry || opcode == SCSIOpcode.reportLUNs || opcode == SCSIOpcode.getConfiguration
            || opcode == SCSIOpcode.getEventStatusNotification
        if !exempt {
            if let sense = disk.unitAttention {
                disk.unitAttention = nil
                return Request(route: .unitAttention(sense), command: command, address: address, device: device)
            }
            if let sense = unitAttention {
                unitAttention = nil
                return Request(route: .unitAttention(sense), command: command, address: address, device: device)
            }
        }
        let answeredByBus =
            address != device.address || opcode == SCSIOpcode.reportLUNs || (opcode == SCSIOpcode.requestSense && disk.deferredSense != nil)
        return Request(route: answeredByBus ? .target(command) : .device(command), command: command, address: address, device: device)
    }

    /// Runs a routed command, or hands back the image operation it waits
    /// on; `finish` completes it once the operation has run.
    func execute(_ request: Request, dataOut: SCSIDataOut, dataIn: SCSIDataBuffer) -> SCSIDisk.Outcome {
        dataIn.clear()
        let completion: SCSICompletion
        switch request.route {
        case .unitAttention(let sense):
            request.device.disk.deferredSense = nil
            return .completed(.checkCondition(sense))
        case .invalidOperationCode:
            completion = .checkCondition(.invalidOperationCode)
        case .invalidField:
            completion = .checkCondition(.invalidFieldInCDB)
        case .target(let command):
            completion = answer(command, of: request, dataIn: dataIn)
        case .device(let command):
            switch request.device.disk.execute(command, dataOut: dataOut, dataIn: dataIn) {
            case .completed(let done):
                completion = done
            case .waiting(let operation):
                return .waiting(operation)
            }
        }
        return .completed(finish(request, completion, dataIn: dataIn))
    }

    /// Completes a command with `completion`.
    ///
    /// The sense of a command that fails goes back with its response, and
    /// the device keeps it for REQUEST SENSE until a command succeeds,
    /// whichever command completes last setting it (scsi_req_complete). A
    /// unit attention condition is reported once: the response carries it,
    /// so the device keeps nothing of it (scsi_req_get_sense).
    func finish(_ request: Request, _ completion: SCSICompletion, dataIn: SCSIDataBuffer) -> SCSICompletion {
        let disk = request.device.disk
        if completion.status == .good {
            disk.deferredSense = nil
        } else {
            dataIn.clear()
            disk.deferredSense = completion.sense
        }
        return completion
    }

    /// What the bus answers itself (scsi_target_send_command).
    private func answer(_ command: SCSICommand, of request: Request, dataIn: SCSIDataBuffer) -> SCSICompletion {
        let cdb = command.cdb
        let lun = request.address.lun
        let opcode = cdb[0]
        guard lun == 0 || opcode == SCSIOpcode.inquiry || opcode == SCSIOpcode.requestSense else {
            return .checkCondition(.logicalUnitNotSupported)
        }
        switch opcode {
        case SCSIOpcode.reportLUNs:
            return reportLUNs(command, of: request.device.disk, target: request.address.target, into: dataIn)
        case SCSIOpcode.inquiry:
            return inquiry(command, lun: lun, into: dataIn)
        case SCSIOpcode.requestSense:
            let descriptorFormat = cdb[1] & 0x01 != 0
            // A LUN with no device reports that it has none. A device's own
            // LUN reports its sense: QEMU reports LUN NOT SUPPORTED for any
            // LUN but 0 here, the sense of a device at another LUN included.
            let sense =
                request.address != request.device.address && lun != 0
                ? SCSISense.logicalUnitNotSupported : request.device.disk.deferredSense ?? .noSense
            let data = sense.data(descriptorFormat: descriptorFormat)
            dataIn.fill(data, length: min(data.count, command.transferLength))
            return .good
        case SCSIOpcode.testUnitReady:
            return .good
        default:
            return .checkCondition(.invalidOperationCode)
        }
    }

    private func reportLUNs(_ command: SCSICommand, of disk: SCSIDisk, target: UInt8, into dataIn: SCSIDataBuffer) -> SCSICompletion {
        // SELECT REPORT: 0, 1 and 2, the logical units and the well-known
        // ones, all list the same.
        guard command.transferLength >= 16, command.cdb[2] <= 2 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        // LUN 0 is listed first whether a device answers there or not.
        let luns = [UInt16(0)] + attachOrder.filter { $0.target == target && $0.lun != 0 }.map(\.lun)
        var data = [UInt8]()
        data.appendBigEndian(UInt32(luns.count * 8))
        data += [0, 0, 0, 0]
        for lun in luns {
            data += Self.encode(lun: lun) + [0, 0, 0, 0, 0, 0]
        }
        dataIn.fill(data, length: min(data.count, command.transferLength & ~7))
        // A REPORT LUNS that runs clears a REPORTED LUNS DATA HAS CHANGED
        // condition (SPC-4, 6.33).
        if disk.unitAttention != nil {
            if disk.unitAttention == .reportedLUNsDataChanged {
                disk.unitAttention = nil
            }
        } else if unitAttention == .reportedLUNsDataChanged {
            unitAttention = nil
        }
        return .good
    }

    /// A LUN as REPORT LUNS lists it and an event names it: single level,
    /// with peripheral device addressing below 256 and flat space addressing
    /// from there (store_lun).
    static func encode(lun: UInt16) -> [UInt8] {
        lun < 256 ? [0, UInt8(lun)] : [0x40 | UInt8(lun >> 8), UInt8(lun & 0xff)]
    }

    /// INQUIRY of a LUN with no device (scsi_target_emulate_inquiry).
    private func inquiry(_ command: SCSICommand, lun: UInt16, into dataIn: SCSIDataBuffer) -> SCSICompletion {
        let cdb = command.cdb
        // CMDDT is not supported.
        guard cdb[1] & 0x02 == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        // Peripheral qualifier 011b for a LUN the target does not have, and
        // 001b, not connected, for its LUN 0.
        let peripheral: UInt8 = lun != 0 ? 0x7f : 0x3f
        if cdb[1] & 0x01 != 0 {
            // EVPD: only the supported pages page, which lists itself, laid
            // out as SPC lays out a VPD page. QEMU's target puts the page
            // code where the peripheral byte goes and the count of pages in
            // the page length's first byte.
            guard cdb[2] == 0 else {
                return .checkCondition(.invalidFieldInCDB)
            }
            let data: [UInt8] = [peripheral, 0x00, 0x00, 0x01, 0x00]
            dataIn.fill(data, length: min(data.count, command.transferLength))
            return .good
        }
        guard cdb[2] == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        let length = min(command.transferLength, 36)
        var data = [UInt8](repeating: 0, count: 36)
        data[0] = peripheral
        if lun == 0 {
            data[2] = SCSIDisk.version
            data[3] = 0x12
            data[4] = UInt8(truncatingIfNeeded: length - 5)
            data[7] = 0x12
            data.place(Self.targetIdentity.vendor, at: 8, width: 8, padding: 0x20)
            data.place(Self.targetIdentity.product, at: 16, width: 16, padding: 0x20)
            data.place(Self.targetIdentity.revision, at: 32, width: 4, padding: 0)
        }
        dataIn.fill(data, length: length)
        return .good
    }
}
