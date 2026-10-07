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

/// The device a machine attaches its containers' block devices on, which
/// decides the name the guest finds each one by.
///
/// A machine has one: every block device its containers bring, a root
/// filesystem, a writable layer, a volume, a disk a container mounts, goes
/// on it. The machine's own disks are virtio block devices whatever the
/// driver: its initial filesystem, and a swap area, which the guest enables
/// by its device path. So is a network block device, which reaches the
/// guest through Virtualization's own attachment alone. Directories go over
/// the machine's virtiofs share.
///
/// This is Kata's block_device_driver, set for a sandbox in its
/// configuration file ("virtio-scsi, virtio-blk or nvdimm"), which its
/// device manager gives every block device it creates. The driver names the
/// device to the guest: a virtio block device by its device path, a SCSI
/// disk by its address. Kata attaches a swap file on virtio-blk whatever
/// the driver, and keeps its guest image on a device of its own.
/// https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/config/configuration-qemu.toml.in#L210-L213
/// https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/pkg/device/manager/manager.go#L55-L67
/// https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/pkg/device/manager/manager.go#L140-L145
/// https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/pkg/device/drivers/block.go#L77-L112
/// https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/virtcontainers/kata_agent.go#L1887-L1917
/// https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/virtcontainers/qemu.go#L2276-L2280
public enum BlockDeviceDriver: String, Sendable, Codable, CaseIterable {
    /// Each block device a virtio block device of its own, which the guest
    /// finds by its device path. Virtualization adds none to a running
    /// machine.
    case virtioBlock = "virtio-blk"
    /// Each block device a logical unit of the machine's one virtio-scsi
    /// host, which the guest finds by its SCSI address. The host takes and
    /// gives back disks while the machine runs.
    case virtioSCSI = "virtio-scsi"

    /// Refuses a driver whose device the machine cannot have, saying why.
    /// `scsiHost` is nil where the machine can have a virtio-scsi host, and
    /// otherwise the reason it cannot.
    func require(scsiHost unavailable: String?) throws {
        guard self == .virtioSCSI, let unavailable else {
            return
        }
        throw ContainerizationError(
            .unsupported,
            message: "the \(rawValue) block device driver needs a virtio-scsi host, and \(unavailable)"
        )
    }
}
