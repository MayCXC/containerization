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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import Synchronization

import struct ContainerizationOS.Swap
import struct ContainerizationOS.Terminal

/// NOTE: Experimental API
///
/// `LinuxPod` allows managing multiple Linux containers within a single
/// virtual machine. Each container has its own rootfs and process, but
/// shares the VM's resources (CPU, memory, network).
public final class LinuxPod: Sendable {
    static let maxIDLength = 64

    /// The identifier of the pod.
    public let id: String

    /// Configuration for the pod.
    public let config: Configuration

    /// The size of the pod's virtual machine.
    public let vm: VMResources

    /// The configuration for the LinuxPod.
    public struct Configuration: Sendable {
        /// Optional swap area shared by every container in the pod, as a block
        /// device mount.
        ///
        /// The area belongs to the pod rather than to any one container, so the
        /// guest kernel decides which container's pages are reclaimed to it.
        /// Containers are free to use all of it unless they carry a limit of
        /// their own. The `destination` field is ignored, as the area is
        /// enabled rather than mounted.
        public var swapLayer: Mount? = nil
        /// The network interfaces for the pod.
        public var interfaces: [any Interface] = []
        /// Whether nested virtualization should be turned on for the pod.
        public var virtualization: Bool = false
        /// The device the pod's machine attaches its containers' block
        /// devices on.
        public var blockDeviceDriver: BlockDeviceDriver = .virtioBlock
        /// Optional file path to store serial boot logs.
        public var bootLog: BootLog?
        /// Whether containers in the pod should share a PID namespace.
        /// When enabled, all containers can see each other's processes.
        ///
        /// The pause process that owns the namespace runs unfiltered — it is
        /// launched by `vmexec`, which ignores `spec.linux.seccomp` — so a
        /// ``seccompProfile`` does not cover everything visible in the
        /// namespace. It runs as uid 0 with an empty capability set, in its own
        /// mount namespace.
        public var shareProcessNamespace: Bool = false
        /// The default hostname for all containers in the pod.
        /// Individual containers can override this by setting their own `hostname` configuration.
        public var hostname: String?
        /// The default DNS configuration for all containers in the pod.
        /// Individual containers can override this by setting their own `dns` configuration.
        public var dns: DNS?
        /// The default hosts file configuration for all containers in the pod.
        /// Individual containers can override this by setting their own `hosts` configuration.
        public var hosts: Hosts?
        /// Volumes attached to the pod. Can be shared with multiple containers.
        public var volumes: [PodVolume] = []
        /// EXPERIMENTAL: Path in the root filesystem for the virtual machine
        /// where the OCI runtime used to spawn the pod's containers lives.
        /// Applies to every container in the pod.
        public var ociRuntimePath: String?
        /// The default seccomp filter for the pod's containers. Defaults to
        /// ``LinuxContainer/Configuration/SeccompProfile/unconfined``; requires
        /// ``ociRuntimePath``. Individual containers can override this by
        /// setting their own `seccompProfile` configuration. Does not cover the
        /// pause process — see ``shareProcessNamespace``.
        public var seccompProfile: LinuxContainer.Configuration.SeccompProfile = .unconfined
        /// Extension objects that participate in the VM instance lifecycle.
        public var extensions: [any Sendable] = []

        public init() {}
    }

    /// Configuration for a container within the pod.
    public struct ContainerConfiguration: Sendable {
        /// Configuration for the init process of the container.
        public var process = LinuxProcessConfiguration()
        /// The container's CPU cgroup limit, in whole cores. May exceed the pod's VM for oversubscription.
        public var cpus: Int = 4
        /// The container's memory cgroup limit in bytes. May exceed the pod's VM for oversubscription.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// Hand this container's cgroup to the user it runs as, so that what
        /// runs inside can place its own work under limits of its own. The
        /// user is given the cgroup it is placed in and nothing above it, so
        /// the limits the pod and this container were given still bind.
        public var cgroupDelegation: Bool = false
        /// Optional cap on how much of the pod's swap area this container may
        /// use, in bytes. Leaving it unset lets the container use the whole
        /// area, which is what containers sharing a pool usually want.
        ///
        /// This counts swap alone. The runtime spec carries memory and swap
        /// combined, so `memoryInBytes` is added to it when the spec is built.
        ///
        /// Kata and docker spell the same limit as the combined figure the spec
        /// carries, subtracting the memory limit to size the area, so a
        /// container asking there for 2 GiB against a 1 GiB memory limit is
        /// asking for 1 GiB of swap and here for 2 GiB. That figure suits a
        /// container whose swap is sized for it alone; this one is a share of
        /// an area the pod owns, and how much of that share a container may
        /// take is what the number says.
        /// https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-setup-swap-devices-in-guest-kernel.md
        public var swapInBytes: UInt64?
        /// The hostname for the container.
        public var hostname: String?
        /// The system control options for the container.
        public var sysctl: [String: String] = [:]
        /// The mounts for the container.
        public var mounts: [Mount] = LinuxContainer.defaultMounts()
        /// Prepare this container for a service manager to run as its init,
        /// which needs somewhere writable to keep runtime state.
        public var systemd: SystemdMode = .disabled
        /// Paths inside the container that vmexec hides from the workload.
        /// Defaults to the OCI standard set (``LinuxContainer/defaultMaskedPaths()``),
        /// matching the restricted capability baseline. Set to `[]` to opt out,
        /// or append to extend it.
        public var maskedPaths: [String] = LinuxContainer.defaultMaskedPaths()
        /// Paths inside the container that vmexec marks read-only.
        /// Defaults to the OCI standard set (``LinuxContainer/defaultReadonlyPaths()``),
        /// matching the restricted capability baseline. Set to `[]` to opt out,
        /// or append to extend it.
        public var readonlyPaths: [String] = LinuxContainer.defaultReadonlyPaths()
        /// The Unix domain socket relays to setup for the container.
        public var sockets: [UnixSocketConfiguration] = []
        /// The DNS configuration for the container.
        public var dns: DNS?
        /// The hosts file configuration for the container.
        public var hosts: Hosts?
        /// The seccomp filter for the container's processes. Overrides the
        /// pod-level ``Configuration/seccompProfile`` when set. Anything other
        /// than ``LinuxContainer/Configuration/SeccompProfile/unconfined``
        /// requires the pod's ``Configuration/ociRuntimePath``.
        public var seccompProfile: LinuxContainer.Configuration.SeccompProfile?
        /// Run the container with a minimal init process that handles signal
        /// forwarding and zombie reaping.
        public var useInit: Bool = false
        /// Devices the container should be given, with the permissions it
        /// should see them under.
        ///
        /// A device already present in the container's /dev arrives with the
        /// kernel's permissions, which are stricter than the ones a machine
        /// running udev would show. Naming it here is how those are asked for.
        public var devices: [ContainerizationOCI.LinuxDevice] = []
        /// Hooks the runtime specification carries for the container. An OCI
        /// runtime is what runs them, so they take effect when the pod is
        /// given an ``Configuration/ociRuntimePath``.
        public var hooks: ContainerizationOCI.Hooks? = nil

        public init() {}
    }

    /// A volume that is attached at the pod level and can be shared by multiple containers.
    public struct PodVolume: Sendable {
        /// Describes the backing storage for the volume.
        public enum Source: Sendable {
            /// A network block device (NBD) volume.
            case nbd(url: URL, timeout: TimeInterval? = nil, readOnly: Bool = false)
            /// A disk-image file on the host, attached on the pod's block
            /// device driver.
            case diskImage(path: URL, readOnly: Bool = false)
            /// An in-memory (tmpfs) volume mounted inside the guest.
            case tmpfs(sizeBytes: UInt64? = nil)
        }

        /// The logical name of this volume. Containers reference this name
        /// via `Mount.sharedMount(name:destination:)` in their mounts.
        public var name: String
        /// The backing storage source for this volume.
        public var source: Source
        /// The filesystem format on the volume.
        public var format: String

        public init(name: String, source: Source, format: String) {
            self.name = name
            self.source = source
            self.format = format
        }

        func toMount() -> Mount {
            switch source {
            case .nbd(let url, let timeout, let readOnly):
                var runtimeOptions: [String] = []
                if let timeout {
                    runtimeOptions.append("vzTimeout=\(timeout)")
                }
                return Mount.block(
                    format: self.format,
                    source: url.absoluteString,
                    destination: LinuxPod.guestVolumePath(name),
                    options: readOnly ? ["ro"] : [],
                    runtimeOptions: runtimeOptions
                )
            case .diskImage(let path, let readOnly):
                return Mount.block(
                    format: self.format,
                    source: path.absolutePath(),
                    destination: LinuxPod.guestVolumePath(name),
                    options: readOnly ? ["ro"] : []
                )
            case .tmpfs(let sizeBytes):
                return Mount.any(
                    type: "tmpfs",
                    source: "tmpfs",
                    destination: LinuxPod.guestVolumePath(name),
                    options: sizeBytes.map { ["size=\($0)"] } ?? []
                )
            }
        }
    }

