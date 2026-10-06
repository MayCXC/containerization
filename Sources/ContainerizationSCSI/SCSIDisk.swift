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

/// A disk logical unit on a raw image.
///
/// It answers the commands QEMU's scsi-hd device answers, with the same data
/// and sense codes and the same flushes, hw/scsi/scsi-disk.c at d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/scsi/scsi-disk.c
public final class SCSIDisk {
    /// What INQUIRY reports the disk as.
    public struct Identity: Sendable {
        /// T10 vendor identification, up to 8 ASCII characters.
        public var vendor: String
        /// Product identification, up to 16 ASCII characters.
        public var product: String
        /// Product revision level, up to 4 ASCII characters.
        public var revision: String
        /// The unit serial number VPD page, up to 36 characters.
        public var serial: String?
        /// A vendor specific designator for the device identification VPD
        /// page. Without one the page carries the serial number, when there is
        /// one of up to 20 characters.
        public var deviceIdentifier: String?
        /// The medium rotation rate of the block device characteristics VPD
        /// page: 0 not reported, 1 a non-rotating medium.
        public var rotationRate: UInt16

        public init(
            vendor: String = "Virtual",
            product: String = "SCSI Disk",
            revision: String = "1.0",
            serial: String? = nil,
            deviceIdentifier: String? = nil,
            rotationRate: UInt16 = 0
        ) {
            self.vendor = vendor
            self.product = product
            self.revision = revision
            self.serial = serial
            self.deviceIdentifier = deviceIdentifier
            self.rotationRate = rotationRate
        }
    }

    /// The logical and physical block size. QEMU sizes a disk on a regular
    /// file in 512-byte blocks (blkconf_blocksizes in hw/block/block.c).
    static let blockSize = 512
    /// SPC-3, the version scsi-hd claims (its scsi_version property).
    static let version: UInt8 = 5
    /// The granularity discards are advertised at
    /// (DEFAULT_DISCARD_GRANULARITY).
    static let discardGranularity = 4096
    /// The most one UNMAP may give back (DEFAULT_MAX_UNMAP_SIZE).
    static let maximumUnmapLength = 1 << 30
    /// The largest transfer (DEFAULT_MAX_IO_SIZE).
    static let maximumTransferLength = Int(Int32.max)
    /// The most an emulated command transfers.
    static let maximumEmulatedTransfer = 65536

    public let image: SCSIDiskImage
    public let identity: Identity
    private let deviceIdentifier: String?
    private let geometry: (cylinders: Int, heads: UInt8, sectors: UInt8)
    /// The disk's size in blocks: the image's size when it was attached,
    /// rounded up to a whole block, as QEMU's block layer counts a file's
    /// sectors when it opens it (bdrv_co_refresh_total_sectors in block.c).
    private let blockCount: UInt64
    /// The last block a command may address (max_lba): block 0 of a disk
    /// with none, as scsi_disk_reset leaves it.
    private let lastBlock: UInt64
    /// Whether written data may stay in the host's cache until a flush: the
    /// caching mode page's WCE, which MODE SELECT can clear to make every
    /// write go through.
    private(set) var writeCacheEnabled = true
    /// A unit attention condition the next command will report.
    var unitAttention: SCSISense?
    /// The sense of the last command that failed, which REQUEST SENSE
    /// returns until a command succeeds.
    var deferredSense: SCSISense?

    public init(image: SCSIDiskImage, identity: Identity = Identity()) throws {
        // The limits scsi_realize enforces.
        if let serial = identity.serial, serial.utf8.count > 36 {
            throw ContainerizationError(.invalidArgument, message: "a disk serial number can't be longer than 36 characters")
        }
        if identity.deviceIdentifier == nil, let serial = identity.serial, serial.utf8.count > 20 {
            throw ContainerizationError(
                .invalidArgument,
                message: "a disk serial number can't be longer than 20 characters when it is also the device identifier"
            )
        }
        let size: UInt64
        do {
            size = try image.size()
        } catch let error as SCSIDiskImage.HostError {
            throw ContainerizationError(.internalError, message: "failed to size disk image \(image.path): errno \(error.code)")
        }
        let blocks = (size + UInt64(Self.blockSize) - 1) / UInt64(Self.blockSize)
        self.image = image
        self.identity = identity
        self.deviceIdentifier = identity.deviceIdentifier ?? identity.serial
        self.blockCount = blocks
        self.lastBlock = blocks > 0 ? blocks - 1 : 0
        self.geometry = Self.geometry(blocks: blocks)
    }

