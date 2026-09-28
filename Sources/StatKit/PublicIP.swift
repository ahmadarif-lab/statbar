import Foundation

public struct PublicIPInfo: Sendable, Equatable {
    public var address: String
    public var city: String?
    public var region: String?
    /// ISO 3166 code, e.g. "ID".
    public var countryCode: String?
    /// The network's owner, e.g. "AS7713 PT Telekomunikasi Indonesia".
    public var organization: String?

    public init(address: String, city: String? = nil, region: String? = nil,
                countryCode: String? = nil, organization: String? = nil) {
        self.address = address
        self.city = city
        self.region = region
        self.countryCode = countryCode
        self.organization = organization
    }

    /// Regional-indicator emoji for the country code, e.g. 🇮🇩.
    public var flag: String? {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
        let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 - 0x41 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    public var countryName: String? {
        countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    /// "Jakarta, Indonesia".
    public var location: String? {
        let parts = [city, countryName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Looks up this Mac's public address, and where it appears to be, from
/// ipinfo.io. It's the one reading StatBar can't take locally, so it only
/// runs when the user has it switched on.
public enum PublicIPLookup {
    private static let endpoint = URL(string: "https://ipinfo.io/json")!

    public static func fetch() async throws -> PublicIPInfo {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> PublicIPInfo {
        struct Payload: Decodable {
            let ip: String
            let city: String?
            let region: String?
            let country: String?
            let org: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return PublicIPInfo(
            address: payload.ip, city: payload.city, region: payload.region,
            countryCode: payload.country, organization: payload.org
        )
    }
}
