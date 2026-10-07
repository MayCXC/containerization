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

/// The image I/O a command waits on. It runs away from the queue the
/// device is driven on, as QEMU's disk hands its reads, writes, flushes and
/// discards to the block layer and completes the command in their callbacks
/// (blk_aio_preadv, blk_aio_pwritev, blk_aio_flush and blk_aio_pdiscard in
/// hw/scsi/scsi-disk.c at d7a65d1793d6):
/// https://github.com/qemu/qemu/blob/d7a65d1793d6/hw/scsi/scsi-disk.c
///
/// An operation owns what it touches while it runs: the bytes of the
/// command's data-in buffer a read fills, which nothing else touches until
/// the operation has run, and the initiator's buffers a write reads.
///
/// An operation is one or more requests to the image, issued in turn. Once
/// issued, a request runs to its end even when its command is canceled, as
/// the block layer lets a request the disk issued complete
/// (bdrv_aio_cancel_async in block/io.c); a canceled command issues no
/// further request, as the disk checks for the cancel in each completion
/// before it issues the next (scsi_disk_req_check_error).
struct SCSIOperation: @unchecked Sendable {
    enum Kind {
        /// Reads into the command's data-in buffer, after a flush of its own
        /// when the command forces unit access (scsi_read_data, scsi_do_read).
        case read(offset: UInt64, flushFirst: Bool)
        /// Writes `length` bytes of the command's data-out, flushed in the
        /// same request when the command forces unit access or the write
        /// cache is off, as the block layer completes such a write
        /// (scsi_dma_writev, bdrv_driver_pwritev).
        case write(offset: UInt64, length: Int, flushAfter: Bool)
        /// SYNCHRONIZE CACHE, or MODE SELECT turning the write cache off.
        case flush
        /// UNMAP: a request for each range in turn, until one falls outside
        /// the disk (scsi_unmap_complete_noio).
        case unmap(ranges: [(lba: UInt64, blocks: UInt64)], lastBlock: UInt64)
        /// WRITE SAME of a block that is not all zeros: the block written
        /// over a range, a request for each run of it, each flushed when the
        /// write cache is off (scsi_write_same_complete).
        case writeSame(pattern: [UInt8], offset: UInt64, length: UInt64, flushAfter: Bool)
        /// WRITE SAME of zeros: one request that writes them, flushed once at
        /// its end when the write cache is off (blk_aio_pwrite_zeroes, and
        /// bdrv_co_do_pwrite_zeroes writing them on a file that cannot zero
        /// a range in place).
        case writeZeros(offset: UInt64, length: UInt64, flushAfter: Bool)
    }

    let image: SCSIDiskImage
    let kind: Kind
    /// Where a read leaves its data.
    let destination: UnsafeMutableRawBufferPointer?
    /// What a write writes.
    let source: SCSIDataOut?

    init(image: SCSIDiskImage, kind: Kind, destination: UnsafeMutableRawBufferPointer? = nil, source: SCSIDataOut? = nil) {
        self.image = image
        self.kind = kind
        self.destination = destination
        self.source = source
    }

    /// Runs the operation and returns how the command completes, or nil when
    /// `canceled` said, between two of its requests, that the command was
    /// canceled.
    func run(until canceled: () -> Bool = { false }) -> SCSICompletion? {
        Self.perform {
            switch kind {
            case .read(let offset, let flushFirst):
                if flushFirst {
                    try image.flush()
                    guard !canceled() else {
                        return nil
                    }
                }
                if let destination {
                    try image.read(into: destination, at: offset)
                }
            case .write(let offset, let length, let flushAfter):
                if let source {
                    try source.withBuffers { buffers in
                        try image.write(buffers, count: length, at: offset)
                    }
                }
                if flushAfter {
                    try image.flush()
                }
            case .flush:
                try image.flush()
            case .unmap(let ranges, let lastBlock):
                for (index, range) in ranges.enumerated() {
                    guard index == 0 || !canceled() else {
                        return nil
                    }
                    guard SCSIDisk.addresses(range.lba, blocks: range.blocks, lastBlock: lastBlock) else {
                        return .checkCondition(.lbaOutOfRange)
                    }
                    let blockSize = UInt64(SCSIDisk.blockSize)
                    try image.discard(offset: range.lba * blockSize, length: range.blocks * blockSize)
                }
            case .writeSame(let pattern, let offset, let length, let flushAfter):
                let finished = try image.write(repeating: pattern, length: length, at: offset) {
                    if flushAfter {
                        try image.flush()
                    }
                    return !canceled()
                }
                guard finished else {
                    return nil
                }
                if flushAfter {
                    try image.flush()
                }
            case .writeZeros(let offset, let length, let flushAfter):
                _ = try image.write(repeating: [UInt8](repeating: 0, count: SCSIDisk.blockSize), length: length, at: offset) { true }
                if flushAfter {
                    try image.flush()
                }
            }
            return .good
        }
    }

    /// Runs `body`, reporting a failed host call the way QEMU reports it to
    /// the guest (scsi_handle_rw_error with the report error action).
    static func perform(_ body: () throws -> SCSICompletion?) -> SCSICompletion? {
        do {
            return try body()
        } catch let error as SCSIDiskImage.HostError {
            return .hostError(error.code)
        } catch {
            return .checkCondition(.ioProcessTerminated)
        }
    }
}
