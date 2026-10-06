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
import Foundation
import Testing

@testable import ContainerizationSCSI

/// The image file under a disk: its lock, and its reads, writes, flushes
/// and discards as QEMU's file driver does them on macOS
/// (block/file-posix.c and block/io.c at d7a65d1793d6).
struct SCSIDiskImageTests {
    @Test func aWritableImageIsHeldExclusively() throws {
        let image = try TemporaryImage(blocks: 4)
        let writer = try SCSIDiskImage(path: image.path, readOnly: false)
        withExtendedLifetime(writer) {
            let second = #expect(throws: ContainerizationError.self) {
                try SCSIDiskImage(path: image.path, readOnly: false)
            }
            #expect(second?.code == .invalidState)
            let reader = #expect(throws: ContainerizationError.self) {
                try SCSIDiskImage(path: image.path, readOnly: true)
            }
            #expect(reader?.code == .invalidState)
        }
    }

    @Test func readOnlyImagesShareTheirLock() throws {
        let image = try TemporaryImage(blocks: 4)
        let first = try SCSIDiskImage(path: image.path, readOnly: true)
        let second = try SCSIDiskImage(path: image.path, readOnly: true)
        withExtendedLifetime((first, second)) {
            let writer = #expect(throws: ContainerizationError.self) {
                try SCSIDiskImage(path: image.path, readOnly: false)
            }
            #expect(writer?.code == .invalidState)
        }
    }

    @Test func theLockGoesWithTheImage() throws {
        let image = try TemporaryImage(blocks: 4)
        do {
            let writer = try SCSIDiskImage(path: image.path, readOnly: false)
            withExtendedLifetime(writer) {}
        }
        #expect(throws: Never.self) {
            try SCSIDiskImage(path: image.path, readOnly: false)
        }
    }

    @Test func aMissingImageIsAnError() {
        #expect(throws: ContainerizationError.self) {
            try SCSIDiskImage(path: "/nonexistent/scsi-\(UUID().uuidString).img", readOnly: true)
        }
    }

    @Test func readsPastTheEndAreZeros() throws {
        let image = try TemporaryImage(bytes: [UInt8](repeating: 0x5a, count: 700))
        let file = try SCSIDiskImage(path: image.path, readOnly: true)
        var buffer = [UInt8](repeating: 0xff, count: 1024)
        try buffer.withUnsafeMutableBytes { try file.read(into: $0, at: 0) }
        #expect(buffer == [UInt8](repeating: 0x5a, count: 700) + [UInt8](repeating: 0, count: 324))
        try buffer.withUnsafeMutableBytes { try file.read(into: $0, at: 4096) }
        #expect(buffer == [UInt8](repeating: 0, count: 1024))
    }

    @Test func writesGatherTheirBuffers() throws {
        let image = try TemporaryImage(blocks: 4)
        let file = try SCSIDiskImage(path: image.path, readOnly: false)
        let pieces: [[UInt8]] = [[UInt8](repeating: 1, count: 3), [], [UInt8](repeating: 2, count: 509), [UInt8](repeating: 3, count: 600)]
        // The first 1000 bytes of the pieces, in order.
        try pieces[0].withUnsafeBytes { first in
            try pieces[1].withUnsafeBytes { second in
                try pieces[2].withUnsafeBytes { third in
                    try pieces[3].withUnsafeBytes { fourth in
                        try file.write([first, second, third, fourth], count: 1000, at: 512)
                    }
                }
            }
        }
        let contents = try image.contents()
        #expect(Array(contents[0..<512]) == [UInt8](repeating: 0, count: 512))
        #expect(Array(contents[512..<1512]) == pieces.joined().prefix(1000).map { $0 })
        #expect(Array(contents[1512..<1536]) == [UInt8](repeating: 2, count: 24))
        // More than the buffers hold.
        #expect(throws: SCSIDiskImage.HostError.self) {
            try pieces[0].withUnsafeBytes { try file.write([$0], count: 4, at: 0) }
        }
    }

    @Test func writesOfManyBuffers() throws {
        let image = try TemporaryImage(blocks: 8)
        let file = try SCSIDiskImage(path: image.path, readOnly: false)
        // More vectors than one pwritev takes.
        let bytes = (0..<3000).map { UInt8(truncatingIfNeeded: $0) }
        try bytes.withUnsafeBytes { all in
            let buffers = (0..<3000).map { UnsafeRawBufferPointer(rebasing: all[$0..<($0 + 1)]) }
            try file.write(buffers, count: 3000, at: 100)
        }
        #expect(Array(try image.contents()[100..<3100]) == bytes)
    }

    @Test func aPatternRepeats() throws {
        let image = try TemporaryImage(blocks: 2048)
        let file = try SCSIDiskImage(path: image.path, readOnly: false)
        // Past one run of the pattern.
        let pattern = (0..<512).map { UInt8(truncatingIfNeeded: $0 * 7) }
        var between = 0
        let finished = try file.write(repeating: pattern, length: 1536 * 512, at: 512) {
            between += 1
            return true
        }
        #expect(finished)
        // Two runs, and a call between them.
        #expect(between == 1)
        let contents = try image.contents()
        #expect(Array(contents[0..<512]) == [UInt8](repeating: 0, count: 512))
        for block in [1, 1024, 1025, 1536] {
            #expect(Array(contents[(block * 512)..<((block + 1) * 512)]) == pattern)
        }
        #expect(Array(contents[(1537 * 512)..<(1538 * 512)]) == [UInt8](repeating: 1, count: 512))
    }

    @Test func flushesInEveryMode() throws {
        for synchronization: SCSIDiskImage.Synchronization in [.full, .fsync, .none] {
            for caching: SCSIDiskImage.Caching in [.cached, .uncached] {
                let image = try TemporaryImage(blocks: 1)
                let file = try SCSIDiskImage(path: image.path, readOnly: false, caching: caching, synchronization: synchronization)
                let block = [UInt8](repeating: 0x42, count: 512)
                try block.withUnsafeBytes { try file.write([$0], count: 512, at: 0) }
                try file.flush()
                #expect(try image.block(0) == block)
            }
        }
    }

    #if os(macOS)
    @Test func discardPunchesTheWholeBlocks() throws {
        let image = try TemporaryImage(bytes: [UInt8](repeating: 0xee, count: 32768))
        let file = try SCSIDiskImage(path: image.path, readOnly: false)
        // An unaligned head and tail around two whole 4 KiB blocks. The file
        // system refuses the head and tail, which keep their data.
        try file.discard(offset: 1000, length: 14000)
        let contents = try image.contents()
        #expect(Array(contents[0..<4096]) == [UInt8](repeating: 0xee, count: 4096))
        #expect(Array(contents[4096..<12288]) == [UInt8](repeating: 0, count: 8192))
        #expect(Array(contents[12288..<32768]) == [UInt8](repeating: 0xee, count: 20480))
        // Less than a block, and a range already a hole.
        try file.discard(offset: 100, length: 200)
        try file.discard(offset: 4096, length: 4096)
        #expect(Array(try image.contents()[0..<4096]) == [UInt8](repeating: 0xee, count: 4096))
    }

    /// A device of the host's is sized by asking it, as raw_getlength asks
    /// one, rather than by its file size, which reads as zero. /dev/zero is a
    /// device that is no disk, so it answers neither request.
    @Test func aDeviceIsSizedByAskingIt() throws {
        let file = try SCSIDiskImage(path: "/dev/zero", readOnly: true)
        #expect(file.isDevice)
        #expect(throws: SCSIDiskImage.HostError.self) {
            try file.size()
        }
        let image = try TemporaryImage(blocks: 2)
        let regular = try SCSIDiskImage(path: image.path, readOnly: true)
        #expect(!regular.isDevice)
        #expect(try regular.size() == 1024)
    }

    /// A device keeps its data through a discard, as handle_aiocb_discard
    /// leaves a host device's on macOS, where a hole punched in it would
    /// fail: a device node answers F_PUNCHHOLE with ENOTTY.
    @Test func aDeviceKeepsItsDataThroughADiscard() throws {
        let file = try SCSIDiskImage(path: "/dev/zero", readOnly: true)
        #expect(throws: Never.self) {
            try file.discard(offset: 0, length: 8192)
        }
    }
    #endif
}
