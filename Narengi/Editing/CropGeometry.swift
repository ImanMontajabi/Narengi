import CoreGraphics
import Foundation

/// Crop-window geometry: handles, aspect presets, drag rules and the saved spec. Rectangles are in image
/// pixels with a top-left origin. Behaviour (and the numbers the tests check) is ported from Satsuma's
/// `edit.rs` (MIT, © sonatina-dream), which matched the original app's demo.
enum CropGeometry {
    enum Handle: Equatable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    }

    /// Aspect presets shown in the Crop window, in order.
    static let aspects: [(name: String, ratio: (Int, Int)?)] = [
        ("Free", nil), ("1:1", (1, 1)), ("16:9", (16, 9)), ("9:16", (9, 16)), ("4:3", (4, 3)), ("3:4", (3, 4)),
    ]

    static func ratioValue(_ ratio: (Int, Int)) -> Double { Double(ratio.0) / Double(max(ratio.1, 1)) }

    /// What is under `point`: a handle within `tolerance`, the inside, or nothing.
    static func hitHandle(_ r: CGRect, at p: CGPoint, tolerance: Double) -> Handle? {
        let withinX = p.x >= r.minX - tolerance && p.x <= r.maxX + tolerance
        let withinY = p.y >= r.minY - tolerance && p.y <= r.maxY + tolerance
        guard withinX && withinY else { return nil }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }
        let l = near(p.x, r.minX), rr = near(p.x, r.maxX), t = near(p.y, r.minY), b = near(p.y, r.maxY)
        switch (l, rr, t, b) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .move
        }
    }

    /// The largest rectangle with `aspect` (w/h) that fits the image, centred where `current` is centred.
    static func fitAspect(_ current: CGRect, aspect: Double, bounds: CGSize) -> CGRect {
        var w = Double(bounds.width), h = w / aspect
        if h > Double(bounds.height) { h = Double(bounds.height); w = h * aspect }
        let x = min(max(Double(current.midX) - w / 2, 0), Double(bounds.width) - w)
        let y = min(max(Double(current.midY) - h / 2, 0), Double(bounds.height) - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Resizes around the centre to exactly `width`×`height` (clamped to the image), for typed sizes.
    static func setSize(_ current: CGRect, width: Double, height: Double, bounds: CGSize) -> CGRect {
        let w = min(max(width, 1), Double(bounds.width)), h = min(max(height, 1), Double(bounds.height))
        let x = min(max(Double(current.midX) - w / 2, 0), Double(bounds.width) - w)
        let y = min(max(Double(current.midY) - h / 2, 0), Double(bounds.height) - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Drags `handle` of `start` by (dx, dy) image pixels, keeping `aspect` if set, at least `min` pixels per
    /// side, and inside the image.
    static func drag(
        _ start: CGRect, handle: Handle, dx: Double, dy: Double, aspect: Double?, bounds: CGSize, min minimum: Double
    ) -> CGRect {
        let bw = Double(bounds.width), bh = Double(bounds.height)
        let minimum = Swift.min(minimum, bw, bh)
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(v, lo), hi) }
        if handle == .move {
            return CGRect(x: clamp(Double(start.minX) + dx, 0, bw - Double(start.width)),
                          y: clamp(Double(start.minY) + dy, 0, bh - Double(start.height)),
                          width: start.width, height: start.height)
        }
        var l = Double(start.minX), t = Double(start.minY), r = Double(start.maxX), b = Double(start.maxY)
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle)
        let movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle)
        let movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        if movesLeft { l = clamp(l + dx, 0, r - minimum) }
        if movesRight { r = clamp(r + dx, l + minimum, bw) }
        if movesTop { t = clamp(t + dy, 0, b - minimum) }
        if movesBottom { b = clamp(b + dy, t + minimum, bh) }
        guard let a = aspect else { return CGRect(x: l, y: t, width: r - l, height: b - t) }

        let cx = Double(start.midX), cy = Double(start.midY)
        if handle == .left || handle == .right {
            // Width drives; height follows around the vertical centre.
            var w = r - l
            let availH = 2 * Swift.min(cy, bh - cy)
            let availW = movesLeft ? Double(start.maxX) : bw - Double(start.minX)
            w = Swift.max(Swift.min(w, availH * a, availW), minimum)
            let h = w / a
            let (l2, r2) = movesLeft ? (Double(start.maxX) - w, Double(start.maxX)) : (Double(start.minX), Double(start.minX) + w)
            return CGRect(x: l2, y: cy - h / 2, width: r2 - l2, height: h)
        }
        if handle == .top || handle == .bottom {
            var h = b - t
            let availW = 2 * Swift.min(cx, bw - cx)
            let availH = movesTop ? Double(start.maxY) : bh - Double(start.minY)
            h = Swift.max(Swift.min(h, availW / a, availH), minimum)
            let w = h * a
            let (t2, b2) = movesTop ? (Double(start.maxY) - h, Double(start.maxY)) : (Double(start.minY), Double(start.minY) + h)
            return CGRect(x: cx - w / 2, y: t2, width: w, height: b2 - t2)
        }
        // Corner: anchor the opposite corner, grow to cover the drag, then fit the space.
        let anchorX = movesLeft ? Double(start.maxX) : Double(start.minX)
        let anchorY = movesTop ? Double(start.maxY) : Double(start.minY)
        var w = r - l, h = b - t
        if w / h > a { h = w / a } else { w = h * a }
        let availW = movesLeft ? anchorX : bw - anchorX
        let availH = movesTop ? anchorY : bh - anchorY
        if w > availW { w = availW; h = w / a }
        if h > availH { h = availH; w = h * a }
        return CGRect(x: movesLeft ? anchorX - w : anchorX, y: movesTop ? anchorY - h : anchorY, width: w, height: h)
    }

    /// Whole pixels, kept inside `bounds`.
    static func rounded(_ r: CGRect, bounds: CGSize) -> CGRect {
        let x = Swift.min(Swift.max(Double(r.minX).rounded(), 0), Double(bounds.width) - 1)
        let y = Swift.min(Swift.max(Double(r.minY).rounded(), 0), Double(bounds.height) - 1)
        let w = Swift.min(Swift.max(Double(r.width).rounded(), 1), Double(bounds.width) - x)
        let h = Swift.min(Swift.max(Double(r.height).rounded(), 1), Double(bounds.height) - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// A crop to apply: a rectangle as fractions of the image (so it also fits other images in a selection),
/// and an optional exact output size in pixels.
struct CropSpec: Sendable, Equatable {
    var rect: CGRect
    var output: CGSize?

    init(rect: CGRect, output: CGSize? = nil) {
        self.rect = rect
        self.output = output
    }

    static func fromPixels(_ r: CGRect, image: CGSize, output: CGSize? = nil) -> CropSpec {
        CropSpec(rect: CGRect(x: r.minX / image.width, y: r.minY / image.height, width: r.width / image.width, height: r.height / image.height), output: output)
    }

    func pixels(in image: CGSize) -> CGRect {
        CropGeometry.rounded(
            CGRect(x: rect.minX * image.width, y: rect.minY * image.height, width: rect.width * image.width, height: rect.height * image.height),
            bounds: image)
    }
}

// MARK: - Add Background

struct GradientPreset: Equatable, Sendable {
    let name: String
    /// Colour stops from top-left to bottom-right.
    let stops: [RGB]
}

struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double
    init(_ r: Int, _ g: Int, _ b: Int) { (self.r, self.g, self.b) = (Double(r) / 255, Double(g) / 255, Double(b) / 255) }
    /// Explicitly sRGB: `CGColor(red:green:blue:)` is Generic RGB and would shift in an sRGB bitmap.
    var cgColor: CGColor { CGColor(colorSpace: ImageOps.sRGB, components: [r, g, b, 1])! }
}

enum FrameBackground: Equatable, Sendable {
    case gradient(Int)
    case solid(RGB)
    case image(URL)
}

struct FrameSpec: Equatable, Sendable {
    static let gradients: [GradientPreset] = [
        GradientPreset(name: "Sunset", stops: [RGB(255, 94, 98), RGB(255, 140, 66), RGB(255, 200, 87)]),
        GradientPreset(name: "Citrus", stops: [RGB(247, 151, 30), RGB(255, 196, 0), RGB(255, 236, 140)]),
        GradientPreset(name: "Dream", stops: [RGB(251, 194, 235), RGB(190, 180, 250), RGB(166, 193, 238)]),
        GradientPreset(name: "Frost", stops: [RGB(240, 245, 252), RGB(214, 228, 244), RGB(196, 214, 238)]),
        GradientPreset(name: "Orchid", stops: [RGB(218, 34, 255), RGB(173, 60, 240), RGB(120, 70, 230)]),
        GradientPreset(name: "Ember", stops: [RGB(241, 39, 17), RGB(245, 110, 30), RGB(245, 175, 25)]),
        GradientPreset(name: "Lagoon", stops: [RGB(67, 198, 172), RGB(40, 120, 160), RGB(25, 22, 84)]),
        GradientPreset(name: "Aqua", stops: [RGB(128, 208, 199), RGB(60, 150, 190), RGB(19, 84, 122)]),
        GradientPreset(name: "Meadow", stops: [RGB(168, 224, 99), RGB(110, 190, 80), RGB(60, 140, 70)]),
    ]

    static let solids: [(name: String, color: RGB)] = [
        ("White", RGB(255, 255, 255)), ("Yellow", RGB(250, 204, 21)), ("Lime", RGB(132, 204, 22)), ("Green", RGB(34, 160, 90)),
        ("Teal", RGB(20, 150, 140)), ("Cyan", RGB(34, 200, 220)), ("Blue", RGB(37, 99, 235)), ("Navy", RGB(23, 37, 84)),
        ("Purple", RGB(126, 58, 220)), ("Black", RGB(12, 12, 14)),
    ]

    /// Canvas ratios offered by Add Background; nil is Auto (padding on every side).
    static let ratios: [(name: String, ratio: (Int, Int)?)] = [("Auto", nil), ("1:1", (1, 1)), ("16:9", (16, 9)), ("4:3", (4, 3))]

    var background: FrameBackground = .gradient(0)
    /// Space around the photo, in output pixels.
    var padding: Double
    /// Corner radius of the photo, in pixels.
    var corners: Double
    /// Shadow blur radius, in pixels (0 = none).
    var shadow: Double
    var ratio: (Int, Int)?

    static func == (l: FrameSpec, r: FrameSpec) -> Bool {
        l.background == r.background && l.padding == r.padding && l.corners == r.corners && l.shadow == r.shadow
            && l.ratio?.0 == r.ratio?.0 && l.ratio?.1 == r.ratio?.1
    }

    /// Starting values scaled to the photo.
    static func defaults(for image: CGSize) -> FrameSpec {
        let long = Double(max(image.width, image.height)), short = Double(min(image.width, image.height))
        return FrameSpec(padding: (long * 0.08).rounded(), corners: (short * 0.03).rounded(), shadow: max((long * 0.012).rounded(), 4), ratio: nil)
    }

    /// Slider maxima for an image: (padding, corners, shadow).
    static func limits(for image: CGSize) -> (padding: Double, corners: Double, shadow: Double) {
        let long = Double(max(image.width, image.height)), short = Double(min(image.width, image.height))
        return ((long * 0.5).rounded(), (short * 0.5).rounded(), max((long * 0.06).rounded(), 20))
    }

    /// Canvas size and where the photo goes, for an image of `image` pixels.
    static func layout(image: CGSize, padding: Double, ratio: (Int, Int)?) -> (canvas: CGSize, photo: CGRect) {
        let p = max(padding, 0)
        var cw = Double(image.width) + 2 * p, ch = Double(image.height) + 2 * p
        if let ratio {
            let a = CropGeometry.ratioValue(ratio)
            if cw / ch > a { ch = cw / a } else { cw = ch * a }
        }
        cw = cw.rounded(); ch = ch.rounded()
        let photo = CGRect(x: ((cw - Double(image.width)) / 2).rounded(), y: ((ch - Double(image.height)) / 2).rounded(),
                           width: image.width, height: image.height)
        return (CGSize(width: cw, height: ch), photo)
    }
}
