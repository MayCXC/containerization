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

/// A raw image in a temporary file.
final class TemporaryImage {
    let url: URL

    /// An image of `blocks` blocks of 512 bytes, each filled with the byte
    /// `fill` gives its number.
    convenience init(blocks: Int, fill: (Int) -> UInt8 = { UInt8(truncatingIfNeeded: $0) }) throws {
        var bytes = [UInt8]()
        bytes.reserveCapacity(blocks * 512)
        for block in 0..<blocks {
            bytes += [UInt8](repeating: fill(block), count: 512)
        }
        try self.init(bytes: bytes)
    }

    /// An image holding `bytes`, then a hole up to `size` bytes.
    init(bytes: [UInt8], size: UInt64? = nil) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("scsi-\(UUID().uuidString).img")
        try Data(bytes).write(to: url)
        if let size {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: size)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }

    func contents() throws -> [UInt8] {
        Array(try Data(contentsOf: url))
    }

    func block(_ number: Int) throws -> [UInt8] {
        Array(try contents()[(number * 512)..<((number + 1) * 512)])
    }
}

/// A disk on a temporary image.
struct DiskFixture {
    let image: TemporaryImage
    let disk: SCSIDisk

    init(
        blocks: Int = 16,
        readOnly: Bool = false,
        synchronization: SCSIDiskImage.Synchronization = .fsync,
        identity: SCSIDisk.Identity = SCSIDisk.Identity()
    ) throws {
        try self.init(image: TemporaryImage(blocks: blocks), readOnly: readOnly, synchronization: synchronization, identity: identity)
    }

    init(
        image: TemporaryImage,
        readOnly: Bool = false,
        synchronization: SCSIDiskImage.Synchronization = .fsync,
        identity: SCSIDisk.Identity = SCSIDisk.Identity()
    ) throws {
        self.image = image
        disk = try SCSIDisk(
            image: SCSIDiskImage(path: image.path, readOnly: readOnly, synchronization: synchronization),
            identity: identity
        )
    }

    /// Runs `cdb` on the disk itself, past the bus: no unit attention, no
    /// deferred sense.
    func run(_ cdb: [UInt8], dataOut: [UInt8] = []) throws -> (completion: SCSICompletion, data: [UInt8]) {
        let command = try #require(SCSICommand(cdb, blockSize: 512))
        let dataIn = SCSIDataBuffer(capacity: 4096)
        let completion = dataOut.withUnsafeBytes { bytes in
            disk.execute(command, dataOut: SCSIDataOut(buffers: [bytes]), dataIn: dataIn)
        }
        return (completion, Array(dataIn.content))
    }
}

/// A descriptor chain held in memory: `readable` bytes for the device, then
/// room for `writable` bytes from it.
final class MemoryChain: VirtioDescriptorChain {
    private var readable: [[UInt8]]
    private let writableCapacity: Int
    private(set) var written: [UInt8] = []
    private(set) var completions = 0

    init(readable: [[UInt8]], writable: Int) {
        self.readable = readable.filter { !$0.isEmpty }
        self.writableCapacity = writable
    }

    convenience init(_ readable: [UInt8], writable: Int) {
        self.init(readable: [readable], writable: writable)
    }

    var readableByteCount: Int { readable.reduce(0) { $0 + $1.count } }
    var writableByteCount: Int { writableCapacity - written.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard readableByteCount >= buffer.count else {
            return false
        }
        var offset = 0
        while offset < buffer.count {
            let take = min(readable[0].count, buffer.count - offset)
            for index in 0..<take {
                buffer[offset + index] = readable[0][index]
            }
            readable[0].removeFirst(take)
            if readable[0].isEmpty {
                readable.removeFirst()
            }
            offset += take
        }
        return true
    }

    /// The remaining pieces, held in one array and handed over as the
    /// buffers they were.
    func readRemaining<Result>(_ body: ([UnsafeRawBufferPointer]) throws -> Result) rethrows -> Result {
        let pieces = readable
        readable = []
        return try pieces.flatMap { $0 }.withUnsafeBytes { all in
            var buffers: [UnsafeRawBufferPointer] = []
            var offset = 0
            for piece in pieces {
                buffers.append(UnsafeRawBufferPointer(rebasing: all[offset..<(offset + piece.count)]))
                offset += piece.count
            }
            return try body(buffers)
        }
    }

    func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard bytes.count <= writableByteCount else {
            return false
        }
        written += bytes
        return true
    }

    func complete() {
        completions += 1
    }
}

/// An event queue holding the buffers a driver posted.
final class MemoryEventQueue: VirtioEventQueue {
    var buffers: [MemoryChain] = []
    private(set) var taken: [MemoryChain] = []

    func post(_ count: Int, size: Int = 16) {
        for _ in 0..<count {
            buffers.append(MemoryChain([], writable: size))
        }
    }

    func nextChain() -> (any VirtioDescriptorChain)? {
        guard !buffers.isEmpty else {
            return nil
        }
        let chain = buffers.removeFirst()
        taken.append(chain)
        return chain
    }
}

let testUnitReady: [UInt8] = [0x00, 0, 0, 0, 0, 0]

/// A virtio-scsi command request: the LUN address, a tag, task attribute,
/// priority and CRN, then the CDB padded to the configured 32 bytes.
func commandRequest(target: UInt8 = 0, lun: UInt16 = 0, cdb: [UInt8]) -> [UInt8] {
    var request: [UInt8] = [1, target]
    request += SCSIBus.encode(lun: lun) + [0, 0, 0, 0]
    request += [UInt8](repeating: 0, count: 8)
    request += [0, 0, 0]
    request += cdb + [UInt8](repeating: 0, count: 32 - cdb.count)
    return request
}

/// The fields of a virtio-scsi command response.
struct CommandResponse {
    let senseLength: UInt32
    let residual: UInt32
    let status: UInt8
    let response: UInt8
    let sense: [UInt8]
    let data: [UInt8]

    init(_ bytes: [UInt8]) throws {
        try #require(bytes.count >= 108)
        senseLength = bytes.littleEndian32(at: 0)
        residual = bytes.littleEndian32(at: 4)
        status = bytes[10]
        response = bytes[11]
        sense = Array(bytes[12..<(12 + Int(senseLength))])
        data = Array(bytes[108...])
    }
}

extension SCSISense {
    var fixed: [UInt8] { data(descriptorFormat: false) }
}
