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

/// SCSI operation codes (SPC-4, SBC-3, and the MMC and SSC codes whose
/// transfer lengths a direct-access device still has to decode), with the
/// values include/scsi/constants.h names in QEMU at d7a65d1793d6.
enum SCSIOpcode {
    static let testUnitReady: UInt8 = 0x00
    static let rewind: UInt8 = 0x01
    static let requestSense: UInt8 = 0x03
    static let formatUnit: UInt8 = 0x04
    static let readBlockLimits: UInt8 = 0x05
    static let reassignBlocks: UInt8 = 0x07
    static let read6: UInt8 = 0x08
    static let write6: UInt8 = 0x0a
    static let setCapacity: UInt8 = 0x0b
    static let readReverse: UInt8 = 0x0f
    static let writeFilemarks: UInt8 = 0x10
    static let space: UInt8 = 0x11
    static let inquiry: UInt8 = 0x12
    static let modeSelect6: UInt8 = 0x15
    static let reserve6: UInt8 = 0x16
    static let release6: UInt8 = 0x17
    static let copy: UInt8 = 0x18
    static let erase: UInt8 = 0x19
    static let modeSense6: UInt8 = 0x1a
    static let startStopUnit: UInt8 = 0x1b
    static let receiveDiagnosticResults: UInt8 = 0x1c
    static let sendDiagnostic: UInt8 = 0x1d
    static let preventAllowMediumRemoval: UInt8 = 0x1e
    static let setWindow: UInt8 = 0x24
    static let readCapacity10: UInt8 = 0x25
    static let read10: UInt8 = 0x28
    static let write10: UInt8 = 0x2a
    static let seek10: UInt8 = 0x2b
    static let writeAndVerify10: UInt8 = 0x2e
    static let verify10: UInt8 = 0x2f
    static let searchHigh10: UInt8 = 0x30
    static let searchEqual10: UInt8 = 0x31
    static let searchLow10: UInt8 = 0x32
    static let setLimits: UInt8 = 0x33
    static let preFetch10: UInt8 = 0x34
    static let synchronizeCache10: UInt8 = 0x35
    static let lockUnlockCache: UInt8 = 0x36
    static let mediumScan: UInt8 = 0x38
    static let compare: UInt8 = 0x39
    static let copyAndVerify: UInt8 = 0x3a
    static let writeBuffer: UInt8 = 0x3b
    static let readBuffer: UInt8 = 0x3c
    static let updateBlock: UInt8 = 0x3d
    static let writeLong10: UInt8 = 0x3f
    static let changeDefinition: UInt8 = 0x40
    static let writeSame10: UInt8 = 0x41
    static let unmap: UInt8 = 0x42
    static let readTOC: UInt8 = 0x43
    static let getConfiguration: UInt8 = 0x46
    static let getEventStatusNotification: UInt8 = 0x4a
    static let logSelect: UInt8 = 0x4c
    static let readDiscInformation: UInt8 = 0x51
    static let reserveTrack: UInt8 = 0x53
    static let modeSelect10: UInt8 = 0x55
    static let reserve10: UInt8 = 0x56
    static let release10: UInt8 = 0x57
    static let modeSense10: UInt8 = 0x5a
    static let sendCueSheet: UInt8 = 0x5d
    static let persistentReserveOut: UInt8 = 0x5f
    static let writeFilemarks16: UInt8 = 0x80
    static let allowOverwrite: UInt8 = 0x82
    static let ataPassThrough16: UInt8 = 0x85
    static let read16: UInt8 = 0x88
    static let write16: UInt8 = 0x8a
    static let writeAndVerify16: UInt8 = 0x8e
    static let verify16: UInt8 = 0x8f
    static let preFetch16: UInt8 = 0x90
    static let synchronizeCache16: UInt8 = 0x91
    static let locate16: UInt8 = 0x92
    static let writeSame16: UInt8 = 0x93
    static let serviceActionIn16: UInt8 = 0x9e
    static let reportLUNs: UInt8 = 0xa0
    static let ataPassThrough12: UInt8 = 0xa1
    static let maintenanceOut: UInt8 = 0xa4
    static let setReadAhead: UInt8 = 0xa7
    static let read12: UInt8 = 0xa8
    static let write12: UInt8 = 0xaa
    static let readDVDStructure: UInt8 = 0xad
    static let writeAndVerify12: UInt8 = 0xae
    static let verify12: UInt8 = 0xaf
    static let searchHigh12: UInt8 = 0xb0
    static let searchEqual12: UInt8 = 0xb1
    static let searchLow12: UInt8 = 0xb2
    static let sendVolumeTag: UInt8 = 0xb6
    static let setCDSpeed: UInt8 = 0xbb
    static let mechanismStatus: UInt8 = 0xbd
    static let readCD: UInt8 = 0xbe
    static let sendDVDStructure: UInt8 = 0xbf

