import XCTest
@testable import Narengi

final class WheelGeometryTests: XCTestCase {
    private let g = WheelGeometry()

    private func polar(_ r: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: r * CGFloat(cos(angle)), y: r * CGFloat(sin(angle)))
    }

    func testFirstPetalIsAtTheTopAndOrderIsClockwise() {
        let a0 = WheelGeometry.petalAngle(0, 6)
        let a1 = WheelGeometry.petalAngle(1, 6)
        XCTAssertEqual(a0, .pi / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(cos(a1), 0, "the next petal sits to the right of the top one")
        XCTAssertLessThan(a1, a0)
    }

    func testThreePetalsStartOnTheLeft() {
        XCTAssertEqual(WheelGeometry.petalAngle(0, 3), .pi, accuracy: 1e-9)
        XCTAssertEqual(WheelGeometry.petalAngle(1, 3), .pi / 3, accuracy: 1e-9)
    }

    func testPetalCentresHitTheirOwnIndex() {
        for n in 1...12 {
            for i in 0..<n {
                let p = polar((g.inner + g.outer) / 2, WheelGeometry.petalAngle(i, n))
                XCTAssertEqual(g.hitTest(dx: p.x, dy: p.y, count: n), i, "n=\(n) i=\(i)")
            }
        }
    }

    func testHubOutsideAndGapsHitNothing() {
        XCTAssertNil(g.hitTest(dx: 0, dy: 0, count: 6))
        XCTAssertNil(g.hitTest(dx: 10, dy: 10, count: 6))
        XCTAssertNil(g.hitTest(dx: 200, dy: 0, count: 6))
        XCTAssertNil(g.hitTest(dx: 1, dy: 80, count: 0))
        // Exactly on the boundary ray between petal 0 and 1.
        let boundary = WheelGeometry.petalAngle(0, 6) - .pi / 6
        let p = polar(80, boundary)
        XCTAssertNil(g.hitTest(dx: p.x, dy: p.y, count: 6))
    }

    func testSixAudioFormatLayoutMatchesTheRecording() {
        XCTAssertEqual(g.hitTest(dx: 0, dy: 90, count: 6), 0)      // top
        XCTAssertEqual(g.hitTest(dx: 70, dy: 45, count: 6), 1)     // upper right
        XCTAssertEqual(g.hitTest(dx: -70, dy: 45, count: 6), 5)    // upper left
    }

    func testPetalPathsAreClosedAndStayInsideTheRing() {
        for n in 1...10 {
            for i in 0..<n {
                let path = g.petalPath(i, n)
                guard case .move? = path.first, case .close? = path.last else { return XCTFail("n=\(n) i=\(i) not closed") }
                for command in path {
                    let points: [CGPoint]
                    switch command {
                    case .move(let p), .line(let p): points = [p]
                    case .curve(_, _, let to): points = [to]
                    case .close: points = []
                    }
                    for p in points {
                        let r = hypot(p.x, p.y)
                        XCTAssertLessThanOrEqual(r, g.outer + 1e-6, "n=\(n) i=\(i)")
                        XCTAssertGreaterThanOrEqual(r, g.inner - 1e-6, "n=\(n) i=\(i)")
                    }
                }
            }
        }
    }

    func testLabelsSitInsideTheirPetals() {
        for n in 1...10 {
            for i in 0..<n {
                let p = g.labelPosition(i, n)
                XCTAssertEqual(g.hitTest(dx: p.x, dy: p.y, count: n), i)
            }
        }
    }

    func testAnchorIsClampedSoTheWheelNeverClips() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(g.clampAnchor(CGPoint(x: 5, y: 5), in: bounds), CGPoint(x: 136, y: 136))
        XCTAssertEqual(g.clampAnchor(CGPoint(x: 500, y: 400), in: bounds), CGPoint(x: 500, y: 400))
        XCTAssertEqual(g.clampAnchor(CGPoint(x: 999, y: 799), in: bounds), CGPoint(x: 864, y: 664))
        // A screen smaller than the wheel centres it instead of crashing.
        XCTAssertEqual(g.clampAnchor(CGPoint(x: 0, y: 0), in: CGRect(x: 0, y: 0, width: 100, height: 100)), CGPoint(x: 50, y: 50))
    }

    func testAngleDifferenceWraps() {
        XCTAssertEqual(WheelGeometry.angleDifference(0.1, 2 * .pi - 0.1), 0.2, accuracy: 1e-9)
        XCTAssertEqual(WheelGeometry.angleDifference(-.pi + 0.1, .pi - 0.1), 0.2, accuracy: 1e-9)
    }

    // MARK: Keyboard navigation and hub text

    func testKeyboardNavigationWraps() {
        XCTAssertEqual(WheelNavigation.navigate(selected: 5, count: 6, key: .next), 0)
        XCTAssertEqual(WheelNavigation.navigate(selected: 0, count: 6, key: .previous), 5)
        XCTAssertEqual(WheelNavigation.navigate(selected: nil, count: 6, key: .next), 0)
        XCTAssertEqual(WheelNavigation.navigate(selected: nil, count: 6, key: .previous), 5)
        XCTAssertEqual(WheelNavigation.navigate(selected: 2, count: 6, key: .last), 5)
        XCTAssertEqual(WheelNavigation.navigate(selected: 2, count: 6, key: .first), 0)
        XCTAssertNil(WheelNavigation.navigate(selected: 0, count: 0, key: .next))
    }

    func testByteFormattingMatchesFinder() {
        XCTAssertEqual(WheelCaption.formatBytes(12), "12 bytes")
        XCTAssertEqual(WheelCaption.formatBytes(823_400), "823 KB")
        XCTAssertEqual(WheelCaption.formatBytes(1_234_567), "1.2 MB")
        XCTAssertEqual(WheelCaption.formatBytes(143_000_000), "143 MB")
        XCTAssertEqual(WheelCaption.formatBytes(999_960), "1.0 MB")
        XCTAssertEqual(WheelCaption.formatBytes(4_500_000_000), "4.5 GB")
    }

    func testHubCaptions() {
        XCTAssertEqual(WheelCaption.lines(count: 1, totalBytes: 1_200_000), ["1.2 MB"])
        XCTAssertEqual(WheelCaption.lines(count: 3, totalBytes: 4_500_000), ["3 ITEMS", "4.5 MB"])
        XCTAssertEqual(WheelCaption.lines(count: 1, totalBytes: nil), ["FOLDER"])
        XCTAssertEqual(WheelCaption.lines(count: 2, totalBytes: nil), ["2 ITEMS"])
        XCTAssertTrue(WheelCaption.lines(count: 0, totalBytes: nil).isEmpty)
    }
}
