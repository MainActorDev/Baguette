import Foundation
import Mockable

/// A booted simulator's view-tree probe surface: arm the injected dylib so
/// apps launched from now on can dump their own view hierarchy on request,
/// and disarm to stop future launches carrying it.
///
/// Same shape as `Motion`/`Network`: no `simctl` verb exists behind this,
/// the only way to read another app's UIKit hierarchy without a debugger
/// attach (which SIGSTOPs the app) is a dylib injected into the app under
/// test. The production impl is `SharedFileViewTree` (Infrastructure).
///
/// Arming writes the intent file (which app to probe) FIRST, then merges
/// the dylib into `DYLD_INSERT_LIBRARIES` — publish-then-arm, the same
/// order `SharedFileMotion.publish` uses, so an app launched the instant
/// arming completes reads a complete intent.
@Mockable
protocol ViewTree: AnyObject, Sendable {
    /// Write the probe intent for `bundleId` and arm the dylib.
    func arm(bundleId: String, on simulator: any Simulator) async throws

    /// Disarm the dylib. Apps launched afterwards never load it. An app
    /// **already running** keeps its watcher until it exits — harmless, it
    /// only reads a file nobody will rewrite.
    func disarm(on simulator: any Simulator) async throws

    /// The bundle id currently targeted, or `nil` when nothing is armed.
    func armed() -> String?
}