    /// The READ CAPACITY (16) service action of SERVICE ACTION IN (16).
    static let readCapacity16ServiceAction: UInt8 = 0x10
}

/// A command descriptor block and the data transfer a direct-access device
/// derives from it: how many bytes move, and which way.
///
/// The CDB lengths, transfer lengths, directions and logical block addresses
/// are the ones QEMU's SCSI bus derives for a disk: scsi_req_parse_cdb,
/// scsi_req_xfer and scsi_cmd_xfer_mode in hw/scsi/scsi-bus.c, and
/// scsi_cdb_length, scsi_cdb_xfer, scsi_data_cdb_xfer and scsi_cmd_lba in
/// scsi/utils.c, at d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/scsi/scsi-bus.c
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/scsi/utils.c
struct SCSICommand {
    enum Direction: Equatable {
        case none
        case toDevice
        case fromDevice
    }

    /// The CDB, cut to the length its operation code's group defines.
    let cdb: [UInt8]
    /// The bytes the command transfers.
    let transferLength: Int
    let direction: Direction
    /// The logical block address field, for operation codes that have one.
    let lba: UInt64

    var opcode: UInt8 { cdb[0] }

    /// Decodes the CDB at the start of `bytes`, or returns nil when its
    /// operation code belongs to a group with no defined CDB length or the
    /// CDB runs past `bytes`.
    init?(_ bytes: [UInt8], blockSize: Int) {
        guard let opcode = bytes.first, let length = Self.length(ofGroup: opcode >> 5), length <= bytes.count else {
            return nil
        }
        let cdb = Array(bytes.prefix(length))
        let transferLength = Self.transferLength(cdb, blockSize: blockSize)
        self.cdb = cdb
        self.transferLength = transferLength
        self.direction = transferLength == 0 ? .none : Self.direction(cdb)
        self.lba = Self.lba(cdb)
    }

    private static func length(ofGroup group: UInt8) -> Int? {
        switch group {
        case 0:
            return 6
        case 1, 2:
            return 10
        case 4:
            return 16
        case 5:
            return 12
        default:
            return nil
        }
    }

    /// The CDB's transfer or allocation length field, by group.
    private static func lengthField(_ cdb: [UInt8]) -> Int {
        switch cdb[0] >> 5 {
        case 0:
            return Int(cdb[4])
        case 1, 2:
            return Int(cdb.bigEndian16(at: 7))
        case 4:
            return Int(cdb.bigEndian32(at: 10))
        default:
            return Int(cdb.bigEndian32(at: 6))
        }
    }

