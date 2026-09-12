import Testing
import Foundation
import Mockable
@testable import Baguette

/// `POST /simulators/:udid/input` — the HTTP door to the gesture
/// pipeline, so a plugin subprocess can drive the device without
/// holding a WebSocket open. Same `GestureDispatcher` the stream socket
/// and `baguette input` use.
@Suite("Server input route")
struct InputRouteTests {

    @Test func `a key envelope is dispatched to the device's input`() async throws {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let outcome = await Server.dispatchInput(
            udid: "key-U",
            body: #"{"type":"key","code":"KeyR","modifiers":["command"]}"#,
            simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        #expect(ack.contains("\"ok\":true"))
        verify(input).key(.any, modifiers: .value([.command]), duration: .any).called(1)
    }

    @Test func `a tap envelope reaches the input as a tap`() async throws {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)

        let outcome = await Server.dispatchInput(
            udid: "tap-U",
            body: #"{"type":"tap","x":100,"y":200,"width":390,"height":844}"#,
            simulators: Self.simulators(input: input)
        )
        guard case .ok = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        verify(input).tap(at: .value(Point(x: 100, y: 200)), size: .any, duration: .any, edge: .any).called(1)
    }

    @Test func `an unknown device is reported`() async throws {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        let outcome = await Server.dispatchInput(
            udid: "nope", body: #"{"type":"tap","x":1,"y":1,"width":10,"height":10}"#,
            simulators: simulators
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `a malformed envelope comes back as a not-ok ack, not a crash`() async throws {
        let input = MockInput()
        let outcome = await Server.dispatchInput(
            udid: "malformed-U", body: "not json", simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok ack, got \(outcome)"); return }
        #expect(ack.contains("\"ok\":false"))
    }

    @Test func `a second gesture while one is in flight fails fast with a busy ack`() async throws {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        // Hold the gate as if a long type were mid-flight on this udid.
        // Dedicated udid: Swift Testing runs this suite's tests in
        // parallel, and "U" is already in use by the dispatch tests.
        #expect(Server.InputDispatchGate.tryAcquire(udid: "busy-hold"))
        defer { Server.InputDispatchGate.release(udid: "busy-hold") }

        let outcome = await Server.dispatchInput(
            udid: "busy-hold",
            body: #"{"type":"key","code":"KeyR"}"#,
            simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok ack, got \(outcome)"); return }
        #expect(ack.contains("device busy"))
        // The queued-behind gesture never reached the device.
        verify(input).key(.any, modifiers: .any, duration: .any).called(0)
    }

    @Test func `the gate frees after dispatch so the next gesture goes through`() async throws {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        let first = await Server.dispatchInput(
            udid: "gate-free",
            body: #"{"type":"key","code":"KeyR"}"#,
            simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack1) = first else { Issue.record("expected .ok, got \(first)"); return }
        #expect(ack1.contains("\"ok\":true"))
        #expect(!Server.InputDispatchGate.isBusy("gate-free"))

        let second = await Server.dispatchInput(
            udid: "gate-free",
            body: #"{"type":"key","code":"KeyR"}"#,
            simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack2) = second else { Issue.record("expected .ok, got \(second)"); return }
        #expect(ack2.contains("\"ok\":true"))
        verify(input).key(.any, modifiers: .any, duration: .any).called(2)
    }

    @Test func `the gate is per-simulator, not global`() async throws {
        let input = MockInput()
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

        #expect(Server.InputDispatchGate.tryAcquire(udid: "A"))
        defer { Server.InputDispatchGate.release(udid: "A") }

        let outcome = await Server.dispatchInput(
            udid: "B",
            body: #"{"type":"key","code":"KeyR"}"#,
            simulators: Self.simulators(input: input)
        )
        guard case .ok(let ack) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        #expect(ack.contains("\"ok\":true"))
    }

    // MARK: - helpers

    static func simulators(input: MockInput) -> MockSimulators {
        let sim = MockSimulator()
        given(sim).input().willReturn(input)
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        return simulators
    }
}
