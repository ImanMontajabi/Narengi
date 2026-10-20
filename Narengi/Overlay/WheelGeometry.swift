import CoreGraphics
import Foundation

/// Path segments with y pointing up (AppKit orientation), relative to the wheel centre.
enum PetalCommand: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(c1: CGPoint, c2: CGPoint, to: CGPoint)
    case close
}

/// Radial wheel geometry: petal angles, hit testing, petal outlines, label positions, screen clamping.
/// Ported in behaviour from Satsuma's `geometry.rs` (MIT, © sonatina-dream), whose numbers come from the
/// original app's website demo. All angles are radians, counter-clockwise from +x, y up.
struct WheelGeometry: Equatable {
    /// Radius of the empty centre.
    var inner: CGFloat = 46
    /// Outer radius of the petals.
    var outer: CGFloat = 120
    /// Constant width of the gap between neighbouring petals.
    var gap: CGFloat = 4.5
    var outerCorner: CGFloat = 16
    var innerCorner: CGFloat = 6
    /// Radius of the glass backdrop disc.
    var backdrop: CGFloat = 127

    /// Side of the square that holds the whole wheel.
    static let viewSize: CGFloat = 272

    /// Centre angle of petal `i` of `n`. The first petal is at the top (on the left when n = 3),
    /// and the rest follow clockwise.
    static func petalAngle(_ i: Int, _ n: Int) -> Double {
        let start = n == 3 ? Double.pi : Double.pi / 2
        return start - 2 * Double.pi * Double(i) / Double(n)
    }