    private static let transfersNothing: Set<UInt8> = [
        SCSIOpcode.testUnitReady, SCSIOpcode.rewind, SCSIOpcode.startStopUnit, SCSIOpcode.setCapacity,
        SCSIOpcode.writeFilemarks, SCSIOpcode.writeFilemarks16, SCSIOpcode.space, SCSIOpcode.reserve6,
        SCSIOpcode.release6, SCSIOpcode.erase, SCSIOpcode.preventAllowMediumRemoval, SCSIOpcode.seek10,
        SCSIOpcode.synchronizeCache10, SCSIOpcode.synchronizeCache16, SCSIOpcode.locate16, SCSIOpcode.lockUnlockCache,
        SCSIOpcode.setCDSpeed, SCSIOpcode.setLimits, SCSIOpcode.writeLong10, SCSIOpcode.updateBlock,
        SCSIOpcode.reserveTrack, SCSIOpcode.setReadAhead, SCSIOpcode.preFetch10, SCSIOpcode.preFetch16,
        SCSIOpcode.allowOverwrite,
    ]

    private static func transferLength(_ cdb: [UInt8], blockSize: Int) -> Int {
        let field = lengthField(cdb)
        switch cdb[0] {
        case let opcode where transfersNothing.contains(opcode):
            return 0
        case SCSIOpcode.verify10, SCSIOpcode.verify12, SCSIOpcode.verify16:
            // BYTCHK 0 compares nothing; BYTCHK 11b sends one block.
            if cdb[1] & 0x02 == 0 {
                return 0
            }
            return (cdb[1] & 0x04 != 0 ? 1 : field) * blockSize
        case SCSIOpcode.writeSame10, SCSIOpcode.writeSame16:
            // NDOB sends no data; otherwise one block of it.
            return cdb[1] & 0x01 != 0 ? 0 : blockSize
        case SCSIOpcode.readCapacity10:
            return 8
        case SCSIOpcode.readBlockLimits:
            return 6
        case SCSIOpcode.sendVolumeTag:
            return Int(cdb.bigEndian16(at: 8))
        case SCSIOpcode.read6, SCSIOpcode.write6, SCSIOpcode.readReverse:
            // A transfer length of 0 means 256 blocks.
            return (field == 0 ? 256 : field) * blockSize
        case SCSIOpcode.read10, SCSIOpcode.read12, SCSIOpcode.read16, SCSIOpcode.write10, SCSIOpcode.write12,
            SCSIOpcode.write16, SCSIOpcode.writeAndVerify10, SCSIOpcode.writeAndVerify12, SCSIOpcode.writeAndVerify16:
            return field * blockSize
        case SCSIOpcode.formatUnit:
            // FMTDATA sends a parameter list header, long with LONGLIST.
            guard cdb[1] & 0x10 != 0 else {
                return 0
            }
            return cdb[1] & 0x20 != 0 ? 8 : 4
        case SCSIOpcode.inquiry, SCSIOpcode.receiveDiagnosticResults, SCSIOpcode.sendDiagnostic:
            return Int(cdb.bigEndian16(at: 3))
        case SCSIOpcode.readCD, SCSIOpcode.readBuffer, SCSIOpcode.writeBuffer, SCSIOpcode.sendCueSheet:
            return Int(cdb[6]) << 16 | Int(cdb.bigEndian16(at: 7))
        case SCSIOpcode.persistentReserveOut:
            return Int(cdb.bigEndian32(at: 5))
        case SCSIOpcode.ataPassThrough12:
            return ataPassThroughLength(cdb, count: cdb[3], sectorCount: cdb[4], blockSize: blockSize)
        case SCSIOpcode.ataPassThrough16:
            let extend = cdb[1] & 0x01 != 0
            let count = UInt16(cdb[4]) | (extend ? UInt16(cdb[3]) << 8 : 0)
            let sectorCount = UInt16(cdb[6]) | (extend ? UInt16(cdb[5]) << 8 : 0)
            return ataPassThroughLength(cdb, count: count, sectorCount: sectorCount, blockSize: blockSize)
        default:
            return field
        }
    }

