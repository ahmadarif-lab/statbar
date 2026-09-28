import XCTest
@testable import StatKit

final class PublicIPTests: XCTestCase {
    func testParsesIpinfoPayload() throws {
        let json = #"{"ip":"182.6.76.33","city":"Jakarta","region":"Jakarta","country":"ID","org":"AS7713 PT Telkom"}"#
        let info = try PublicIPLookup.parse(Data(json.utf8))
        XCTAssertEqual(info.address, "182.6.76.33")
        XCTAssertEqual(info.countryCode, "ID")
        XCTAssertEqual(info.flag, "🇮🇩")
        XCTAssertEqual(info.organization, "AS7713 PT Telkom")
    }

    func testMissingFieldsAreOptional() throws {
        let info = try PublicIPLookup.parse(Data(#"{"ip":"1.2.3.4"}"#.utf8))
        XCTAssertNil(info.flag)
        XCTAssertNil(info.location)
    }

    func testFlagNeedsTwoLetters() {
        XCTAssertNil(PublicIPInfo(address: "x", countryCode: "IDN").flag)
        XCTAssertEqual(PublicIPInfo(address: "x", countryCode: "au").flag, "🇦🇺")
    }
}

/// Hits the network, so it only runs with STATBAR_LIVE_TESTS=1.
final class LiveNetworkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STATBAR_LIVE_TESTS"] == "1", "set STATBAR_LIVE_TESTS=1")
    }

    func testPublicIPLookup() async throws {
        let info = try await PublicIPLookup.fetch()
        print("public IP:", info.address, info.flag ?? "-", info.location ?? "-", info.organization ?? "-")
        XCTAssertFalse(info.address.isEmpty)
    }

    func testLatency() async {
        let latency = await LatencyProbe.measure(host: "1.1.1.1")
        print("latency 1.1.1.1:", latency.map { "\(Int($0 * 1000)) ms" } ?? "nil")
        XCTAssertNotNil(latency)
        let unreachable = await LatencyProbe.measure(host: "no-such-host.invalid", timeout: 3)
        XCTAssertNil(unreachable)
    }

    func testInterfacesListed() {
        let interfaces = NetworkSampler.availableInterfaces()
        print("interfaces:", interfaces.map { "\($0.id)=\($0.name)" })
        XCTAssertFalse(interfaces.isEmpty)
    }
}
