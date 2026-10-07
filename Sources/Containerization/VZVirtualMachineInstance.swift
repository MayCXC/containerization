//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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
import Foundation
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Logging
import NIOCore
import NIOPosix
import Synchronization
@preconcurrency import Virtualization

public final class VZVirtualMachineInstance: Sendable {
    public typealias Agent = Vminitd

    /// The machine's attached storage.
    ///
    /// Where a hotplug provider is installed it holds the registry, so a disk
    /// taken while the machine runs is registered with the ones it booted
    /// with. The machine's own copy answers only where there is no provider.
    private let _storage: Mutex<MachineAttachments>
    public var storage: MachineAttachments {
        if let hotplugProvider {
            return hotplugProvider.storage
        }
        return _storage.withLock { $0 }
    }

    /// The underlying Virtualization framework virtual machine.
    public var vzVirtualMachine: VZVirtualMachine { vm }

    /// The dispatch queue used for VZ operations.
    public var vmQueue: DispatchQueue { queue }

    /// Mutate the storage registry.
    public func withStorage<T: Sendable>(_ body: (inout sending MachineAttachments) throws -> sending T) rethrows -> T {
        if let hotplugProvider {
            return try hotplugProvider.withStorage(body)
        }
        return try _storage.withLock(body)
    }

    /// Serialize VM operations with the instance lock.
    public func withInstanceLock<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await lock.withLock { _ in try await body() }
    }

    /// The hotplug provider, if hotplug is enabled for this instance.
    public var hotplugProvider: (any HotplugProvider)? {
        get { _hotplugProvider.withLock { $0 } }
        set { _hotplugProvider.withLock { $0 = newValue } }
    }
    private let _hotplugProvider = Mutex<(any HotplugProvider)?>(nil)

    /// Returns the runtime state of the vm.
    public var state: VirtualMachineInstanceState {
        vzStateToInstanceState()
    }

    /// The virtual machine instance configuration.
    private let config: Configuration
    public struct Configuration: Sendable {
        /// Amount of cpus to allocated.
        public var cpus: Int
        /// Amount of memory in bytes allocated.
        public var memoryInBytes: UInt64
        /// Toggle rosetta's x86_64 emulation support.
        public var rosetta: Bool
        /// Toggle nested virtualization support.
        public var nestedVirtualization: Bool
        /// The device the machine attaches its containers' block devices on.
        /// virtio-scsi is the host this process implements, which
        /// Virtualization lets it from macOS 27.
        public var blockDeviceDriver: BlockDeviceDriver
        /// The machine's storage: each container's mounts by role, and the
        /// volumes and swap its containers share.
        public var storage: MachineMounts
        /// Network interface attachments.
        public var interfaces: [any Interface]
        /// Kernel image.
        public var kernel: Kernel?
        /// The root filesystem.
        public var initialFilesystem: Mount?
        /// Destination for the virtual machine's boot logs.
        public var bootLog: BootLog?
        /// Extension objects that participate in the VM instance lifecycle.
        public var extensions: [any Sendable] = []

        public init() {
            self.cpus = 4
            self.memoryInBytes = 1024.mib()
            self.rosetta = false
            self.nestedVirtualization = false
            self.blockDeviceDriver = .virtioBlock
            self.storage = MachineMounts()
            self.interfaces = []
        }
    }

    // `vm` isn't used concurrently.
    private nonisolated(unsafe) let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let lock: AsyncLock
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let timeSyncer: TimeSyncer
    private let logger: Logger?
    /// The disks of the machine's virtio-scsi host (`VZSCSIHotplugProvider`),
    /// where Virtualization lets this process implement the host; nil when
    /// the machine has none.
    private nonisolated(unsafe) let scsi: AnyObject?
    /// The balloon this process implements (`VZVirtioBalloon`), where
    /// Virtualization lets it; nil when the machine has none.
    private nonisolated(unsafe) let balloon: AnyObject?
    /// What the machine was last asked to hold.
    private let targetMemorySize: Mutex<UInt64>

    public convenience init(
        group: EventLoopGroup? = nil,
        logger: Logger? = nil,
        with: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try with(&config)
        try self.init(group: group, config: config, logger: logger)
    }

    init(group: EventLoopGroup?, config: Configuration, logger: Logger?) throws {
        if let group {
            self.ownsGroup = false
            self.group = group
        } else {
            self.ownsGroup = true
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }

        self.config = config
        self.lock = .init()
        self.queue = DispatchQueue(label: "com.apple.containerization.vzvm.\(UUID().uuidString)")
        self.logger = logger
        self.timeSyncer = .init(logger: logger)

        let scsi = try Self.makeSCSI(driver: config.blockDeviceDriver, cpus: config.cpus, logger: logger)
        self.scsi = scsi

        let allocator = Character.blockDeviceTagAllocator()
        let (mountAttachments, _) = try config.mountAttachments(allocator: allocator) { mount in
            guard #available(macOS 27, *), let host = scsi as? VZSCSIHotplugProvider else {
                throw ContainerizationError(.unsupported, message: "this machine has no virtio-scsi host for \(mount.source)")
            }
            return try host.bootDisk(mount)
        }
        self._storage = Mutex(mountAttachments)

        let balloon = Self.makeBalloon(config: config, logger: logger)
        self.balloon = balloon
        self.targetMemorySize = Mutex(config.memoryInBytes)
        self.vm = VZVirtualMachine(
            configuration: try config.toVZ(allocator: allocator, attachments: mountAttachments, scsi: scsi, balloon: balloon),
            queue: self.queue
        )

        // A disk or a directory can be given to the machine while it runs: a
        // disk as a logical unit of its virtio-scsi host, a directory as an
        // export of its share.
        if #available(macOS 15.0, *) {
            self.hotplugProvider = VZHotplugProvider(
                vm: self.vm,
                queue: self.queue,
                initialStorage: mountAttachments,
                scsi: scsi,
                logger: logger
            )
        }

        for ext in config.extensions.compactMap({ $0 as? any VZInstanceExtension }) {
            try ext.didCreate(self)
        }
    }

    /// The machine's virtio-scsi host when its block device driver is
    /// virtio-scsi, with a request queue for each of its `cpus` vCPUs.
    /// Virtualization's custom virtio devices, which let this process
    /// implement the host, arrive in macOS 27, so the driver is refused
    /// before it.
    private static func makeSCSI(driver: BlockDeviceDriver, cpus: Int, logger: Logger?) throws -> AnyObject? {
        guard #available(macOS 27, *) else {
            try driver.require(scsiHost: "Virtualization lets this process implement one from macOS 27")
            return nil
        }
        guard driver == .virtioSCSI else {
            return nil
        }
        return VZSCSIHotplugProvider(device: VZVirtioSCSI(cpus: cpus, logger: logger))
    }
}