    private struct PodContainer: Sendable {
        let id: String
        let rootfs: Mount
        let writableLayer: Mount?
        var config: ContainerConfiguration
        /// The container's own profile, or the pod's when it set none.
        let seccomp: ResolvedSeccomp
        var state: ContainerState
        var process: LinuxProcess?
        var fileMountContext: FileMountContext
        /// Why the container is errored, when the machine's boot could not
        /// set it up: its start answers with this.
        var failure: (any Error)?
        /// Whether the guest has the container's root filesystem mounted, so
        /// that its removal unmounts it before the devices under it are given
        /// back, as a block volume's attachment records the volume's mount.
        var rootfsMounted = false

        enum ContainerState: Sendable {
            case registered
            case created
            case started
            case stopped
            case errored
        }
    }

    /// A block volume the pod's containers mount, which the machine attaches
    /// once and the guest mounts once, at the path every container that
    /// mounts the same image is given a bind of. Kata mounts each block
    /// device at one location within the machine and counts the containers
    /// that mount it, and the CSI node contract stages a volume once per node
    /// and publishes it to each workload, the orchestrator counting them. A
    /// pod's volumes have the pod's lifetime: they outlive a container's
    /// restart and its removal, and the kubelet tears them down with the pod.
    /// So the volume is the pod's: its containers share one filesystem, and
    /// the machine holds it, attached and mounted, until the machine stops.
    /// https://github.com/kata-containers/kata-containers/blob/main/src/runtime/virtcontainers/kata_agent.go
    /// https://github.com/container-storage-interface/spec/blob/master/spec.md
    /// https://kubernetes.io/docs/concepts/storage/volumes/
    private struct BlockVolume: Sendable {
        /// The volume as the machine attaches it, at its guest path: the
        /// first container's mount of the image, writable where a container
        /// placed before the machine boots writes to it.
        var mount: Mount
        /// The containers that mount it.
        var users: Set<String>
        /// Where the guest finds the volume, once the machine has attached it
        /// and the guest has mounted it at its path.
        var attachment: AttachedFilesystem?
    }

    private let state: AsyncMutex<State>

    // Ports to be allocated from for stdio and for
    // unix socket relays that are sharing a guest
    // uds to the host. Released ports are reused — see
    // `VsockPortAllocator` for why that matters.
    private let hostVsockPorts: VsockPortAllocator
    // Ports we request the guest to allocate for unix socket relays from
    // the host.
    private let guestVsockPorts: Atomic<UInt32>

    // Where the blocking reads and writes of a file transfer run.
    private let copyQueue = DispatchQueue(label: "com.apple.containerization.copy")

    private struct State: Sendable {
        var phase: Phase
        var containers: [String: PodContainer]
        var pauseProcess: LinuxProcess?
        // Whether the unified virtiofs share is mounted at `/run/virtiofs` in the guest
        var unifiedVirtiofsMounted: Bool = false
        /// The block volumes the containers mount, by the name the pod gives
        /// each: the tag of its image.
        var blockVolumes: [String: BlockVolume] = [:]
    }

    private enum Phase: Sendable {
        /// The pod has been created but no live resources are running.
        case initialized
        /// The pod's virtual machine has been setup and the runtime environment has been configured.
        case created(CreatedState)
        /// An error occurred during the lifetime of this class.
        case errored(Swift.Error)

        struct CreatedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
        }

