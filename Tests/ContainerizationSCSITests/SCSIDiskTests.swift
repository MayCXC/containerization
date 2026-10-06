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

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// What the disk answers each command with, held against what QEMU's
/// scsi-hd answers (hw/scsi/scsi-disk.c at d7a65d1793d6).
struct SCSIDiskTests {
    // MARK: INQUIRY

    @Test func standardInquiry() throws {
        let fixture = try DiskFixture(identity: SCSIDisk.Identity(vendor: "Vend", product: "Prod", revision: "r1"))
        let (completion, data) = try fixture.run([0x12, 0, 0, 0, 96, 0])
        #expect(completion == .good)
        // Zero-padded to the allocation length.
        #expect(data.count == 96)
        #expect(data[0] == 0x00)
        #expect(data[1] == 0x00)
        #expect(data[2] == 5)
        #expect(data[3] == 0x12)
        // Additional length: the allocation length less five.
        #expect(data[4] == 91)
        #expect(data[7] == 0x12)
        #expect(Array(data[8..<16]) == Array("Vend    ".utf8))
        #expect(Array(data[16..<32]) == Array("Prod            ".utf8))
        #expect(Array(data[32..<36]) == [0x72, 0x31, 0, 0])
        #expect(data[36...].allSatisfy { $0 == 0 })
    }

    @Test func shortInquiryKeepsTheStandardAdditionalLength() throws {
        let fixture = try DiskFixture()
        let (completion, data) = try fixture.run([0x12, 0, 0, 0, 5, 0])
        #expect(completion == .good)
        #expect(data == [0x00, 0x00, 5, 0x12, 31])
    }

    @Test func inquiryOfAPageWithoutEVPDIsRefused() throws {
        let fixture = try DiskFixture()
        #expect(try fixture.run([0x12, 0, 0x80, 0, 96, 0]).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func supportedPages() throws {
        let plain = try DiskFixture()
        #expect(try plain.run([0x12, 1, 0x00, 0, 32, 0]).data.prefix(9) == [0, 0, 0, 5, 0x00, 0x83, 0xb0, 0xb1, 0xb2])
        let serial = try DiskFixture(identity: SCSIDisk.Identity(serial: "SN01"))
        #expect(try serial.run([0x12, 1, 0x00, 0, 32, 0]).data.prefix(10) == [0, 0, 0, 6, 0x00, 0x80, 0x83, 0xb0, 0xb1, 0xb2])
    }

    @Test func serialNumberPage() throws {
        let serial = try DiskFixture(identity: SCSIDisk.Identity(serial: "SN01"))
        #expect(try serial.run([0x12, 1, 0x80, 0, 8, 0]).data == [0, 0x80, 0, 4] + Array("SN01".utf8))
        let plain = try DiskFixture()
        #expect(try plain.run([0x12, 1, 0x80, 0, 8, 0]).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func deviceIdentificationPage() throws {
        // The serial number stands in for a device identifier.
        let serial = try DiskFixture(identity: SCSIDisk.Identity(serial: "SN01"))
        #expect(try serial.run([0x12, 1, 0x83, 0, 12, 0]).data == [0, 0x83, 0, 8, 0x02, 0x00, 0x00, 4] + Array("SN01".utf8))
        let identified = try DiskFixture(identity: SCSIDisk.Identity(serial: "SN01", deviceIdentifier: "vol"))
        #expect(try identified.run([0x12, 1, 0x83, 0, 11, 0]).data == [0, 0x83, 0, 7, 0x02, 0x00, 0x00, 3] + Array("vol".utf8))
        let plain = try DiskFixture()
        #expect(try plain.run([0x12, 1, 0x83, 0, 4, 0]).data == [0, 0x83, 0, 0])
    }

    @Test func blockLimitsPage() throws {
        let fixture = try DiskFixture()
        let data = try fixture.run([0x12, 1, 0xb0, 0, 64, 0]).data
        #expect(Array(data[0..<4]) == [0, 0xb0, 0, 0x3c])
        // WSNZ.
        #expect(data[4] == 1)
        // Maximum transfer length: INT_MAX bytes in blocks.
        #expect(data.bigEndian32(at: 8) == 4_194_303)
        #expect(data.bigEndian32(at: 12) == 0)
        // Maximum unmap LBA count: 1 GiB.
        #expect(data.bigEndian32(at: 20) == 2_097_152)
        #expect(data.bigEndian32(at: 24) == 255)
        // Optimal unmap granularity: 4 KiB.
        #expect(data.bigEndian32(at: 28) == 8)
        #expect(data.bigEndian64(at: 36) == 4_194_303)
    }

