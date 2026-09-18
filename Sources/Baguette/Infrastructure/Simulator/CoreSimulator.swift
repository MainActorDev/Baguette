import Foundation
import ObjectiveC

/// Production `Simulator` — owns identity + state plus the verbs that
/// touch the booted iOS guest. Resolves a fresh `SimDevice` via
/// `host.resolveDevice(udid:)` on each operation so we never act on a
/// stale `NSObject` (CoreSimulator returns a new one when state
/// changes; clients that cached the first ref get hit with `EBADF`-ish
/// errors on subsequent calls).
///
/// Constructed by `CoreSimulators.all` — this type is the only place
/// in the codebase that knows about CoreSimulator's `bootWithError:` /
/// `shutdownWithError:` selectors, and the only place that hands raw
/// UDIDs to `SimulatorKitScreen` / `IndigoHIDInput` /
/// `AXPTranslatorAccessibility` / `SimDeviceLogStream` /
/// `PurpleEventOrientation`.
final class CoreSimulator: Simulator, @unchecked Sendable {
    let udid: String
    let name: String
    let state: SimulatorState
    let runtime: String
    let deviceTypeName: String

    private let host: any DeviceHost

    init(
        udid: String,
        name: String,
        state: SimulatorState,
        runtime: String,
        deviceTypeName: String,
        host: any DeviceHost
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.deviceTypeName = deviceTypeName
        self.host = host
    }

    func boot() throws {
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }

        // Try bootWithOptions:error: first (headless boot, persists past disconnect).
        let bootOpts = NSSelectorFromString("bootWithOptions:error:")
        if device.responds(to: bootOpts) {
            var err: NSError?
            let opts: NSDictionary = ["persist": true]
            if invokeBoolWithObjAndError(device, bootOpts, opts, &err) { return }
            if let err { logErr("bootWithOptions failed: \(err)") }
        }

        let bootSel = NSSelectorFromString("bootWithError:")
        if device.responds(to: bootSel) {
            var err: NSError?
            if invokeBoolWithError(device, bootSel, &err) { return }
            if let err { logErr("bootWithError failed: \(err)") }
        }

        throw SimulatorError.bootFailed
    }

    func shutdown() throws {
        guard let device = host.resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        let sel = NSSelectorFromString("shutdownWithError:")
        guard device.responds(to: sel) else { throw SimulatorError.shutdownFailed }
        var err: NSError?
        guard invokeBoolWithError(device, sel, &err) else {
            if let err { logErr("shutdownWithError failed: \(err)") }
            throw SimulatorError.shutdownFailed
        }
    }

    func screen() -> any Screen {
        SimulatorKitScreen(udid: udid, host: host)
    }

    func input() -> any Input {
        IndigoHIDInput(udid: udid, host: host)
    }

    func displays() -> any Displays {
        SimulatorKitDisplays(udid: udid, host: host)
    }

    func externalDisplays() -> any ExternalDisplays {
        HostExternalDisplays(udid: udid)
    }

    func accessibility() -> any Accessibility {
        AXPTranslatorAccessibility(udid: udid, host: host)
    }

    func logs() -> any LogStream {
        SimDeviceLogStream(udid: udid, host: host)
    }

    func orientation() -> any Orientation {
        PurpleEventOrientation(udid: udid, host: host)
    }

    func statusBar() -> any StatusBar {
        SimctlStatusBar(udid: udid)
    }

    func interface() -> any Interface {
        SimctlInterface(udid: udid)
    }

    func location() -> any Location {
        SimctlLocation(udid: udid)
    }

    func shake() -> any Shake {
        SimctlShake(udid: udid)
    }

    /// Resolves the bundled `VirtualMotion.dylib` on the way through, since
    /// publishing an intent is useless without the dylib that reads it. A
    /// build that doesn't ship the dylib yields a handle whose `publish`
    /// throws `MotionError.dylibMissing` rather than silently doing nothing.
    func motion() -> any Motion {
        SharedFileMotion(
            fileURL: URL(fileURLWithPath: SharedFileMotion.path(forUDID: udid)),
            dylibPath: InjectedDylibInstaller.installIfNeeded(.motion),
            injection: SimctlSimulatorInjection()
        )
    }

    /// Resolves the bundled `VirtualNetwork.dylib` on the way through, since
    /// publishing a condition is useless without the dylib that applies it.
    /// A build that doesn't ship the dylib yields a handle whose `apply`
    /// throws `NetworkError.dylibMissing` rather than silently doing nothing
    /// — which for a throttle would be indistinguishable from working.
    func network() -> any Network {
        SharedFileNetwork(
            fileURL: URL(fileURLWithPath: SharedFileNetwork.path(forUDID: udid)),
            dylibPath: InjectedDylibInstaller.installIfNeeded(.network),
            injection: SimctlSimulatorInjection()
        )
    }

    /// Resolves the bundled `ViewTreeProbe.dylib` on the way through, since
    /// an armed probe is useless without the dylib that answers. A build
    /// that doesn't ship the dylib yields a handle whose `arm` throws
    /// `ViewTreeError.dylibMissing` rather than silently doing nothing.
    func viewTree() -> any ViewTree {
        SharedFileViewTree(
            requestURL: URL(fileURLWithPath: SharedFileViewTree.requestPath(forUDID: udid)),
            dylibPath: InjectedDylibInstaller.installIfNeeded(.viewTreeProbe),
            injection: SimctlSimulatorInjection()
        )
    }

    func pasteboard() -> any Pasteboard {
        SimctlPasteboard(udid: udid)
    }

    func apps() -> any Apps {
        SimctlApps(udid: udid)
    }

    func photos() -> any PhotoLibrary {
        SimctlPhotoLibrary(udid: udid)
    }

    func watchPairing() -> any WatchPairing {
        SimctlWatchPairing(udid: udid)
    }
}