        func createdState(_ operation: String) throws -> CreatedState {
            switch self {
            case .created(let state):
                return state
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): pod must be created"
                )
            }
        }

        mutating func validateForCreate() throws {
            switch self {
            case .initialized:
                break
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "pod must be in initialized state to create"
                )
            }
        }

        mutating func setErrored(error: Swift.Error) {
            self = .errored(error)
        }
    }

    private let vmm: VirtualMachineManager
    private let logger: Logger?

    /// A pod or container seccomp setting, resolved as far as it can be without
    /// a container's process configuration. `.default` needs the init process's
    /// capabilities, which differ per container, so it carries the verified
    /// architecture and the profile itself is built in ``generateRuntimeSpec``.
    private enum ResolvedSeccomp: Sendable {
        case unconfined
        case defaultProfile(arch: Arch)
        case profile(LinuxSeccomp)
    }

    /// The pod-level filter, applied to containers that set none of their own.
    private let seccomp: ResolvedSeccomp

    /// Create a new `LinuxPod`. A `VirtualMachineManager` instance must be
    /// provided that will handle launching the virtual machine the containers
    /// will execute inside of. `vm` sizes that virtual machine.
    public init(
        _ id: String,
        vmm: VirtualMachineManager,
        vm: VMResources = .default,
        logger: Logger? = nil,
        configuration: (inout Configuration) throws -> Void
    ) throws {
        guard id.count <= Self.maxIDLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "pod id length \(id.count) exceeds maximum of \(Self.maxIDLength) characters"
            )
        }
        self.id = id
        self.vmm = vmm
        self.vm = vm
        self.hostVsockPorts = VsockPortAllocator(base: 0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.logger = logger

        var config = Configuration()
        try configuration(&config)

        self.seccomp = try Self.resolveSeccomp(config.seccompProfile, ociRuntimePath: config.ociRuntimePath)

        self.config = config
        self.state = AsyncMutex(State(phase: .initialized, containers: [:], pauseProcess: nil))
    }

    /// Resolve a seccomp setting against the pod's runtime, rejecting a profile
    /// that no runtime will install. `vmexec` does not read
    /// `spec.linux.seccomp`, so such a container would run unfiltered while
    /// every observable said it was sandboxed.
    private static func resolveSeccomp(
        _ profile: LinuxContainer.Configuration.SeccompProfile,
        ociRuntimePath: String?
    ) throws -> ResolvedSeccomp {
        switch profile {
        case .unconfined:
            return .unconfined
        case .default:
            try Self.requireOCIRuntime(ociRuntimePath)
            // Verified here so an unsupported architecture fails before the
            // caller has booted a VM.
            return .defaultProfile(arch: try Arch.currentVerified())
        case .profile(let profile):
            try Self.requireOCIRuntime(ociRuntimePath)
            return .profile(profile)
        }
    }

    private static func requireOCIRuntime(_ ociRuntimePath: String?) throws {
        guard ociRuntimePath != nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "seccompProfile requires ociRuntimePath: seccomp is applied by the OCI runtime, and the default vmexec launch path ignores it"
            )
        }
    }

    private static func createDefaultRuntimeSpec(_ containerID: String, podID: String) -> Spec {
        .init(
            process: .init(),
            hostname: containerID,
            root: .init(
                path: Self.guestRootfsPath(containerID),
                readonly: false
            ),
            linux: .init(
                resources: .init(),
                cgroupsPath: "/container/pod/\(podID)/\(containerID)"
            )
        )
    }

    /// What a generated runtime spec is for. The guest keeps only
    /// `spec.process` (plus `root`, to resolve the user) for an exec.
    private enum SpecPurpose {
        case containerInit
        case exec
    }

    private func generateRuntimeSpec(
        containerID: String,
        config: ContainerConfiguration,
        rootfs: Mount,
        writableLayer: Mount? = nil,
        seccomp: ResolvedSeccomp,
        purpose: SpecPurpose
    ) throws -> Spec {
        var spec = Self.createDefaultRuntimeSpec(containerID, podID: self.id)

        // Process configuration
        spec.process = config.process.toOCI()

        // Wrap with init process if requested.
        if config.useInit {
            let originalArgs = spec.process?.args ?? []
            spec.process?.args = ["/.cz-init", "--"] + originalArgs
        }

        // General toggles
        // Container-level hostname takes precedence; fall back to pod-level hostname.
        if let hostname = config.hostname ?? self.config.hostname {
            spec.hostname = hostname
        }
        spec.hooks = config.hooks

        // Linux toggles
        if config.cgroupDelegation {
            var annotations = spec.annotations ?? [:]
            annotations[AnnotationKeys.containerizationCgroupDelegation] = "true"
            spec.annotations = annotations
        }
        spec.linux?.sysctl = config.sysctl
        spec.linux?.devices = config.devices
        spec.linux?.maskedPaths = config.maskedPaths
        spec.linux?.readonlyPaths = config.readonlyPaths

        // If the rootfs was requested as read-only, set it in the OCI spec.
        // We let the OCI runtime remount as ro, instead of doing it originally.
        spec.root?.readonly = rootfs.options.contains("ro") && writableLayer == nil

        // Resource limits.
        spec.linux?.resources?.cpu = LinuxCPU(
            quota: Int64(config.cpus * 100_000),
            period: 100_000
        )
        // The runtime spec's `swap` is the memory and swap total, not the
        // swap alone, so the container's memory limit is folded in here.
        spec.linux?.resources?.memory = LinuxMemory(
            limit: Int64(config.memoryInBytes),
            swap: config.swapInBytes.map { Int64(config.memoryInBytes + $0) }
        )

        // Init spec only. runc installs seccomp for `runc exec` from the
        // container's saved config.json, so a profile in an exec's spec would
        // change nothing in the guest and just add ~12 KB of JSON per exec.
        if case .containerInit = purpose, let profile = Self.seccompProfile(seccomp, for: config) {
            // Not `spec.linux?.seccomp = ...`: that is a silent no-op when
            // `linux` is nil, and the failure mode is a container running
            // unfiltered with nothing saying so.
            guard var linux = spec.linux else {
                throw ContainerizationError(
                    .internalError,
                    message: "cannot apply the seccomp profile: the runtime spec has no linux section"
                )
            }
            linux.seccomp = profile
            spec.linux = linux
        }

        return spec
    }

    /// A container's seccomp filter, or `nil` when it runs unfiltered. The
    /// default profile is resolved against that container's init-process
    /// capabilities, which is what runc installs for its execs too.
    private static func seccompProfile(_ resolved: ResolvedSeccomp, for config: ContainerConfiguration) -> LinuxSeccomp? {
        switch resolved {
        case .unconfined:
            return nil
        case .defaultProfile(let arch):
            return .defaultProfile(capabilities: config.process.toOCI().capabilities, arch: arch)
        case .profile(let profile):
            return profile
        }
    }

    static func guestRootfsPath(_ containerID: String) -> String {
        "/run/container/\(containerID)/rootfs"
    }

    /// Unmount a container's rootfs, and the layers it is built from when it
    /// was given a writable layer. Every mount is tried whatever the others
    /// did, and the first failure is thrown once all have been, so a mount
    /// left behind by a partial setup still comes down.
    private static func umountRootfs(of containerID: String, hasWritableLayer: Bool, agent: VirtualMachineAgent) async throws {
        var paths = [Self.guestRootfsPath(containerID)]
        if hasWritableLayer {
            paths.append("/run/container/\(containerID)/upper")
            paths.append("/run/container/\(containerID)/lower")
        }
        var failure: (any Error)?
        for path in paths {
            do {
                try await agent.umount(path: path, flags: 0)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure {
            throw failure
        }
    }

    /// Mount a stopped container's rootfs again so a fresh process can run on
    /// it. A stop leaves the container's block devices attached and its
    /// storage entry registered, and takes down only the guest mounts, so the
    /// mount of its rootfs is all a restart has to put back: the block, its
    /// image and its shares are what they were, and the pod's volumes it
    /// mounts stayed.
    private static func remountRootfs(
        of containerID: String,
        vm: any VirtualMachineInstance,
        agent: any VirtualMachineAgent
    ) async throws {
        guard let attached = vm.storage.containers[containerID] else {
            throw ContainerizationError(
                .invalidState,
                message: "container \(containerID) has no registered rootfs to mount again"
            )
        }
        try await agent.mountRootfs(
            containerID: containerID,
            rootfsAttachment: attached.rootfs,
            writableAttachment: attached.writableLayer,
            rootfsPath: Self.guestRootfsPath(containerID)
        )
    }

    static func guestSocketStagingPath(_ socketID: String) -> String {
        "/run/sockets/\(socketID).sock"
    }

    private static func guestVolumePath(_ volumeName: String) -> String {
        "/run/volumes/\(volumeName)"
    }

    /// The owner a volume attached while the machine runs is recorded under
    /// in the machine's hotplug: the pod's, so that releasing the container
    /// that brought it leaves it attached for the machine's life.
    private static func volumeOwner(_ volumeName: String) -> String {
        "volume-\(volumeName)"
    }

    /// A container's mounts with each block volume given as a mount of the
    /// pod's volume of its image, and those volumes as the machine attaches
    /// them, by name. An image the pod declares a volume of is that volume;
    /// any other is named by its tag, which no declared volume may take.
    /// Kata finds a block device a container brings among the sandbox's by
    /// the device itself, and takes the one it finds.
    /// https://github.com/kata-containers/kata-containers/blob/main/src/runtime/pkg/device/manager/manager.go
    private func podVolumes(of mounts: [Mount], for containerID: String) throws -> (mounts: [Mount], volumes: [String: Mount]) {
        var rewritten: [Mount] = []
        var volumes: [String: Mount] = [:]
        for mount in mounts {
            guard mount.isBlock else {
                rewritten.append(mount)
                continue
            }
            let tag = try mount.tagHash
            if let declared = try self.declaredVolume(ofImage: tag) {
                if declared.readOnly {
                    try Self.requireReadOnly(mount, of: declared.name, for: containerID)
                }
                rewritten.append(.sharedMount(name: declared.name, destination: mount.destination, options: mount.options))
                continue
            }
            guard !self.config.volumes.contains(where: { $0.name == tag }) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "pod volume \"\(tag)\" takes the name of the volume of \(mount.source)"
                )
            }
            var volume = volumes[tag] ?? mount
            volume.destination = Self.guestVolumePath(tag)
            if !mount.options.contains("ro") {
                volume.options.removeAll { $0 == "ro" }
            }
            volumes[tag] = volume
            rewritten.append(.sharedMount(name: tag, destination: mount.destination, options: mount.options))
        }
        return (rewritten, volumes)
    }

    /// The volume the pod declares of the image `tag` names, when it declares
    /// one.
    private func declaredVolume(ofImage tag: String) throws -> (name: String, readOnly: Bool)? {
        for volume in self.config.volumes {
            guard case .diskImage(let path, let readOnly) = volume.source else { continue }
            if try hashFilePath(path: path.absolutePath()) == tag {
                return (volume.name, readOnly)
            }
        }
        return nil
    }

    /// Refuse a container's writable mount of a volume the pod mounts
    /// read-only: the volume is one filesystem for all its containers, and
    /// mount(8) refuses a writable mount over a loop device already bound
    /// read-only to the same file the same way, since a device set up
    /// read-only cannot be changed.
    /// https://github.com/util-linux/util-linux/blob/master/libmount/src/hook_loopdev.c
    private static func requireReadOnly(_ mount: Mount, of volumeName: String, for containerID: String) throws {
        guard mount.options.contains("ro") else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container \(containerID) mounts \(mount.source) writable, and the pod's volume \"\(volumeName)\" of it is read-only"
            )
        }
    }

    /// Count a container placed before the machine boots among the users of
    /// its volumes. Nothing is attached yet, so a volume any of them writes
    /// to is attached writable, and a container that only reads it is given
    /// a read-only bind.
    private static func registerVolumes(_ volumes: [String: Mount], for containerID: String, in blockVolumes: inout [String: BlockVolume]) {
        for (name, mount) in volumes {
            var volume = blockVolumes[name] ?? BlockVolume(mount: mount, users: [])
            if !mount.options.contains("ro") {
                volume.mount.options.removeAll { $0 == "ro" }
            }
            volume.users.insert(containerID)
            blockVolumes[name] = volume
        }
    }

    /// Give a container added to the running machine its volumes: one the
    /// machine has is counted, and one it lacks is attached through the
    /// machine's hotplug and mounted at its path, the guest's mount waiting
    /// for a device just attached as it waits for the root's. A volume
    /// already attached keeps the mode it was attached with.
    private static func stageVolumes(
        _ volumes: [String: Mount],
        for containerID: String,
        in blockVolumes: inout [String: BlockVolume],
        vm: any VirtualMachineInstance,
        agent: any VirtualMachineAgent
    ) async throws {
        for name in volumes.keys.sorted() {
            guard let mount = volumes[name] else { continue }
            var volume = blockVolumes[name] ?? BlockVolume(mount: mount, users: [])
            if volume.attachment != nil {
                if volume.mount.options.contains("ro") {
                    try Self.requireReadOnly(mount, of: name, for: containerID)
                }
            } else {
                let owner = Self.volumeOwner(name)
                let attachment = try await vm.hotplug(volume.mount, id: owner)
                do {
                    try await agent.mount(attachment.to, of: attachment)
                } catch {
                    try? await vm.releaseHotplug(id: owner)
                    try? await vm.releaseVirtioFS(id: owner)
                    throw error
                }
                volume.attachment = attachment
            }
            volume.users.insert(containerID)
            blockVolumes[name] = volume
        }
    }

    /// Take a container off the users of its volumes. The machine keeps a
    /// volume attached and mounted for its life whether or not a container
    /// still mounts it, as a pod keeps its volumes until it is torn down; one
    /// the machine never attached, since it has not booted, is forgotten with
    /// its last container.
    private static func releaseVolumes(of containerID: String, in blockVolumes: inout [String: BlockVolume]) {
        for name in blockVolumes.keys.sorted() {
            guard var volume = blockVolumes[name], volume.users.remove(containerID) != nil else { continue }
            if volume.users.isEmpty && volume.attachment == nil {
                blockVolumes[name] = nil
            } else {
                blockVolumes[name] = volume
            }
        }
    }
}

extension LinuxPod {
    /// Number of CPU cores allocated to the pod's VM.
    public var cpus: Int {
        vm.cpus
    }

    /// Amount of memory in bytes allocated for the pod's VM.
    public var memoryInBytes: UInt64 {
        vm.memoryInBytes
    }

    /// Network interfaces of the pod.
    public var interfaces: [any Interface] {
        config.interfaces
    }

