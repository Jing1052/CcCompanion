import Foundation

/// Server configuration used by the app and app group storage.
/// Phase multi-server fallback (2026-05-11): `serverURL` reads endpoint list and
/// current active index. `EndpointResolver` maintains the active endpoint.
nonisolated public enum CcServerConfig {
    public static let appGroup = "group.starryfield.cccompanion"

    private static let kServerURLList = "serverURLList"
    private static let kServerLabelList = "serverLabelList"
    private static let kServerActiveIndex = "serverActiveIndex"

    private static let placeholderURL = URL(string: "http://example.com:8795")!

    public static var endpoints: [(url: String, label: String)] {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return [] }
        let urls = defaults.stringArray(forKey: kServerURLList) ?? []
        let labels = defaults.stringArray(forKey: kServerLabelList) ?? []
        return urls.enumerated().map { idx, u in
            (url: u, label: idx < labels.count ? labels[idx] : "endpoint \(idx + 1)")
        }
    }

    public static func setEndpoints(_ list: [(url: String, label: String)]) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(list.map(\.url), forKey: kServerURLList)
        defaults.set(list.map(\.label), forKey: kServerLabelList)
        let active = max(0, min(activeIndex, list.count - 1))
        defaults.set(active, forKey: kServerActiveIndex)
    }

    public static var activeIndex: Int {
        UserDefaults(suiteName: appGroup)?.integer(forKey: kServerActiveIndex) ?? 0
    }

    public static func setActiveIndex(_ idx: Int) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(max(0, idx), forKey: kServerActiveIndex)
    }

    public static var serverURL: URL {
        let list = endpoints
        if !list.isEmpty {
            let idx = max(0, min(activeIndex, list.count - 1))
            if let u = URL(string: list[idx].url) { return u }
        }
        if let s = UserDefaults(suiteName: appGroup)?.string(forKey: "serverURL"),
           let u = URL(string: s) {
            return u
        }
        if let s = Bundle.main.infoDictionary?["CC_PUSH_SERVER"] as? String,
           let u = URL(string: s) {
            return u
        }
        return placeholderURL
    }

    public static var sharedSecret: String? {
        if let s = UserDefaults(suiteName: appGroup)?.string(forKey: "sharedSecret") {
            return s
        }
        return Bundle.main.infoDictionary?["CC_PUSH_SECRET"] as? String
    }

    public static func syncToAppGroup() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(serverURL.absoluteString, forKey: "serverURL")
        if let sharedSecret {
            defaults.set(sharedSecret, forKey: "sharedSecret")
        }
    }

    @discardableResult
    public static func migrateLegacySingleURLIfNeeded() -> Bool {
        guard endpoints.isEmpty else { return false }
        guard let defaults = UserDefaults(suiteName: appGroup) else { return false }
        var seed: [(url: String, label: String)] = []
        if let legacy = defaults.string(forKey: "serverURL"),
           !legacy.isEmpty,
           !legacy.contains("example.com") {
            seed.append((url: legacy, label: legacyLabel(for: legacy)))
        }
        guard !seed.isEmpty else { return false }
        setEndpoints(seed)
        setActiveIndex(0)
        return true
    }

    private static func legacyLabel(for url: String) -> String {
        if url.contains("100.") { return "Tailscale" }
        if url.contains("10.") || url.contains("192.168.") { return "LAN" }
        if url.contains("localhost") || url.contains("127.0.0.1") { return "Local" }
        return "Server"
    }
}
