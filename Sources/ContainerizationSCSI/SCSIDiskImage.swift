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
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// A raw disk image file a logical unit reads and writes.
///
/// Its reads, writes, flushes and discards behave as QEMU's file driver
/// makes them behave on macOS, block/file-posix.c with the block layer's
/// discard in block/io.c, at d7a65d1793d6:
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/block/file-posix.c
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/block/io.c
///
/// Operations on the image run on several threads at once, as the file
/// driver's do on QEMU's thread pool: each is a positioned call on the one
/// descriptor, and the image's only mutable state is atomic.
public final class SCSIDiskImage: @unchecked Sendable {
    /// Whether the host's page cache holds the image's data (QEMU's
    /// cache.direct).
    public enum Caching: Sendable {
        case cached
        /// QEMU's cache.direct=on. macOS has no O_DIRECT, so QEMU opens the
        /// image O_DSYNC instead (file-posix.c): each write reaches the
        /// drive before it completes.
        case uncached
    }

    /// What a flush of the image reaches.
    public enum Synchronization: Sendable {
        /// Permanent storage: F_FULLFSYNC.
        case full
        /// The drive, with fsync(2). It is QEMU's flush on macOS, where
        /// _POSIX_SYNCHRONIZED_IO is -1 and qemu_fdatasync falls back to
        /// fsync (util/osdep.c).
        case fsync
        /// Nothing: QEMU's cache.no-flush, a flush completes at once.
        case none
    }

    /// A host call on the image that failed with `code`.
    struct HostError: Error {
        let code: Int32
    }

    public let path: String
    public let readOnly: Bool
    public let caching: Caching
    public let synchronization: Synchronization
    /// The open image, or -1 once it is closed.
    private let openDescriptor: Atomic<Int32>
    private var descriptor: Int32 { openDescriptor.load(ordering: .acquiring) }
    /// The granularity a hole can be punched at: the file system's block
    /// size, as file-posix.c takes it for pdiscard_alignment on macOS.
    private let discardAlignment: UInt64

