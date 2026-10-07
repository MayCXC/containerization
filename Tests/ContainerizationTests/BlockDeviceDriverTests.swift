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
    /// A machine with a container's root, writable layer, swap area and two
    /// disks of its own, one a network block device, beside a directory
    /// share and a guest mount; a volume and a swap area the machine's
    /// containers share; booted from a block initial filesystem.
    private static func machine(driver: BlockDeviceDriver) -> VZVirtualMachineInstance.Configuration {
        var config = VZVirtualMachineInstance.Configuration()
        config.blockDeviceDriver = driver
        config.initialFilesystem = .block(format: "ext4", source: "/images/init.block", destination: "/", options: ["ro"])
        config.storage = MachineMounts(
            containers: [
                "c": ContainerMounts(
                    rootfs: .block(format: "ext4", source: "/images/root.ext4", destination: "/"),
                    writableLayer: .block(format: "ext4", source: "/images/layer.ext4", destination: "/"),
                    swap: .block(format: "swap", source: "/images/swap.img", destination: ""),
                    mounts: [
                        .block(format: "ext4", source: "/images/data.ext4", destination: "/data", options: ["ro"]),
                        .block(format: "ext4", source: "nbd://localhost:10809/export", destination: "/remote"),
                        .share(source: "/Users/shared", destination: "/shared"),
                        .any(type: "tmpfs", source: "tmpfs", destination: "/tmp"),
                    ]
                )
            ],
            volumes: ["v": .block(format: "ext4", source: "/images/volume.ext4", destination: "/run/volumes/v")],
            swap: .block(format: "swap", source: "/images/pod-swap.img", destination: "")
        )
        return config
    }

    /// Attaches the machine's mounts, recording the disks given to the
    /// virtio-scsi host and the addresses it gave them.
    private static func attach(
        _ config: VZVirtualMachineInstance.Configuration
    ) throws -> (attachments: MachineAttachments, scsi: [String], storageDevices: Int) {
        var scsi: [String] = []
        let (attachments, storageDevices) = try config.mountAttachments(allocator: Character.blockDeviceTagAllocator()) { mount in
            scsi.append(mount.source)
            return AttachedFilesystem(mount: mount, scsiAddress: SCSIAddress(target: 0, lun: UInt16(scsi.count - 1)))
        }
        return (attachments, scsi, storageDevices)
    }

    @Test func virtioBlockNamesEveryDiskByItsDevicePath() throws {
        let (attachments, scsi, storageDevices) = try Self.attach(Self.machine(driver: .virtioBlock))
        #expect(scsi.isEmpty)
        #expect(attachments.ordered.allSatisfy { $0.scsiAddress == nil })
        // The initial filesystem holds vda; the rest take letters in the
        // machine's device order.
        let container = try #require(attachments.containers["c"])
        #expect(container.rootfs.source == "/dev/vdb")
        #expect(container.writableLayer?.source == "/dev/vdc")
        #expect(container.swap?.source == "/dev/vdd")
        #expect(container.mounts.map(\.source).prefix(2) == ["/dev/vde", "/dev/vdf"])
        #expect(container.mounts[3].source == "tmpfs")
        #expect(attachments.volumes["v"]?.source == "/dev/vdg")
        #expect(attachments.swap?.source == "/dev/vdh")
        #expect(storageDevices == 8)
    }

    @Test func virtioSCSICarriesEveryContainerDisk() throws {
        let (attachments, scsi, storageDevices) = try Self.attach(Self.machine(driver: .virtioSCSI))
        // The root, the writable layer, the container's own disk and the
        // volume are logical units, named to the guest by address alone.
        #expect(scsi == ["/images/root.ext4", "/images/layer.ext4", "/images/data.ext4", "/images/volume.ext4"])
        let container = try #require(attachments.containers["c"])
        let carried = [container.rootfs, container.writableLayer, container.mounts[0], attachments.volumes["v"]]
        for (index, attachment) in carried.enumerated() {
            #expect(attachment?.scsiAddress == SCSIAddress(target: 0, lun: UInt16(index)))
            #expect(attachment?.source.isEmpty == true)
        }
        // What was asked of the disk is kept.
        #expect(container.mounts[0].options == ["ro"])
        #expect(container.mounts[0].destination == "/data")
        // The swap areas, which the guest enables by device path, and a
        // network block device stay virtio block devices, after the initial
        // filesystem's vda; the share and the guest mount take no disk.
        #expect(container.swap?.source == "/dev/vdb")
        #expect(container.mounts[1].source == "/dev/vdc")
        #expect(container.mounts[1].scsiAddress == nil)
        #expect(container.mounts[2].type == "virtiofs")
        #expect(container.mounts[3].source == "tmpfs")
        #expect(attachments.swap?.source == "/dev/vdd")
        #expect(storageDevices == 4)
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