    /// Add a container to the pod.
    ///
    /// When called before `create()`, the container is registered for setup during VM creation.
    /// When called after `create()`, the container is hotplugged into the running VM.
    /// If the underlying VMM does not support hotplug, an error is thrown.
    /// - Parameters:
    ///   - writableLayer: Optional writable layer mount. When provided, an overlayfs is used with
    ///     the container's rootfs as the lower layer and this as the upper layer, so all writes
    ///     go to this layer instead of the rootfs.
    public func addContainer(
        _ id: String,
        rootfs: Mount,
        writableLayer: Mount? = nil,
        configuration: @Sendable @escaping (inout ContainerConfiguration) throws -> Void
    ) async throws {
        guard id.count <= Self.maxIDLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container id length \(id.count) exceeds maximum of \(Self.maxIDLength) characters"
            )
        }
        if let writableLayer {
            guard writableLayer.isBlock else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "writableLayer must be a block device"
                )
            }
        }
        try await self.state.withLock { state in
            guard state.containers[id] == nil else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container with id \(id) already exists in pod"
                )
            }

            var config = ContainerConfiguration()
            try configuration(&config)

            // A container's own profile wins over the pod's. Resolved here so a
            // profile the runtime cannot install is rejected at add time,
            // before the VM boots or the container is hotplugged.
            let seccomp: ResolvedSeccomp
            if let override = config.seccompProfile {
                seccomp = try Self.resolveSeccomp(override, ociRuntimePath: self.config.ociRuntimePath)
            } else {
                seccomp = self.seccomp
            }

            // An OCI runtime needs a tmpfs on /dev. Written back into the stored
            // config so every later read of `container.config.mounts` sees the
            // rewrite, not just the VM mounts derived from it here.
            config.mounts = LinuxContainer.mountsForRuntime(
                config.mounts,
                ociRuntimePath: self.config.ociRuntimePath,
                containerID: id,
                logger: self.logger
            )

            // A block volume the container mounts is the pod's, so the
            // container is given it as a mount of the pod's volume, written
            // back into the stored config for the same reason.
            let (mounts, volumes) = try self.podVolumes(of: config.mounts, for: id)
            config.mounts = mounts

            let fileMountContext = try FileMountContext.prepare(
                mounts: LinuxContainer.systemdAwareMounts(
                    config.mounts, systemd: config.systemd,
                    arguments: config.process.arguments))

            switch state.phase {
            case .initialized:
                Self.registerVolumes(volumes, for: id, in: &state.blockVolumes)
                state.containers[id] = PodContainer(
                    id: id,
                    rootfs: rootfs,
                    writableLayer: writableLayer,
                    config: config,
                    seccomp: seccomp,
                    state: .registered,
                    process: nil,
                    fileMountContext: fileMountContext
                )

            case .created(let createdState):
                let vm = createdState.vm

                // Strip "ro" as create() does: readonly is expressed through
                // the OCI spec's root.readonly field and a remount in vmexec
                // after setup completes, so the device attaches writable.
                var modifiedRootfs = rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })

                let attachment = try await vm.hotplug(modifiedRootfs, id: id)

                var updatedFileMountContext = fileMountContext
                do {
                    // The writable layer is a block device like the rootfs,
                    // attached alongside it so the overlay has both layers.
                    var writableAttachment: AttachedFilesystem?
                    if let writableLayer {
                        writableAttachment = try await vm.hotplug(writableLayer, id: id)
                    }

                    let virtioFSMounts = fileMountContext.transformedMounts.filter {
                        if case .virtiofs(_) = $0.runtimeOptions { return true }
                        return false
                    }
                    if !virtioFSMounts.isEmpty {
                        try await vm.hotplugVirtioFS(virtioFSMounts, id: id)
                    }

                    let agent = try await vm.dialAgent()
                    do {
                        try await agent.mountRootfs(
                            containerID: id,
                            rootfsAttachment: attachment,
                            writableAttachment: writableAttachment,
                            rootfsPath: Self.guestRootfsPath(id)
                        )
                        try await Self.stageVolumes(volumes, for: id, in: &state.blockVolumes, vm: vm, agent: agent)

                        // Shared mounts are handled separately as pod volume
                        // bind mounts; without the filter here, a container
                        // added to an already-created pod would add a
                        // duplicated mount into the shared VM.
                        let nonSharedMounts = fileMountContext.transformedMounts.filter {
                            if case .shared = $0.runtimeOptions { return false }
                            return true
                        }
                        try vm.registerMounts(
                            id: id,
                            rootfs: attachment,
                            writableLayer: writableAttachment,
                            additionalMounts: try nonSharedMounts.map { try AttachedFilesystem(mount: $0) }
                        )

                        // Mount this container's additional virtiofs shares in the
                        // guest. create() does this for boot-time containers (the
                        // /run/virtiofs loop); the hotplug path must do the same or
                        // the container's bind mounts from /run/virtiofs/<tag> fail
                        // with ENOENT.
                        //
                        // Derive the new tags from the additional mounts being added;
                        // the machine's storage names what is already shared.
                        let newVirtiofsTags = try virtioFSMounts.map { try hashFilePath(path: $0.source) }
                        if !newVirtiofsTags.isEmpty {
                            try await agent.mkdir(path: "/run/virtiofs", all: true, perms: 0o755)
                            if vm.virtiofsLayout == .perTag {
                                // Tags already mounted in the guest at boot or by a
                                // prior hotplug (i.e. present on another container or
                                // a machine volume). Only additional mounts put their
                                // tags under /run/virtiofs; a virtiofs rootfs is
                                // mounted at the container's own rootfs path, so it
                                // says nothing about /run/virtiofs and would wrongly
                                // satisfy a tag another container binds from.
                                let alreadyMounted: Set<String> = {
                                    var mounted = Set(
                                        vm.storage.containers
                                            .filter { $0.key != id }
                                            .values.flatMap { $0.mounts }
                                            .filter { $0.type == "virtiofs" }
                                            .map { $0.source })
                                    mounted.formUnion(
                                        vm.storage.volumes.values
                                            .filter { $0.type == "virtiofs" }
                                            .map { $0.source })
                                    return mounted
                                }()
                                var seen: Set<String> = []
                                for tag in newVirtiofsTags
                                where !alreadyMounted.contains(tag) && seen.insert(tag).inserted {
                                    let dest = "/run/virtiofs/\(tag)"
                                    try await agent.mkdir(path: dest, all: true, perms: 0o755)
                                    try await agent.mount(
                                        ContainerizationOCI.Mount(
                                            type: "virtiofs",
                                            source: tag,
                                            destination: dest,
                                            options: []
                                        ))
                                }
                            } else if !state.unifiedVirtiofsMounted && vm.virtiofsLayout == .unified {
                                // Unified layout: one /run/virtiofs mount for the
                                // VM's lifetime, so mount it only if nothing has
                                // mounted it at boot or on an earlier hotplug.
                                try await agent.mount(
                                    ContainerizationOCI.Mount(
                                        type: "virtiofs",
                                        source: "virtiofs",
                                        destination: "/run/virtiofs",
                                        options: []
                                    ))
                                state.unifiedVirtiofsMounted = true
                            }
                        }

                        if fileMountContext.hasFileMounts {
                            let containerMounts = vm.storage.containers[id]?.mounts ?? []
                            try await updatedFileMountContext.mountHoldingDirectories(
                                vmMounts: containerMounts,
                                agent: agent
                            )
                        }

                        if let dns = config.dns ?? self.config.dns {
                            try await agent.configureDNS(
                                config: dns,
                                location: Self.guestRootfsPath(id)
                            )
                        }

                        if let hosts = config.hosts ?? self.config.hosts {
                            try await agent.configureHosts(
                                config: hosts,
                                location: Self.guestRootfsPath(id)
                            )
                        }

                        for socket in config.sockets {
                            try await self.relayUnixSocket(
                                socket: socket,
                                containerID: id,
                                relayManager: createdState.relayManager,
                                agent: agent
                            )
                        }

                        try await agent.close()
                    } catch {
                        try? await Self.umountRootfs(of: id, hasWritableLayer: writableAttachment != nil, agent: agent)
                        try? await agent.close()
                        throw error
                    }

                    state.containers[id] = PodContainer(
                        id: id,
                        rootfs: rootfs,
                        writableLayer: writableLayer,
                        config: config,
                        seccomp: seccomp,
                        state: .created,
                        process: nil,
                        fileMountContext: updatedFileMountContext,
                        rootfsMounted: true
                    )
                } catch {
                    Self.releaseVolumes(of: id, in: &state.blockVolumes)
                    try? await vm.releaseHotplug(id: id)
                    try? await vm.releaseVirtioFS(id: id)
                    throw error
                }

            case .errored(let err):
                throw err
            }
        }
    }

    /// Create and start the underlying pod's virtual machine and set up
    /// the runtime environment. All registered containers will have their
    /// rootfs mounted, but no init processes will be running.
    public func create() async throws {
        try await self.state.withLock { state in
            try state.phase.validateForCreate()

            // Build the machine's storage from its containers.
            // Strip "ro" from rootfs options - we handle readonly via the OCI spec's
            // root.readonly field and remount in vmexec after setup is complete.
            // Use transformedMounts from fileMountContext (file mounts become directory shares).
            var machineStorage = MachineMounts()
            for (id, container) in state.containers {
                var modifiedRootfs = container.rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })
                // Shared mounts are handled separately as pod volume bind mounts.
                let containerMounts = container.fileMountContext.transformedMounts.filter {
                    if case .shared = $0.runtimeOptions { return false }
                    return true
                }
                machineStorage.containers[id] = ContainerMounts(
                    rootfs: modifiedRootfs,
                    writableLayer: container.writableLayer,
                    mounts: containerMounts
                )
            }

            // Validate pod volume names are unique.
            var volumeNames = Set<String>()
            for volume in self.config.volumes {
                guard volumeNames.insert(volume.name).inserted else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "duplicate pod volume name \"\(volume.name)\""
                    )
                }
            }
            // The containers' block volumes are the pod's too, named by their
            // images' tags, which no declared volume takes.
            let blockVolumes = state.blockVolumes
            volumeNames.formUnion(blockVolumes.keys)

            // Validate that all shared mounts reference valid pod volume names.
            for (id, container) in state.containers {
                for mount in container.config.mounts {
                    if case .shared = mount.runtimeOptions {
                        guard volumeNames.contains(mount.source) else {
                            throw ContainerizationError(
                                .invalidArgument,
                                message: "container \(id) references unknown pod volume \"\(mount.source)\""
                            )
                        }
                    }
                }
            }
            for volume in self.config.volumes {
                machineStorage.volumes[volume.name] = volume.toMount()
            }
            for (name, volume) in blockVolumes {
                machineStorage.volumes[name] = volume.mount
            }
            // The swap area is attached with the machine's own storage so the
            // guest is told the /dev path the VMM allocates it.
            machineStorage.swap = self.config.swapLayer

            // Captured into an immutable `let` so the value is safely usable
            // from the concurrent `withAgent` closure below. CH attaches a
            // virtiofs device only when a share is configured, so mounting an
            // unbacked /run/virtiofs would fail with EINVAL there, while a VZ
            // machine always carries its one share device and mounts it at
            // boot whether or not anything is exported yet, so a directory
            // exported to it later appears under /run/virtiofs as it is
            // exported.
            let hasVirtiofsMount = machineStorage.ordered.contains { mount in
                if case .virtiofs = mount.runtimeOptions { return true }
                return false
            }

            var vmConfig = VMConfiguration(
                cpus: self.vm.cpus,
                memoryInBytes: self.vm.memoryInBytes,
                interfaces: self.config.interfaces,
                storage: machineStorage,
                bootLog: self.config.bootLog,
                nestedVirtualization: self.config.virtualization,
                blockDeviceDriver: self.config.blockDeviceDriver
            )
            vmConfig.extensions = self.config.extensions
            let creationConfig = StandardVMConfig(configuration: vmConfig)
            let vm = try await self.vmm.create(config: creationConfig)
            let mountsShareAtBoot = hasVirtiofsMount || vm.virtiofsLayout == .unified
            let relayManager = UnixSocketRelayManager(vm: vm)
            do {
                try await vm.start()
                let containers = state.containers
                let shareProcessNamespace = self.config.shareProcessNamespace
                let pauseProcessHolder = Mutex<LinuxProcess?>(nil)
                let fileMountContextUpdates = Mutex<[String: FileMountContext]>([:])
                // A container the machine cannot set up is left errored with
                // the reason while the rest come up: a container's failure is
                // its own and never the sandbox's, and the container's start
                // answers with it.
                // https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
                let setupFailures = Mutex<[String: any Error]>([:])
                let mountedRoots = Mutex<Set<String>>([])
                let mountedVolumes = Mutex<Set<String>>([])
                let hasSwapLayer = self.config.swapLayer != nil

                try await vm.withAgent { agent in
                    try await agent.standardSetup()

                    // The swap area belongs to the pod rather than to any one
                    // container, so it is enabled once here and every container
                    // reclaims to it through the guest's own memory management.
                    if hasSwapLayer {
                        guard let swap = vm.storage.swap else {
                            throw ContainerizationError(.notFound, message: "swap mount not found")
                        }
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: Swap.mountType,
                                source: swap.source,
                                destination: "",
                                options: swap.options
                            ))
                    }

                    // Mount the machine's share at /run/virtiofs: the unified
                    // device whenever the machine has one, so that a directory
                    // exported later appears under it, and a per-tag device
                    // only where a container has a virtiofs mount, since an
                    // unbacked one does not mount.
                    if mountsShareAtBoot {
                        try await agent.mkdir(path: "/run/virtiofs", all: true, perms: 0o755)
                        if vm.virtiofsLayout == .perTag {
                            // CH backend: one virtio-fs device per source-hash
                            // tag, so mount each tag separately at
                            // /run/virtiofs/<tag>. See LinuxContainer for the
                            // VZ vs. CH model split. /run/virtiofs carries the
                            // tags containers bind additional mounts from; a
                            // virtiofs rootfs is mounted at the container's own
                            // rootfs path and takes no bind, so its tag stays
                            // out, and the machine's volumes are bound from here
                            // the way a container's additional mounts are.
                            var seenTags: Set<String> = []
                            let bindable =
                                vm.storage.containers.keys.sorted()
                                .flatMap { vm.storage.containers[$0]?.mounts ?? [] }
                                + vm.storage.volumes.keys.sorted().compactMap { vm.storage.volumes[$0] }
                            for entry in bindable where entry.type == "virtiofs" {
                                guard seenTags.insert(entry.source).inserted else { continue }
                                let dest = "/run/virtiofs/\(entry.source)"
                                try await agent.mkdir(path: dest, all: true, perms: 0o755)
                                try await agent.mount(
                                    ContainerizationOCI.Mount(
                                        type: "virtiofs",
                                        source: entry.source,
                                        destination: dest,
                                        options: []
                                    ))
                            }
                        } else {
                            try await agent.mount(
                                ContainerizationOCI.Mount(
                                    type: "virtiofs",
                                    source: "virtiofs",
                                    destination: "/run/virtiofs",
                                    options: []
                                ))
                        }
                    }

                    // Create pause container if PID namespace sharing is enabled
                    if shareProcessNamespace {
                        let pauseID = "pause-\(self.id)"
                        let pauseRootfsPath = "/run/container/\(pauseID)/rootfs"

                        // Bind mount /sbin into the pause container rootfs.
                        // This is where the guest agent lives.
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: "",
                                source: "/sbin",
                                destination: "\(pauseRootfsPath)/sbin",
                                options: ["bind"]
                            ))

                        var pauseSpec = Self.createDefaultRuntimeSpec(pauseID, podID: self.id)
                        pauseSpec.process?.args = ["/sbin/vminitd", "pause"]
                        pauseSpec.hostname = ""
                        pauseSpec.mounts = LinuxContainer.defaultMounts().map {
                            ContainerizationOCI.Mount(
                                type: $0.type,
                                source: $0.source,
                                destination: $0.destination,
                                options: $0.options
                            )
                        }
                        pauseSpec.linux?.namespaces = [
                            LinuxNamespace(type: .cgroup),
                            LinuxNamespace(type: .ipc),
                            LinuxNamespace(type: .mount),
                            LinuxNamespace(type: .pid),
                            LinuxNamespace(type: .uts),
                        ]

                        // Create LinuxProcess for pause container. It stays on
                        // vmexec under any pod runtime: its rootfs is a bind of
                        // the guest's /sbin, not an image, and the containers
                        // join its PID namespace by path either way. vmexec
                        // ignores spec.linux.seccomp, so it runs unfiltered.
                        let process = LinuxProcess(
                            pauseID,
                            containerID: pauseID,
                            spec: pauseSpec,
                            io: LinuxProcess.Stdio(stdin: nil, stdout: nil, stderr: nil),
                            portAllocator: self.hostVsockPorts,
                            ociRuntimePath: nil,
                            agent: agent,
                            vm: vm,
                            logger: self.logger
                        )

                        try await process.start()
                        pauseProcessHolder.withLock { $0 = process }

                        self.logger?.debug("Pause container started", metadata: ["pid": "\(process.pid)"])
                    }

                    // Mount all container rootfs. A rootfs that cannot be
                    // mounted leaves nothing of itself mounted, so the disks
                    // under it can be given back without taking a filesystem
                    // down with them.
                    for (_, container) in containers {
                        do {
                            guard let attached = vm.storage.containers[container.id] else {
                                throw ContainerizationError(.notFound, message: "rootfs mount not found for container \(container.id)")
                            }
                            try await agent.mountRootfs(
                                containerID: container.id,
                                rootfsAttachment: attached.rootfs,
                                writableAttachment: attached.writableLayer,
                                rootfsPath: Self.guestRootfsPath(container.id)
                            )
                            mountedRoots.withLock { _ = $0.insert(container.id) }
                        } catch {
                            try? await Self.umountRootfs(of: container.id, hasWritableLayer: container.writableLayer != nil, agent: agent)
                            setupFailures.withLock { $0[container.id] = error }
                        }
                    }

                    // Mount file mount holding directories under /run for each container.
                    for (id, container) in containers where setupFailures.withLock({ $0[id] == nil }) {
                        if container.fileMountContext.hasFileMounts {
                            var ctx = container.fileMountContext
                            let containerMounts = vm.storage.containers[id]?.mounts ?? []
                            do {
                                try await ctx.mountHoldingDirectories(
                                    vmMounts: containerMounts,
                                    agent: agent
                                )
                                fileMountContextUpdates.withLock { $0[id] = ctx }
                            } catch {
                                setupFailures.withLock { $0[id] = error }
                            }
                        }
                    }

                    // Mount pod-level volumes.
                    for volume in self.config.volumes {
                        guard let attachment = vm.storage.volumes[volume.name] else {
                            throw ContainerizationError(
                                .notFound,
                                message: "attached filesystem not found for pod volume \"\(volume.name)\""
                            )
                        }
                        let guestPath = Self.guestVolumePath(volume.name)
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: volume.format,
                                source: attachment.source,
                                destination: guestPath,
                                options: attachment.options
                            ),
                            of: attachment
                        )
                    }

                    // Mount the volumes the containers mount, each once. A
                    // volume the guest cannot mount is the failure of the
                    // containers that mount it.
                    for name in blockVolumes.keys.sorted() {
                        guard let volume = blockVolumes[name] else { continue }
                        do {
                            guard let attachment = vm.storage.volumes[name] else {
                                throw ContainerizationError(
                                    .notFound,
                                    message: "attached filesystem not found for pod volume \"\(name)\""
                                )
                            }
                            try await agent.mount(attachment.to, of: attachment)
                            mountedVolumes.withLock { _ = $0.insert(name) }
                        } catch {
                            setupFailures.withLock { failures in
                                for user in volume.users where failures[user] == nil {
                                    failures[user] = error
                                }
                            }
                        }
                    }

                    // Start up unix socket relays for each container
                    for (id, container) in containers where setupFailures.withLock({ $0[id] == nil }) {
                        do {
                            for socket in container.config.sockets {
                                try await self.relayUnixSocket(
                                    socket: socket,
                                    containerID: container.id,
                                    relayManager: relayManager,
                                    agent: agent
                                )
                            }
                        } catch {
                            setupFailures.withLock { $0[id] = error }
                        }
                    }

                    // For every interface asked for:
                    // 1. Add the address requested
                    // 2. Online the adapter
                    // 3. For the first interface, add the default route
                    var defaultRouteSet = false
                    for (index, i) in self.interfaces.enumerated() {
                        let name = "eth\(index)"
                        try await agent.setupInterface(
                            i,
                            name: name,
                            setDefaultRoute: !defaultRouteSet,
                            logger: self.logger
                        )
                        defaultRouteSet = true
                    }

                    // Setup /etc/resolv.conf and /etc/hosts for each container.
                    // Container-level config takes precedence over pod-level config.
                    for (id, container) in containers where setupFailures.withLock({ $0[id] == nil }) {
                        do {
                            if let dns = container.config.dns ?? self.config.dns {
                                try await agent.configureDNS(
                                    config: dns,
                                    location: Self.guestRootfsPath(container.id)
                                )
                            }
                            if let hosts = container.config.hosts ?? self.config.hosts {
                                try await agent.configureHosts(
                                    config: hosts,
                                    location: Self.guestRootfsPath(container.id)
                                )
                            }
                        } catch {
                            setupFailures.withLock { $0[id] = error }
                        }
                    }
                }

                state.pauseProcess = pauseProcessHolder.withLock { $0 }
                state.unifiedVirtiofsMounted = mountsShareAtBoot && vm.virtiofsLayout == .unified
                for name in mountedVolumes.withLock({ $0 }) {
                    state.blockVolumes[name]?.attachment = vm.storage.volumes[name]
                }

                // Apply file mount context updates.
                let updates = fileMountContextUpdates.withLock { $0 }
                for (id, ctx) in updates {
                    state.containers[id]?.fileMountContext = ctx
                }

                // Every container the machine set up is created; one it could
                // not is errored, holding the reason for its start.
                let failed = setupFailures.withLock { $0 }
                let roots = mountedRoots.withLock { $0 }
                for id in state.containers.keys {
                    state.containers[id]?.rootfsMounted = roots.contains(id)
                    if let failure = failed[id] {
                        self.logger?.error(
                            "the machine could not set a container up as it booted",
                            metadata: ["container": "\(id)", "error": "\(failure)"])
                        state.containers[id]?.state = .errored
                        state.containers[id]?.failure = failure
                    } else {
                        state.containers[id]?.state = .created
                    }
                }

                state.phase = .created(.init(vm: vm, relayManager: relayManager))
            } catch {
                try? await relayManager.stopAll()
                try? await vm.stop()
                state.phase.setErrored(error: error)
                throw error
            }
        }
    }

    /// Start a container's initial process.
    ///
    /// The process runs with the container's process configuration, as the
    /// container was added with it or as `configuration` leaves it: a start
    /// may bring its own streams, since a container that ran and stopped had
    /// its last run's streams closed with its exit, the way a task carries
    /// its own io onto a container it runs again.
    /// https://github.com/containerd/containerd/blob/main/docs/getting-started.md
    public func startContainer(
        _ containerID: String,
        configuration: (@Sendable (inout LinuxProcessConfiguration) throws -> Void)? = nil
    ) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("startContainer")

            guard var container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            if container.state == .errored, let failure = container.failure {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) could not be set up when the machine booted",
                    cause: failure
                )
            }

            guard container.state == .created || container.state == .stopped else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be in created or stopped state to start"
                )
            }

            if let configuration {
                try configuration(&container.config.process)
                state.containers[containerID] = container
            }

            let agent = try await createdState.vm.dialAgent()
            do {
                // A container that ran and stopped kept its place: its block
                // devices are attached and registered, and its guest mounts
                // are what the stop took down. Mounting them again the way
                // its placement did makes it a created container, so a
                // failure before the process starts is cleaned up by the same
                // stop path a never-started one takes.
                if container.state == .stopped {
                    try await Self.remountRootfs(of: containerID, vm: createdState.vm, agent: agent)
                    container.rootfsMounted = true
                    container.state = .created
                    state.containers[containerID] = container
                }

                var spec = try self.generateRuntimeSpec(
                    containerID: containerID,
                    config: container.config,
                    rootfs: container.rootfs,
                    writableLayer: container.writableLayer,
                    seccomp: container.seccomp,
                    purpose: .containerInit
                )
                // We don't need the rootfs, nor do OCI runtimes want it included.
                // Also filter out file mount holding directories - we mount those separately under /run.
                // Transform virtiofs mounts to bind mounts from /run/virtiofs/{tag}
                let containerMounts = createdState.vm.storage.containers[containerID]?.mounts ?? []
                let holdingTags = container.fileMountContext.holdingDirectoryTags
                var mounts: [ContainerizationOCI.Mount] =
                    containerMounts
                    .filter { !holdingTags.contains($0.source) }
                    .map { attached -> ContainerizationOCI.Mount in
                        if attached.type == "virtiofs" {
                            // Transform to bind mount from holding directory
                            return ContainerizationOCI.Mount(
                                type: "none",
                                source: "/run/virtiofs/\(attached.source)",
                                destination: attached.destination,
                                options: ["bind"] + attached.options
                            )
                        }
                        return attached.to
                    }
                    + container.fileMountContext.ociBindMounts()

                // When useInit is enabled, bind mount vminitd from the VM's filesystem
                // into the container so it can be executed.
                if container.config.useInit {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: "/sbin/vminitd",
                            destination: "/.cz-init",
                            options: ["bind", "ro"]
                        ))
                }

                // Bind mount staged sockets into the container. Sockets relayed
                // .into the container are created in a staging directory outside
                // the rootfs to avoid symlink traversal and mount shadowing.
                for socket in container.config.sockets where socket.direction == .into {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: Self.guestSocketStagingPath(socket.id),
                            destination: socket.destination.path,
                            options: ["bind"]
                        ))
                }

                // Bind mount pod volumes into the container.
                for mount in container.config.mounts {
                    if case .shared = mount.runtimeOptions {
                        mounts.append(
                            ContainerizationOCI.Mount(
                                type: "none",
                                source: Self.guestVolumePath(mount.source),
                                destination: mount.destination,
                                options: ["bind"] + mount.options
                            ))
                    }
                }

                spec.mounts = cleanAndSortMounts(mounts)

                // Configure namespaces for the container
                var namespaces: [LinuxNamespace] = [
                    LinuxNamespace(type: .cgroup),
                    LinuxNamespace(type: .ipc),
                    LinuxNamespace(type: .mount),
                    LinuxNamespace(type: .uts),
                ]

                // Either join pause container's pid ns or create a new one
                if self.config.shareProcessNamespace, let pausePID = state.pauseProcess?.pid {
                    let nsPath = "/proc/\(pausePID)/ns/pid"

                    self.logger?.debug(
                        "Container joining pause PID namespace",
                        metadata: [
                            "container": "\(containerID)",
                            "pausePID": "\(pausePID)",
                            "nsPath": "\(nsPath)",
                        ])

                    namespaces.append(LinuxNamespace(type: .pid, path: nsPath))
                } else {
                    namespaces.append(LinuxNamespace(type: .pid))
                }

                spec.linux?.namespaces = namespaces

                let stdio = IOUtil.setup(
                    portAllocator: self.hostVsockPorts,
                    stdin: container.config.process.stdin,
                    stdout: container.config.process.stdout,
                    stderr: container.config.process.stderr
                )

                let process = LinuxProcess(
                    containerID,
                    containerID: containerID,
                    spec: spec,
                    io: stdio,
                    portAllocator: self.hostVsockPorts,
                    ociRuntimePath: self.config.ociRuntimePath,
                    agent: agent,
                    vm: createdState.vm,
                    logger: self.logger
                )
                try await process.start()

                container.process = process
                container.state = .started
                state.containers[containerID] = container
            } catch {
                try? await agent.close()
                throw error
            }
        }
    }

    /// Stop a container from executing.
    ///
    /// Stopping keeps the container's place: its process is torn down and
    /// its guest mounts unmounted, while its block devices stay attached, its
    /// storage entry stays registered and the pod's volumes it mounts stay
    /// mounted, so the container starts again by mounting its own back.
    /// Detaching the devices is removeContainer's,
    /// the separate act the runtime specification names for giving the
    /// place up.
    /// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
    public func stopContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("stopContainer")

            guard var container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            // Allow stop to be called multiple times
            if container.state == .stopped {
                return
            }

            guard container.state == .created || container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be in created or started state to stop"
                )
            }

            // Check if the vm is even still running
            if createdState.vm.state == .stopped {
                // The guest is gone with the container's process, so
                // deleting it gives back only the host's end of it, and a
                // failure says no more than that.
                if let process = container.process {
                    do {
                        try await process.delete()
                    } catch {
                        self.logger?.error("failed to delete the init process of container \(containerID): \(error)")
                    }
                }
                container.process = nil
                container.rootfsMounted = false
                container.state = .stopped
                state.containers[containerID] = container
                return
            }

            // Every step is taken whatever the one before it did, as a
            // container's own machine is stopped, so that a kill or a wait
            // that fails still has the container's mounts brought down and its
            // process deleted. Each failure is logged, and the first is thrown
            // with the container left errored.
            // https://github.com/apple/containerization/blob/main/Sources/Containerization/LinuxContainer.swift
            var firstError: (any Error)?

            // A started container has a process to tear down; a created
            // one holds only what its placement mounted.
            if let process = container.process {
                do {
                    try await process.kill(.kill)
                } catch {
                    self.logger?.error("failed to kill the init of container \(containerID): \(error)")
                    firstError = firstError ?? error
                }
                do {
                    try await process.wait(timeoutInSeconds: 3)
                } catch {
                    self.logger?.error("failed to wait for the init of container \(containerID): \(error)")
                    firstError = firstError ?? error
                }
            }

            // The container's rootfs comes down, with the layers under it
            // when it was given a writable layer, while the disks stay
            // attached: a disk detached under a mounted filesystem takes
            // the filesystem down with I/O errors and a journal abort, so
            // removal, which detaches, finds nothing mounted. The volumes it
            // mounts are the pod's, and stay for its restart.
            if container.rootfsMounted {
                let hasWritableLayer = container.writableLayer != nil
                do {
                    try await createdState.vm.withAgent { agent in
                        try await Self.umountRootfs(of: containerID, hasWritableLayer: hasWritableLayer, agent: agent)
                    }
                    container.rootfsMounted = false
                } catch {
                    self.logger?.error("failed to unmount the root filesystem of container \(containerID): \(error)")
                    firstError = firstError ?? error
                }
            }

            // The process is deleted once and let go of either way, as a
            // container's own machine deletes its init: a process answers a
            // later deletion with the outcome of its first.
            if let process = container.process {
                do {
                    try await process.delete()
                } catch {
                    self.logger?.error("failed to delete the init process of container \(containerID): \(error)")
                    firstError = firstError ?? error
                }
                container.process = nil
            }

            if let firstError {
                container.state = .errored
                state.containers[containerID] = container
                throw firstError
            }
            container.state = .stopped
            state.containers[containerID] = container
        }
    }

    /// Take a container out of the pod, so its name is free to place again.
    ///
    /// Stopping a container tears down what it was running and keeps its
    /// place; the name still answers for it, and placing another container
    /// under it is refused. Removal is the separate act the runtime
    /// specification names for giving the place up, taken once the container
    /// has stopped: its block devices are detached, its shares and storage
    /// entry released, the resources a stop keeps so a stopped container can
    /// start again, and it leaves the users of the volumes it mounts, which
    /// the machine keeps until it stops. A container that is running keeps
    /// its place and this call refuses it.
    /// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
    public func removeContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }
            switch container.state {
            case .registered, .stopped, .errored:
                var vm: (any VirtualMachineInstance)?
                var relayManager: UnixSocketRelayManager?
                if case .created(let createdState) = state.phase {
                    vm = createdState.vm
                    relayManager = createdState.relayManager
                }
                // A container whose stop could not finish still holds what
                // the stop left: its root filesystem is unmounted in the guest
                // before the devices under it are given back. A filesystem the
                // guest cannot unmount keeps its devices and the container its
                // place, the order Kata's runtime keeps when a container goes:
                // the agent lets go of the container's mounts first, and a
                // failure there stops the detach of its devices.
                // https://github.com/kata-containers/kata-containers/blob/main/src/runtime/virtcontainers/container.go
                if let vm, vm.state == .running {
                    // The relays of the container's sockets are its place's,
                    // set up when it was placed and kept for its restart, so
                    // they end with the place, before the root they keep busy
                    // is unmounted, as a container's own machine stops them
                    // first when the container goes.
                    // https://github.com/apple/containerization/blob/main/Sources/Containerization/LinuxContainer.swift
                    for socket in container.config.sockets {
                        do {
                            try await relayManager?.stop(socket: socket)
                        } catch {
                            self.logger?.error(
                                "failed to stop the host end of a socket relay of a container being removed",
                                metadata: ["container": "\(containerID)", "socket": "\(socket.id)", "error": "\(error)"])
                        }
                        do {
                            try await vm.withAgent { agent in
                                guard let relayAgent = agent as? SocketRelayAgent else {
                                    throw ContainerizationError(
                                        .unsupported,
                                        message: "VirtualMachineAgent does not support relaySocket surface"
                                    )
                                }
                                try await relayAgent.stopSocketRelay(configuration: socket)
                            }
                        } catch {
                            self.logger?.error(
                                "failed to stop the guest end of a socket relay of a container being removed",
                                metadata: ["container": "\(containerID)", "socket": "\(socket.id)", "error": "\(error)"])
                        }
                    }
                    if container.rootfsMounted {
                        let hasWritableLayer = container.writableLayer != nil
                        do {
                            try await vm.withAgent { agent in
                                try await Self.umountRootfs(of: containerID, hasWritableLayer: hasWritableLayer, agent: agent)
                            }
                        } catch {
                            self.logger?.error(
                                "the guest could not unmount the root filesystem of a container being removed, so it keeps its place",
                                metadata: ["container": "\(containerID)", "error": "\(error)"])
                            throw error
                        }
                    }
                }
                Self.releaseVolumes(of: containerID, in: &state.blockVolumes)
                // A container removed before the machine booted took no
                // device; one placed in the boot storage holds no hotplug
                // record, and its release clears the storage entry alone.
                if let vm {
                    try? await vm.releaseHotplug(id: containerID)
                    try? await vm.releaseVirtioFS(id: containerID)
                }
                state.containers[containerID] = nil
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must stop before it is removed"
                )
            }
        }
    }

    /// Stop the pod's VM and all containers.
    public func stop() async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("stop")

            do {
                try await createdState.relayManager.stopAll()

                // Stop all containers
                let containerIDs = Array(state.containers.keys)

                for containerID in containerIDs {
                    // Stop the container inline
                    guard var container = state.containers[containerID] else {
                        continue
                    }

                    if container.state == .stopped {
                        continue
                    }

                    if let process = container.process, container.state == .started {
                        if createdState.vm.state != .stopped {
                            try? await process.kill(.kill)
                            _ = try? await process.wait(timeoutInSeconds: 3)

                            try? await createdState.vm.withAgent { agent in
                                try await agent.umount(
                                    path: Self.guestRootfsPath(containerID),
                                    flags: 0
                                )
                            }
                        }

                        try? await process.delete()
                        container.process = nil
                        container.state = .stopped

                        state.containers[containerID] = container
                    }
                }

                // Unmount pod-level volumes.
                if createdState.vm.state != .stopped && !self.config.volumes.isEmpty {
                    try? await createdState.vm.withAgent { agent in
                        for volume in self.config.volumes {
                            try? await agent.umount(
                                path: Self.guestVolumePath(volume.name),
                                flags: 0
                            )
                        }
                    }
                }

                // Unmount the volumes the containers mount.
                let mountedVolumes = state.blockVolumes.filter { $0.value.attachment != nil }.map(\.key)
                if createdState.vm.state != .stopped && !mountedVolumes.isEmpty {
                    try? await createdState.vm.withAgent { agent in
                        for name in mountedVolumes {
                            try? await agent.umount(path: Self.guestVolumePath(name), flags: 0)
                        }
                    }
                }

                try await createdState.vm.stop()
                // The machine's volumes went with it. A pod created again
                // attaches the ones its containers still mount as it boots.
                state.blockVolumes = state.blockVolumes.compactMapValues { volume in
                    guard !volume.users.isEmpty else { return nil }
                    var volume = volume
                    volume.attachment = nil
                    return volume
                }
                // So did the containers' root filesystems, which its boot
                // mounts again.
                for id in state.containers.keys {
                    state.containers[id]?.rootfsMounted = false
                }
                state.phase = .initialized
            } catch {
                try? await createdState.vm.stop()
                state.phase.setErrored(error: error)
                throw error
            }
        }
    }

    /// Send a signal to a container.
    public func killContainer(_ containerID: String, signal: Signal) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.kill(signal)
        }
    }

    /// Discard the free blocks of a container's root filesystem, so a sparse
    /// file backing it can give them back to the host. Returns the number of
    /// bytes the filesystem reported trimmed.
    @discardableResult
    public func trimContainer(_ containerID: String) async throws -> UInt64 {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("trimContainer")
            guard let container = state.containers[containerID], container.state == .started else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            return try await createdState.vm.withAgent { agent in
                try await agent.trimContainerRootfs(containerID: containerID)
            }
        }
    }

    /// Wait for a container to exit. Returns the exit code.
    @discardableResult
    public func waitContainer(_ containerID: String, timeoutInSeconds: Int64? = nil) async throws -> ExitStatus {
        let process = try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            return process
        }
        return try await process.wait(timeoutInSeconds: timeoutInSeconds)
    }

    /// Resize a container's terminal (if one was requested).
    public func resizeContainer(_ containerID: String, to: Terminal.Size) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.resize(to: to)
        }
    }

    /// Execute a new process in a container.
    public func execInContainer(
        _ containerID: String,
        processID: String,
        configuration: @Sendable @escaping (inout LinuxProcessConfiguration) throws -> Void
    ) async throws -> LinuxProcess {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("execInContainer")

            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to exec"
                )
            }

            var spec = try self.generateRuntimeSpec(
                containerID: containerID,
                config: container.config,
                rootfs: container.rootfs,
                writableLayer: container.writableLayer,
                seccomp: container.seccomp,
                purpose: .exec
            )
            // Inherit environment variables, working directory, user, capabilities, rlimits from container process.
            // Reset: process arguments, terminal, stdio as these are not supposed to be inherited.
            var config = container.config.process
            config.arguments = []
            config.terminal = false
            config.stdin = nil
            config.stdout = nil
            config.stderr = nil
            try configuration(&config)
            spec.process = config.toOCI()

            let stdio = IOUtil.setup(
                portAllocator: self.hostVsockPorts,
                stdin: config.stdin,
                stdout: config.stdout,
                stderr: config.stderr
            )
            let agent = try await createdState.vm.dialAgent()
            let process = LinuxProcess(
                processID,
                containerID: containerID,
                spec: spec,
                io: stdio,
                portAllocator: self.hostVsockPorts,
                ociRuntimePath: self.config.ociRuntimePath,
                agent: agent,
                vm: createdState.vm,
                logger: self.logger
            )
            return process
        }
    }

    /// List all container IDs in the pod.
    public func listContainers() async -> [String] {
        await self.state.withLock { state in
            Array(state.containers.keys)
        }
    }

    /// The disk images the pod's machine holds, by host path: those of the
    /// volumes the pod declares and of the block volumes its containers
    /// brought, each held from when the machine attached it until the machine
    /// stops, whether or not a container still mounts it. A machine that is
    /// not running holds none. A caller deciding whether a volume is free
    /// asks this rather than the containers it knows of, since a volume
    /// outlives the container that brought it; the kubelet reports the
    /// volumes a node has in use apart from the pods that use them the same
    /// way.
    /// https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/node-v1/#NodeStatus
    public func heldDiskImages() async -> [String] {
        await self.state.withLock { state in
            guard case .created = state.phase else {
                return []
            }
            var paths = Set<String>()
            for volume in self.config.volumes {
                if case .diskImage(let path, _) = volume.source {
                    paths.insert(path.absolutePath())
                }
            }
            for volume in state.blockVolumes.values where volume.attachment != nil {
                paths.insert(volume.mount.source)
            }
            return paths.sorted()
        }
    }

    /// Get statistics for containers in the pod.
    public func statistics(containerIDs: [String]? = nil, categories: StatCategory = .all) async throws -> [ContainerStatistics] {
        let (createdState, ids) = try await self.state.withLock { state in
            let createdState = try state.phase.createdState("statistics")
            let ids = containerIDs ?? Array(state.containers.keys)
            return (createdState, ids)
        }

        let stats = try await createdState.vm.withAgent { agent in
            try await agent.containerStatistics(containerIDs: ids, categories: categories)
        }

        return stats
    }

    /// Dial a vsock port in the pod's VM.
    public func dialVsock(port: UInt32) async throws -> FileHandle {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("dialVsock")
            return try await createdState.vm.dial(port)
        }
    }

    /// Provides scoped access to the underlying virtual machine instance.
    ///
    /// Most users should prefer the higher level APIs on ``LinuxPod``
    /// directly. This is intended for advanced use cases that need to interact
    /// with the virtual machine outside of the pod abstraction.
    public func withVirtualMachineInstance<T: Sendable>(
        _ fn: @Sendable (any VirtualMachineInstance) async throws -> T
    ) async throws -> T {
        let vm = try await self.state.withLock { state in
            try state.phase.createdState("withVirtualMachineInstance").vm
        }
        return try await fn(vm)
    }

    // Perform filesystem operations in a container.
    public func filesystemOperation(_ containerID: String, operation: FilesystemOperation, path: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("filesystemOperation")

            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to perform filesystem operations"
                )
            }

            try await createdState.vm.withAgent { agent in
                guard let vminitd = agent as? Vminitd else {
                    throw ContainerizationError(.unsupported, message: "filesystemOperation requires Vminitd agent")
                }
                try await vminitd.filesystemOperation(operation: operation, path: path, containerID: containerID)
            }
        }
    }

    /// Default chunk size for file transfers (1MiB).
    public static let defaultCopyChunkSize = GuestFileTransfer.defaultChunkSize

    /// Copy a file or directory from the host into a container in the pod.
    ///
    /// Data transfer happens over a dedicated vsock connection. For
    /// directories, the source is archived as tar+gzip and streamed directly
    /// through vsock without intermediate temp files.
    public func copyIn(
        _ containerID: String,
        from source: URL,
        to destination: URL,
        mode: UInt32 = 0o644,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize
    ) async throws {
        try await self.state.withLock { state in
            try await self.transfer(containerID, state: state, operation: "copyIn").copyIn(
                from: source,
                to: destination,
                mode: mode,
                createParents: createParents,
                chunkSize: chunkSize
            )
        }
    }

    /// Copy a file or directory from a container in the pod to the host.
    ///
    /// Data transfer happens over a dedicated vsock connection. For
    /// directories, the guest archives the source as tar+gzip and streams it
    /// directly through vsock. The host extracts the archive without
    /// intermediate temp files.
    public func copyOut(
        _ containerID: String,
        from source: URL,
        to destination: URL,
        createParents: Bool = true,
        chunkSize: Int = defaultCopyChunkSize
    ) async throws {
        try await self.state.withLock { state in
            try await self.transfer(containerID, state: state, operation: "copyOut").copyOut(
                from: source,
                to: destination,
                createParents: createParents,
                chunkSize: chunkSize
            )
        }
    }

    /// A transfer against one container's filesystem, on a port of its own.
    private func transfer(_ containerID: String, state: State, operation: String) throws -> GuestFileTransfer {
        let createdState = try state.phase.createdState(operation)

        guard let container = state.containers[containerID] else {
            throw ContainerizationError(
                .notFound,
                message: "container \(containerID) not found in pod"
            )
        }

        guard container.state == .started else {
            throw ContainerizationError(
                .invalidState,
                message: "container \(containerID) must be started to copy files"
            )
        }

        return GuestFileTransfer(
            vm: createdState.vm,
            guestRoot: Self.guestRootfsPath(containerID),
            ports: self.hostVsockPorts,
            queue: self.copyQueue
        )
    }

    /// Close a container's standard input to signal no more input is arriving.
    public func closeContainerStdin(_ containerID: String) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.closeStdin()
        }
    }

    /// Relay a unix socket for a container.
    public func relayUnixSocket(_ containerID: String, socket: UnixSocketConfiguration) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("relayUnixSocket")

            guard let _ = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            try await createdState.vm.withAgent { agent in
                try await self.relayUnixSocket(
                    socket: socket,
                    containerID: containerID,
                    relayManager: createdState.relayManager,
                    agent: agent
                )
            }
        }
    }

    private func relayUnixSocket(
        socket: UnixSocketConfiguration,
        containerID: String,
        relayManager: UnixSocketRelayManager,
        agent: any VirtualMachineAgent
    ) async throws {
        guard let relayAgent = agent as? SocketRelayAgent else {
            throw ContainerizationError(
                .unsupported,
                message: "VirtualMachineAgent does not support relaySocket surface"
            )
        }

        var socket = socket

        // Adjust paths to be relative to the container's rootfs
        let rootInGuest = URL(filePath: Self.guestRootfsPath(containerID))

        let port: UInt32
        if socket.direction == .into {
            // Held for the lifetime of the relay, so it is deliberately never
            // released — the relay manager outlives this call.
            port = self.hostVsockPorts.allocate()
            socket.destination = URL(filePath: Self.guestSocketStagingPath(socket.id))
        } else {
            port = self.guestVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
            socket.source = rootInGuest.appending(path: socket.source.path)
        }

        try await relayManager.start(port: port, socket: socket)
        try await relayAgent.relaySocket(port: port, configuration: socket)
    }
}
