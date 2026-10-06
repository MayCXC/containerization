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

import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage

#if os(macOS)
@available(macOS 27, *)
extension IntegrationSuite {
    /// A volume on the machine's virtio-scsi host keeps what one machine
    /// wrote for the next machine that mounts it.
    func testPodSCSIVolumeAcrossStopAndStart() async throws {
        let id = "test-pod-scsi-volume-stop-start"
        let bs = try await bootstrap(id)
        let disk = try createEXT4DiskImage(testID: id, name: "scsi")

        let writerOutput = try await runPodContainer(
            podID: "\(id)-first",
            bootstrap: bs,
            volumes: [.init(name: "data", source: .diskImage(path: disk), format: "ext4")],
            mounts: [.sharedMount(name: "data", destination: "/data")],
            script: "echo scsi-content > /data/file && grep ' /data ' /proc/mounts"
        )
        try assertSCSIDiskMount(writerOutput, path: "/data")
        let written = try readFileFromDiskImage(disk, path: "/file")
        guard written == "scsi-content" else {
            throw IntegrationError.assert(msg: "disk image /file after the first machine: expected 'scsi-content', got '\(written)'")
        }

        let readerOutput = try await runPodContainer(
            podID: "\(id)-second",
            bootstrap: bs,
            volumes: [.init(name: "data", source: .diskImage(path: disk), format: "ext4")],
            mounts: [.sharedMount(name: "data", destination: "/data")],
            script: "cat /data/file && echo second-content > /data/second"
        )
        guard readerOutput == "scsi-content" else {
            throw IntegrationError.assert(msg: "the second machine read '\(readerOutput)' from the volume, expected 'scsi-content'")
        }
        let second = try readFileFromDiskImage(disk, path: "/second")
        guard second == "second-content" else {
            throw IntegrationError.assert(msg: "disk image /second after the second machine: expected 'second-content', got '\(second)'")
        }
    }

    /// One machine takes forty volumes on its virtio-scsi host beside its
    /// container's root, past the disks Virtualization lets a machine boot
    /// with.
    func testPodFortySCSIVolumes() async throws {
        let id = "test-pod-forty-scsi-volumes"
        let count = 40
        let bs = try await bootstrap(id)

        var volumes: [LinuxPod.PodVolume] = []
        var mounts: [Containerization.Mount] = []
        var disks: [URL] = []
        for index in 0..<count {
            let disk = try createEXT4DiskImage(testID: id, name: "v\(index)", size: 16.mib())
            disks.append(disk)
            volumes.append(.init(name: "v\(index)", source: .diskImage(path: disk), format: "ext4"))
            mounts.append(.sharedMount(name: "v\(index)", destination: "/v\(index)"))
        }

        // Each volume gets its own index, then the container counts the
        // indexes it reads back and the SCSI disks the guest has: the
        // volumes and the container's root.
        let output = try await runPodContainer(
            podID: id,
            bootstrap: bs,
            volumes: volumes,
            mounts: mounts,
            script: """
                i=0; while [ $i -lt \(count) ]; do echo $i > /v$i/index; i=$((i+1)); done
                i=0; n=0; while [ $i -lt \(count) ]; do [ "$(cat /v$i/index)" = "$i" ] && n=$((n+1)); i=$((i+1)); done
                echo "$n $(ls /sys/block | grep -c '^sd')"
                """
        )
        guard output == "\(count) \(count + 1)" else {
            throw IntegrationError.assert(msg: "expected '\(count) \(count + 1)' (indexes read back, SCSI disks), got '\(output)'")
        }
        for (index, disk) in disks.enumerated() {
            let content = try readFileFromDiskImage(disk, path: "/index")
            guard content == "\(index)" else {
                throw IntegrationError.assert(msg: "disk image v\(index) holds '\(content)', expected '\(index)'")
            }
        }
    }