    private static func polar(_ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: r * CGFloat(cos(angle)), y: r * CGFloat(sin(angle)))
    }

    private func halfGapAngle(_ r: CGFloat) -> Double {
        let half = gap / 2
        return asin(min(0.95, Double(half / max(r, half + 0.01))))
    }

    /// Signed smallest difference a − b, in (−π, π].
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// Which petal (if any) lies under the offset (dx, dy) from the centre. Points in the gaps
    /// between petals, in the hub and outside the ring select nothing.
    func hitTest(dx: CGFloat, dy: CGFloat, count n: Int) -> Int? {
        guard n > 0 else { return nil }
        let d = hypot(dx, dy)
        guard d >= inner, d <= outer else { return nil }
        if n == 1 { return 0 }

        let angle = atan2(Double(dy), Double(dx))
        let step = 2 * Double.pi / Double(n)
        var fromFirst = (Self.petalAngle(0, n) - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if fromFirst < 0 { fromFirst += 2 * .pi }
        let i = Int((fromFirst / step).rounded()) % n
        let delta = abs(Self.angleDifference(angle, Self.petalAngle(i, n)))
        return delta > step / 2 - halfGapAngle(d) ? nil : i
    }

    /// Where petal `i`'s label is centred.
    func labelPosition(_ i: Int, _ n: Int) -> CGPoint {
        let r = inner + (outer - inner) * 0.5
        return Self.polar(r, Self.petalAngle(i, n))
    }

    /// Outline of petal `i` of `n` as a closed path (a full ring with a hole when n = 1).
    func petalPath(_ i: Int, _ n: Int) -> [PetalCommand] {
        guard n > 0 else { return [] }
        if n == 1 {
            var commands: [PetalCommand] = [.move(Self.polar(outer, 0))]
            Self.arc(&commands, outer, 0, 2 * .pi)
            commands.append(.close)
            commands.append(.move(Self.polar(inner, 0)))
            Self.arc(&commands, inner, 0, -2 * .pi)
            commands.append(.close)
            return commands
        }

        let mid = Self.petalAngle(i, n)
        let half = Double.pi / Double(n)
        let lo = mid - half  // clockwise-most edge
        let hi = mid + half
        let (ro, ri) = (outer, inner)

        // Keep corners from swallowing narrow petals.
        let spanOut = (hi - lo) - 2 * halfGapAngle(ro)
        let co = min(outerCorner, CGFloat(spanOut) * ro * 0.3, (ro - ri) * 0.4)
        let spanIn = (hi - lo) - 2 * halfGapAngle(ri)
        let ci = min(innerCorner, CGFloat(spanIn) * ri * 0.3, (ro - ri) * 0.2)

        func loAt(_ r: CGFloat) -> CGPoint { Self.polar(r, lo + halfGapAngle(r)) }
        func hiAt(_ r: CGFloat) -> CGPoint { Self.polar(r, hi - halfGapAngle(r)) }

        var c: [PetalCommand] = []
        c.append(.move(loAt(ri + ci)))
        c.append(.line(loAt(ro - co)))
        let a0 = lo + halfGapAngle(ro)
        Self.quad(&c, from: loAt(ro - co), control: loAt(ro), to: Self.polar(ro, a0 + Double(co / ro)))
        let a1 = hi - halfGapAngle(ro)
        Self.arc(&c, ro, a0 + Double(co / ro), a1 - Double(co / ro))
        Self.quad(&c, from: Self.polar(ro, a1 - Double(co / ro)), control: hiAt(ro), to: hiAt(ro - co))
        c.append(.line(hiAt(ri + ci)))
        let b1 = hi - halfGapAngle(ri)
        Self.quad(&c, from: hiAt(ri + ci), control: hiAt(ri), to: Self.polar(ri, b1 - Double(ci / ri)))
        let b0 = lo + halfGapAngle(ri)
        Self.arc(&c, ri, b1 - Double(ci / ri), b0 + Double(ci / ri))
        Self.quad(&c, from: Self.polar(ri, b0 + Double(ci / ri)), control: loAt(ri), to: loAt(ri + ci))
        c.append(.close)
        return c
    }

    /// Moves `anchor` so the whole wheel fits inside `bounds`; centres it when the bounds are too small.
    func clampAnchor(_ anchor: CGPoint, in bounds: CGRect) -> CGPoint {
        let margin = Self.viewSize / 2
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi)
        }
        return CGPoint(
            x: clamp(anchor.x, bounds.minX + margin, bounds.maxX - margin),
            y: clamp(anchor.y, bounds.minY + margin, bounds.maxY - margin))
    }

    // MARK: - Curve helpers

    private static func quad(_ c: inout [PetalCommand], from: CGPoint, control: CGPoint, to: CGPoint) {
        let c1 = CGPoint(x: from.x + 2.0 / 3.0 * (control.x - from.x), y: from.y + 2.0 / 3.0 * (control.y - from.y))
        let c2 = CGPoint(x: to.x + 2.0 / 3.0 * (control.x - to.x), y: to.y + 2.0 / 3.0 * (control.y - to.y))
        c.append(.curve(c1: c1, c2: c2, to: to))
    }

    /// Appends a circular arc from angle `a` to `b` (either direction) as cubic segments of at most 90°.
    private static func arc(_ c: inout [PetalCommand], _ r: CGFloat, _ a: Double, _ b: Double) {
        let total = b - a
        let segments = max(1, Int((abs(total) / (.pi / 2)).rounded(.up)))
        let step = total / Double(segments)
        for s in 0..<segments {
            let s0 = a + step * Double(s)
            let s1 = s0 + step
            let k = CGFloat(4.0 / 3.0 * tan(step / 4))
            let p0 = polar(r, s0), p3 = polar(r, s1)
            let c1 = CGPoint(x: p0.x - k * r * CGFloat(sin(s0)), y: p0.y + k * r * CGFloat(cos(s0)))
            let c2 = CGPoint(x: p3.x + k * r * CGFloat(sin(s1)), y: p3.y - k * r * CGFloat(cos(s1)))
            c.append(.curve(c1: c1, c2: c2, to: p3))
        }
    }
}

/// Keyboard navigation over the petals (wraps around).
enum WheelNavKey {
    case next, previous, first, last
}

enum WheelNavigation {
    static func navigate(selected: Int?, count n: Int, key: WheelNavKey) -> Int? {
        guard n > 0 else { return nil }
        switch key {
        case .first: return 0
        case .last: return n - 1
        case .next: return selected.map { ($0 + 1) % n } ?? 0
        case .previous: return selected.map { ($0 + n - 1) % n } ?? n - 1
        }
    }
}

/// Text in the wheel's hub while no petal is highlighted.
enum WheelCaption {
    /// Bytes as Finder shows them (decimal units): "823 KB", "1.2 MB", "143 MB".
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        if bytes < 1000 { return "\(bytes) bytes" }
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 999.95, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 || value >= 100 { return "\(Int(value.rounded())) \(units[unit])" }
        return String(format: "%.1f %@", value, units[unit])
    }

    /// Lines for the hub: the size for one file, "N ITEMS" above the size for several, "FOLDER" for a folder.
    static func lines(count: Int, totalBytes: UInt64?) -> [String] {
        let size = totalBytes.map(formatBytes)
        switch (count, size) {
        case (0, _): return []
        case (1, let s?): return [s]
        case (1, nil): return ["FOLDER"]
        case (let n, let s?): return ["\(n) ITEMS", s]
        case (let n, nil): return ["\(n) ITEMS"]
        }
    }
}