/// Protocol for extensions that participate in VZVirtualMachineInstance lifecycle.
/// Append conforming types to `Configuration.extensions` to hook into VM setup and teardown.
public protocol VZInstanceExtension: Sendable {
    /// Modify the VZ configuration before the VM is created.
    func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        storage: MachineMounts
    ) throws

    /// Called after the VZVirtualMachine is created but before start.
    func didCreate(_ instance: VZVirtualMachineInstance) throws

    /// Called during stop before the VM is shut down.
    func willStop(_ instance: VZVirtualMachineInstance) async throws
}

extension VZInstanceExtension {
    public func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        storage: MachineMounts
    ) throws {}

    public func didCreate(_ instance: VZVirtualMachineInstance) throws {}

    public func willStop(_ instance: VZVirtualMachineInstance) async throws {}
}

extension VZVirtualMachineInstance: VirtualMachineInstance {
    public func start() async throws {
        try await lock.withLock { _ in
            guard self.state == .stopped else {
                throw ContainerizationError(
                    .invalidState,
                    message: "virtual machine is not stopped \(self.state)"
                )
            }

            // Do any necessary setup needed prior to starting the guest.
            try await self.prestart()

            // The boot disks of the virtio-scsi host are attached before the
            // guest's driver scans it.
            if #available(macOS 27, *), let host = self.scsi as? VZSCSIHotplugProvider {
                try host.attachBootDisks()
            }

            do {
                try await self.vm.start(queue: self.queue)
            } catch {
                if #available(macOS 27, *), let host = self.scsi as? VZSCSIHotplugProvider {
                    host.detachAll()
                }
                throw error
            }

            let agent = try await Vminitd(
                connection: try await self.vm.waitForAgent(queue: self.queue),
                group: self.group
            )

