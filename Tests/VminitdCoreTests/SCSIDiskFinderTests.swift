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

#if os(Linux)

import ContainerizationError
import Foundation
import Testing

@testable import VminitdCore

@Suite("SCSI disk finder tests")
struct SCSIDiskFinderTests {
    /// A sysfs and dev root with two SCSI hosts and no disks.
    private struct Root {
        let url: URL
        var sys: URL { url.appendingPathComponent("sys") }
        var dev: URL { url.appendingPathComponent("dev") }

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("scsi-finder-\(UUID().uuidString)")
            for host in ["host0", "host1"] {
                let directory = url.appendingPathComponent("sys/class/scsi_host/\(host)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.touch(directory.appendingPathComponent("scan"))
            }
            try FileManager.default.createDirectory(at: url.appendingPathComponent("sys/bus/scsi/devices"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("dev"), withIntermediateDirectories: true)
        }

        static func touch(_ file: URL) throws {
            guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }

        func finder(timeout: Duration = .seconds(3)) -> SCSIDiskFinder {
            SCSIDiskFinder(sys: sys, dev: dev, timeout: timeout, interval: .milliseconds(5))
        }

        /// Registers a disk the way the kernel shows it: the SCSI device's
        /// block directory names the disk, then devtmpfs holds its node.
        func addDisk(_ name: String, address: String, node: Bool = true) throws {
            let block = sys.appendingPathComponent("bus/scsi/devices/\(address)/block/\(name)")
            try FileManager.default.createDirectory(at: block, withIntermediateDirectories: true)
            if node {
                try Self.touch(dev.appendingPathComponent(name))
            }
        }

        func scanWritten(_ host: String) throws -> String {
            try String(contentsOf: sys.appendingPathComponent("class/scsi_host/\(host)/scan"), encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test
    func scanAsksEveryHostForTheLogicalUnitOnChannelZero() throws {
        let root = try Root()
        defer { root.remove() }

        try root.finder().scan(target: 3, lun: 7)

        #expect(try root.scanWritten("host0") == "0 3 7")
        #expect(try root.scanWritten("host1") == "0 3 7")
    }

    @Test
    func blockDeviceNeedsTheRegisteredDiskAndItsNode() throws {
        let root = try Root()
        defer { root.remove() }
        let finder = root.finder()

        #expect(finder.blockDevice(target: 3, lun: 7) == nil)

        try root.addDisk("sdb", address: "0:0:3:7", node: false)
        #expect(finder.blockDevice(target: 3, lun: 7) == nil)

        try Root.touch(root.dev.appendingPathComponent("sdb"))
        #expect(finder.blockDevice(target: 3, lun: 7) == root.dev.appendingPathComponent("sdb").path)
    }

    @Test
    func addressIsOnHostZeroAndChannelZero() throws {
        let root = try Root()
        defer { root.remove() }
        let finder = root.finder()

        try root.addDisk("sdc", address: "1:0:3:7")
        try root.addDisk("sdd", address: "0:1:3:7")
        try root.addDisk("sde", address: "0:0:7:3")

        #expect(finder.blockDevice(target: 3, lun: 7) == nil)
    }

    @Test
    func findWaitsForADiskThatAppearsAfterTheScan() async throws {
        let root = try Root()
        defer { root.remove() }

        let arrival = Task {
            try await Task.sleep(for: .milliseconds(50))
            try root.addDisk("sdb", address: "0:0:3:7")
        }
        let device = try await root.finder().find(target: 3, lun: 7)
        try await arrival.value

        #expect(device == root.dev.appendingPathComponent("sdb").path)
        #expect(try root.scanWritten("host0") == "0 3 7")
    }

    @Test
    func findTimesOutWhenNoDiskAppears() async throws {
        let root = try Root()
        defer { root.remove() }

        do {
            _ = try await root.finder(timeout: .milliseconds(50)).find(target: 3, lun: 7)
            Issue.record("found a disk that was never registered")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }
    }
}

#endif
