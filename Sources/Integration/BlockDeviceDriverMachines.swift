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

/// A machine manager whose machines attach their containers' block devices
/// on `driver`.
///
/// The suite gives every test one when it runs on a block device driver
/// (`--block-device-driver`): a machine its test left on the default takes
/// the suite's driver, and one its test put on virtio-scsi keeps it. A test
/// that measures a driver forces its own machines onto one with
/// `forcing(_:on:)`, whatever the suite runs on.
struct BlockDeviceDriverMachines: VirtualMachineManager {
    let base: any VirtualMachineManager
    let driver: BlockDeviceDriver
    /// Whether a machine its test put on virtio-scsi takes `driver` too.
    let overridesConfigured: Bool

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        var configuration = config.configuration
        if overridesConfigured || configuration.blockDeviceDriver == .virtioBlock {
            configuration.blockDeviceDriver = driver
        }
        return try await base.create(config: StandardVMConfig(configuration: configuration))
    }

    /// `vmm` with every machine it makes on `driver`.
    static func forcing(_ driver: BlockDeviceDriver, on vmm: any VirtualMachineManager) -> any VirtualMachineManager {
        let base = (vmm as? BlockDeviceDriverMachines)?.base ?? vmm
        return BlockDeviceDriverMachines(base: base, driver: driver, overridesConfigured: true)
    }
}
