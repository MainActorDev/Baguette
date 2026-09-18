import Testing
import Foundation
import Mockable
@testable import Baguette

/// `SharedFileViewTree` lifecycle coverage, driven with
/// `MockSimulatorInjection` (the `SimctlSimulatorInjection` orchestration
/// itself is covered by its own suite).
@Suite("SharedFileViewTree")
struct SharedFileViewTreeTests {

    private static let dylib = "/builds/abc123/ViewTreeProbe.dylib"

    private func make(
        dylibPath: String? = SharedFileViewTreeTests.dylib
    ) -> (SharedFileViewTree, MockSimulatorInjection, MockSimulator, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("viewtree-\(UUID().uuidString).json")
        let injection = MockSimulatorInjection()
        given(injection).arm(dylibPath: .any, on: .any).willReturn(())
        given(injection).disarm(dylibPath: .any, on: .any).willReturn(())
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let surface = SharedFileViewTree(
            requestURL: url, dylibPath: dylibPath, injection: injection)
        return (surface, injection, sim, url)
    }

    @Test func `paths name the simulator, per house convention`() {
        // Every simulator sees the host's `/tmp`, so a single shared file
        // meant targeting one device would retarget the probe out from
        // under an app on another. Both sides derive this path — the dylib
        // from its own `SIMULATOR_UDID`.
        #expect(SharedFileViewTree.requestPath(forUDID: "ABC-123")
                    == "/tmp/BaguetteViewTree-ABC-123.json")
        #expect(SharedFileViewTree.responsePath(forUDID: "ABC-123")
                    == "/tmp/BaguetteViewTree-ABC-123.dump.json")
        #expect(SharedFileViewTree.requestPath(forUDID: "A")
                    != SharedFileViewTree.requestPath(forUDID: "B"))
    }

    @Test func `arm writes the intent BEFORE merging the dylib in`() async throws {
        // An app launched the instant arming completes must read a complete
        // intent — publish-then-arm, the same order SharedFileMotion uses.
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("viewtree-order-\(UUID().uuidString).json")
        let injection = MockSimulatorInjection()
        var intentAtArmTime: Data? = nil
        given(injection).arm(dylibPath: .any, on: .any).willProduce { _, _ in
            // Runs at arm time: what does the intent file hold RIGHT NOW?
            intentAtArmTime = try? Data(contentsOf: url)
        }
        let surface = SharedFileViewTree(
            requestURL: url, dylibPath: Self.dylib, injection: injection)
        try await surface.arm(bundleId: "com.example.app", on: sim)

        let data = try #require(intentAtArmTime)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["bundleId"] == "com.example.app")
    }

    @Test func `arm fails loudly when the build ships no dylib`() async throws {
        let (surface, injection, sim, _) = make(dylibPath: nil)
        await #expect(throws: ViewTreeError.dylibMissing) {
            try await surface.arm(bundleId: "com.example.app", on: sim)
        }
        // And nothing was merged into DYLD_INSERT_LIBRARIES.
        verify(injection).arm(dylibPath: .any, on: .any).called(0)
    }

    @Test func `armed() reports the written target and nil before arming`() async throws {
        let (surface, _, sim, _) = make()
        #expect(surface.armed() == nil)
        try await surface.arm(bundleId: "com.example.app", on: sim)
        #expect(surface.armed() == "com.example.app")
    }

    @Test func `disarm leaves the intent file in place`() async throws {
        // A running app's watcher still reads the file; `armed()` reports
        // from it. Removing it would orphan both for no gain.
        let (surface, injection, sim, _) = make()
        try await surface.arm(bundleId: "com.example.app", on: sim)
        try await surface.disarm(on: sim)
        #expect(surface.armed() == "com.example.app")
        verify(injection).disarm(dylibPath: .value(Self.dylib), on: .any).called(1)
    }
}
