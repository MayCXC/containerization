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

import Testing

@testable import ContainerizationSCSI

/// CDB lengths, transfer lengths, directions and addresses as QEMU's SCSI bus
/// derives them for a disk (scsi_req_parse_cdb in hw/scsi/scsi-bus.c).
struct SCSICommandTests {
    private func command(_ cdb: [UInt8]) throws -> SCSICommand {
        try #require(SCSICommand(cdb + [UInt8](repeating: 0, count: 32 - cdb.count), blockSize: 512))
    }

    @Test func cdbLengthFollowsTheGroupCode() throws {
        #expect(try command([0x00]).cdb.count == 6)
        #expect(try command([0x28]).cdb.count == 10)
        #expect(try command([0x5a]).cdb.count == 10)
        #expect(try command([0x88]).cdb.count == 16)
        #expect(try command([0xa8]).cdb.count == 12)
    }

    @Test func groupsWithoutALengthDoNotDecode() {
        for opcode: UInt8 in [0x60, 0x7f, 0xc0, 0xff] {
            #expect(SCSICommand([opcode] + [UInt8](repeating: 0, count: 31), blockSize: 512) == nil)
        }
    }

    @Test func aCDBLongerThanItsBytesDoesNotDecode() {
        #expect(SCSICommand([0x88, 0, 0, 0], blockSize: 512) == nil)
    }

    @Test func readAndWriteTransferWholeBlocks() throws {
        // READ (6) of 0 blocks means 256.
        #expect(try command([0x08, 0, 0, 1, 0, 0]).transferLength == 256 * 512)
        #expect(try command([0x0a, 0, 0, 1, 3, 0]).transferLength == 3 * 512)
        #expect(try command([0x28, 0, 0, 0, 0, 5, 0, 0, 2, 0]).transferLength == 2 * 512)
        #expect(try command([0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0]).transferLength == 4 * 512)
        #expect(try command([0x8a, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0]).transferLength == 7 * 512)
        #expect(try command([0x2e, 0, 0, 0, 0, 0, 0, 0, 1, 0]).transferLength == 512)
    }

    @Test func directions() throws {
        #expect(try command([0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0]).direction == .fromDevice)
        #expect(try command([0x2a, 0, 0, 0, 0, 0, 0, 0, 1, 0]).direction == .toDevice)
        #expect(try command([0x12, 0, 0, 0, 36, 0]).direction == .fromDevice)
        #expect(try command([0x15, 0x10, 0, 0, 12, 0]).direction == .toDevice)
        #expect(try command([0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0]).direction == .toDevice)
        #expect(try command([0x00, 0, 0, 0, 0, 0]).direction == .none)
        // A command with no transfer moves nothing whatever its direction.
        #expect(try command([0x2a, 0, 0, 0, 0, 0, 0, 0, 0, 0]).direction == .none)
    }

    @Test func commandsThatTransferNothing() throws {
        for cdb: [UInt8] in [
            [0x00], [0x1b, 0, 0, 0, 1, 0], [0x1e, 0, 0, 0, 1, 0], [0x35], [0x91], [0x2b], [0x16, 0, 0, 0, 9, 0],
        ] {
            #expect(try command(cdb).transferLength == 0)
        }
    }

    @Test func allocationLengths() throws {
        #expect(try command([0x12, 0, 0, 0x01, 0x02, 0]).transferLength == 0x102)
        #expect(try command([0x1a, 0, 0x3f, 0, 0xfc, 0]).transferLength == 0xfc)
        #expect(try command([0x5a, 0, 0x3f, 0, 0, 0, 0, 0x10, 0x00, 0]).transferLength == 0x1000)
        #expect(try command([0x25]).transferLength == 8)
        #expect(try command([0x9e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0]).transferLength == 32)
        #expect(try command([0xa0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]).transferLength == 256)
        #expect(try command([0x03, 0, 0, 0, 252, 0]).transferLength == 252)
    }

    @Test func verifySendsDataOnlyWithByteCheck() throws {
        #expect(try command([0x2f, 0x00, 0, 0, 0, 0, 0, 0, 4, 0]).transferLength == 0)
        #expect(try command([0x2f, 0x02, 0, 0, 0, 0, 0, 0, 4, 0]).transferLength == 4 * 512)
        // BYTCHK 11b sends one block whatever the count.
        #expect(try command([0x2f, 0x06, 0, 0, 0, 0, 0, 0, 4, 0]).transferLength == 512)
    }

    @Test func writeSameSendsOneBlockUnlessNDOB() throws {
        #expect(try command([0x41, 0, 0, 0, 0, 0, 0, 0, 8, 0]).transferLength == 512)
        #expect(try command([0x93, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0]).transferLength == 0)
    }

    @Test func formatUnitSendsAHeaderWithFormatData() throws {
        #expect(try command([0x04, 0x00, 0, 0, 0, 0]).transferLength == 0)
        #expect(try command([0x04, 0x10, 0, 0, 0, 0]).transferLength == 4)
        #expect(try command([0x04, 0x30, 0, 0, 0, 0]).transferLength == 8)
    }

    @Test func ataPassThroughCountsByItsFields() throws {
        // T_LENGTH 2 (sector count), BYT_BLOK in 512-byte units, T_DIR in.
        let twelve = try command([0xa1, 0, 0x0e, 0, 3, 0, 0, 0, 0, 0, 0, 0])
        #expect(twelve.transferLength == 3 * 512)
        #expect(twelve.direction == .fromDevice)
        // EXTEND with T_LENGTH 1 (features field), bytes, out.
        let sixteen = try command([0x85, 0x01, 0x01, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(sixteen.transferLength == 0x102)
        #expect(sixteen.direction == .toDevice)
    }

    @Test func logicalBlockAddresses() throws {
        #expect(try command([0x08, 0x1f, 0xff, 0xfe, 1, 0]).lba == 0x1f_fffe)
        #expect(try command([0x08, 0xe1, 0x00, 0x02, 1, 0]).lba == 0x1_0002)
        #expect(try command([0x28, 0, 0x12, 0x34, 0x56, 0x78, 0, 0, 1, 0]).lba == 0x1234_5678)
        #expect(try command([0x88, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 1, 0, 0]).lba == 0x0102_0304_0506_0708)
        #expect(try command([0xa8, 0, 0, 0, 0x10, 0x01, 0, 0, 0, 1, 0, 0]).lba == 0x1001)
    }
}