    /// The cylinder, head and sector geometry QEMU guesses for a disk with no
    /// partition table to go on: 16 heads of 63 sectors, cylinders filling
    /// the rest (guess_chs_for_size in hw/block/hd-geometry.c).
    private static func geometry(blocks: UInt64) -> (cylinders: Int, heads: UInt8, sectors: UInt8) {
        let cylinders = min(max(blocks / (16 * 63), 2), 16383)
        return (Int(cylinders), 16, 63)
    }

    /// Makes `sense` the unit attention the next command reports, unless a
    /// condition ranked before it is already pending (scsi_device_set_ua).
    func raiseUnitAttention(_ sense: SCSISense) {
        if sense.unitAttentionRank < (unitAttention?.unitAttentionRank ?? Int.max) {
            unitAttention = sense
        }
    }

    /// Resets the logical unit: its next command reports the reset
    /// (scsi_disk_reset).
    func reset() {
        raiseUnitAttention(.reset)
    }

    /// Runs `command`, reading what it sends from `dataOut` and leaving what
    /// it returns in `dataIn`.
    func execute(_ command: SCSICommand, dataOut: SCSIDataOut, dataIn: SCSIDataBuffer) -> SCSICompletion {
        switch command.opcode {
        case SCSIOpcode.read6, SCSIOpcode.read10, SCSIOpcode.read12, SCSIOpcode.read16:
            return read(command, into: dataIn)
        case SCSIOpcode.write6, SCSIOpcode.write10, SCSIOpcode.write12, SCSIOpcode.write16, SCSIOpcode.writeAndVerify10,
            SCSIOpcode.writeAndVerify12, SCSIOpcode.writeAndVerify16:
            return write(command, from: dataOut)
        default:
            return emulate(command, dataOut: dataOut, dataIn: dataIn)
        }
    }

    // MARK: - Data transfer commands (scsi_disk_dma_command)

    /// Whether the command forces unit access: written data reaches the
    /// medium before it completes, read data is the medium's (scsi_is_cmd_fua).
    private static func forcesUnitAccess(_ cdb: [UInt8]) -> Bool {
        switch cdb[0] {
        case SCSIOpcode.read10, SCSIOpcode.read12, SCSIOpcode.read16, SCSIOpcode.write10, SCSIOpcode.write12, SCSIOpcode.write16:
            return cdb[1] & 0x08 != 0
        case SCSIOpcode.writeAndVerify10, SCSIOpcode.writeAndVerify12, SCSIOpcode.writeAndVerify16:
            return true
        default:
            return false
        }
    }

    /// Whether `blocks` blocks from `lba` lie within the disk; zero blocks
    /// just past its end do (check_lba_range).
    private func addresses(_ lba: UInt64, blocks: UInt64) -> Bool {
        let (end, overflow) = lba.addingReportingOverflow(blocks)
        return !overflow && end <= lastBlock + 1
    }

    private func read(_ command: SCSICommand, into dataIn: SCSIDataBuffer) -> SCSICompletion {
        // RDPROTECT: protection information is not supported.
        guard command.cdb[1] & 0xe0 == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        let blocks = UInt64(command.transferLength / Self.blockSize)
        guard addresses(command.lba, blocks: blocks) else {
            return .checkCondition(.lbaOutOfRange)
        }
        guard blocks > 0 else {
            return .good
        }
        return perform {
            if Self.forcesUnitAccess(command.cdb) {
                try image.flush()
            }
            try image.read(into: dataIn.prepare(command.transferLength), at: command.lba * UInt64(Self.blockSize))
        } failed: {
            dataIn.clear()
        }
    }

