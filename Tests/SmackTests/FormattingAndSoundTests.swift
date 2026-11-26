import XCTest
@testable import Smack

final class FormattingAndSoundTests: XCTestCase {
    func testFormattingPercentAndRates_P1() {
        let zeroExpected = "\(0.0.formatted(.number.precision(.fractionLength(2))))%"
        let lowExpected = "\(3.456.formatted(.number.precision(.fractionLength(2))))%"
        let highExpected = "\(12.34.formatted(.number.precision(.fractionLength(1))))%"
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .memory
        byteFormatter.allowsNonnumericFormatting = false
        XCTAssertEqual(Formatting.percent(-5), zeroExpected)
        XCTAssertEqual(Formatting.percent(3.456), lowExpected)
        XCTAssertEqual(Formatting.percent(12.34), highExpected)
        XCTAssertEqual(Formatting.bytes(0), byteFormatter.string(fromByteCount: 0))
        XCTAssertEqual(Formatting.bytes(1_048_576), byteFormatter.string(fromByteCount: 1_048_576))
        XCTAssertEqual(Formatting.rate(-10), byteFormatter.string(fromByteCount: 0) + "/s")
        XCTAssertEqual(Formatting.rate(2_048), byteFormatter.string(fromByteCount: 2_048) + "/s")
    }

    func testFormattingDurationBoundaries_N1() {
        XCTAssertEqual(Formatting.duration(nil), "—")
        XCTAssertEqual(Formatting.duration(0), "—")
        XCTAssertEqual(Formatting.duration(-42), "—")
        XCTAssertEqual(Formatting.duration(.nan), "—")

        let expectedShort = DateComponentsFormatter()
        expectedShort.allowedUnits = [.minute, .second]
        expectedShort.unitsStyle = .abbreviated
        XCTAssertEqual(Formatting.duration(95), expectedShort.string(from: 95))

        let expectedLong = DateComponentsFormatter()
        expectedLong.allowedUnits = [.hour, .minute]
        expectedLong.unitsStyle = .abbreviated
        XCTAssertEqual(Formatting.duration(3_660), expectedLong.string(from: 3_660))
    }

    func testSmackSoundWavDataHeaderLengthAndDeterminism_P2() {
        let first = SmackSound.wavData()
        let second = SmackSound.wavData()
        let expectedSampleCount = Int(Double(44_100) * 0.22)

        XCTAssertEqual(first.count, 44 + expectedSampleCount * 2)
        XCTAssertEqual(first, second)
        XCTAssertEqual(String(decoding: first.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: first[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: first[36..<40], as: UTF8.self), "data")
        XCTAssertTrue(first.dropFirst(44).contains { $0 != 0 })
    }
}