    /// The transfer of an ATA PASS-THROUGH command: T_LENGTH picks the
    /// field that holds the count, BYT_BLOK and T_TYPE its unit.
    private static func ataPassThroughLength<Count: BinaryInteger>(_ cdb: [UInt8], count: Count, sectorCount: Count, blockSize: Int) -> Int {
        let unit: Int
        if cdb[2] & 0x04 == 0 {
            unit = 1
        } else {
            unit = cdb[2] & 0x10 != 0 ? blockSize : 512
        }
        switch cdb[2] & 0x03 {
        case 1:
            return Int(count) * unit
        case 2:
            return Int(sectorCount) * unit
        default:
            return 0
        }
    }

    private static let sendsData: Set<UInt8> = [
        SCSIOpcode.write6, SCSIOpcode.write10, SCSIOpcode.writeAndVerify10, SCSIOpcode.write12,
        SCSIOpcode.writeAndVerify12, SCSIOpcode.write16, SCSIOpcode.writeAndVerify16, SCSIOpcode.verify10,
        SCSIOpcode.verify12, SCSIOpcode.verify16, SCSIOpcode.copy, SCSIOpcode.copyAndVerify, SCSIOpcode.compare,
        SCSIOpcode.changeDefinition, SCSIOpcode.logSelect, SCSIOpcode.modeSelect6, SCSIOpcode.modeSelect10,
        SCSIOpcode.sendDiagnostic, SCSIOpcode.writeBuffer, SCSIOpcode.formatUnit, SCSIOpcode.reassignBlocks,
        SCSIOpcode.searchEqual10, SCSIOpcode.searchHigh10, SCSIOpcode.searchLow10, SCSIOpcode.updateBlock,
        SCSIOpcode.writeLong10, SCSIOpcode.writeSame10, SCSIOpcode.writeSame16, SCSIOpcode.unmap,
        SCSIOpcode.searchHigh12, SCSIOpcode.searchEqual12, SCSIOpcode.searchLow12, SCSIOpcode.mediumScan,
        SCSIOpcode.sendVolumeTag, SCSIOpcode.sendCueSheet, SCSIOpcode.sendDVDStructure,
        SCSIOpcode.persistentReserveOut, SCSIOpcode.maintenanceOut, SCSIOpcode.setWindow,
        // SCAN, which shares START STOP UNIT's code; that one transfers nothing.
        SCSIOpcode.startStopUnit,
    ]

    private static func direction(_ cdb: [UInt8]) -> Direction {
        switch cdb[0] {
        case SCSIOpcode.ataPassThrough12, SCSIOpcode.ataPassThrough16:
            // T_DIR.
            return cdb[2] & 0x08 != 0 ? .fromDevice : .toDevice
        case let opcode where sendsData.contains(opcode):
            return .toDevice
        default:
            return .fromDevice
        }
    }

    private static func lba(_ cdb: [UInt8]) -> UInt64 {
        switch cdb[0] >> 5 {
        case 0:
            return UInt64(cdb.bigEndian32(at: 0) & 0x1f_ffff)
        case 4:
            return cdb.bigEndian64(at: 2)
        default:
            return UInt64(cdb.bigEndian32(at: 2))
        }
    }
}

extension Array where Element == UInt8 {
    func bigEndian16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func bigEndian32(at offset: Int) -> UInt32 {
        UInt32(bigEndian16(at: offset)) << 16 | UInt32(bigEndian16(at: offset + 2))
    }

    func bigEndian64(at offset: Int) -> UInt64 {
        UInt64(bigEndian32(at: offset)) << 32 | UInt64(bigEndian32(at: offset + 4))
    }

    func littleEndian32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func littleEndian64(at offset: Int) -> UInt64 {
        UInt64(littleEndian32(at: offset)) | UInt64(littleEndian32(at: offset + 4)) << 32
    }

    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func storeBigEndian<Value: FixedWidthInteger>(_ value: Value, at offset: Int) {
        Swift.withUnsafeBytes(of: value.bigEndian) { bytes in
            for (index, byte) in bytes.enumerated() {
                self[offset + index] = byte
            }
        }
    }
}