    private func write(_ command: SCSICommand, from dataOut: SCSIDataOut) -> SCSICompletion {
        guard !image.readOnly else {
            return .checkCondition(.writeProtected)
        }
        // WRPROTECT: protection information is not supported.
        guard command.cdb[1] & 0xe0 == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        let blocks = UInt64(command.transferLength / Self.blockSize)
        guard addresses(command.lba, blocks: blocks) else {
            return .checkCondition(.lbaOutOfRange)
        }
        guard blocks > 0 else {
            return .good
        }
        return perform {
            try image.write(dataOut.buffers, count: command.transferLength, at: command.lba * UInt64(Self.blockSize))
            // The block layer writes through when the cache is off, and
            // completes a forced unit access with a flush (bdrv_co_do_pwritev).
            if Self.forcesUnitAccess(command.cdb) || !writeCacheEnabled {
                try image.flush()
            }
        }
    }

    /// Runs `body`, reporting a failed host call the way QEMU reports it to
    /// the guest (scsi_handle_rw_error with the report error action).
    private func perform(_ body: () throws -> Void, failed: () -> Void = {}) -> SCSICompletion {
        do {
            try body()
            return .good
        } catch let error as SCSIDiskImage.HostError {
            failed()
            return .hostError(error.code)
        } catch {
            failed()
            return .checkCondition(.ioProcessTerminated)
        }
    }

    // MARK: - Emulated commands (scsi_disk_emulate_command)

    private func emulate(_ command: SCSICommand, dataOut: SCSIDataOut, dataIn: SCSIDataBuffer) -> SCSICompletion {
        guard command.transferLength <= Self.maximumEmulatedTransfer else {
            return .checkCondition(.invalidFieldInCDB)
        }
        let cdb = command.cdb
        switch command.opcode {
        case SCSIOpcode.testUnitReady, SCSIOpcode.startStopUnit, SCSIOpcode.preventAllowMediumRemoval:
            // A fixed disk: it has no medium to load, eject or lock.
            return .good
        case SCSIOpcode.inquiry:
            guard let data = inquiry(cdb, allocationLength: command.transferLength) else {
                return .checkCondition(.invalidFieldInCDB)
            }
            return respond(data, to: command, in: dataIn)
        case SCSIOpcode.modeSense6, SCSIOpcode.modeSense10:
            return modeSense(command, into: dataIn)
        case SCSIOpcode.reserve6, SCSIOpcode.release6:
            // Third-party reservations are not supported.
            return cdb[1] & 0x01 != 0 ? .checkCondition(.invalidFieldInCDB) : .good
        case SCSIOpcode.reserve10, SCSIOpcode.release10:
            return cdb[1] & 0x03 != 0 ? .checkCondition(.invalidFieldInCDB) : .good
        case SCSIOpcode.readCapacity10:
            return readCapacity10(command, into: dataIn)
        case SCSIOpcode.serviceActionIn16:
            guard cdb[1] & 0x1f == SCSIOpcode.readCapacity16ServiceAction else {
                return .checkCondition(.invalidFieldInCDB)
            }
            return readCapacity16(command, into: dataIn)
        case SCSIOpcode.requestSense:
            // Sense a command left behind is the bus's to report; here there
            // is none.
            return respond(SCSISense.noSense.data(descriptorFormat: cdb[1] & 0x01 != 0), to: command, in: dataIn)
        case SCSIOpcode.synchronizeCache10:
            return perform { try image.flush() }
        case SCSIOpcode.seek10:
            return command.lba > lastBlock ? .checkCondition(.lbaOutOfRange) : .good
        case SCSIOpcode.verify10, SCSIOpcode.verify12, SCSIOpcode.verify16:
            // BYTCHK: comparing the medium against sent data is not
            // supported; without it there is nothing to verify.
            return cdb[1] & 0x06 != 0 ? .checkCondition(.invalidFieldInCDB) : .good
        case SCSIOpcode.modeSelect6, SCSIOpcode.modeSelect10:
            guard command.transferLength > 0 else {
                return .good
            }
            return modeSelect(cdb, parameters: dataOut.bytes(command.transferLength))
        case SCSIOpcode.unmap:
            guard command.transferLength > 0 else {
                return .good
            }
            return unmap(cdb, parameters: dataOut.bytes(command.transferLength))
        case SCSIOpcode.writeSame10, SCSIOpcode.writeSame16:
            return writeSame(command, block: dataOut.bytes(command.transferLength))
        case SCSIOpcode.formatUnit:
            // The medium is formatted already; a parameter list header
            // changes nothing.
            return .good
        case SCSIOpcode.getConfiguration, SCSIOpcode.getEventStatusNotification, SCSIOpcode.mechanismStatus,
            SCSIOpcode.readDiscInformation, SCSIOpcode.readDVDStructure:
            // Multimedia commands, which only a CD-ROM answers.
            return .checkCondition(.invalidFieldInCDB)
        default:
            // READ TOC among them: QEMU's emulation, shared with its CD-ROM,
            // answers it for a disk with a CD's table of contents, which
            // SBC gives a disk no command for.
            return .checkCondition(.invalidOperationCode)
        }
    }

