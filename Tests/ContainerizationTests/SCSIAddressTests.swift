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

import ContainerizationExtras
import Testing

@testable import Containerization

struct SCSIAddressTests {
    @Test func allocatesTargetsOfTwoHundredFiftySixLUNs() throws {
        let allocator = SCSIAddress.allocator()
        var addresses: [SCSIAddress] = []
        for _ in 0..<258 {
            addresses.append(try allocator.allocate())
        }

        // Kata's GetSCSIIdLun: index n is target n / 256, LUN n % 256.
        #expect(addresses[0] == SCSIAddress(target: 0, lun: 0))
        #expect(addresses[255] == SCSIAddress(target: 0, lun: 255))
        #expect(addresses[256] == SCSIAddress(target: 1, lun: 0))
        #expect(addresses[257] == SCSIAddress(target: 1, lun: 1))
    }

    @Test func reusesAReleasedAddress() throws {
        let allocator = SCSIAddress.allocator()
        let first = try allocator.allocate()
        let second = try allocator.allocate()
        try allocator.release(first)

        #expect(try allocator.allocate() == first)
        #expect(try allocator.allocate() != second)
    }

    @Test func runsOutAfterTheLastTarget() throws {
        let allocator = SCSIAddress.allocator()
        // Reserving every address fills the allocator without the scan an
        // allocation makes from the first address.
        for target in 0...255 {
            for lun in 0...255 {
                try allocator.reserve(SCSIAddress(target: UInt8(target), lun: UInt16(lun)))
            }
        }

        #expect(throws: (any Error).self) {
            try allocator.allocate()
        }
    }

    @Test func refusesALUNPastTwoHundredFiftyFive() {
        let allocator = SCSIAddress.allocator()

        #expect(throws: (any Error).self) {
            try allocator.reserve(SCSIAddress(target: 0, lun: 256))
        }
    }
}
