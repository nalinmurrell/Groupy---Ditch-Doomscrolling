import Foundation
import Supabase

/// The one Supabase client, configured from `Supabase.plist`.
enum Backend {

    struct Config {
        let url: URL
        let anonKey: String
    }

    static let config: Config? = {
        guard let file = Bundle.main.url(forResource: "Supabase", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: file) as? [String: String],
              let urlString = dict["SUPABASE_URL"],
              let key = dict["SUPABASE_ANON_KEY"],
              urlString.hasPrefix("https://"),
              let url = URL(string: urlString),
              !key.isEmpty else { return nil }
        return Config(url: url, anonKey: key)
    }()

    static var isConfigured: Bool { config != nil }

    /// Built even when unconfigured so stores can hold a reference; nothing
    /// calls it before `RootView` has checked `isConfigured`.
    static let client: SupabaseClient = {
        let cfg = config ?? Config(url: URL(string: "https://unconfigured.invalid")!, anonKey: "unconfigured")
        return SupabaseClient(
            supabaseURL: cfg.url,
            supabaseKey: cfg.anonKey,
            options: .init(db: .init(encoder: encoder, decoder: decoder))
        )
    }()

    // Postgres timestamps come back with microseconds and an offset —
    // "2026-09-15T01:02:03.123456+00:00" — which Foundation's stock ISO8601
    // strategy rejects. This accepts that, and the no-fraction form too.
    static let decoder: JSONDecoder = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognised timestamp: \(raw)"
            ))
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