    /// A container joining the running machine gets its root filesystem as a
    /// logical unit added to the virtio-scsi host, beside the first
    /// container's root; the guest sees the disk appear, the container writes
    /// to it, and once the container is stopped the guest sees the disk go
    /// and the write is in the image.
    func testPodHotplugSCSIRootfs() async throws {
        let id = "test-pod-hotplug-scsi-rootfs"
        let bs = try await bootstrap(id)

        let pod = try LinuxPod(id, vmm: bs.vmm, vm: .default) { config in
            config.bootLog = bs.bootLog
            config.blockDeviceDriver = .virtioSCSI
        }
        try await pod.addContainer("seed", rootfs: try cloneRootfs(bs.rootfs, testID: id, containerID: "seed")) { config in
            config.process.arguments = ["/bin/sleep", "infinity"]
        }
        let hotRootfs = try cloneRootfs(bs.rootfs, testID: id, containerID: "hot")

        do {
            try await pod.create()
            try await pod.startContainer("seed")
            let before = try await scsiDisks(in: pod, container: "seed")
            guard before.count == 1 else {
                throw IntegrationError.assert(msg: "expected the first container's root alone on the SCSI host, the guest has \(before)")
            }

            let buffer = BufferWriter()
            try await pod.addContainer("hot", rootfs: hotRootfs) { config in
                config.process.arguments = ["/bin/sh", "-c", "echo hot-write > /hotfile && grep ' / ' /proc/mounts"]
                config.process.stdout = buffer
            }
            let during = try await scsiDisks(in: pod, container: "seed")
            guard during.count == 2, Set(during).isSuperset(of: before) else {
                throw IntegrationError.assert(msg: "expected a second SCSI disk once the container joined, the guest has \(during)")
            }

            try await pod.startContainer("hot")
            let status = try await pod.waitContainer("hot")
            guard status.exitCode == 0 else {
                throw IntegrationError.assert(msg: "hot container status \(status) != 0")
            }
            let rootMount = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try assertSCSIDiskMount(rootMount, path: "/")

            try await pod.stopContainer("hot")
            var after = try await scsiDisks(in: pod, container: "seed")
            for _ in 0..<50 where after != before {
                try await Task.sleep(for: .milliseconds(100))
                after = try await scsiDisks(in: pod, container: "seed")
            }
            guard after == before else {
                throw IntegrationError.assert(msg: "the guest has \(after) after the container's disk was removed, expected \(before)")
            }
            try await pod.stop()
        } catch {
            try? await pod.stop()
            throw error
        }

        let written = try readFileFromDiskImage(URL(fileURLWithPath: hotRootfs.source), path: "/hotfile")
        guard written == "hot-write" else {
            throw IntegrationError.assert(msg: "the hot container's root filesystem image holds '\(written)', expected 'hot-write'")
        }
    }

