import UIKit
import XCTest
@testable import StickerGeniOS

@MainActor
final class PetSkyPositionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: hour, minute: minute))!
    }

    func testSunMovesLeftToRightAndReachesItsHighestPointAtMidday() {
        let bounds = CGRect(x: 20, y: 40, width: 300, height: 220)
        let morning = PetSkyOrbit.position(at: date(hour: 8), isDay: true, in: bounds, calendar: calendar)
        let noon = PetSkyOrbit.position(at: date(hour: 12, minute: 30), isDay: true, in: bounds, calendar: calendar)
        let evening = PetSkyOrbit.position(at: date(hour: 17), isDay: true, in: bounds, calendar: calendar)
        XCTAssertLessThan(morning.x, noon.x)
        XCTAssertLessThan(noon.x, evening.x)
        XCTAssertLessThan(noon.y, morning.y)
        XCTAssertLessThan(noon.y, evening.y)
        XCTAssertEqual(noon.x, bounds.midX, accuracy: 0.01)
    }

    func testMoonMovesAcrossMidnightAndDayFallbackUsesLocalTime() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 220)
        let evening = PetSkyOrbit.position(at: date(hour: 21), isDay: false, in: bounds, calendar: calendar)
        let midnight = PetSkyOrbit.position(at: date(hour: 0), isDay: false, in: bounds, calendar: calendar)
        let dawn = PetSkyOrbit.position(at: date(hour: 4), isDay: false, in: bounds, calendar: calendar)
        XCTAssertLessThan(evening.x, midnight.x)
        XCTAssertLessThan(midnight.x, dawn.x)
        let earlyNight = PetSkyOrbit.position(at: date(hour: 18), isDay: false, in: bounds, calendar: calendar)
        XCTAssertLessThan(earlyNight.x, evening.x)
        let before = PetSkyOrbit.position(at: date(hour: 23, minute: 59), isDay: false, in: bounds, calendar: calendar)
        XCTAssertEqual(before.x, midnight.x, accuracy: 1)
        XCTAssertFalse(PetSkyOrbit.isDay(at: date(hour: 5), calendar: calendar))
        XCTAssertTrue(PetSkyOrbit.isDay(at: date(hour: 6), calendar: calendar))
        XCTAssertFalse(PetSkyOrbit.isDay(at: date(hour: 19), calendar: calendar))
        var hongKong = calendar
        hongKong.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        XCTAssertTrue(PetSkyOrbit.isDay(at: date(hour: 0), calendar: hongKong))
    }

    func testBodyFitsInsideCurvedPanesAndAvoidsTheCrossbar() throws {
        let image = room { context in
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 30, y: 30, width: 240, height: 240))
            context.setBlendMode(.normal)
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 140, y: 0, width: 20, height: 300))
            context.fill(CGRect(x: 0, y: 140, width: 300, height: 20))
        }
        let layout = PetWindowOpeningLayout(image: image, drawn: CGRect(x: 0, y: 0, width: 300, height: 300),
                                            bounds: CGSize(width: 300, height: 300))
        let left = try XCTUnwrap(layout.placement(near: CGPoint(x: 75, y: 90), preferredSide: 150))
        let right = try XCTUnwrap(layout.placement(near: CGPoint(x: 225, y: 90), preferredSide: 150))
        XCTAssertLessThan(left.center.x, 140)
        XCTAssertGreaterThan(right.center.x, 160)
        for placement in [left, right] {
            XCTAssertLessThan(placement.side, 150)
            let half = placement.side / 2
            XCTAssertLessThan(placement.center.y + half, 140)
            XCTAssertTrue(placement.center.x + half < 140 || placement.center.x - half > 160)
            for dx in [-half, half] {
                for dy in [-half, half] {
                    let x = (placement.center.x + dx - 150) / 120
                    let y = (placement.center.y + dy - 150) / 120
                    XCTAssertLessThan(x * x + y * y, 1)
                }
            }
        }
    }

    func testOpeningsRespectVerticalOrientationCroppingAndRoomShift() throws {
        let image = room { context in
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 100, y: 20, width: 100, height: 80))
        }
        let layout = PetWindowOpeningLayout(image: image, drawn: CGRect(x: -100, y: 10, width: 600, height: 300),
                                            bounds: CGSize(width: 300, height: 300))
        let placement = try XCTUnwrap(layout.placement(near: CGPoint(x: 200, y: 55), preferredSide: 60))
        XCTAssertEqual(layout.bounds.minX, 100, accuracy: 3)
        XCTAssertEqual(layout.bounds.minY, 30, accuracy: 3)
        XCTAssertLessThan(placement.center.y + placement.side / 2, 110)
        XCTAssertGreaterThan(placement.center.y - placement.side / 2, 30)
    }

    func testOpaqueRoomHasNoSafePlacement() {
        let layout = PetWindowOpeningLayout(image: room { _ in }, drawn: CGRect(x: 0, y: 0, width: 300, height: 300),
                                            bounds: CGSize(width: 300, height: 300))
        XCTAssertNil(layout.placement(near: CGPoint(x: 200, y: 60), preferredSide: 84))
    }

    func testFixedMoonMovesBetweenPanesWithoutShrinkingItsPaddedArtwork() throws {
        let image = room { context in
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 20, y: 30, width: 110, height: 120))
            context.fill(CGRect(x: 170, y: 30, width: 110, height: 120))
        }
        let layout = PetWindowOpeningLayout(image: image, drawn: CGRect(x: 0, y: 0, width: 300, height: 300),
                                            bounds: CGSize(width: 300, height: 300))
        // The artwork occupies 60 points inside a 240-point transparent sprite cell.
        let footprint = [CGPoint(x: -0.125, y: -0.125), CGPoint(x: 0.125, y: -0.125),
                         CGPoint(x: -0.125, y: 0.125), CGPoint(x: 0.125, y: 0.125)]
        let left = try XCTUnwrap(layout.fixedPlacement(near: CGPoint(x: 75, y: 90), side: 240, footprint: footprint))
        let right = try XCTUnwrap(layout.fixedPlacement(near: CGPoint(x: 225, y: 90), side: 240, footprint: footprint))
        XCTAssertEqual(left.side, 240)
        XCTAssertEqual(right.side, 240)
        XCTAssertLessThan(left.center.x + 30, 130)
        XCTAssertGreaterThan(right.center.x - 30, 170)
        XCTAssertLessThan(left.center.x, right.center.x)
    }

    func testNarrowWindowChangesOnlyTheFixedMoonsPosition() throws {
        let image = room { context in
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 40, y: 20, width: 60, height: 80))
        }
        let layout = PetWindowOpeningLayout(image: image, drawn: CGRect(x: 0, y: 0, width: 300, height: 300),
                                            bounds: CGSize(width: 300, height: 300))
        let placement = try XCTUnwrap(layout.fixedPlacement(near: CGPoint(x: 250, y: 250), side: 120,
                                                           footprint: PetSkyFootprint.moon))
        XCTAssertEqual(placement.side, 120)
        XCTAssertTrue(layout.bounds.contains(placement.center))
    }

    private func room(cut: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            cut(context)
        }
    }
}
