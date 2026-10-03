import Foundation

/// One scroll-wheel tick. `deltaX` / `deltaY` in points.
struct Scroll: Gesture, Equatable {
    static let wireType = "scroll"

    let deltaX: Double
    let deltaY: Double
    /// screen size in device points (same wire fields the positional
    /// gestures carry) — required to synthesize the pan coordinates
    let width: Double
    let height: Double

    static func parse(_ dict: [String: Any]) throws -> Scroll {
        Scroll(
            deltaX: Field.optionalDouble(dict, "deltaX", default: 0),
            deltaY: Field.optionalDouble(dict, "deltaY", default: 0),
            width: Field.optionalDouble(dict, "width", default: 0),
            height: Field.optionalDouble(dict, "height", default: 0)
        )
    }

    func execute(on input: any Input) -> Bool {
        // NO scroll-HID: IndigoHIDMessageForScrollEvent crashes backboardd
        // on this runtime — the router reads an unexpected target and
        // aborts, killing SpringBoard = the operator's "sim restarted on
        // scroll" (found live Sep 10, lionidas 1bfe056; regressed 2026-10-03
        // via the cockpit scroll-delta; re-confirmed twice tonight: 4-arg
        // AND 5-arg variants both abort).
        // The proven recipe: a 2-finger pan around the screen centre,
        // shifted by the (inverted) deltas — what the retired drive page
        // synthesized client-side, now owned by the child.
        guard width > 0, height > 0 else { return false }
        let cx = width / 2
        let cy = height / 2
        let spread: Double = 80
        // browser deltas are inverted vs iOS content scroll (drive-page parity)
        let endX1 = cx + spread - deltaX, endY1 = cy - deltaY
        let endX2 = cx - spread - deltaX, endY2 = cy - deltaY
        return input.twoFingerPath(
            start1: Point(x: cx + spread, y: cy), end1: Point(x: endX1, y: endY1),
            start2: Point(x: cx - spread, y: cy), end2: Point(x: endX2, y: endY2),
            size: Size(width: width, height: height), duration: 0.35
        )
    }
}