    /// Opens the image at `path` and takes the lock a disk image attachment
    /// holds on it: shared for a read-only image, exclusive otherwise, so
    /// that an image one machine writes reaches no other.
    public init(path: String, readOnly: Bool, caching: Caching = .cached, synchronization: Synchronization = .fsync) throws {
        var flags = (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC
        if caching == .uncached {
            flags |= O_DSYNC
        }
        let descriptor = open(path, flags)
        guard descriptor >= 0 else {
            throw ContainerizationError(.internalError, message: "failed to open disk image \(path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, (readOnly ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            let error = errno
            _ = closeDescriptor(descriptor)
            guard error == EWOULDBLOCK else {
                throw ContainerizationError(.internalError, message: "failed to lock disk image \(path): \(String(cString: strerror(error)))")
            }
            throw ContainerizationError(
                .invalidState,
                message: "disk image \(path) is attached to another machine; a disk is attached to a second machine only while every machine mounts it read-only"
            )
        }
        self.path = path
        self.readOnly = readOnly
        self.caching = caching
        self.synchronization = synchronization
        self.openDescriptor = Atomic(descriptor)
        self.discardAlignment = Self.fileSystemBlockSize(descriptor)
    }

    deinit {
        close()
    }

    /// Closes the image, which lets go of its lock. Called once no
    /// operation can reach the image any more; one that did would fail as on
    /// a closed file.
    public func close() {
        let descriptor = openDescriptor.exchange(-1, ordering: .acquiringAndReleasing)
        if descriptor >= 0 {
            _ = closeDescriptor(descriptor)
        }
    }

    private static func fileSystemBlockSize(_ descriptor: Int32) -> UInt64 {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0, info.f_bsize > 0 else {
            return 4096
        }
        return UInt64(info.f_bsize)
    }

    /// The image's size in bytes.
    func size() throws -> UInt64 {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw HostError(code: errno)
        }
        return UInt64(info.st_size)
    }

    /// Fills `buffer` from `offset`. Bytes past the end of the file read as
    /// zeros, as file-posix.c returns them.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws {
        guard let base = buffer.baseAddress else {
            return
        }
        var done = 0
        while done < buffer.count {
            let count = pread(descriptor, base + done, buffer.count - done, off_t(offset) + off_t(done))
            if count < 0 {
                guard errno == EINTR else {
                    throw HostError(code: errno)
                }
                continue
            }
            if count == 0 {
                (base + done).initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count - done)
                return
            }
            done += count
        }
    }

    /// Writes the first `count` bytes of `buffers`, in order, at `offset`,
    /// straight from where they lie.
    func write(_ buffers: [UnsafeRawBufferPointer], count: Int, at offset: UInt64) throws {
        var vectors: [iovec] = []
        var remaining = count
        for buffer in buffers where remaining > 0 {
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                continue
            }
            let length = min(buffer.count, remaining)
            vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: length))
            remaining -= length
        }
        guard remaining == 0 else {
            throw HostError(code: EINVAL)
        }
        var position = off_t(offset)
        var first = 0
        while first < vectors.count {
            let batch = Int32(min(vectors.count - first, Self.maximumVectors))
            let written = vectors.withUnsafeMutableBufferPointer { vectors in
                pwritev(descriptor, vectors.baseAddress.map { $0 + first }, batch, position)
            }
            if written < 0 {
                guard errno == EINTR else {
                    throw HostError(code: errno)
                }
                continue
            }
            // A write that stops short of its buffers is one QEMU's file
            // driver fails with EINVAL (handle_aiocb_rw).
            guard written > 0 else {
                throw HostError(code: EINVAL)
            }
            position += off_t(written)
            var left = written
            while left > 0 {
                if left >= vectors[first].iov_len {
                    left -= vectors[first].iov_len
                    first += 1
                } else {
                    vectors[first].iov_base = vectors[first].iov_base.map { $0 + left }
                    vectors[first].iov_len -= left
                    left = 0
                }
            }
        }
    }

    /// IOV_MAX on macOS and Linux.
    private static let maximumVectors = 1024

    /// The largest run a pattern is written in at once (SCSI_WRITE_SAME_MAX
    /// in hw/scsi/scsi-disk.c).
    static let patternRunLength = 512 * 1024

    /// Writes `pattern` again and again over `length` bytes from `offset`,
    /// a run at a time. Between two runs it calls `betweenRuns`, and stops
    /// when that returns false. Returns whether it wrote the whole range.
    func write(repeating pattern: [UInt8], length: UInt64, at offset: UInt64, betweenRuns: () throws -> Bool) throws -> Bool {
        guard !pattern.isEmpty else {
            return true
        }
        let runLength = Int(min(length, UInt64(Self.patternRunLength)))
        var run = [UInt8]()
        run.reserveCapacity(runLength)
        while run.count < runLength {
            run.append(contentsOf: pattern.prefix(runLength - run.count))
        }
        var done: UInt64 = 0
        while done < length {
            guard try done == 0 || betweenRuns() else {
                return false
            }
            let count = Int(min(length - done, UInt64(run.count)))
            try run.withUnsafeBytes { bytes in
                try write([UnsafeRawBufferPointer(rebasing: bytes.prefix(count))], count: count, at: offset + done)
            }
            done += UInt64(count)
        }
        return true
    }

    /// Makes what the image has written so far reach what its
    /// synchronization mode says a flush reaches.
    func flush() throws {
        let result: Int32
        switch synchronization {
        case .none:
            return
        case .fsync:
            result = fsync(descriptor)
        case .full:
            #if canImport(Darwin)
            result = fcntl(descriptor, F_FULLFSYNC)
            #else
            result = fsync(descriptor)
            #endif
        }
        guard result == 0 else {
            throw HostError(code: errno)
        }
    }

    /// Gives back the storage under `length` bytes from `offset`.
    ///
    /// The range goes to the file system in the pieces bdrv_co_pdiscard
    /// splits it into: an unaligned head up to the first block boundary, the
    /// whole blocks, and an unaligned tail. A discard is advisory, so a piece
    /// the file system refuses for its alignment keeps its data, and once
    /// the file system has refused to punch holes at all, no discard tries
    /// again (has_discard in file-posix.c).
    func discard(offset: UInt64, length: UInt64) throws {
        let alignment = discardAlignment
        var offset = offset
        var remaining = length
        var head = offset % alignment
        let tail = (offset + length) % alignment
        while remaining > 0 {
            var count = remaining
            if head != 0 {
                count = min(remaining, alignment - head)
                head = (head + count) % alignment
            } else if tail != 0 && count > alignment {
                count -= tail
            }
            try punchHole(offset: offset, length: count)
            offset += count
            remaining -= count
        }
    }

    /// Whether the file system punches holes, until it first refuses to.
    private let punchesHoles = Atomic(true)

    /// Punches a hole as handle_aiocb_discard does on macOS: F_PUNCHHOLE,
    /// with ENODEV taken for ENOTSUP. Elsewhere the image keeps its data.
    private func punchHole(offset: UInt64, length: UInt64) throws {
        #if canImport(Darwin)
        guard punchesHoles.load(ordering: .relaxed) else {
            return
        }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(length))
        guard fcntl(descriptor, F_PUNCHHOLE, &hole) == -1 else {
            return
        }
        let error = errno
        switch error {
        case ENOTSUP, ENODEV:
            punchesHoles.store(false, ordering: .relaxed)
        case EINVAL where offset % discardAlignment != 0 || length % discardAlignment != 0:
            break
        default:
            throw HostError(code: error)
        }
        #endif
    }
}

/// The C library's close, which the image's own `close()` hides inside it.
private func closeDescriptor(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Musl)
    Musl.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #endif
}
