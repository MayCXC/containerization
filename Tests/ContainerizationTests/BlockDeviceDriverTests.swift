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
import ContainerizationExtras
import Foundation
import Testing

@testable import Containerization

/// A machine's block device driver: which of the machine's mounts it
/// carries, the name it gives each to the guest, and the driver a machine
/// that cannot have its device refuses.
struct BlockDeviceDriverTests {
    @Test func theDriversAreKatasValues() {
        #expect(BlockDeviceDriver.virtioBlock.rawValue == "virtio-blk")
        #expect(BlockDeviceDriver.virtioSCSI.rawValue == "virtio-scsi")
        #expect(BlockDeviceDriver(rawValue: "nvdimm") == nil)
    }

    @Test func virtioBlockIsTheDefault() {
        #expect(VMConfiguration().blockDeviceDriver == .virtioBlock)
        #expect(LinuxContainer.Configuration().blockDeviceDriver == .virtioBlock)
        #expect(LinuxPod.Configuration().blockDeviceDriver == .virtioBlock)
    }

    @Test func virtioSCSIIsRefusedWhereTheMachineCanHaveNoHost() {
        #expect(throws: Never.self) {
            try BlockDeviceDriver.virtioBlock.require(scsiHost: "the machine has none")
        }
        #expect(throws: Never.self) {
            try BlockDeviceDriver.virtioSCSI.require(scsiHost: nil)
        }
        let error = #expect(throws: ContainerizationError.self) {
            try BlockDeviceDriver.virtioSCSI.require(scsiHost: "the machine has none")
        }
        #expect(error?.code == .unsupported)
        #expect(error?.message.contains("the machine has none") == true)
    }

    #if os(macOS)
    /// A machine with a container's root, writable layer and two disks of
    /// its own, one a network block device, beside a directory share and a
    /// guest mount, booted from a block initial filesystem.
    private static func machine(driver: BlockDeviceDriver) -> VZVirtualMachineInstance.Configuration {
        var config = VZVirtualMachineInstance.Configuration()
        config.blockDeviceDriver = driver
        config.initialFilesystem = .block(format: "ext4", source: "/images/init.block", destination: "/", options: ["ro"])
        config.mountsByID = [
            "c": [
                .block(format: "ext4", source: "/images/root.ext4", destination: "/"),
                .block(format: "ext4", source: "/images/layer.ext4", destination: "/"),
                .block(format: "ext4", source: "/images/data.ext4", destination: "/data", options: ["ro"]),
                .block(format: "ext4", source: "nbd://localhost:10809/export", destination: "/remote"),
                .share(source: "/Users/shared", destination: "/shared"),
                .any(type: "tmpfs", source: "tmpfs", destination: "/tmp"),
            ]
        ]
        return config
    }

    /// Attaches the machine's mounts, recording the disks given to the
    /// virtio-scsi host and the addresses it gave them.
    private static func attach(
        _ config: VZVirtualMachineInstance.Configuration
    ) throws -> (attachments: [AttachedFilesystem], scsi: [String], storageDevices: Int) {
        var scsi: [String] = []
        let (attachments, storageDevices) = try config.mountAttachments(allocator: Character.blockDeviceTagAllocator()) { mount in
            scsi.append(mount.source)
            return AttachedFilesystem(mount: mount, scsiAddress: SCSIAddress(target: 0, lun: UInt16(scsi.count - 1)))
        }
        return (attachments["c"] ?? [], scsi, storageDevices)
    }

    @Test func virtioBlockNamesEveryDiskByItsDevicePath() throws {
        let (attachments, scsi, storageDevices) = try Self.attach(Self.machine(driver: .virtioBlock))
        #expect(scsi.isEmpty)
        #expect(attachments.allSatisfy { $0.scsiAddress == nil })
        // The initial filesystem holds vda.
        #expect(attachments.map(\.source).prefix(4) == ["/dev/vdb", "/dev/vdc", "/dev/vdd", "/dev/vde"])
        #expect(attachments[5].source == "tmpfs")
        #expect(storageDevices == 5)
    }

    @Test func virtioSCSICarriesEveryContainerDisk() throws {
        let (attachments, scsi, storageDevices) = try Self.attach(Self.machine(driver: .virtioSCSI))
        // The root, the writable layer and the container's own disk are
        // logical units, named to the guest by address alone.
        #expect(scsi == ["/images/root.ext4", "/images/layer.ext4", "/images/data.ext4"])
        for (index, attachment) in attachments.prefix(3).enumerated() {
            #expect(attachment.scsiAddress == SCSIAddress(target: 0, lun: UInt16(index)))
            #expect(attachment.source.isEmpty)
        }
        // What was asked of the disk is kept.
        #expect(attachments[2].options == ["ro"])
        #expect(attachments[2].destination == "/data")
        // A network block device stays a virtio block device, after the
        // initial filesystem's vda; the share and the guest mount take no
        // disk at all.
        #expect(attachments[3].source == "/dev/vdb")
        #expect(attachments[3].scsiAddress == nil)
        #expect(attachments[4].type == "virtiofs")
        #expect(attachments[5].source == "tmpfs")
        #expect(storageDevices == 2)
    }

    @Test func aDiskOnTheHostIsMountedByItsAddressAndBoundIntoTheContainer() {
        let disk = AttachedFilesystem(
            mount: .block(format: "ext4", source: "/images/data.ext4", destination: "/data", options: ["ro"]),
            scsiAddress: SCSIAddress(target: 1, lun: 3)
        )
        #expect(disk.guestDiskPath == "/run/scsi/1-3")
        let bind = disk.diskBind(at: "/run/scsi/1-3")
        #expect(bind.type == "none")
        #expect(bind.source == "/run/scsi/1-3")
        #expect(bind.destination == "/data")
        #expect(bind.options == ["bind", "ro"])

        let device = AttachedFilesystem(type: "ext4", source: "/dev/vdb", destination: "/data", options: [])
        #expect(device.guestDiskPath == nil)
    }
    #endif
}
