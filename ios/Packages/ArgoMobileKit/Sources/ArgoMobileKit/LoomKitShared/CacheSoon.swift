import Foundation

/// FT129-03: the 「缓存 N 分」 hint of the 「等你回答」 panel and its order.
/// The page's sidebar rows use the same rule (web/js/usage.js
/// cacheSoonText); Fixtures/cache-soon.json pins both.
public enum CacheSoon {
    /// The hint shows once the prompt cache goes cold within this.
    public static let window: TimeInterval = 5 * 60

    /// A Go time (up to nine fractional digits) to a Date; nil when empty,
    /// unparsable or the zero time.
    public static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        var fraction = 0.0
        if let r = iso.range(of: #"\.\d+"#, options: .regularExpression) {
            fraction = Double("0" + iso[r]) ?? 0
        }
        let whole = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let date = ISO8601DateFormatter().date(from: whole),
              date > Date(timeIntervalSince1970: 946_684_800) else { return nil } // 2000-01-01: zero time
        return date.addingTimeInterval(fraction)
    }

    /// The pane head's minutes (rounded up) for a waiting Agent whose cache
    /// expires within `window`; "" otherwise.
    public static func text(state: String, expiresAt: String?, now: Date) -> String {
        guard state == "waiting", let at = date(expiresAt) else { return "" }
        let left = at.timeIntervalSince(now)
        guard left > 0, left <= window else { return "" }
        return "缓存 \(Int((left / 60).rounded(.up))) 分"
    }

    /// External Claude uses the same minute rounding as web cacheChip, with
    /// a persistent expired notice and the last input-side token estimate.
    public static func externalText(expiresAt: String?, tokens: Int?, now: Date) -> String {
        guard let at = date(expiresAt) else { return "" }
        let left = at.timeIntervalSince(now)
        if left > 0 { return "缓存 \(Int((left / 60).rounded(.up))) 分" }
        guard let tokens, tokens > 0 else { return "缓存已过期" }
        let amount = tokens < 10_000 ? "\(tokens)"
            : tokens < 100_000_000 ? String(format: "%.1f万", Double(tokens) / 10_000).replacingOccurrences(of: ".0万", with: "万")
            : String(format: "%.1f亿", Double(tokens) / 100_000_000).replacingOccurrences(of: ".0亿", with: "亿")
        return "缓存已过期，下一问会重读约 \(amount)"
    }

    /// Waiting entries with a still-warm cache first, the nearest expiry
    /// first; the rest keep their order after them. A team's questions share
    /// their run's expiry, so they stay together.
    public static func ordered(_ entries: [AttentionEntry], expiry: (AttentionEntry) -> Date?, now: Date) -> [AttentionEntry] {
        let keyed = entries.enumerated().map { (i, e) -> (Int, Date?, AttentionEntry) in
            let at = expiry(e).flatMap { $0 > now ? $0 : nil }
            return (i, at, e)
        }
        return keyed.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?): return x != y ? x < y : a.0 < b.0
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.0 < b.0
            }
        }.map(\.2)
    }
}
