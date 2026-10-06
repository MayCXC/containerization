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

/// Logical units on a bus, and the commands they run through it.
final class BusFixture {
    let bus = SCSIBus()
    private var images: [TemporaryImage] = []

    @discardableResult
    func attach(target: UInt8 = 0, lun: UInt16, blocks: Int = 16) throws -> SCSIDisk {
        let image = try TemporaryImage(blocks: blocks)
        images.append(image)
        let disk = try SCSIDisk(image: SCSIDiskImage(path: image.path, readOnly: false))
        try #require(bus.attach(disk, at: SCSIBus.Address(target: target, lun: lun)))
        return disk
    }

    /// Runs `cdb` through the bus. An image operation runs before it returns.
    func run(_ cdb: [UInt8], target: UInt8 = 0, lun: UInt16 = 0, dataOut: [UInt8] = []) throws -> (completion: SCSICompletion, data: [UInt8]) {
        let request = try #require(bus.prepare(cdb, at: SCSIBus.Address(target: target, lun: lun)))
        let dataIn = SCSIDataBuffer(capacity: 4096)
        let completion: SCSICompletion
        switch bus.execute(request, dataOut: SCSIDataOut(bytes: dataOut), dataIn: dataIn) {
        case .completed(let done):
            completion = done
        case .waiting(let operation):
            completion = bus.finish(request, try #require(operation.run()), dataIn: dataIn)
        }
        return (completion, Array(dataIn.content))
    }
}

private func reportLUNs(allocationLength: UInt8, select: UInt8 = 0) -> [UInt8] {
    [0xa0, 0, select, 0, 0, 0, 0, 0, 0, allocationLength, 0, 0]
}

private func inquiry(evpd: Bool = false, page: UInt8 = 0, allocationLength: UInt8 = 96) -> [UInt8] {
    [0x12, evpd ? 1 : 0, page, 0, allocationLength, 0]
}

private func requestSense(descriptorFormat: Bool = false, allocationLength: UInt8 = 252) -> [UInt8] {
    [0x03, descriptorFormat ? 1 : 0, 0, 0, allocationLength, 0]
}

/// How QEMU's SCSI bus routes commands and what it answers itself:
/// scsi_req_new, scsi_target_send_command and the unit attention handling
/// in hw/scsi/scsi-bus.c at d7a65d1793d6.
struct SCSIBusTests {
    // MARK: REPORT LUNS

    @Test func reportLUNsListsLUNZeroThenTheNewestFirst() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        try fixture.attach(lun: 3)
        try fixture.attach(lun: 1)
        try fixture.attach(lun: 300)
        try fixture.attach(target: 1, lun: 5)
        let (completion, data) = try fixture.run(reportLUNs(allocationLength: 64))
        #expect(completion == .good)
        #expect(Array(data[0..<8]) == [0, 0, 0, 32, 0, 0, 0, 0])
        #expect(Array(data[8...]) == [0, 0] + [0, 0, 0, 0, 0, 0] + [0x41, 0x2c] + [0, 0, 0, 0, 0, 0] + [0, 1] + [0, 0, 0, 0, 0, 0] + [0, 3] + [0, 0, 0, 0, 0, 0])
    }

