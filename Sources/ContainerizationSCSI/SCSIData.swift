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

/// The data a command sends to the device, left in the initiator's buffers,
/// where an image operation can read it from any thread.
struct SCSIDataOut: Sendable {
    let source: any VirtioReadableData

    /// Data held in byte arrays, as the transport hands no buffers over.
    init(bytes: [UInt8] = []) {
        source = HeldBytes(pieces: bytes.isEmpty ? [] : [bytes])
    }

    init(_ source: any VirtioReadableData) {
        self.source = source
    }

    /// The first `length` bytes, copied out.
    func bytes(_ length: Int) -> [UInt8] {
        source.withBuffers { buffers in
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for buffer in buffers where bytes.count < length {
                bytes.append(contentsOf: buffer.prefix(length - bytes.count))
            }
            return bytes
        }
    }

    func withBuffers<Result>(_ body: ([UnsafeRawBufferPointer]) throws -> Result) rethrows -> Result {
        try source.withBuffers(body)
    }
}

/// Data a driver wrote, held in one byte array and handed over as the
/// pieces it came in.
struct HeldBytes: VirtioReadableData {
    private let bytes: [UInt8]
    private let lengths: [Int]

    init(pieces: [[UInt8]]) {
        bytes = pieces.flatMap { $0 }
        lengths = pieces.map(\.count)
    }

    func withBuffers<Result>(_ body: ([UnsafeRawBufferPointer]) throws -> Result) rethrows -> Result {
        try bytes.withUnsafeBytes { all in
            var buffers: [UnsafeRawBufferPointer] = []
            buffers.reserveCapacity(lengths.count)
            var offset = 0
            for length in lengths {
                buffers.append(UnsafeRawBufferPointer(rebasing: all[offset..<(offset + length)]))
                offset += length
            }
            return try body(buffers)
        }
    }
}

/// The data a command returns to the initiator, held until the command
/// completes: a virtio-scsi response carries its status ahead of its data.
///
/// A read's operation fills the bytes `prepare` handed out on another
/// thread; nothing else touches the buffer until the operation has run.
final class SCSIDataBuffer {
    private var storage: UnsafeMutableRawBufferPointer
    private(set) var count = 0

    init(capacity: Int = 1 << 20) {
        storage = .allocate(byteCount: capacity, alignment: 16384)
    }

    deinit {
        storage.deallocate()
    }

    var content: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: storage[0..<count])
    }

    /// Makes the content `length` bytes long and returns them for the
    /// command to fill.
    func prepare(_ length: Int) -> UnsafeMutableRawBufferPointer {
        if length > storage.count {
            storage.deallocate()
            storage = .allocate(byteCount: length, alignment: 16384)
        }
        count = length
        return UnsafeMutableRawBufferPointer(rebasing: storage[0..<length])
    }

    /// Makes the content `bytes`, cut short or padded with zeros to `length`.
    func fill(_ bytes: [UInt8], length: Int) {
        let content = prepare(length)
        let copied = min(bytes.count, length)
        bytes.withUnsafeBytes { bytes in
            content.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes.prefix(copied)))
        }
        if copied < length {
            _ = UnsafeMutableRawBufferPointer(rebasing: content[copied...]).initializeMemory(as: UInt8.self, repeating: 0)
        }
    }

    func clear() {
        count = 0
    }
}
