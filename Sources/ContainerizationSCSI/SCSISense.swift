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

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// The status a SCSI command completes with (SAM-5, 5.3).
public enum SCSIStatus: UInt8, Sendable {
    case good = 0x00
    case checkCondition = 0x02
    case taskSetFull = 0x28
}

/// A sense key with its additional sense code and qualifier: why a command
/// completed with CHECK CONDITION, or a unit attention condition a logical
/// unit holds.
///
/// Each condition and its codes is the one QEMU's SCSI emulation reports for
/// the same situation, sense_code_* in scsi/utils.c at d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/scsi/utils.c
public struct SCSISense: Hashable, Sendable {
    public var key: UInt8
    public var asc: UInt8
    public var ascq: UInt8

    public init(key: UInt8, asc: UInt8, ascq: UInt8) {
        self.key = key
        self.asc = asc
        self.ascq = ascq
    }
}

extension SCSISense {
    /// Sense keys (SPC-4, 4.5.6).
    public enum Key {
        public static let noSense: UInt8 = 0x00
        public static let notReady: UInt8 = 0x02
        public static let hardwareError: UInt8 = 0x04
        public static let illegalRequest: UInt8 = 0x05
        public static let unitAttention: UInt8 = 0x06
        public static let dataProtect: UInt8 = 0x07
        public static let abortedCommand: UInt8 = 0x0b
    }

    public static let noSense = SCSISense(key: Key.noSense, asc: 0x00, ascq: 0x00)
    /// LOGICAL UNIT NOT READY, MANUAL INTERVENTION REQUIRED.
    public static let notReady = SCSISense(key: Key.notReady, asc: 0x04, ascq: 0x03)
    /// MEDIUM NOT PRESENT.
    public static let noMedium = SCSISense(key: Key.notReady, asc: 0x3a, ascq: 0x00)
    public static let invalidOperationCode = SCSISense(key: Key.illegalRequest, asc: 0x20, ascq: 0x00)
    public static let lbaOutOfRange = SCSISense(key: Key.illegalRequest, asc: 0x21, ascq: 0x00)
    public static let invalidFieldInCDB = SCSISense(key: Key.illegalRequest, asc: 0x24, ascq: 0x00)
    public static let invalidFieldInParameterList = SCSISense(key: Key.illegalRequest, asc: 0x26, ascq: 0x00)
    public static let parameterListLengthError = SCSISense(key: Key.illegalRequest, asc: 0x1a, ascq: 0x00)
    public static let logicalUnitNotSupported = SCSISense(key: Key.illegalRequest, asc: 0x25, ascq: 0x00)
    public static let savingParametersNotSupported = SCSISense(key: Key.illegalRequest, asc: 0x39, ascq: 0x00)
    /// INTERNAL TARGET FAILURE.
    public static let targetFailure = SCSISense(key: Key.hardwareError, asc: 0x44, ascq: 0x00)
    /// I/O PROCESS TERMINATED, what QEMU reports a failed host I/O call with.
    public static let ioProcessTerminated = SCSISense(key: Key.abortedCommand, asc: 0x00, ascq: 0x06)
    public static let writeProtected = SCSISense(key: Key.dataProtect, asc: 0x27, ascq: 0x00)
    /// SPACE ALLOCATION FAILED WRITE PROTECT.
    public static let spaceAllocationFailed = SCSISense(key: Key.dataProtect, asc: 0x27, ascq: 0x07)
    /// POWER ON, RESET, OR BUS DEVICE RESET OCCURRED.
    public static let reset = SCSISense(key: Key.unitAttention, asc: 0x29, ascq: 0x00)
    public static let reportedLUNsDataChanged = SCSISense(key: Key.unitAttention, asc: 0x3f, ascq: 0x0e)

    /// The sense data reporting this condition: fixed format (SPC-4, 4.5.3)
    /// or descriptor format (4.5.2), laid out as scsi_build_sense_buf lays
    /// them out.
    public func data(descriptorFormat: Bool) -> [UInt8] {
        if descriptorFormat {
            return [0x72, key, asc, ascq, 0, 0, 0, 0]
        }
        var data = [UInt8](repeating: 0, count: 18)
        data[0] = 0x70
        data[2] = key
        data[7] = 10
        data[12] = asc
        data[13] = ascq
        return data
    }

    /// How this unit attention ranks against another pending one, lower
    /// first: a pending condition gives way only to one ranked before it.
    /// The ranking is scsi_ua_precedence in QEMU's hw/scsi/scsi-bus.c:
    /// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/scsi/scsi-bus.c
    var unitAttentionRank: Int {
        guard key == Key.unitAttention else {
            return Int.max
        }
        switch (asc, ascq) {
        case (0x29, 0x04):
            return 1
        case (0x3f, 0x01):
            return 2
        case (0x29, 0x05), (0x29, 0x06):
            break
        case (0x29, 0...0x07):
            return Int(ascq)
        case (0x2f, 0x01):
            return 8
        default:
            break
        }
        return Int(asc) << 8 | Int(ascq)
    }
}

/// Where a SCSI command left off: its status and, with CHECK CONDITION, the
/// condition it reports.
struct SCSICompletion: Equatable {
    var status: SCSIStatus
    var sense: SCSISense?

    static let good = SCSICompletion(status: .good, sense: nil)

    static func checkCondition(_ sense: SCSISense) -> SCSICompletion {
        SCSICompletion(status: .checkCondition, sense: sense)
    }

    /// How a command whose host I/O call failed with `code` completes, as
    /// scsi_sense_from_errno maps the call's errno in a macOS build of QEMU,
    /// where ENOMEDIUM is ENODEV (include/qemu/osdep.h).
    ///
    /// Every failure is reported to the guest. QEMU's default error policy
    /// for writes, werror=enospc, stops the machine on ENOSPC instead; a
    /// machine here has no one to resume it.
    static func hostError(_ code: Int32) -> SCSICompletion {
        switch code {
        case EDOM:
            return SCSICompletion(status: .taskSetFull, sense: nil)
        case ENODEV:
            return .checkCondition(.noMedium)
        case ENOMEM:
            return .checkCondition(.targetFailure)
        case EINVAL:
            return .checkCondition(.invalidFieldInCDB)
        case ENOSPC:
            return .checkCondition(.spaceAllocationFailed)
        default:
            return .checkCondition(.ioProcessTerminated)
        }
    }
}
