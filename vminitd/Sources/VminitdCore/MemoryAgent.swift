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

import ArgumentParser
import ContainerizationOS
import Foundation
import Logging

/// The init arguments that ask vminitd to run mem-agent, which the host sets
/// through `Kernel.CommandLine.enableMemoryAgent`.
public struct MemoryAgentOption: ParsableArguments {
    @Flag(name: .customLong("mem-agent"), help: "Run mem-agent-srv beside the agent")
    public var enabled = false

    @Option(name: .customLong("mem-agent-arg"), parsing: .unconditionalSingleValue, help: "An argument for mem-agent-srv")
    public var arguments: [String] = []

    public init() {}

    /// These options as init arguments, for an agent this one starts.
    var initArgs: [String] {
        guard enabled else {
            return []
        }
        return ["--mem-agent"] + arguments.map { "--mem-agent-arg=\($0)" }
    }
}

/// Runs mem-agent-srv, the standalone program of the guest memory manager
/// Kata Containers links into its agent:
/// https://github.com/teawater/mem-agent/blob/4a2bed653ab6c0f8f87d99d505a2332c94613479/bin/srv/src/main.rs
///
/// It shares the agent's cgroup, as mem-agent shares kata-agent's process.
/// Kata fails its agent when mem-agent cannot start and only logs it when
/// mem-agent stops later; a separate process cannot tell the two apart, so
/// every exit is logged as an error and the agent carries on.
enum MemoryAgentProcess {
    static let path = "/sbin/mem-agent-srv"

    /// mem-agent-srv's socket for runtime changes. Its default is under
    /// /var/run, which the guest does not have.
    static let address = "unix:///run/mem-agent.sock"

    static func start(_ option: MemoryAgentOption, logLevel: Logger.Level, log: Logger) throws {
        // mem-agent checks the multi-gen LRU through debugfs when it starts,
        // and refuses to run without it. Mounted as systemd mounts it:
        // https://github.com/systemd/systemd/blob/main/units/sys-kernel-debug.mount
        let debugfs = ContainerizationOS.Mount(
            type: "debugfs",
            source: "debugfs",
            target: "/sys/kernel/debug",
            options: ["nosuid", "nodev", "noexec"]
        )
        try debugfs.mount(createWithPerms: 0o755)

        let runner = ProcessSupervisor.default.reaperCommandRunner
        var command = Command(
            path,
            arguments: ["--addr", address, "--log-level", Self.logLevel(logLevel)] + option.arguments
        )
        // mem-agent compacts through a child `sh`, found on PATH.
        command.environment = ["PATH=/usr/bin:/usr/sbin:/bin:/sbin"]
        command.stdout = .standardOutput
        command.stderr = .standardError
        let subscription = try runner.start(&command)
        log.info("started mem-agent-srv", metadata: ["pid": "\(command.pid)"])

        Task { [command] in
            do {
                let status = try await runner.wait(command, subscription: subscription)
                log.error("mem-agent-srv exited", metadata: ["status": "\(status)"])
            } catch {
                log.error("mem-agent-srv could not be waited on: \(error)")
            }
        }
    }

    /// slog's name for a level; slog has no notice, so notice is info.
    static func logLevel(_ level: Logger.Level) -> String {
        switch level {
        case .trace: "trace"
        case .debug: "debug"
        case .info, .notice: "info"
        case .warning: "warning"
        case .error: "error"
        case .critical: "critical"
        }
    }
}

#endif
