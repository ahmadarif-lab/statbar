import XCTest
@testable import StatKit

final class FormatTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(Format.percent(0.426), "43%")
        XCTAssertEqual(Format.percent(1), "100%")
        XCTAssertEqual(Format.percent(-0.1), "0%")
        XCTAssertEqual(Format.percent(nil), "–")
        XCTAssertEqual(Format.percent(.nan), "–")
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(1536), "1.5 KB")
        XCTAssertEqual(Format.bytes(16 * 1024 * 1024 * 1024), "16 GB")
        XCTAssertEqual(Format.bytes(128 * 1024 * 1024), "128 MB")
    }

    func testRate() {
        XCTAssertEqual(Format.rate(0), "0 B/s")
        XCTAssertEqual(Format.rate(1_258_291), "1.2 MB/s")
        XCTAssertEqual(Format.rate(1_258_291, compact: true), "1.2M")
        XCTAssertEqual(Format.rate(-5), "0 B/s")
        // Just under 1000 stays in the smaller unit; at 1000 it rolls over
        // so the menu bar never shows four digits.
        XCTAssertEqual(Format.rate(999), "999 B/s")
        XCTAssertEqual(Format.rate(1000), "1.0 KB/s")
    }

    func testOneDecimalRates() {
        XCTAssertEqual(Format.rate(70 * 1024, oneDecimal: true), "70 KB/s")
        XCTAssertEqual(Format.rate(41.4 * 1024, oneDecimal: true), "41.4 KB/s")
        XCTAssertEqual(Format.rate(69.97 * 1024, oneDecimal: true), "70 KB/s")
        XCTAssertEqual(Format.rate(1_258_291, oneDecimal: true), "1.2 MB/s")
        XCTAssertEqual(Format.rate(951, oneDecimal: true), "951 B/s")
        // 999.96 KB would print as "1000.0"; it rolls over to MB instead.
        XCTAssertEqual(Format.rate(999.96 * 1024, oneDecimal: true), "1 MB/s")
        // At or above 100 the decimal is dropped so the menu bar stays narrow.
        XCTAssertEqual(Format.rate(123.45 * 1024, oneDecimal: true), "123 KB/s")
        XCTAssertEqual(Format.rate(99.95 * 1024, oneDecimal: true), "100 KB/s")
    }

    func testBitRates() {
        XCTAssertEqual(Format.rate(1_250_000, oneDecimal: true, bits: true), "10 Mb/s")
        XCTAssertEqual(Format.rate(1_300_000, oneDecimal: true, bits: true), "10.4 Mb/s")
        XCTAssertEqual(Format.rate(100, bits: true), "800 b/s")
    }

    func testDuration() {
        XCTAssertEqual(Format.duration(59), "0m")
        XCTAssertEqual(Format.duration(3 * 3600 + 5 * 60), "3h 5m")
        XCTAssertEqual(Format.duration(2 * 86400 + 7 * 3600), "2d 7h")
        XCTAssertEqual(Format.longDuration(44 * 60), "0 hours, 44 minutes")
        XCTAssertEqual(Format.longDuration(86400 + 3600), "1 day, 1 hour")
    }

    func testHistoryKeepsNewestValues() {
        var history = History(capacity: 3)
        for value in 1...5 { history.append(Double(value)) }
        XCTAssertEqual(history.values, [3, 4, 5])
        XCTAssertEqual(history.peak, 5)
    }

    func testCPUUsageHandlesCounterWrap() {
        let old = [CPUSampler.Ticks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let new = [CPUSampler.Ticks(user: 10, system: 0, idle: 20, nice: 0)]
        let usage = CPUSampler.usage(from: old, to: new)
        XCTAssertEqual(usage.user, 0.5, accuracy: 0.0001)
        XCTAssertEqual(usage.cores, [0.5])
    }
}
