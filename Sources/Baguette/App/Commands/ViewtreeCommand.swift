import ArgumentParser
import Foundation

/// `baguette viewtree arm|disarm|status --udid <UDID> [--bundle <BUNDLE>]`
///
/// Arms or disarms the view-tree probe: apps launched while armed answer a
/// dump request with their own UIView hierarchy, pause-free. The
/// alternative — a debugger attach — SIGSTOPs the app for the whole dump.
///
/// Like `motion`, there is **no `simctl` verb behind this**, so the
/// surprise the help text must repeat: only apps launched **after**
/// `viewtree arm` carry the probe (dyld inserts at exec time). The dump
/// request itself is a file write any host process can make — this command
/// owns only the arming lifecycle.
struct ViewtreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "viewtree",
        abstract: "Arm the pause-free view-tree probe for apps on a simulator",
        discussion: """
            The probe is injected, not simulated by simctl: relaunch the target \
            app after `viewtree arm` or it won't carry the probe. Once running, \
            a dump is requested by rewriting the intent file \
            (/tmp/BaguetteViewTree-<udid>.json) with a fresh id — usually by \
            the calling tool, not by hand.
            """,
        subcommands: [Arm.self, Disarm.self, Status.self]
    )

    struct Arm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "arm",
            abstract: "Target one app and arm the probe (relaunch it afterwards)"
        )

        @OptionGroup var options: DeviceOption

        @Option(name: .customLong("bundle"), help: "Bundle id of the app to probe")
        var bundleId: String

        func validate() throws {
            guard !bundleId.isEmpty, bundleId.contains("."), !bundleId.hasPrefix("."), !bundleId.hasSuffix(".")
            else {
                throw ValidationError("'\(bundleId)' doesn't look like a bundle id (expect e.g. com.example.app).")
            }
        }

        func run() async throws {
            let simulator = try ViewtreeCommand.resolve(options)
            do {
                try await simulator.viewTree().arm(bundleId: bundleId, on: simulator)
            } catch {
                log("viewtree arm failed: \(error)")
                throw ExitCode.failure
            }
            log("View-tree probe armed on \(simulator.name) for \(bundleId). " +
                "Relaunch the app to pick it up.")
        }
    }

    struct Disarm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disarm",
            abstract: "Stop future app launches carrying the probe"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulator = try ViewtreeCommand.resolve(options)
            do {
                try await simulator.viewTree().disarm(on: simulator)
            } catch {
                log("viewtree disarm failed: \(error)")
                throw ExitCode.failure
            }
            log("View-tree probe disarmed on \(simulator.name). " +
                "Running apps keep their watcher until they exit.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the armed target bundle id, if any"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulator = try ViewtreeCommand.resolve(options)
            if let bundleId = simulator.viewTree().armed() {
                log("armed for \(bundleId) on \(simulator.name)")
            } else {
                log("not armed on \(simulator.name)")
                throw ExitCode.failure
            }
        }
    }

    private static func resolve(_ options: DeviceOption) throws -> any Simulator {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        return simulator
    }
}