            do {
                if self.config.rosetta {
                    try await agent.enableRosetta()
                }
            } catch {
                try await agent.close()
                throw error
            }

            // Don't close our remote context as we are providing
            // it to our time sync routine.
            await self.timeSyncer.start(context: agent)
        }
    }

    public func stop() async throws {
        try await lock.withLock { connections in
            // NOTE: We should record HOW the vm stopped eventually. If the vm exited
            // unexpectedly virtualization framework offers you a way to store
            // an error on how it exited. We should report that here instead of the
            // generic vm is not running.
            guard self.state == .running else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }

            try await self.timeSyncer.close()

            if self.ownsGroup {
                try await self.group.shutdownGracefully()
            }

            for ext in self.config.extensions.compactMap({ $0 as? any VZInstanceExtension }) {
                try? await ext.willStop(self)
            }

            try await self.vm.stop(queue: self.queue)

            // The stopped machine lets go of the disks of its virtio-scsi
            // host: each image closes and its lock is released.
            if #available(macOS 27, *), let host = self.scsi as? VZSCSIHotplugProvider {
                host.detachAll()
            }
            self.hotplugProvider?.cleanup()
        }
    }

    // NOTE: Investigate what is the "right" way to handle already vended vsock
    // connections for pause and resume.

    public func pause() async throws {
        try await lock.withLock { _ in
            await self.timeSyncer.pause()
            try await self.vm.pause(queue: self.queue)
        }
    }

    public func resume() async throws {
        try await lock.withLock { _ in
            try await self.vm.resume(queue: self.queue)
            await self.timeSyncer.resume()
        }
    }

    public var hasMemoryBalloon: Bool {
        self.balloon != nil
    }

    public func setTargetMemorySize(_ bytes: UInt64) async throws {
        guard bytes <= self.config.memoryInBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "cannot hold \(bytes) bytes, the machine was created with \(self.config.memoryInBytes)"
            )
        }
        guard #available(macOS 27, *) else {
            throw ContainerizationError(.unsupported, message: "memory balloon not supported")
        }
        let balloon = try self.virtioBalloon()
        // Virtualization asks a guest to compact its memory before the balloon
        // takes pages, so that what the guest gives up fills whole host pages:
        // https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice
        // That only makes the pages taken worth more, so the balloon takes
        // them whether or not the guest could compact.
        if bytes < self.targetMemorySize.withLock({ $0 }) {
            do {
                let outcome = try await self.compactGuestMemory()
                self.logger?.debug("guest memory compaction before a shrink", metadata: ["outcome": "\(outcome)"])
            } catch {
                self.logger?.warning("guest memory compaction before a shrink failed", metadata: ["error": "\(error)"])
            }
        }
        try await lock.withLock { _ in
            try await balloon.setTargetMemorySize(bytes)
        }
        self.targetMemorySize.withLock { $0 = bytes }
    }

    @available(macOS 27, *)
    private func virtioBalloon() throws -> VZVirtioBalloon {
        guard let balloon = self.balloon as? VZVirtioBalloon else {
            throw ContainerizationError(.unsupported, message: "memory balloon not supported")
        }
        return balloon
    }

    /// The balloon to attach, a device this process implements. Virtualization
    /// lets a process implement a Virtio device from macOS 27; its own balloon
    /// gives back only the pages macOS has already compressed (see
    /// `VZVirtioBalloon`), so none is attached before then.
    private static func makeBalloon(config: Configuration, logger: Logger?) -> AnyObject? {
        guard #available(macOS 27, *) else {
            return nil
        }
        let mib: UInt64 = 1 << 20
        return VZVirtioBalloon(memorySize: (config.memoryInBytes + mib - 1) & ~(mib - 1), logger: logger)
    }

    public func dialAgent() async throws -> Vminitd {
        try await lock.withLock { _ in
            do {
                let conn = try await self.vm.connect(
                    queue: self.queue,
                    port: Vminitd.port
                )
                let handle = try conn.dupHandle()
                return try await Vminitd(connection: handle, group: self.group)
            } catch {
                if let err = error as? ContainerizationError {
                    throw err
                }
                throw ContainerizationError(
                    .internalError,
                    message: "failed to dial agent",
                    cause: error
                )
            }
        }
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        try await lock.withLock { _ in
            do {
                let conn = try await self.vm.connect(
                    queue: self.queue,
                    port: port
                )
                return try conn.dupHandle()
            } catch {
                if let err = error as? ContainerizationError {
                    throw err
                }
                throw ContainerizationError(
                    .internalError,
                    message: "failed to dial vsock port",
                    cause: error
                )
            }
        }
    }

    public func listen(_ port: UInt32) throws -> VsockListener {
        let stream = VsockListener(port: port, stopListen: self.stopListen)
        let listener = VZVirtioSocketListener()
        listener.delegate = stream

        try self.vm.listen(
            queue: queue,
            port: port,
            listener: listener
        )
        return stream
    }

    private func stopListen(_ port: UInt32) throws {
        try self.vm.removeListener(
            queue: queue,
            port: port
        )
    }

    // MARK: - Hotplug

    public func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        guard let hotplugProvider else {
            throw ContainerizationError(.unsupported, message: "hotplug not supported")
        }
        return try await hotplugProvider.hotplug(block, id: id)
    }

    public func registerMounts(id: String, rootfs: AttachedFilesystem, writableLayer: AttachedFilesystem?, additionalMounts: [AttachedFilesystem]) throws {
        guard let hotplugProvider else { return }
        try hotplugProvider.registerMounts(id: id, rootfs: rootfs, writableLayer: writableLayer, additionalMounts: additionalMounts)
    }

    public func releaseHotplug(id: String) async throws {
        guard let hotplugProvider else { return }
        try await hotplugProvider.releaseHotplug(id: id)
    }

    public func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        guard let hotplugProvider else { return }
        try await hotplugProvider.hotplugVirtioFS(mounts, id: id)
    }

    public func releaseVirtioFS(id: String) async throws {
        guard let hotplugProvider else { return }
        try await hotplugProvider.releaseVirtioFS(id: id)
    }
}

