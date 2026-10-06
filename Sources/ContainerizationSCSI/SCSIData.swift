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

/// The data a command sends to the device, left in the initiator's buffers.
struct SCSIDataOut {
    let buffers: [UnsafeRawBufferPointer]

    /// The first `length` bytes, copied out.
    func bytes(_ length: Int) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for buffer in buffers where bytes.count < length {
            bytes.append(contentsOf: buffer.prefix(length - bytes.count))
        }
        return bytes
    }
}

/// The data a command returns to the initiator, held until the command
/// completes: a virtio-scsi response carries its status ahead of its data.
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