    @Test func reportLUNsListsLUNZeroWithoutADeviceThere() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 2)
        // The target's other unit answers for LUN 0.
        let (completion, data) = try fixture.run(reportLUNs(allocationLength: 64))
        #expect(completion == .good)
        #expect(data == [0, 0, 0, 16, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 8) + [0, 2, 0, 0, 0, 0, 0, 0])
    }

    @Test func reportLUNsAllocationLength() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        try fixture.attach(lun: 1)
        // Cut to whole entries, the list's length still counting them all.
        #expect(try fixture.run(reportLUNs(allocationLength: 20)).data == [0, 0, 0, 16, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
        #expect(try fixture.run(reportLUNs(allocationLength: 15)).completion == .checkCondition(.invalidFieldInCDB))
        #expect(try fixture.run(reportLUNs(allocationLength: 64, select: 2)).completion == .good)
        #expect(try fixture.run(reportLUNs(allocationLength: 64, select: 3)).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func reportLUNsToAnotherLUNIsNotSupported() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        try fixture.attach(lun: 1)
        #expect(try fixture.run(reportLUNs(allocationLength: 64), lun: 1).completion == .checkCondition(.logicalUnitNotSupported))
    }

    // MARK: LUNs with no device

    @Test func inquiryOfALUNWithNoDevice() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        let (completion, data) = try fixture.run(inquiry(), lun: 7)
        #expect(completion == .good)
        // Peripheral qualifier 011b, cut to the standard data's 36 bytes.
        #expect(data == [0x7f] + [UInt8](repeating: 0, count: 35))
    }

    @Test func inquiryOfAnEmptyLUNZero() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 2)
        let (completion, data) = try fixture.run(inquiry())
        #expect(completion == .good)
        var expected: [UInt8] = [0x3f, 0x00, 5, 0x12, 31, 0, 0, 0x12]
        expected += Array("Virtual ".utf8) + Array("SCSI Target     ".utf8) + Array("1.0".utf8) + [0]
        #expect(data == expected)
        // The additional length counts what the allocation length leaves.
        #expect(try fixture.run(inquiry(allocationLength: 8)).data == [0x3f, 0x00, 5, 0x12, 3, 0, 0, 0x12])
    }

    /// The supported pages page of a LUN with no device, laid out as SPC lays
    /// a VPD page out. QEMU's target puts the page code where the
    /// peripheral byte goes and a count of pages where the page length goes.
    @Test func vitalProductDataOfALUNWithNoDevice() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        #expect(try fixture.run(inquiry(evpd: true), lun: 7).data == [0x7f, 0x00, 0x00, 0x01, 0x00])
        #expect(try fixture.run(inquiry(evpd: true, page: 0x80), lun: 7).completion == .checkCondition(.invalidFieldInCDB))
        // CMDDT, and a page code without EVPD.
        #expect(try fixture.run([0x12, 0x02, 0, 0, 96, 0], lun: 7).completion == .checkCondition(.invalidFieldInCDB))
        #expect(try fixture.run(inquiry(page: 0x80), lun: 7).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func otherCommandsToALUNWithNoDevice() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        #expect(try fixture.run(testUnitReady, lun: 7).completion == .checkCondition(.logicalUnitNotSupported))
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0], lun: 7).completion == .checkCondition(.logicalUnitNotSupported))
        // REQUEST SENSE reports that the LUN has no device, cut to the sense
        // data rather than padded to the allocation length.
        let (completion, data) = try fixture.run(requestSense(), lun: 7)
        #expect(completion == .good)
        #expect(data == SCSISense.logicalUnitNotSupported.fixed)
    }

    @Test func aTargetWithoutLUNZeroAnswersForIt() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 2)
        #expect(try fixture.run(testUnitReady).completion == .good)
    }

    /// The unit that answered for a LUN with no device keeps the sense of
    /// the command it failed, as QEMU's request does on its device.
    @Test func theAnsweringUnitKeepsTheSense() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        #expect(try fixture.run(testUnitReady, lun: 7).completion == .checkCondition(.logicalUnitNotSupported))
        #expect(try fixture.run(requestSense()).data == SCSISense.logicalUnitNotSupported.fixed)
    }

    @Test func aTargetWithNoDeviceIsNotRouted() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        #expect(fixture.bus.prepare(testUnitReady, at: SCSIBus.Address(target: 1, lun: 0)) == nil)
    }

    // MARK: Unit attention

    @Test func aUnitAttentionIsReportedOnce() throws {
        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        disk.reset()
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reset))
        #expect(try fixture.run(testUnitReady).completion == .good)
    }

    @Test func inquiriesGoAheadOfAUnitAttention() throws {
        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        disk.reset()
        #expect(try fixture.run(inquiry()).completion == .good)
        #expect(try fixture.run(reportLUNs(allocationLength: 64)).completion == .good)
        // GET CONFIGURATION and GET EVENT STATUS NOTIFICATION, which a disk
        // refuses.
        #expect(try fixture.run([0x46, 0, 0, 0, 0, 0, 0, 0, 8, 0]).completion == .checkCondition(.invalidFieldInCDB))
        #expect(try fixture.run([0x4a, 1, 0, 0, 0x10, 0, 0, 0, 8, 0]).completion == .checkCondition(.invalidFieldInCDB))
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reset))
    }

    @Test func requestSenseReportsAPendingUnitAttention() throws {
        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        disk.reset()
        #expect(try fixture.run(requestSense()).completion == .checkCondition(.reset))
        // Reported with the command, it leaves no sense behind.
        #expect(try fixture.run(requestSense()).data == SCSISense.noSense.fixed + [UInt8](repeating: 0, count: 252 - 18))
    }

    @Test func theUnitReportsItsOwnAttentionBeforeTheBuses() throws {
        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        disk.reset()
        fixture.bus.raiseUnitAttention(.reportedLUNsDataChanged)
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reset))
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reportedLUNsDataChanged))
        #expect(try fixture.run(testUnitReady).completion == .good)
    }

    @Test func oneUnitReportsTheBusesAttention() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        try fixture.attach(lun: 1)
        fixture.bus.raiseUnitAttention(.reportedLUNsDataChanged)
        #expect(try fixture.run(testUnitReady, lun: 1).completion == .checkCondition(.reportedLUNsDataChanged))
        #expect(try fixture.run(testUnitReady, lun: 0).completion == .good)
    }

    /// scsi_ua_precedence: a pending condition gives way only to one ranked
    /// before it, and the reset conditions rank first.
    @Test func unitAttentionPrecedence() throws {
        func attention(_ asc: UInt8, _ ascq: UInt8) -> SCSISense {
            SCSISense(key: SCSISense.Key.unitAttention, asc: asc, ascq: ascq)
        }
        #expect(attention(0x29, 0x00).unitAttentionRank == 0)
        #expect(attention(0x29, 0x04).unitAttentionRank == 1)
        #expect(attention(0x3f, 0x01).unitAttentionRank == 2)
        #expect(attention(0x29, 0x02).unitAttentionRank == 2)
        #expect(attention(0x29, 0x07).unitAttentionRank == 7)
        #expect(attention(0x2f, 0x01).unitAttentionRank == 8)
        #expect(attention(0x29, 0x05).unitAttentionRank == 0x2905)
        #expect(attention(0x29, 0x06).unitAttentionRank == 0x2906)
        #expect(attention(0x3f, 0x0e).unitAttentionRank == 0x3f0e)
        #expect(SCSISense.invalidFieldInCDB.unitAttentionRank == Int.max)

        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        disk.raiseUnitAttention(.reportedLUNsDataChanged)
        disk.raiseUnitAttention(.reset)
        #expect(disk.unitAttention == .reset)
        disk.raiseUnitAttention(.reportedLUNsDataChanged)
        disk.raiseUnitAttention(.invalidFieldInCDB)
        #expect(disk.unitAttention == .reset)
    }

    @Test func reportLUNsClearsAReportedLUNsChange() throws {
        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        fixture.bus.raiseUnitAttention(.reportedLUNsDataChanged)
        #expect(try fixture.run(reportLUNs(allocationLength: 64)).completion == .good)
        #expect(try fixture.run(testUnitReady).completion == .good)

        disk.raiseUnitAttention(.reportedLUNsDataChanged)
        #expect(try fixture.run(reportLUNs(allocationLength: 64)).completion == .good)
        #expect(try fixture.run(testUnitReady).completion == .good)

        // Only the condition that would be reported next is looked at: a
        // reset pending on the unit keeps the bus's change pending too.
        disk.reset()
        fixture.bus.raiseUnitAttention(.reportedLUNsDataChanged)
        #expect(try fixture.run(reportLUNs(allocationLength: 64)).completion == .good)
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reset))
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reportedLUNsDataChanged))
        #expect(try fixture.run(testUnitReady).completion == .good)
    }

    @Test func commandsThatDoNotDecodeLeaveTheAttentionPending() throws {
        let fixture = BusFixture()
        let disk = try fixture.attach(lun: 0)
        disk.reset()
        // A group with no CDB length.
        #expect(try fixture.run([0x60] + [UInt8](repeating: 0, count: 15)).completion == .checkCondition(.invalidOperationCode))
        // A transfer past INT32_MAX bytes.
        let huge: [UInt8] = [0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0, 0]
        #expect(try fixture.run(huge).completion == .checkCondition(.invalidFieldInCDB))
        #expect(try fixture.run(testUnitReady).completion == .checkCondition(.reset))
    }

    // MARK: Deferred sense

    @Test func requestSenseReturnsTheLastFailure() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0]).completion == .checkCondition(.lbaOutOfRange))
        // The bus answers, with the sense data alone.
        #expect(try fixture.run(requestSense()).data == SCSISense.lbaOutOfRange.fixed)
        // Once reported it is gone, and the disk answers, padded.
        #expect(try fixture.run(requestSense()).data == SCSISense.noSense.fixed + [UInt8](repeating: 0, count: 252 - 18))

        #expect(try fixture.run([0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0]).completion == .checkCondition(.lbaOutOfRange))
        #expect(try fixture.run(requestSense(descriptorFormat: true)).data == [0x72, 0x05, 0x21, 0x00, 0, 0, 0, 0])
    }

    @Test func aCommandThatSucceedsClearsTheSense() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0]).completion == .checkCondition(.lbaOutOfRange))
        #expect(try fixture.run(testUnitReady).completion == .good)
        #expect(try fixture.run(requestSense(allocationLength: 18)).data == SCSISense.noSense.fixed)
    }

    // MARK: Reset

    @Test func resettingATargetResetsItsUnits() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        try fixture.attach(lun: 1)
        try fixture.attach(target: 1, lun: 0)
        fixture.bus.reset(target: 0)
        #expect(try fixture.run(testUnitReady, lun: 0).completion == .checkCondition(.reset))
        #expect(try fixture.run(testUnitReady, lun: 1).completion == .checkCondition(.reset))
        #expect(try fixture.run(testUnitReady, target: 1).completion == .good)
        fixture.bus.reset()
        #expect(try fixture.run(testUnitReady, target: 1).completion == .checkCondition(.reset))
    }

    @Test func aDetachedUnitIsGone() throws {
        let fixture = BusFixture()
        try fixture.attach(lun: 0)
        try fixture.attach(lun: 4)
        #expect(fixture.bus.detach(at: SCSIBus.Address(target: 0, lun: 4)) != nil)
        #expect(fixture.bus.detach(at: SCSIBus.Address(target: 0, lun: 4)) == nil)
        #expect(try fixture.run(reportLUNs(allocationLength: 64)).data == [0, 0, 0, 8, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
        #expect(try fixture.run(testUnitReady, lun: 4).completion == .checkCondition(.logicalUnitNotSupported))
    }
}
