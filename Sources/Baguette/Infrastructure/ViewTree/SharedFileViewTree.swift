import Foundation

/// `ViewTree` backed by the shared `/tmp` intent file plus the shared
/// `DYLD_INSERT_LIBRARIES` arming — the house pattern of
/// `SharedFileMotion`/`SharedFileNetwork`, with one difference: the
/// "intent" here is not state the dylib continuously applies but WHO the
/// probe's one target app is. The dylib's constructor reads it once to
/// decide whether to install its watcher at all (it loads into every
/// process the simulator launches, including launchctl and SpringBoard).
final class SharedFileViewTree: ViewTree, @unchecked Sendable {

    /// The request/response paths for `udid`. Same shared-`/tmp`,
    /// per-device convention as motion/network — every simulator sees the
    /// host's `/tmp`, so a single shared file would retarget the probe on
    /// one device out from under an app on another. The dylib builds these
    /// same paths from its own `SIMULATOR_UDID`.
    static func requestPath(forUDID udid: String) -> String {
        "/tmp/BaguetteViewTree-\(udid).json"
    }
    static func responsePath(forUDID udid: String) -> String {
        "/tmp/BaguetteViewTree-\(udid).dump.json"
    }

    private let requestURL: URL
    /// `nil` when this build didn't ship the dylib — arming then fails
    /// loudly rather than publishing an intent nobody reads.
    private let dylibPath: String?
    private let injection: any SimulatorInjection

    init(
        requestURL: URL,
        dylibPath: String?,
        injection: any SimulatorInjection = SimctlSimulatorInjection()
    ) {
        self.requestURL = requestURL
        self.dylibPath = dylibPath
        self.injection = injection
    }

    func arm(bundleId: String, on simulator: any Simulator) async throws {
        // Refuse before touching anything: an empty DYLD_INSERT_LIBRARIES
        // entry makes dyld log a load failure for every app launched
        // afterwards, and an intent nobody reads looks like success.
        guard let dylibPath, !dylibPath.isEmpty else { throw ViewTreeError.dylibMissing }
        let intent: [String: String] = ["bundleId": bundleId]
        let data = try JSONSerialization.data(withJSONObject: intent)
        try data.write(to: requestURL, options: .atomic)
        // Publish-then-arm, the same order as `SharedFileMotion.publish`:
        // an app launched the instant arming completes must read a
        // complete intent, never a half-written one.
        try await injection.arm(dylibPath: dylibPath, on: simulator)
    }

    func disarm(on simulator: any Simulator) async throws {
        // The intent file is deliberately left in place. Disarming only
        // stops *future* launches loading the dylib; an app already running
        // still has the watcher, and the file is also what `armed()`
        // reports from. Removing it would make a live watcher's target
        // unresolvable for no gain.
        guard let dylibPath, !dylibPath.isEmpty else { return }
        try await injection.disarm(dylibPath: dylibPath, on: simulator)
    }

    func armed() -> String? {
        guard let data = try? Data(contentsOf: requestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let bundleId = json["bundleId"], !bundleId.isEmpty
        else { return nil }
        return bundleId
    }
}

/// Failure modes the viewtree surface surfaces. Maps to a CLI exit message.
enum ViewTreeError: Error, Equatable, CustomStringConvertible {
    /// This build doesn't carry `ViewTreeProbe.dylib`, so there's nothing
    /// to inject and nothing would answer a dump request.
    case dylibMissing

    var description: String {
        switch self {
        case .dylibMissing:
            return "ViewTreeProbe.dylib is not bundled in this build"
        }
    }
}