    /// Returns `data` as the command's data, zero-padded or cut to the
    /// command's allocation length, as scsi_disk_emulate_command transfers it.
    private func respond(_ data: [UInt8], to command: SCSICommand, in dataIn: SCSIDataBuffer) -> SCSICompletion {
        dataIn.fill(data, length: command.transferLength)
        return .good
    }

    // MARK: INQUIRY

    private func inquiry(_ cdb: [UInt8], allocationLength: Int) -> [UInt8]? {
        // EVPD.
        if cdb[1] & 0x01 != 0 {
            return vitalProductData(page: cdb[2])
        }
        guard cdb[2] == 0 else {
            return nil
        }
        var data = [UInt8](repeating: 0, count: 36)
        // Peripheral device type 0: a direct access block device.
        data[0] = 0x00
        data[2] = Self.version
        // Response data format 2, HISUP.
        data[3] = 0x12
        let length = min(allocationLength, 256)
        data[4] = UInt8(length > 36 ? length - 5 : 31)
        // SYNC, CMDQUE.
        data[7] = 0x12
        data.place(identity.vendor, at: 8, width: 8, padding: 0x20)
        data.place(identity.product, at: 16, width: 16, padding: 0x20)
        data.place(identity.revision, at: 32, width: 4, padding: 0)
        return data
    }

    private func vitalProductData(page: UInt8) -> [UInt8]? {
        var body: [UInt8]
        switch page {
        case 0x00:
            // The supported pages.
            body = [0x00]
            if identity.serial != nil {
                body.append(0x80)
            }
            body += [0x83, 0xb0, 0xb1, 0xb2]
        case 0x80:
            guard let serial = identity.serial else {
                return nil
            }
            body = Array(serial.utf8.prefix(36))
        case 0x83:
            body = []
            if let deviceIdentifier {
                let designator = Array(deviceIdentifier.utf8.prefix(255 - 8))
                // ASCII code set, vendor specific designator type.
                body = [0x02, 0x00, 0x00, UInt8(designator.count)] + designator
            }
        case 0xb0:
            body = blockLimits()
        case 0xb1:
            body = [UInt8](repeating: 0, count: 0x3c)
            body.storeBigEndian(identity.rotationRate, at: 0)
        case 0xb2:
            // UNMAP and WRITE SAME (16) and (10) can unmap; thin provisioned.
            body = [0x00, 0xe0, 0x02, 0x00]
        default:
            return nil
        }
        return [0x00, page, 0x00, UInt8(body.count)] + body
    }