    /// What a container writes to a volume on the virtio-scsi host without
    /// syncing is in the image once the machine has stopped.
    func testPodSCSIVolumeKeepsUnsyncedWrites() async throws {
        let id = "test-pod-scsi-volume-unsynced"
        let bs = try await bootstrap(id)
        let disk = try createEXT4DiskImage(testID: id, name: "scsi")
        let size = 4 * 1024 * 1024

        _ = try await runPodContainer(
            podID: id,
            bootstrap: bs,
            volumes: [.init(name: "data", source: .diskImage(path: disk), format: "ext4")],
            mounts: [.sharedMount(name: "data", destination: "/data")],
            script: "yes scsi | head -c \(size) > /data/big && echo written > /data/marker"
        )

        let marker = try readFileFromDiskImage(disk, path: "/marker")
        guard marker == "written" else {
            throw IntegrationError.assert(msg: "disk image /marker: expected 'written', got '\(marker)'")
        }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(disk.path))
        let big = try reader.readFile(at: FilePath("/big"))
        let expected = Data(String(repeating: "scsi\n", count: size / 5 + 1).utf8.prefix(size))
        guard big == expected else {
            throw IntegrationError.assert(msg: "disk image /big holds \(big.count) bytes, not the \(size) written")
        }
    }

    /// The same transfers from the guest on a volume of equal size on each
    /// block device driver, each in a machine of that driver, two rounds
    /// with the order swapped. A cold read is the first read in a freshly
    /// booted machine. Runs only when CONTAINERIZATION_SCSI_SPEED is set,
    /// alone on a quiet host, since its numbers are the measurement.
    func testPodSCSISpeed() async throws {
        guard ProcessInfo.processInfo.environment["CONTAINERIZATION_SCSI_SPEED"] != nil else {
            throw SkipTest(reason: "set CONTAINERIZATION_SCSI_SPEED to measure")
        }
        let id = "test-pod-scsi-speed"
        let bs = try await bootstrap(id)
        let size: UInt64 = 1.gib()
        let disks: [String: URL] = [
            "blk": try createEXT4DiskImage(testID: id, name: "blk", size: size),
            "scsi": try createEXT4DiskImage(testID: id, name: "scsi", size: size),
        ]
        let machines: [String: any VirtualMachineManager] = [
            "blk": BlockDeviceDriverMachines.forcing(.virtioBlock, on: bs.vmm),
            "scsi": BlockDeviceDriverMachines.forcing(.virtioSCSI, on: bs.vmm),
        ]
        func volumes(_ name: String) -> [LinuxPod.PodVolume] {
            disks[name].map { [.init(name: name, source: .diskImage(path: $0), format: "ext4")] } ?? []
        }
        func mounts(_ name: String) -> [Containerization.Mount] {
            [.sharedMount(name: name, destination: "/\(name)")]
        }
        // busybox's dd times its own transfer, fsync included, to the
        // microsecond and prints it on its last status line; the guest's date
        // has whole seconds only. A transfer that fails prints FAIL, which no
        // status line reads as.
        let timed = """
            run() { out=$("$@" 2>&1 >/dev/null) || { echo FAIL; return; }; echo "$out" | tail -n 1; }
            """
        var lines: [String] = []
        for round in 1...2 {
            let order = round == 1 ? ["blk", "scsi"] : ["scsi", "blk"]
            for name in order {
                let writes =
                    timed + """

                        echo "\(name) write-fsync-256MiB $(run dd if=/dev/zero of=/\(name)/f bs=1M count=256 conv=fsync)"
                        echo "\(name) write-direct-1MiB-256MiB $(run dd if=/dev/zero of=/\(name)/d bs=1M count=256 oflag=direct)"
                        echo "\(name) read-direct-1MiB-256MiB $(run dd if=/\(name)/d of=/dev/null bs=1M iflag=direct)"
                        echo "\(name) write-direct-4KiB-20000 $(run dd if=/dev/zero of=/\(name)/k bs=4k count=20000 oflag=direct)"
                        echo "\(name) read-direct-4KiB-20000 $(run dd if=/\(name)/k of=/dev/null bs=4k iflag=direct)"
                        """
                let written = try await runPodContainer(
                    podID: "\(id)-\(name)-w\(round)", bootstrap: bs, vmm: machines[name], volumes: volumes(name), mounts: mounts(name), script: writes)
                let reads =
                    timed + """

                        echo "\(name) read-cold-256MiB $(run dd if=/\(name)/f of=/dev/null bs=1M)"
                        """
                let read = try await runPodContainer(
                    podID: "\(id)-\(name)-r\(round)", bootstrap: bs, vmm: machines[name], volumes: volumes(name), mounts: mounts(name), script: reads)
                lines += (written + "\n" + read).split(separator: "\n").map { "round \(round) \($0)" }
            }
        }

        var report = "virtio-blk against virtio-scsi, from the guest (MB/s, or IOPS for 4 KiB):"
        for line in lines {
            // "round <n> <volume> <test> <dd's last status line>"
            let fields = line.split(separator: " ", maxSplits: 4)
            guard fields.count == 5, let seconds = Self.ddSeconds(String(fields[4])), seconds > 0 else {
                throw IntegrationError.assert(msg: "unreadable measurement line '\(line)'")
            }
            let test = String(fields[3])
            let rate: String
            if test.hasSuffix("4KiB-20000") {
                rate = String(format: "%.0f IOPS", 20000 / seconds)
            } else {
                rate = String(format: "%.0f MB/s", 256 * 1_048_576 / seconds / 1e6)
            }
            report += "\n  \(fields[0]) \(fields[1]) \(fields[2]) \(test): \(rate)"
        }
        print(report)
    }

    /// A container with a machine of its own on the virtio-scsi host: its
    /// root and the disk it mounts are logical units, the disk mounted by its
    /// address and bound into the container, and what the container writes is
    /// in the image once the container stops.
    func testContainerDiskOnSCSIHost() async throws {
        let id = "test-container-disk-on-scsi-host"
        let output = try await runContainerWithDisk(id: id, driver: .virtioSCSI)
        let lines = output.text.split(separator: "\n").map(String.init)
        guard lines.count == 2, lines[0].hasPrefix("/dev/sd"), lines[1].hasPrefix("/dev/sd") else {
            throw IntegrationError.assert(msg: "expected the root and /data on SCSI disks (/dev/sd*), got: \(output.text)")
        }
        guard output.written == "disk-write" else {
            throw IntegrationError.assert(msg: "the disk image holds '\(output.written)', expected 'disk-write'")
        }
    }

    /// The same container on the default driver: its root and its disk are
    /// virtio block devices, named by their device paths.
    func testContainerDiskOnDefaultDriver() async throws {
        let id = "test-container-disk-on-default-driver"
        let output = try await runContainerWithDisk(id: id, driver: nil)
        let lines = output.text.split(separator: "\n").map(String.init)
        guard lines.count == 2, lines[0].hasPrefix("/dev/vd"), lines[1].hasPrefix("/dev/vd") else {
            throw IntegrationError.assert(msg: "expected the root and /data on virtio block devices (/dev/vd*), got: \(output.text)")
        }
        guard output.written == "disk-write" else {
            throw IntegrationError.assert(msg: "the disk image holds '\(output.written)', expected 'disk-write'")
        }
    }

    /// 4 KiB direct reads from one stream and from eight at once, on a
    /// volume of equal size on each block device driver, each in a machine
    /// of that driver, two rounds with the order swapped: eight streams keep
    /// eight commands in flight, where each transfer of the speed test keeps
    /// one. Runs only when CONTAINERIZATION_SCSI_SPEED is set, alone on a
    /// quiet host, since its numbers are the measurement.
    func testPodSCSIStreams() async throws {
        guard ProcessInfo.processInfo.environment["CONTAINERIZATION_SCSI_SPEED"] != nil else {
            throw SkipTest(reason: "set CONTAINERIZATION_SCSI_SPEED to measure")
        }
        let id = "test-pod-scsi-streams"
        let bs = try await bootstrap(id)
        let size: UInt64 = 1.gib()
        let disks: [String: URL] = [
            "blk": try createEXT4DiskImage(testID: id, name: "blk", size: size),
            "scsi": try createEXT4DiskImage(testID: id, name: "scsi", size: size),
        ]
        let machines: [String: any VirtualMachineManager] = [
            "blk": BlockDeviceDriverMachines.forcing(.virtioBlock, on: bs.vmm),
            "scsi": BlockDeviceDriverMachines.forcing(.virtioSCSI, on: bs.vmm),
        ]
        // Each stream reads its own share of the file. The guest's clock
        // reads to the hundredth of a second in /proc/uptime, its date to the
        // second, and a read that fails ends the script, so no time is taken
        // over a transfer that did not happen.
        let blocks = 64000
        var output = ""
        for round in 1...2 {
            for name in round == 1 ? ["blk", "scsi"] : ["scsi", "blk"] {
                var script = """
                    set -e
                    dd if=/dev/zero of=/\(name)/k bs=4k count=\(blocks) conv=fsync 2>/dev/null
                    reads() { per=$((\(blocks) / $2)); pids=""; i=0; while [ $i -lt $2 ]; do dd if=/$1/k of=/dev/null bs=4k skip=$((i * per)) count=$per iflag=direct 2>/dev/null & pids="$pids $!"; i=$((i + 1)); done; for p in $pids; do wait $p; done; }
                    """
                for streams in [1, 8] {
                    script += """

                        s=$(cut -d' ' -f1 /proc/uptime); reads \(name) \(streams); e=$(cut -d' ' -f1 /proc/uptime); echo "round \(round) \(name) \(streams) $s $e"
                        """
                }
                let volumes: [LinuxPod.PodVolume] = disks[name].map { [.init(name: name, source: .diskImage(path: $0), format: "ext4")] } ?? []
                output +=
                    try await runPodContainer(
                        podID: "\(id)-\(name)-\(round)", bootstrap: bs, vmm: machines[name], volumes: volumes,
                        mounts: [.sharedMount(name: name, destination: "/\(name)")], script: script) + "\n"
            }
        }

        var report = "virtio-blk against virtio-scsi, \(blocks) direct 4 KiB reads from one stream and from eight (IOPS):"
        for line in output.split(separator: "\n") {
            // "round <n> <volume> <streams> <start> <end>", the times in
            // seconds since the guest booted.
            let fields = line.split(separator: " ")
            guard fields.count == 6, let start = Double(fields[4]), let end = Double(fields[5]), end > start else {
                throw IntegrationError.assert(msg: "unreadable measurement line '\(line)'")
            }
            let rate = String(format: "%.0f IOPS", Double(blocks) / (end - start))
            report += "\n  \(fields[0]) \(fields[1]) \(fields[2]) \(fields[3]) streams: \(rate)"
        }
        print(report)
    }

    // MARK: - Helpers

    /// Runs a container with a machine of its own and a disk image mounted at
    /// /data, on `driver`, or on the default when it is nil and whatever the
    /// suite runs on; returns the devices its root and /data are mounted from
    /// and what it wrote to the disk.
    private func runContainerWithDisk(id: String, driver: BlockDeviceDriver?) async throws -> (text: String, written: String) {
        let bs = try await bootstrap(id)
        let disk = try createEXT4DiskImage(testID: id, name: "disk")
        let buffer = BufferWriter()
        let vmm = BlockDeviceDriverMachines.forcing(driver ?? .virtioBlock, on: bs.vmm)
        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: vmm) { config in
            config.blockDeviceDriver = driver ?? .virtioBlock
            config.mounts.append(.block(format: "ext4", source: disk.absolutePath(), destination: "/data"))
            config.process.arguments = [
                "/bin/sh", "-c",
                "echo disk-write > /data/file && grep ' / ' /proc/mounts | cut -d' ' -f1 && grep ' /data ' /proc/mounts | cut -d' ' -f1",
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }
        try await container.create()
        try await container.start()
        let status = try await container.wait()
        try await container.stop()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "container exited with \(status)")
        }
        let text = String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text, try readFileFromDiskImage(disk, path: "/file"))
    }

    /// Runs one container with `script` in a pod of its own that has
    /// `volumes` on the virtio-scsi host, stops the pod, and returns what the
    /// script printed. `vmm` makes the pod's machine where one is given.
    private func runPodContainer(
        podID: String,
        bootstrap bs: (rootfs: Containerization.Mount, vmm: VirtualMachineManager, image: Containerization.Image, bootLog: BootLog),
        vmm: (any VirtualMachineManager)? = nil,
        volumes: [LinuxPod.PodVolume],
        mounts: [Containerization.Mount],
        script: String
    ) async throws -> String {
        let pod = try LinuxPod(podID, vmm: vmm ?? bs.vmm, vm: VMResources(cpus: 2, memoryInBytes: 1.gib())) { config in
            config.bootLog = bs.bootLog
            config.blockDeviceDriver = .virtioSCSI
            config.volumes = volumes
        }
        let buffer = BufferWriter()
        let errors = BufferWriter()
        try await pod.addContainer("c", rootfs: try cloneRootfs(bs.rootfs, testID: podID, containerID: "c")) { config in
            config.process.arguments = ["/bin/sh", "-c", script]
            config.process.stdout = buffer
            config.process.stderr = errors
            config.mounts.append(contentsOf: mounts)
        }
        do {
            try await pod.create()
            try await pod.startContainer("c")
            let status = try await pod.waitContainer("c")
            try await pod.stop()
            guard status.exitCode == 0 else {
                let stderr = String(data: errors.data, encoding: .utf8) ?? ""
                throw IntegrationError.assert(msg: "container in \(podID) exited with \(status): \(stderr)")
            }
        } catch {
            try? await pod.stop()
            throw error
        }
        return String(data: buffer.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The SCSI disks the guest has, as `container` sees /sys/block.
    private func scsiDisks(in pod: LinuxPod, container: String) async throws -> [String] {
        let buffer = BufferWriter()
        let exec = try await pod.execInContainer(container, processID: "ls-\(UUID().uuidString.prefix(8))") { config in
            config.arguments = ["/bin/ls", "/sys/block"]
            config.stdout = buffer
        }
        try await exec.start()
        let status = try await exec.wait()
        try await exec.delete()
        guard status.exitCode == 0 else {
            throw IntegrationError.assert(msg: "ls /sys/block exited with \(status)")
        }
        let output = String(data: buffer.data, encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("sd") }
    }

    /// The seconds on busybox dd's last status line, which reads
    /// "<bytes> bytes (<size>) copied, <seconds> seconds, <rate>".
    private static func ddSeconds(_ status: String) -> Double? {
        let suffix = " seconds"
        for part in status.components(separatedBy: ", ") where part.hasSuffix(suffix) {
            return Double(part.dropLast(suffix.count))
        }
        return nil
    }

    private func assertSCSIDiskMount(_ output: String, path: String) throws {
        guard output.contains("/dev/sd") else {
            throw IntegrationError.assert(msg: "expected a SCSI disk (/dev/sd*) at \(path), got: \(output)")
        }
    }
}
#endif
