import XCTest
@testable import LivePhotoEngine

final class ClipTimingTests: XCTestCase {
    func testCenteredThreeSecondClipAndShiftedMarker() throws {
        let clip = try ClipTiming.make(sourceStart: 0, sourceDuration: 6,
                                       timestampMicroseconds: 4_000_000, framesPerSecond: 30, trim: true)
        XCTAssertEqual(clip.start, 2.5, accuracy: 0.0001)
        XCTAssertEqual(clip.duration, 3)
        XCTAssertEqual(clip.outputKeyTime, 1.5, accuracy: 0.0001)
    }

    func testBeginningAndEndDoNotExtendOutsideSource() throws {
        for timestamp: Int64 in [0, 100_000, 5_999_999] {
            let clip = try ClipTiming.make(sourceStart: 0, sourceDuration: 6,
                                           timestampMicroseconds: timestamp, framesPerSecond: 30, trim: true)
            XCTAssertGreaterThanOrEqual(clip.start, 0)
            XCTAssertLessThanOrEqual(clip.end, 6.00001)
            XCTAssertGreaterThanOrEqual(clip.outputKeyTime, 0)
            XCTAssertLessThan(clip.outputKeyTime, clip.duration)
        }
    }

    func testNonzeroTrackStartUsesOneTimeline() throws {
        let clip = try ClipTiming.make(sourceStart: 0.2, sourceDuration: 6,
                                       timestampMicroseconds: 4_200_000, framesPerSecond: 30, trim: true)
        XCTAssertEqual(clip.start, 2.7, accuracy: 0.034)
        XCTAssertEqual(clip.outputKeyTime, 1.5, accuracy: 0.034)
    }

    func testShortVideoIsNotPadded() throws {
        let clip = try ClipTiming.make(sourceStart: 0, sourceDuration: 1.2,
                                       timestampMicroseconds: nil, framesPerSecond: 30, trim: true)
        XCTAssertEqual(clip.start, 0)
        XCTAssertEqual(clip.duration, 1.2)
        XCTAssertFalse(clip.warnings.isEmpty)
    }

    func testFullClipKeepsDurationAndTimestamp() throws {
        let clip = try ClipTiming.make(sourceStart: 0, sourceDuration: 8,
                                       timestampMicroseconds: 3_000_000, framesPerSecond: 30, trim: false)
        XCTAssertEqual(clip.start, 0)
        XCTAssertEqual(clip.duration, 8)
        XCTAssertEqual(clip.outputKeyTime, 3, accuracy: 0.034)
    }

    func testOutOfRangeTimestampFallsBackWithWarning() throws {
        let clip = try ClipTiming.make(sourceStart: 0, sourceDuration: 4,
                                       timestampMicroseconds: Int64.max, framesPerSecond: 30, trim: false)
        XCTAssertEqual(clip.keyTime, 2, accuracy: 0.034)
        XCTAssertEqual(clip.warnings.count, 1)
    }

    func testInvalidDurationNeverCreatesZeroFrameTime() {
        for duration in [0.0, -1.0, 0.000001, Double.nan, Double.infinity, 121] {
            XCTAssertThrowsError(try ClipTiming.make(sourceStart: 0, sourceDuration: duration,
                                                      timestampMicroseconds: nil, framesPerSecond: 30, trim: true))
        }
    }
}