    @Test func blockDeviceCharacteristicsAndProvisioningPages() throws {
        let fixture = try DiskFixture(identity: SCSIDisk.Identity(rotationRate: 1))
        let characteristics = try fixture.run([0x12, 1, 0xb1, 0, 64, 0]).data
        #expect(Array(characteristics[0..<6]) == [0, 0xb1, 0, 0x3c, 0, 1])
        #expect(characteristics[6...].allSatisfy { $0 == 0 })
        #expect(try fixture.run([0x12, 1, 0xb2, 0, 8, 0]).data == [0, 0xb2, 0, 4, 0, 0xe0, 0x02, 0])
    }

    @Test func unknownPagesAreRefused() throws {
        let fixture = try DiskFixture()
        for page: UInt8 in [0x81, 0x86, 0xb3, 0xff] {
            #expect(try fixture.run([0x12, 1, page, 0, 64, 0]).completion == .checkCondition(.invalidFieldInCDB))
        }
    }

    // MARK: READ CAPACITY

    @Test func readCapacity10() throws {
        let fixture = try DiskFixture(blocks: 16)
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0]).data == [0, 0, 0, 15, 0, 0, 2, 0])
        // An address needs PMI.
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 1, 0, 0, 0, 0]).completion == .checkCondition(.invalidFieldInCDB))
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 1, 0, 0, 1, 0]).completion == .good)
    }

    @Test func readCapacity16() throws {
        let fixture = try DiskFixture(blocks: 16)
        let data = try fixture.run([0x9e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0]).data
        #expect(data.count == 32)
        #expect(data.bigEndian64(at: 0) == 15)
        #expect(data.bigEndian32(at: 8) == 512)
        // TPE.
        #expect(Array(data[12..<16]) == [0, 0, 0x80, 0])
        #expect(data[16...].allSatisfy { $0 == 0 })
        // Another service action of SERVICE ACTION IN (16).
        #expect(try fixture.run([0x9e, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0]).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func allocationLengthsPastSixtyFourKiBAreRefused() throws {
        let fixture = try DiskFixture()
        let cdb: [UInt8] = [0x9e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x00, 0x01, 0, 0]
        #expect(try fixture.run(cdb).completion == .checkCondition(.invalidFieldInCDB))
    }

    // MARK: MODE SENSE and MODE SELECT

    @Test func modeSenseCachingPage() throws {
        let fixture = try DiskFixture(blocks: 16)
        let data = try fixture.run([0x1a, 0, 0x08, 0, 255, 0]).data
        // Header, an 8-byte block descriptor, the caching page.
        #expect(data[0] == 3 + 8 + 2 + 0x12)
        // DPOFUA, not write protected.
        #expect(data[2] == 0x10)
        #expect(data[3] == 8)
        #expect(Array(data[4..<12]) == [0, 0, 0, 16, 0, 0, 2, 0])
        #expect(Array(data[12..<15]) == [0x08, 0x12, 0x04])
    }

    @Test func modeSenseOfEveryPage() throws {
        let fixture = try DiskFixture(blocks: 16)
        // DBD: no block descriptor.
        let data = try fixture.run([0x1a, 0x08, 0x3f, 0, 255, 0]).data
        #expect(data[3] == 0)
        var pages: [(UInt8, UInt8)] = []
        var offset = 4
        while offset < 1 + Int(data[0]) {
            pages.append((data[offset], data[offset + 1]))
            offset += 2 + Int(data[offset + 1])
        }
        #expect(pages.map(\.0) == [0x01, 0x04, 0x05, 0x08])
        #expect(pages.map(\.1) == [10, 0x16, 0x1e, 0x12])
    }

    @Test func modeSenseGeometryPages() throws {
        let fixture = try DiskFixture(blocks: 16)
        let rigid = try fixture.run([0x1a, 0x08, 0x04, 0, 255, 0]).data
        // Two cylinders at least, 16 heads.
        #expect(Array(rigid[4..<10]) == [0x04, 0x16, 0, 0, 2, 16])
        #expect(Array(rigid[22..<26]) == [0, 0, 0x15, 0x18])
        let flexible = try fixture.run([0x1a, 0x08, 0x05, 0, 255, 0]).data
        #expect(Array(flexible[4..<12]) == [0x05, 0x1e, 0x13, 0x88, 16, 63, 0x02, 0x00])
    }

    @Test func modeSense10() throws {
        let fixture = try DiskFixture(blocks: 16)
        let data = try fixture.run([0x5a, 0, 0x08, 0, 0, 0, 0, 0, 255, 0]).data
        #expect(data.bigEndian16(at: 0) == UInt16(6 + 8 + 2 + 0x12))
        #expect(data[3] == 0x10)
        #expect(data.bigEndian16(at: 6) == 8)
        #expect(Array(data[16..<19]) == [0x08, 0x12, 0x04])
    }

    @Test func modeSenseChangeableValues() throws {
        let fixture = try DiskFixture()
        let caching = try fixture.run([0x1a, 0x08, 0x48, 0, 255, 0]).data
        #expect(Array(caching[4..<7]) == [0x08, 0x12, 0x04])
        let errorRecovery = try fixture.run([0x1a, 0x08, 0x41, 0, 255, 0]).data
        #expect(Array(errorRecovery[4..<7]) == [0x01, 10, 0])
    }

    @Test func modeSenseRefusals() throws {
        let fixture = try DiskFixture()
        // Saved values.
        #expect(try fixture.run([0x1a, 0, 0xc8, 0, 255, 0]).completion == .checkCondition(.savingParametersNotSupported))
        // The control page is not one a disk reports.
        #expect(try fixture.run([0x1a, 0, 0x0a, 0, 255, 0]).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func readOnlyDisksReportWriteProtect() throws {
        let fixture = try DiskFixture(readOnly: true)
        #expect(try fixture.run([0x1a, 0x08, 0x08, 0, 255, 0]).data[2] == 0x90)
    }

    @Test func modeSelectTurnsTheWriteCacheOff() throws {
        let fixture = try DiskFixture()
        let parameters: [UInt8] = [0, 0, 0, 0, 0x08, 0x12] + [UInt8](repeating: 0, count: 0x12)
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(parameters.count), 0], dataOut: parameters).completion == .good)
        #expect(!fixture.disk.writeCacheEnabled)
        #expect(try fixture.run([0x1a, 0x08, 0x08, 0, 255, 0]).data[6] == 0x00)
        var enable = parameters
        enable[6] = 0x04
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(enable.count), 0], dataOut: enable).completion == .good)
        #expect(fixture.disk.writeCacheEnabled)
    }

    @Test func modeSelectRefusals() throws {
        let fixture = try DiskFixture()
        let caching: [UInt8] = [0, 0, 0, 0, 0x08, 0x12] + [UInt8](repeating: 0, count: 0x12)
        // Without PF.
        #expect(try fixture.run([0x15, 0x00, 0, 0, UInt8(caching.count), 0], dataOut: caching).completion == .checkCondition(.invalidFieldInCDB))
        // A header cut short.
        #expect(try fixture.run([0x15, 0x10, 0, 0, 3, 0], dataOut: [0, 0, 0]).completion == .checkCondition(.parameterListLengthError))
        // A block descriptor of a length other than 0 or 8.
        let descriptor: [UInt8] = [0, 0, 0, 4, 0, 0, 0, 0]
        #expect(try fixture.run([0x15, 0x10, 0, 0, 8, 0], dataOut: descriptor).completion == .checkCondition(.invalidFieldInParameterList))
        // A bit MODE SENSE does not report changeable.
        var unchangeable = caching
        unchangeable[7] = 0x01
        #expect(
            try fixture.run([0x15, 0x10, 0, 0, UInt8(unchangeable.count), 0], dataOut: unchangeable).completion
                == .checkCondition(.invalidFieldInParameterList))
        // A page longer than the disk's.
        let long: [UInt8] = [0, 0, 0, 0, 0x08, 0x13] + [UInt8](repeating: 0, count: 0x13)
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(long.count), 0], dataOut: long).completion == .checkCondition(.invalidFieldInParameterList))
        // A page running past the list.
        let cut: [UInt8] = [0, 0, 0, 0, 0x08, 0x12, 0x04]
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(cut.count), 0], dataOut: cut).completion == .checkCondition(.parameterListLengthError))
        // Every page at once, which only MODE SENSE takes, and a subpage.
        let every: [UInt8] = [0, 0, 0, 0, 0x3f, 0x00]
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(every.count), 0], dataOut: every).completion == .checkCondition(.invalidFieldInParameterList))
        let subpage: [UInt8] = [0, 0, 0, 0, 0x48, 0x01, 0x00, 0x00]
        #expect(
            try fixture.run([0x15, 0x10, 0, 0, UInt8(subpage.count), 0], dataOut: subpage).completion == .checkCondition(.invalidFieldInParameterList))
        // A list whose first page is good and second is not changes nothing.
        let mixed: [UInt8] = [0, 0, 0, 0, 0x08, 0x01, 0x00, 0x0a, 0x00]
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(mixed.count), 0], dataOut: mixed).completion == .checkCondition(.invalidFieldInParameterList))
        #expect(fixture.disk.writeCacheEnabled)
        // An empty list changes nothing and succeeds whatever the CDB says.
        #expect(try fixture.run([0x15, 0x00, 0, 0, 0, 0]).completion == .good)
    }

    @Test func modeSelectTakesATruncatedPage() throws {
        let fixture = try DiskFixture()
        // The caching page cut to the byte holding WCE.
        let truncated: [UInt8] = [0, 0, 0, 0, 0x08, 0x01, 0x00]
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(truncated.count), 0], dataOut: truncated).completion == .good)
        #expect(!fixture.disk.writeCacheEnabled)
        // Cut to nothing, it changes nothing.
        let empty: [UInt8] = [0, 0, 0, 0, 0x08, 0x00]
        #expect(try fixture.run([0x15, 0x10, 0, 0, UInt8(empty.count), 0], dataOut: empty).completion == .good)
        #expect(!fixture.disk.writeCacheEnabled)
    }

    @Test func modeSelect10WithABlockDescriptor() throws {
        let fixture = try DiskFixture()
        // An 8-byte header naming an 8-byte block descriptor, which changes
        // nothing, then the caching page with WCE clear.
        var parameters: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 8] + [0, 0, 0, 16, 0, 0, 0x10, 0]
        parameters += [0x08, 0x12] + [UInt8](repeating: 0, count: 0x12)
        let cdb: [UInt8] = [0x55, 0x10, 0, 0, 0, 0, 0, 0, UInt8(parameters.count), 0]
        #expect(try fixture.run(cdb, dataOut: parameters).completion == .good)
        #expect(!fixture.disk.writeCacheEnabled)
        // The block size stays 512.
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0]).data == [0, 0, 0, 15, 0, 0, 2, 0])
    }

    // MARK: READ and WRITE

    @Test func readReturnsTheImage() throws {
        let fixture = try DiskFixture(blocks: 16)
        let (completion, data) = try fixture.run([0x28, 0, 0, 0, 0, 5, 0, 0, 2, 0])
        #expect(completion == .good)
        #expect(data == [UInt8](repeating: 5, count: 512) + [UInt8](repeating: 6, count: 512))
        // READ (6) and READ (16) address the same blocks.
        #expect(try fixture.run([0x08, 0, 0, 15, 1, 0]).data == [UInt8](repeating: 15, count: 512))
        #expect(try fixture.run([0x88, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0]).data == [UInt8](repeating: 3, count: 512))
    }

    @Test func writeLandsInTheImage() throws {
        let fixture = try DiskFixture(blocks: 16)
        let block = [UInt8](repeating: 0xab, count: 512)
        #expect(try fixture.run([0x2a, 0, 0, 0, 0, 7, 0, 0, 1, 0], dataOut: block).completion == .good)
        #expect(try fixture.image.block(7) == block)
        #expect(try fixture.image.block(8) == [UInt8](repeating: 8, count: 512))
        // Forced unit access, and WRITE AND VERIFY, flush as well.
        #expect(try fixture.run([0x2a, 0x08, 0, 0, 0, 9, 0, 0, 1, 0], dataOut: block).completion == .good)
        #expect(try fixture.run([0x2e, 0x00, 0, 0, 0, 10, 0, 0, 1, 0], dataOut: block).completion == .good)
        #expect(try fixture.image.block(10) == block)
    }

    @Test func writeFromScatteredBuffers() throws {
        let fixture = try DiskFixture(blocks: 16)
        let command = try #require(SCSICommand([0x2a, 0, 0, 0, 0, 2, 0, 0, 2, 0], blockSize: 512))
        let first = [UInt8](repeating: 1, count: 100)
        let second = [UInt8](repeating: 2, count: 924)
        let outcome = fixture.disk.execute(command, dataOut: SCSIDataOut(HeldBytes(pieces: [first, second])), dataIn: SCSIDataBuffer())
        guard case .waiting(let operation) = outcome else {
            Issue.record("a write waits on its operation")
            return
        }
        // Nothing reaches the image until the operation runs.
        #expect(try fixture.image.block(2) == [UInt8](repeating: 2, count: 512))
        #expect(operation.run() == .good)
        #expect(try fixture.image.block(2) + fixture.image.block(3) == first + second)
    }

    @Test func blocksOutsideTheDiskAreRefused() throws {
        let fixture = try DiskFixture(blocks: 16)
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 15, 0, 0, 1, 0]).completion == .good)
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 15, 0, 0, 2, 0]).completion == .checkCondition(.lbaOutOfRange))
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0]).completion == .checkCondition(.lbaOutOfRange))
        // Zero blocks just past the end are within it.
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 16, 0, 0, 0, 0]).completion == .good)
        let overflow: [UInt8] = [0x88, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 2, 0, 0]
        #expect(try fixture.run(overflow).completion == .checkCondition(.lbaOutOfRange))
    }

    @Test func protectionInformationIsRefused() throws {
        let fixture = try DiskFixture()
        #expect(try fixture.run([0x28, 0x20, 0, 0, 0, 0, 0, 0, 1, 0]).completion == .checkCondition(.invalidFieldInCDB))
        let block = [UInt8](repeating: 0, count: 512)
        #expect(try fixture.run([0x2a, 0x20, 0, 0, 0, 0, 0, 0, 1, 0], dataOut: block).completion == .checkCondition(.invalidFieldInCDB))
    }

    @Test func readOnlyDisksRefuseWrites() throws {
        let fixture = try DiskFixture(blocks: 16, readOnly: true)
        let block = [UInt8](repeating: 0xab, count: 512)
        #expect(try fixture.run([0x2a, 0, 0, 0, 0, 1, 0, 0, 1, 0], dataOut: block).completion == .checkCondition(.writeProtected))
        #expect(try fixture.run([0x41, 0, 0, 0, 0, 1, 0, 0, 1, 0], dataOut: block).completion == .checkCondition(.writeProtected))
        let unmap: [UInt8] = [0, 22, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0]
        #expect(try fixture.run([0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0], dataOut: unmap).completion == .checkCondition(.writeProtected))
        #expect(try fixture.image.block(1) == [UInt8](repeating: 1, count: 512))
        // Reads still work.
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 1, 0, 0, 1, 0]).data == [UInt8](repeating: 1, count: 512))
    }

    // MARK: Cache, UNMAP, WRITE SAME

    @Test func synchronizeCacheFlushesInEveryMode() throws {
        for synchronization: SCSIDiskImage.Synchronization in [.full, .fsync, .none] {
            let fixture = try DiskFixture(synchronization: synchronization)
            #expect(try fixture.run([0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0]).completion == .good)
        }
        // SYNCHRONIZE CACHE (16) is not one scsi-hd answers.
        let fixture = try DiskFixture()
        #expect(try fixture.run([0x91, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).completion == .checkCondition(.invalidOperationCode))
    }

    @Test func writeSameRepeatsTheBlock() throws {
        let fixture = try DiskFixture(blocks: 16)
        let block = [UInt8](repeating: 0x5a, count: 512)
        #expect(try fixture.run([0x93, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0], dataOut: block).completion == .good)
        for number in 3..<7 {
            #expect(try fixture.image.block(number) == block)
        }
        #expect(try fixture.image.block(7) == [UInt8](repeating: 7, count: 512))
    }

    @Test func writeSameOfZerosZeroes() throws {
        let fixture = try DiskFixture(blocks: 16)
        // UNMAP set with a block of zeros.
        let zeros = [UInt8](repeating: 0, count: 512)
        #expect(try fixture.run([0x41, 0x08, 0, 0, 0, 2, 0, 0, 2, 0], dataOut: zeros).completion == .good)
        #expect(try fixture.image.block(2) == zeros)
        #expect(try fixture.image.block(3) == zeros)
        #expect(try fixture.image.block(4) == [UInt8](repeating: 4, count: 512))
    }

    /// NDOB: no block is sent, and the range is written with zeros. QEMU's
    /// WRITE SAME treats NDOB as a zero write too, but its emulation
    /// completes a command that transfers no data before reaching it, so
    /// there NDOB writes nothing; this disk writes the zeros.
    @Test func writeSameWithNoDataOutBlockZeroes() throws {
        let fixture = try DiskFixture(blocks: 16)
        #expect(try fixture.run([0x93, 0x01, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 2, 0, 0]).completion == .good)
        #expect(try fixture.image.block(8) == [UInt8](repeating: 0, count: 512))
        #expect(try fixture.image.block(9) == [UInt8](repeating: 0, count: 512))
        #expect(try fixture.image.block(10) == [UInt8](repeating: 10, count: 512))
        // It is refused where a write is.
        #expect(try fixture.run([0x93, 0x01, 0, 0, 0, 0, 0, 0, 0, 15, 0, 0, 0, 2, 0, 0]).completion == .checkCondition(.lbaOutOfRange))
        let readOnly = try DiskFixture(blocks: 16, readOnly: true)
        #expect(try readOnly.run([0x93, 0x01, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0]).completion == .checkCondition(.writeProtected))
    }

    @Test func writeSameRefusals() throws {
        let fixture = try DiskFixture(blocks: 16)
        let block = [UInt8](repeating: 1, count: 512)
        // No block count, ANCHOR, PBDATA, LBDATA.
        for cdb: [UInt8] in [
            [0x41, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0x41, 0x10, 0, 0, 0, 0, 0, 0, 1, 0], [0x41, 0x04, 0, 0, 0, 0, 0, 0, 1, 0],
            [0x41, 0x02, 0, 0, 0, 0, 0, 0, 1, 0],
        ] {
            #expect(try fixture.run(cdb, dataOut: block).completion == .checkCondition(.invalidFieldInCDB))
        }
        #expect(try fixture.run([0x41, 0, 0, 0, 0, 15, 0, 0, 2, 0], dataOut: block).completion == .checkCondition(.lbaOutOfRange))
    }

    @Test func unmapGivesBackWholeFileSystemBlocks() throws {
        let fixture = try DiskFixture(blocks: 64)
        // Blocks 8 to 23: 8 KiB from 4 KiB, aligned to the file system's
        // blocks, and block 24, half of one.
        var parameters: [UInt8] = [0, 38, 0, 32, 0, 0, 0, 0]
        parameters += [0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0, 0]
        parameters += [0, 0, 0, 0, 0, 0, 0, 24, 0, 0, 0, 1, 0, 0, 0, 0]
        #expect(try fixture.run([0x42, 0, 0, 0, 0, 0, 0, 0, UInt8(parameters.count), 0], dataOut: parameters).completion == .good)
        #if os(macOS)
        // A hole reads as zeros.
        #expect(try fixture.image.block(8) == [UInt8](repeating: 0, count: 512))
        #expect(try fixture.image.block(23) == [UInt8](repeating: 0, count: 512))
        #endif
        // The half block keeps its data.
        #expect(try fixture.image.block(24) == [UInt8](repeating: 24, count: 512))
        #expect(try fixture.image.block(7) == [UInt8](repeating: 7, count: 512))
    }

    // MARK: Canceled commands

    /// A canceled command's operation runs the request it issued to its
    /// end and issues no other: the read after a forced read's flush is not
    /// issued, and a plain read, one request, runs.
    @Test func aCanceledReadIssuesNoReadAfterItsFlush() throws {
        let fixture = try DiskFixture(blocks: 16)
        let dataIn = SCSIDataBuffer(capacity: 4096)
        let stale = [UInt8](repeating: 0xee, count: 512)
        dataIn.fill(stale, length: 512)
        let forced = try #require(SCSICommand([0x28, 0x08, 0, 0, 0, 3, 0, 0, 1, 0], blockSize: 512))
        guard case .waiting(let operation) = fixture.disk.execute(forced, dataOut: SCSIDataOut(), dataIn: dataIn) else {
            Issue.record("a read waits on its operation")
            return
        }
        var asked = 0
        #expect(
            operation.run(until: {
                asked += 1
                return true
            }) == nil)
        #expect(asked == 1)
        #expect(Array(dataIn.content) == stale)

        let plain = try #require(SCSICommand([0x28, 0, 0, 0, 0, 3, 0, 0, 1, 0], blockSize: 512))
        guard case .waiting(let read) = fixture.disk.execute(plain, dataOut: SCSIDataOut(), dataIn: dataIn) else {
            Issue.record("a read waits on its operation")
            return
        }
        #expect(read.run(until: { true }) == .good)
        #expect(Array(dataIn.content) == [UInt8](repeating: 3, count: 512))
    }

    @Test func aCanceledUnmapIssuesNoFurtherRange() throws {
        let fixture = try DiskFixture(blocks: 64)
        // Blocks 8 to 23, then 32 to 47: 8 KiB each, aligned to the file
        // system's blocks.
        var parameters: [UInt8] = [0, 38, 0, 32, 0, 0, 0, 0]
        parameters += [0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0, 0]
        parameters += [0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0, 16, 0, 0, 0, 0]
        let command = try #require(SCSICommand([0x42, 0, 0, 0, 0, 0, 0, 0, UInt8(parameters.count), 0], blockSize: 512))
        guard case .waiting(let operation) = fixture.disk.execute(command, dataOut: SCSIDataOut(bytes: parameters), dataIn: SCSIDataBuffer()) else {
            Issue.record("an unmap waits on its operation")
            return
        }
        var asked = 0
        #expect(
            operation.run(until: {
                asked += 1
                return true
            }) == nil)
        #expect(asked == 1)
        #if os(macOS)
        #expect(try fixture.image.block(8) == [UInt8](repeating: 0, count: 512))
        #endif
        #expect(try fixture.image.block(32) == [UInt8](repeating: 32, count: 512))
    }

    /// A pattern goes to the image a run per request, and a canceled WRITE
    /// SAME stops between runs; zeros go in one request, which runs.
    @Test func aCanceledWriteSameStopsBetweenRuns() throws {
        let run = SCSIDiskImage.patternRunLength / 512
        let blocks = 2 * run
        let fixture = try DiskFixture(blocks: blocks)
        var cdb: [UInt8] = [0x93, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        cdb.appendBigEndian(UInt32(blocks))
        cdb += [0, 0]
        let block = [UInt8](repeating: 0x5a, count: 512)
        let pattern = try #require(SCSICommand(cdb, blockSize: 512))
        guard case .waiting(let operation) = fixture.disk.execute(pattern, dataOut: SCSIDataOut(bytes: block), dataIn: SCSIDataBuffer()) else {
            Issue.record("a WRITE SAME waits on its operation")
            return
        }
        var asked = 0
        #expect(
            operation.run(until: {
                asked += 1
                return true
            }) == nil)
        #expect(asked == 1)
        #expect(try fixture.image.block(run - 1) == block)
        #expect(try fixture.image.block(run) == [UInt8](repeating: UInt8(truncatingIfNeeded: run), count: 512))

        // NDOB: zeros.
        cdb[1] = 0x01
        let zeros = try #require(SCSICommand(cdb, blockSize: 512))
        guard case .waiting(let zeroing) = fixture.disk.execute(zeros, dataOut: SCSIDataOut(), dataIn: SCSIDataBuffer()) else {
            Issue.record("a WRITE SAME waits on its operation")
            return
        }
        #expect(zeroing.run(until: { true }) == .good)
        #expect(try fixture.image.block(blocks - 1) == [UInt8](repeating: 0, count: 512))
    }

    @Test func unmapRefusals() throws {
        let fixture = try DiskFixture(blocks: 16)
        let descriptor: [UInt8] = [0, 22, 0, 16, 0, 0, 0, 0] + [0, 0, 0, 0, 0, 0, 0, 15, 0, 0, 0, 2, 0, 0, 0, 0]
        // ANCHOR.
        #expect(try fixture.run([0x42, 1, 0, 0, 0, 0, 0, 0, 24, 0], dataOut: descriptor).completion == .checkCondition(.invalidFieldInCDB))
        // Out of range.
        #expect(try fixture.run([0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0], dataOut: descriptor).completion == .checkCondition(.lbaOutOfRange))
        // Lengths that do not add up.
        #expect(try fixture.run([0x42, 0, 0, 0, 0, 0, 0, 0, 4, 0], dataOut: [0, 2, 0, 0]).completion == .checkCondition(.parameterListLengthError))
        let unaligned: [UInt8] = [0, 14, 0, 8, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 8)
        #expect(try fixture.run([0x42, 0, 0, 0, 0, 0, 0, 0, 16, 0], dataOut: unaligned).completion == .checkCondition(.parameterListLengthError))
        // An empty list does nothing.
        #expect(try fixture.run([0x42, 1, 0, 0, 0, 0, 0, 0, 0, 0]).completion == .good)
    }

    // MARK: Other commands

    @Test func commandsAFixedDiskCompletesAtOnce() throws {
        let fixture = try DiskFixture()
        for cdb: [UInt8] in [
            [0x00, 0, 0, 0, 0, 0], [0x1b, 0, 0, 0, 1, 0], [0x1b, 0, 0, 0, 0x02, 0], [0x1e, 0, 0, 0, 1, 0],
            [0x16, 0, 0, 0, 0, 0], [0x17, 0, 0, 0, 0, 0], [0x56, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0x57, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0x2f, 0, 0, 0, 0, 0, 0, 0, 1, 0], [0x04, 0, 0, 0, 0, 0],
        ] {
            #expect(try fixture.run(cdb).completion == .good)
        }
    }

    @Test func refusedFields() throws {
        let fixture = try DiskFixture()
        // Third-party reservations, a byte check.
        for cdb: [UInt8] in [[0x16, 1, 0, 0, 0, 0], [0x57, 2, 0, 0, 0, 0, 0, 0, 0, 0], [0x2f, 0x02, 0, 0, 0, 0, 0, 0, 1, 0]] {
            #expect(try fixture.run(cdb, dataOut: [UInt8](repeating: 0, count: 512)).completion == .checkCondition(.invalidFieldInCDB))
        }
        // A seek past the end.
        #expect(try fixture.run([0x2b, 0, 0, 0, 0, 16, 0, 0, 0, 0]).completion == .checkCondition(.lbaOutOfRange))
        #expect(try fixture.run([0x2b, 0, 0, 0, 0, 15, 0, 0, 0, 0]).completion == .good)
    }

    @Test func requestSenseWithNothingToReport() throws {
        let fixture = try DiskFixture()
        #expect(try fixture.run([0x03, 0, 0, 0, 18, 0]).data == SCSISense.noSense.fixed)
        #expect(try fixture.run([0x03, 1, 0, 0, 8, 0]).data == [0x72, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func commandsADiskDoesNotHave() throws {
        let fixture = try DiskFixture()
        // LOG SENSE, PERSISTENT RESERVE IN.
        #expect(try fixture.run([0x4d, 0, 0, 0, 0, 0, 0, 0, 0, 0]).completion == .checkCondition(.invalidOperationCode))
        #expect(try fixture.run([0x5e, 0, 0, 0, 0, 0, 0, 0, 0, 0]).completion == .checkCondition(.invalidOperationCode))
        // Multimedia commands, which QEMU's emulation answers only for a CD.
        for cdb: [UInt8] in [
            [0x46, 0, 0, 0, 0, 0, 0, 0, 8, 0], [0x4a, 1, 0, 0, 0x10, 0, 0, 0, 8, 0], [0xbd, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0],
            [0x51, 0, 0, 0, 0, 0, 0, 0, 8, 0], [0xad, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0],
        ] {
            #expect(try fixture.run(cdb).completion == .checkCondition(.invalidFieldInCDB))
        }
    }

    /// READ TOC is a multimedia command. QEMU's emulation answers it for a
    /// disk as well, with a CD's table of contents built from the disk's
    /// size; this disk does not have one.
    @Test func readTOCIsNotADiskCommand() throws {
        let fixture = try DiskFixture()
        #expect(try fixture.run([0x43, 0, 0, 0, 0, 0, 0, 0, 12, 0]).completion == .checkCondition(.invalidOperationCode))
    }

    @Test func identityLimits() throws {
        let image = try TemporaryImage(blocks: 1)
        // The limits scsi_realize enforces.
        #expect(throws: (any Error).self) {
            try SCSIDisk(
                image: SCSIDiskImage(path: image.path, readOnly: true),
                identity: SCSIDisk.Identity(serial: String(repeating: "s", count: 21))
            )
        }
        #expect(throws: (any Error).self) {
            try SCSIDisk(
                image: SCSIDiskImage(path: image.path, readOnly: true),
                identity: SCSIDisk.Identity(serial: String(repeating: "s", count: 37), deviceIdentifier: "id")
            )
        }
        #expect(throws: Never.self) {
            try SCSIDisk(
                image: SCSIDiskImage(path: image.path, readOnly: true),
                identity: SCSIDisk.Identity(serial: String(repeating: "s", count: 36), deviceIdentifier: "id")
            )
        }
    }

    // MARK: Size

    @Test func aPartialBlockCountsAsAWholeOne() throws {
        // 1000 bytes are two blocks, the second cut short.
        let fixture = try DiskFixture(image: TemporaryImage(bytes: [UInt8](repeating: 7, count: 1000)))
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0]).data == [0, 0, 0, 1, 0, 0, 2, 0])
        // Past the end of the file it reads as zeros.
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 1, 0, 0, 1, 0]).data == [UInt8](repeating: 7, count: 488) + [UInt8](repeating: 0, count: 24))
        // Writing it fills the file out to the block.
        let block = [UInt8](repeating: 9, count: 512)
        #expect(try fixture.run([0x2a, 0, 0, 0, 0, 1, 0, 0, 1, 0], dataOut: block).completion == .good)
        #expect(try fixture.image.contents().count == 1024)
        #expect(try fixture.image.block(1) == block)
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 2, 0, 0, 1, 0]).completion == .checkCondition(.lbaOutOfRange))
    }

    @Test func anEmptyImageIsNotReady() throws {
        let fixture = try DiskFixture(image: TemporaryImage(bytes: []))
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0]).completion == .checkCondition(.notReady))
        #expect(try fixture.run([0x9e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0]).completion == .checkCondition(.notReady))
        // No block descriptor.
        #expect(try fixture.run([0x1a, 0, 0x08, 0, 255, 0]).data[3] == 0)
        // Block 0 is addressable, as QEMU leaves the last block of an empty disk.
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0]).data == [UInt8](repeating: 0, count: 512))
        #expect(try fixture.run([0x28, 0, 0, 0, 0, 1, 0, 0, 1, 0]).completion == .checkCondition(.lbaOutOfRange))
    }

    @Test func largeDisks() throws {
        // A hole of 2 TiB and two blocks: past what READ CAPACITY (10) and a
        // block descriptor can count.
        let blocks: UInt64 = (1 << 32) + 2
        let fixture = try DiskFixture(image: TemporaryImage(bytes: [], size: blocks * 512))
        #expect(try fixture.run([0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0]).data == [0xff, 0xff, 0xff, 0xff, 0, 0, 2, 0])
        #expect(try fixture.run([0x9e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0]).data.bigEndian64(at: 0) == blocks - 1)
        #expect(Array(try fixture.run([0x1a, 0, 0x08, 0, 255, 0]).data[4..<12]) == [0, 0, 0, 0, 0, 0, 2, 0])
        // The last block reads.
        let last: [UInt8] = [0x88, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0]
        #expect(try fixture.run(last).data == [UInt8](repeating: 0, count: 512))
    }

    // MARK: Host errors

    /// A failed host call completes the command as scsi_sense_from_errno
    /// maps its errno in a macOS build of QEMU.
    @Test func hostErrors() {
        #expect(SCSICompletion.hostError(EDOM) == SCSICompletion(status: .taskSetFull, sense: nil))
        #expect(SCSICompletion.hostError(ENODEV) == .checkCondition(.noMedium))
        #expect(SCSICompletion.hostError(ENOMEM) == .checkCondition(.targetFailure))
        #expect(SCSICompletion.hostError(EINVAL) == .checkCondition(.invalidFieldInCDB))
        #expect(SCSICompletion.hostError(ENOSPC) == .checkCondition(.spaceAllocationFailed))
        #expect(SCSICompletion.hostError(EIO) == .checkCondition(.ioProcessTerminated))
        #expect(SCSICompletion.hostError(EPERM) == .checkCondition(.ioProcessTerminated))
    }
}