    /// The block limits VPD page (scsi_emulate_block_limits in
    /// hw/scsi/emulation.c).
    private func blockLimits() -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 0x3c)
        let maximumTransferBlocks = UInt32(Self.maximumTransferLength / Self.blockSize)
        // WSNZ: WRITE SAME needs a block count.
        body[0] = 1
        body.storeBigEndian(maximumTransferBlocks, at: 4)
        body.storeBigEndian(UInt32(Self.maximumUnmapLength / Self.blockSize), at: 16)
        // Unmap block descriptors: 255 fit in 4 KiB after the 8-byte header.
        body.storeBigEndian(UInt32(255), at: 20)
        body.storeBigEndian(UInt32(Self.discardGranularity / Self.blockSize), at: 24)
        // The maximum WRITE SAME length, the maximum transfer's.
        body.storeBigEndian(maximumTransferBlocks, at: 36)
        return body
    }

    // MARK: MODE SENSE and MODE SELECT

    private func modeSense(_ command: SCSICommand, into dataIn: SCSIDataBuffer) -> SCSICompletion {
        let cdb = command.cdb
        let sixByte = cdb[0] == SCSIOpcode.modeSense6
        let disableBlockDescriptors = cdb[1] & 0x08 != 0
        let page = cdb[2] & 0x3f
        let control = cdb[2] >> 6
        // DPOFUA, and WP for a read-only image.
        let deviceSpecific: UInt8 = image.readOnly ? 0x90 : 0x10
        var data: [UInt8] = sixByte ? [0, 0, deviceSpecific, 0] : [0, 0, 0, deviceSpecific, 0, 0, 0, 0]
        if !disableBlockDescriptors && blockCount > 0 {
            data[sixByte ? 3 : 7] = 8
            let reported = blockCount > 0xff_ffff ? 0 : UInt32(blockCount)
            data += [0, UInt8(reported >> 16 & 0xff), UInt8(reported >> 8 & 0xff), UInt8(reported & 0xff)]
            data += [0, 0, UInt8(Self.blockSize >> 8), 0]
        }
        // Saved values.
        guard control != 3 else {
            return .checkCondition(.savingParametersNotSupported)
        }
        let changeable = control == 1
        if page == 0x3f {
            for code in UInt8(0)..<0x3f {
                if let body = modePage(code, changeable: changeable) {
                    data += [code, UInt8(body.count)] + body
                }
            }
        } else {
            guard let body = modePage(page, changeable: changeable) else {
                return .checkCondition(.invalidFieldInCDB)
            }
            data += [page, UInt8(body.count)] + body
        }
        // The mode data length counts what follows it.
        if sixByte {
            data[0] = UInt8(data.count - 1)
        } else {
            data.storeBigEndian(UInt16(data.count - 2), at: 0)
        }
        return respond(data, to: command, in: dataIn)
    }

    /// A mode page's parameters, without its two-byte header: the current
    /// values, or with `changeable` the mask of the ones MODE SELECT may
    /// change (mode_sense_page).
    private func modePage(_ code: UInt8, changeable: Bool) -> [UInt8]? {
        switch code {
        case 0x01:
            // Read-write error recovery: AWRE.
            var body = [UInt8](repeating: 0, count: 10)
            if !changeable {
                body[0] = 0x80
            }
            return body
        case 0x04:
            // Rigid disk drive geometry.
            var body = [UInt8](repeating: 0, count: 0x16)
            guard !changeable else {
                return body
            }
            body.storeBigEndian24(geometry.cylinders, at: 0)
            body[3] = geometry.heads
            // Write precompensation and reduced write current start at the
            // last cylinder: neither is used.
            body.storeBigEndian24(geometry.cylinders, at: 4)
            body.storeBigEndian24(geometry.cylinders, at: 7)
            // Step rate 200 ns.
            body.storeBigEndian(UInt16(200), at: 10)
            // Landing zone.
            body[12] = 0xff
            body[13] = 0xff
            body[14] = 0xff
            // 5400 rpm.
            body.storeBigEndian(UInt16(5400), at: 18)
            return body
        case 0x05:
            // Flexible disk.
            var body = [UInt8](repeating: 0, count: 0x1e)
            guard !changeable else {
                return body
            }
            // Transfer rate 5 Mbit/s.
            body.storeBigEndian(UInt16(5000), at: 0)
            body[2] = geometry.heads
            body[3] = geometry.sectors
            body.storeBigEndian(UInt16(Self.blockSize), at: 4)
            body.storeBigEndian(UInt16(geometry.cylinders), at: 6)
            body.storeBigEndian(UInt16(geometry.cylinders), at: 8)
            body.storeBigEndian(UInt16(geometry.cylinders), at: 10)
            // Step rate 100 us, step pulse 1 us, head settle 100 us, motor
            // on and off delays 0.1 s.
            body[13] = 1
            body[14] = 1
            body[16] = 1
            body[17] = 1
            body[18] = 1
            body.storeBigEndian(UInt16(5400), at: 26)
            return body
        case 0x08:
            // Caching: WCE, the only parameter MODE SELECT changes.
            var body = [UInt8](repeating: 0, count: 0x12)
            if changeable || writeCacheEnabled {
                body[0] = 0x04
            }
            return body
        default:
            return nil
        }
    }

    /// MODE SELECT (scsi_disk_emulate_mode_select): every page is checked
    /// before any changes, so a bad list changes nothing.
    private func modeSelect(_ cdb: [UInt8], parameters: [UInt8]) -> SCSICompletion {
        // Only PF=1 and SP=0: page format, nothing saved.
        guard cdb[1] & 0x11 == 0x10 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        let sixByte = cdb[0] == SCSIOpcode.modeSelect6
        let headerLength = sixByte ? 4 : 8
        guard parameters.count >= headerLength else {
            return .checkCondition(.parameterListLengthError)
        }
        let descriptorsLength = sixByte ? Int(parameters[3]) : Int(parameters.bigEndian16(at: 6))
        guard parameters.count - headerLength >= descriptorsLength else {
            return .checkCondition(.parameterListLengthError)
        }
        guard descriptorsLength == 0 || descriptorsLength == 8 else {
            return .checkCondition(.invalidFieldInParameterList)
        }
        let pages = Array(parameters[(headerLength + descriptorsLength)...])
        if let sense = selectModePages(pages, apply: false) {
            return .checkCondition(sense)
        }
        _ = selectModePages(pages, apply: true)
        guard writeCacheEnabled else {
            // Turning the cache off makes what it held reach the medium.
            return perform { try image.flush() }
        }
        return .good
    }

    private func selectModePages(_ pages: [UInt8], apply: Bool) -> SCSISense? {
        var offset = 0
        while offset < pages.count {
            let code = pages[offset] & 0x3f
            let subpage: UInt8
            let length: Int
            // SPF: a subpage, with a two-byte length.
            if pages[offset] & 0x40 != 0 {
                guard pages.count - offset >= 4 else {
                    return .parameterListLengthError
                }
                subpage = pages[offset + 1]
                length = Int(pages.bigEndian16(at: offset + 2))
                offset += 4
            } else {
                guard pages.count - offset >= 2 else {
                    return .parameterListLengthError
                }
                subpage = 0
                length = Int(pages[offset + 1])
                offset += 2
            }
            guard subpage == 0 else {
                return .invalidFieldInParameterList
            }
            guard length <= pages.count - offset else {
                return .parameterListLengthError
            }
            let parameters = Array(pages[offset..<(offset + length)])
            if apply {
                if code == 0x08, let caching = parameters.first {
                    writeCacheEnabled = caching & 0x04 != 0
                }
            } else {
                // The page may be cut short, but no longer than MODE SENSE
                // reports it, and may change only what is changeable.
                guard code != 0x3f, let current = modePage(code, changeable: false), let changeable = modePage(code, changeable: true),
                    length <= current.count
                else {
                    return .invalidFieldInParameterList
                }
                for index in 0..<length where (current[index] ^ parameters[index]) & ~changeable[index] != 0 {
                    return .invalidFieldInParameterList
                }
            }
            offset += length
        }
        return nil
    }

    // MARK: READ CAPACITY

    private func readCapacity10(_ command: SCSICommand, into dataIn: SCSIDataBuffer) -> SCSICompletion {
        guard blockCount > 0 else {
            return .checkCondition(.notReady)
        }
        // Without PMI the logical block address must be zero.
        guard command.cdb[8] & 0x01 != 0 || command.lba == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        var data = [UInt8]()
        // A disk past 2 TiB reports the largest value, for READ CAPACITY (16).
        data.appendBigEndian(UInt32(min(lastBlock, UInt64(UInt32.max))))
        data.appendBigEndian(UInt32(Self.blockSize))
        return respond(data, to: command, in: dataIn)
    }

    private func readCapacity16(_ command: SCSICommand, into dataIn: SCSIDataBuffer) -> SCSICompletion {
        guard blockCount > 0 else {
            return .checkCondition(.notReady)
        }
        guard command.cdb[14] & 0x01 != 0 || command.lba == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        var data = [UInt8]()
        data.appendBigEndian(lastBlock)
        data.appendBigEndian(UInt32(Self.blockSize))
        // No protection, one logical block per physical block, and TPE: the
        // disk is thin provisioned and unmaps.
        data += [0x00, 0x00, 0x80, 0x00]
        return respond(data, to: command, in: dataIn)
    }

    // MARK: UNMAP and WRITE SAME

    /// UNMAP (scsi_disk_emulate_unmap): each block descriptor in turn, until
    /// one falls outside the disk.
    private func unmap(_ cdb: [UInt8], parameters: [UInt8]) -> SCSICompletion {
        // ANCHOR is not supported.
        guard cdb[1] & 0x01 == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        guard parameters.count >= 8, parameters.count >= Int(parameters.bigEndian16(at: 0)) + 2 else {
            return .checkCondition(.parameterListLengthError)
        }
        let descriptorsLength = Int(parameters.bigEndian16(at: 2))
        guard parameters.count >= descriptorsLength + 8, descriptorsLength & 15 == 0 else {
            return .checkCondition(.parameterListLengthError)
        }
        guard !image.readOnly else {
            return .checkCondition(.writeProtected)
        }
        for offset in stride(from: 8, to: 8 + descriptorsLength, by: 16) {
            let lba = parameters.bigEndian64(at: offset)
            let blocks = UInt64(parameters.bigEndian32(at: offset + 8))
            guard addresses(lba, blocks: blocks) else {
                return .checkCondition(.lbaOutOfRange)
            }
            let completion = perform {
                try image.discard(offset: lba * UInt64(Self.blockSize), length: blocks * UInt64(Self.blockSize))
            }
            guard completion == .good else {
                return completion
            }
        }
        return .good
    }

    /// WRITE SAME (scsi_disk_emulate_write_same): one block written over a
    /// range. A block of zeros, or none, writes zeros, as QEMU's file driver
    /// writes them on macOS, where it has no way to zero a range in place.
    ///
    /// No block is NDOB, which QEMU's routine also takes for a zero write,
    /// but its emulation completes a command that transfers no data before
    /// the routine runs, so there NDOB writes nothing. Here it writes the
    /// zeros SBC asks for.
    private func writeSame(_ command: SCSICommand, block: [UInt8]) -> SCSICompletion {
        let cdb = command.cdb
        let blocks = UInt64(cdb[0] == SCSIOpcode.writeSame10 ? UInt32(cdb.bigEndian16(at: 7)) : cdb.bigEndian32(at: 10))
        // Zero blocks, which would mean to the end of the medium, ANCHOR,
        // PBDATA and LBDATA are not supported.
        guard blocks != 0, cdb[1] & 0x16 == 0 else {
            return .checkCondition(.invalidFieldInCDB)
        }
        guard !image.readOnly else {
            return .checkCondition(.writeProtected)
        }
        guard addresses(command.lba, blocks: blocks) else {
            return .checkCondition(.lbaOutOfRange)
        }
        // NDOB sends no block: the range is written with zeros.
        let pattern = block.isEmpty ? [UInt8](repeating: 0, count: Self.blockSize) : block
        return perform {
            try image.write(
                repeating: pattern,
                length: blocks * UInt64(Self.blockSize),
                at: command.lba * UInt64(Self.blockSize)
            )
            if !writeCacheEnabled {
                try image.flush()
            }
        }
    }
}

extension Array where Element == UInt8 {
    /// Writes `text`'s bytes into `width` bytes at `offset`, cut short or
    /// padded with `padding`.
    mutating func place(_ text: String, at offset: Int, width: Int, padding: UInt8) {
        let bytes = Array(text.utf8.prefix(width))
        for index in 0..<width {
            self[offset + index] = index < bytes.count ? bytes[index] : padding
        }
    }

    mutating func storeBigEndian24(_ value: Int, at offset: Int) {
        self[offset] = UInt8(value >> 16 & 0xff)
        self[offset + 1] = UInt8(value >> 8 & 0xff)
        self[offset + 2] = UInt8(value & 0xff)
    }
}
