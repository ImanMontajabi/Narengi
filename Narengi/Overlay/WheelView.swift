import SwiftUI

/// One rounded petal, drawn from `WheelGeometry.petalPath` (y-up) into SwiftUI's y-down space.
struct PetalShape: Shape {
    let geometry: WheelGeometry
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x, y: center.y - p.y) }
        var path = Path()
        for command in geometry.petalPath(index, count) {
            switch command {
            case .move(let p): path.move(to: map(p))
            case .line(let p): path.addLine(to: map(p))
            case .curve(let c1, let c2, let to): path.addCurve(to: map(to), control1: map(c1), control2: map(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject var settings: SettingsStore
    let geometry: WheelGeometry

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var size: CGFloat { WheelGeometry.viewSize }
    /// Denser, smaller labels once there are more than six petals.
    private var dense: Bool { model.items.count > 6 }

    var body: some View {
        ZStack {
            backdrop
            if model.items.isEmpty {
                emptyMessage
            } else {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    petal(index: index, item: item)
                }
                hub
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(model.isPresented ? 1 : (reduceMotion ? 1 : 0.82))
        .opacity(model.isPresented ? 1 : 0)
        .animation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.72), value: model.isPresented)
        .allowsHitTesting(false)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var backdrop: some View {
        let diameter = geometry.backdrop * 2
        switch settings.style {
        case .glass:
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.black.opacity(0.28)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        case .solid:
            Circle()
                .fill(Color(white: 0.11))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
        }
    }

    private func petal(index: Int, item: WheelItem) -> some View {
        let count = model.items.count
        let isHovered = model.hovered == index
        let label = geometry.labelPosition(index, count)
        let position = CGPoint(x: size / 2 + label.x, y: size / 2 - label.y)

        return ZStack {
            PetalShape(geometry: geometry, index: index, count: count)
                .fill(isHovered ? Theme.accent : Color.white.opacity(0.10), style: FillStyle(eoFill: true))
            labelView(for: item, hovered: isHovered)
                .position(position)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func labelView(for item: WheelItem, hovered: Bool) -> some View {
        VStack(spacing: 3) {
            if let symbol = item.symbol {
                Image(systemName: symbol).font(.system(size: dense ? 12 : 15, weight: .medium))
                Text(item.title).font(.system(size: dense ? 7.5 : 8.5, weight: .semibold)).tracking(0.5)
            } else {
                Text(item.title).font(.system(size: dense ? 11 : 13, weight: .bold))
            }
        }
        .foregroundStyle(hovered ? Color.white : Color.white.opacity(0.85))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: dense ? 52 : 64)
    }

    private var hub: some View {
        VStack(spacing: 2) {
            if let item = model.hoveredItem {
                Text(item.title)
                    .font(.system(size: 11, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            } else {
                ForEach(Array(model.captionLines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: index == 0 && model.captionLines.count > 1 ? 9 : 12, weight: .semibold))
                        .opacity(index == 0 && model.captionLines.count > 1 ? 0.65 : 1)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: geometry.inner * 2 - 14, height: geometry.inner * 2 - 14)
    }

    private var emptyMessage: some View {
        Text(model.emptyMessage)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 170)
    }
}