extension VZVirtualMachineInstance {
    func vzStateToInstanceState() -> VirtualMachineInstanceState {
        self.queue.sync {
            let state: VirtualMachineInstanceState
            switch self.vm.state {
            case .starting:
                state = .starting
            case .running:
                state = .running
            case .stopping:
                state = .stopping
            case .stopped:
                state = .stopped
            default:
                state = .unknown
            }
            return state
        }
    }

    func prestart() async throws {
        if self.config.rosetta {
            #if arch(arm64)
            if VZLinuxRosettaDirectoryShare.availability == .notInstalled {
                self.logger?.info("installing rosetta")
                try await VZVirtualMachineInstance.Configuration.installRosetta()
            }
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        }
    }
}

extension VZVirtualMachineInstance.Configuration {
    public static func installRosetta() async throws {
        do {
            #if arch(arm64)
            try await VZLinuxRosettaDirectoryShare.installRosetta()
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to install rosetta",
                cause: error
            )
        }
    }

    private func serialPort(destination: BootLog) throws -> [VZVirtioConsoleDeviceSerialPortConfiguration] {
        let c = VZVirtioConsoleDeviceSerialPortConfiguration()
        switch destination.base {
        case .file(let path, let append):
            c.attachment = try VZFileSerialPortAttachment(url: path, append: append)
        case .fileHandle(let fileHandle):
            c.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: fileHandle
            )
        }
        return [c]
    }

    /// The Virtualization configuration of the machine whose storage is
    /// attached as `attachments` describes.
    func toVZ(
        allocator: any AddressAllocator<Character>,
        attachments: MachineAttachments,
        scsi: AnyObject?,
        balloon: AnyObject? = nil
    ) throws -> VZVirtualMachineConfiguration {
        var config = VZVirtualMachineConfiguration()

        config.cpuCount = self.cpus
        let mib: UInt64 = 1 << 20
        config.memorySize = (self.memoryInBytes + mib - 1) & ~(mib - 1)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        // A balloon lets the host take back memory the guest has stopped using.
        // Nothing else can: the guest has no way to report a page it has freed,
        // so without one those pages stay with the machine until the host runs
        // short and compresses them as it would any cold memory, keeping pages
        // the guest would have given up for nothing.
        var hasBalloon = false
        if #available(macOS 27, *), let balloon = balloon as? VZVirtioBalloon {
            config.customVirtioDevices = [balloon.configuration]
            hasBalloon = true
        }

        if let bootLog = self.bootLog {
            config.serialPorts = try serialPort(destination: bootLog)
        } else {
            // We always supply a serial console. If no explicit path was provided just send em to the void.
            config.serialPorts = try serialPort(destination: .file(path: URL(filePath: "/dev/null")))
        }

        config.networkDevices = try self.interfaces.map {
            guard let vzi = $0 as? VZInterface else {
                throw ContainerizationError(.invalidArgument, message: "interface type not supported by VZ")
            }
            return try vzi.device()
        }

        if self.rosetta {
            #if arch(arm64)
            switch VZLinuxRosettaDirectoryShare.availability {
            case .notSupported:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "rosetta was requested but is not supported on this machine"
                )
            case .notInstalled:
                // NOTE: If rosetta isn't installed, we'll error with a nice error message
                // during .start() of the virtual machine instance.
                fallthrough
            case .installed:
                let share = try VZLinuxRosettaDirectoryShare()
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                device.share = share
                config.directorySharingDevices.append(device)
            @unknown default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unknown rosetta availability encountered: \(VZLinuxRosettaDirectoryShare.availability)"
                )
            }
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        }

        guard var kernel = self.kernel else {
            throw ContainerizationError(.invalidArgument, message: "kernel cannot be nil")
        }

        guard let initialFilesystem = self.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "rootfs cannot be nil")
        }

        // The guest's SCSI layer scans no host at boot: the agent asks for
        // each disk by its address, which scans for that one logical unit.
        // Kata's runtime boots with the scan off whenever its block device
        // driver is virtio-scsi:
        // https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/pkg/katautils/config.go#L1583-L1592
        // A scan mode already on the command line is left as it is.
        if self.blockDeviceDriver == .virtioSCSI, !kernel.commandLine.kernelArgs.contains(where: { $0.hasPrefix("scsi_mod.scan=") }) {
            kernel.commandLine.kernelArgs.append("scsi_mod.scan=none")
        }

        // The guest compacts its memory before the balloon takes pages, and
        // stops when its workloads stall, which it learns from pressure stall
        // information. Kata's kernels build that in but leave it off unless
        // booted with psi=1, which Kata's runtime adds for its memory agent:
        // https://github.com/kata-containers/kata-containers/blob/846c6f80343788a057eedc15fae7f3c91ae2d13a/src/libs/kata-types/src/config/mod.rs#L254-L256
        // A psi= already on the command line is left as it is.
        if hasBalloon, !kernel.commandLine.kernelArgs.contains(where: { $0.hasPrefix("psi=") }) {
            kernel.commandLine.kernelArgs.append("psi=1")
        }

        let loader = VZLinuxBootLoader(kernelURL: kernel.path)
        loader.commandLine = kernel.linuxCommandline(initialFilesystem: initialFilesystem)
        config.bootLoader = loader

        try initialFilesystem.configure(config: &config)

        // Track used virtiofs tags to avoid creating duplicate VZ devices.
        // The same source directory mounted to multiple destinations shares one device.
        // The walk is the machine's device order, matching the addresses
        // `mountAttachments` hands out walking the same way.
        var usedVirtioFSTags: Set<String> = []
        // A disk the virtio-scsi host carries is a logical unit of it, not a
        // storage device of its own: its attachment has an address.
        for (mount, attachment) in zip(self.storage.ordered, attachments.ordered) where attachment.scsiAddress == nil {
            if case .virtiofs = mount.runtimeOptions {
                let tag = try hashFilePath(path: mount.source)
                if usedVirtioFSTags.contains(tag) {
                    continue
                }
                usedVirtioFSTags.insert(tag)
            }
            try mount.configure(config: &config)
        }

        // Create the unified virtiofs device with VZMultipleDirectoryShare
        // This device hosts all virtiofs shares and supports runtime updates
        var directories: [String: VZSharedDirectory] = [:]
        for mount in self.storage.ordered {
            guard case .virtiofs(_) = mount.runtimeOptions else { continue }
            guard FileManager.default.fileExists(atPath: mount.source) else {
                throw ContainerizationError(.notFound, message: "directory \(mount.source) does not exist")
            }
            let name = try hashFilePath(path: mount.source)
            directories[name] = VZSharedDirectory(
                url: URL(fileURLWithPath: mount.source),
                readOnly: mount.options.contains("ro")
            )
        }
        let multiShare = VZMultipleDirectoryShare(directories: directories)
        let virtiofsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "virtiofs")
        virtiofsDevice.share = multiShare
        config.directorySharingDevices.append(virtiofsDevice)

        if #available(macOS 27, *), let host = scsi as? VZSCSIHotplugProvider {
            config.customVirtioDevices.append(host.device.configuration)
        }

        let storageDeviceCount = config.storageDevices.count

        let platform = VZGenericPlatformConfiguration()
        // We shouldn't silently succeed if the user asked for virt and their hardware does
        // not support it.
        if !VZGenericPlatformConfiguration.isNestedVirtualizationSupported && self.nestedVirtualization {
            throw ContainerizationError(
                .unsupported,
                message: "nested virtualization is not supported on the platform"
            )
        }
        platform.isNestedVirtualizationEnabled = self.nestedVirtualization
        config.platform = platform

        for ext in self.extensions.compactMap({ $0 as? any VZInstanceExtension }) {
            try ext.configureVZ(&config, allocator: allocator, storageDeviceCount: storageDeviceCount, storage: self.storage)
        }

        try config.validate()
        return config
    }

    /// Whether the machine's virtio-scsi host carries `mount`: a block device
    /// its containers bring, when the machine's block device driver is
    /// virtio-scsi, unless it is a network block device, which reaches the
    /// guest through Virtualization's own attachment alone.
    func carriesOnSCSIHost(_ mount: Mount) -> Bool {
        self.blockDeviceDriver == .virtioSCSI && mount.isBlock && !mount.isNetworkBlockDevice
    }

    /// The machine's attachments for its mounts: a virtio block device takes
    /// a device letter from `allocator`, and a disk on the virtio-scsi host
    /// takes its address from `scsiDisk`, each the name its driver gives it
    /// to the guest.
    func mountAttachments(
        allocator: any AddressAllocator<Character>,
        scsiDisk: (Mount) throws -> AttachedFilesystem
    ) throws -> (
        attachments: MachineAttachments, storageDeviceCount: Int
    ) {
        var storageDeviceCount = 0

        if let initialFilesystem {
            // When the initial filesystem is a blk, allocate the first letter "vd(a)"
            // as that is what this blk will be attached under.
            if initialFilesystem.isBlock {
                _ = try allocator.allocate()
                storageDeviceCount += 1
            }
        }

        // The machine's device order: addresses are handed out in the same
        // walk `toVZ` creates the devices in. A disk on the virtio-scsi host
        // takes its address on that host and no device letter.
        func attach(_ mount: Mount) throws -> AttachedFilesystem {
            if self.carriesOnSCSIHost(mount) {
                return try scsiDisk(mount)
            }
            return try attachOwn(mount)
        }
        // A swap area stays a virtio block device whatever the driver: the
        // guest enables it by its device path, as Kata attaches its swap
        // files on virtio-blk:
        // https://github.com/kata-containers/kata-containers/blob/ea7aba03b1d48813cae07413c95ab6bc464b7a5f/src/runtime/virtcontainers/qemu.go#L2276-L2280
        func attachOwn(_ mount: Mount) throws -> AttachedFilesystem {
            let attached = try AttachedFilesystem(mount: mount, allocator: allocator)
            if mount.isBlock {
                storageDeviceCount += 1
            }
            return attached
        }

        var containers: [String: ContainerAttachments] = [:]
        for id in self.storage.containers.keys.sorted() {
            guard let container = self.storage.containers[id] else { continue }
            containers[id] = ContainerAttachments(
                rootfs: try attach(container.rootfs),
                writableLayer: try container.writableLayer.map(attach),
                swap: try container.swap.map(attachOwn),
                mounts: try container.mounts.map(attach)
            )
        }
        var volumes: [String: AttachedFilesystem] = [:]
        for name in self.storage.volumes.keys.sorted() {
            guard let mount = self.storage.volumes[name] else { continue }
            volumes[name] = try attach(mount)
        }
        let swap = try self.storage.swap.map(attachOwn)

        return (MachineAttachments(containers: containers, volumes: volumes, swap: swap), storageDeviceCount)
    }
}

public protocol VZInterface {
    func device() throws -> VZVirtioNetworkDeviceConfiguration
}

extension NATInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }
        config.attachment = VZNATNetworkDeviceAttachment()
        return config
    }
}

#endif
