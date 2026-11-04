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

#if os(macOS)
import Darwin

/// Memory this process allocates and writes so that macOS runs short and
/// reclaims memory from everything else, test machines included. What macOS
/// does with a machine's memory when it runs short is only observable while it
/// is short.
final class HostMemoryPressure {
    private var regions: [(address: UnsafeMutableRawPointer, size: Int)] = []
    private(set) var bytes: UInt64 = 0

    /// Allocate `size` more bytes and write every page of them.
    func grow(by size: Int) throws {
        let address = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let address, address != MAP_FAILED else {
            throw IntegrationError.assert(msg: "could not map \(size) bytes: errno \(errno)")
        }
        let pageSize = Int(getpagesize())
        for offset in stride(from: 0, to: size, by: pageSize) {
            address.storeBytes(of: UInt64(offset + 1), toByteOffset: offset, as: UInt64.self)
        }
        regions.append((address, size))
        bytes += UInt64(size)
    }

    func release() {
        for region in regions {
            munmap(region.address, region.size)
        }
        regions.removeAll()
        bytes = 0
    }

    deinit {
        release()
    }
}
#endif
