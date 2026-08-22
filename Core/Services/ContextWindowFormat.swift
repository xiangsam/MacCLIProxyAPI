import Foundation

/// Human-friendly context window formatting (`1M`, `272K`, raw tokens).
enum ContextWindowFormat {
    static func display(_ tokens: Int) -> String {
        guard tokens > 0 else { return "0" }
        if tokens % 1_000_000 == 0 {
            return "\(tokens / 1_000_000)M"
        }
        if tokens % 1_000 == 0 {
            let k = tokens / 1_000
            if k >= 1000, k % 1000 == 0 {
                return "\(k / 1000)M"
            }
            return "\(k)K"
        }
        // Near-million / near-thousand with small remainder → still show compact when close.
        if tokens >= 1_000_000 {
            let m = Double(tokens) / 1_000_000.0
            if abs(m.rounded() - m) < 0.001 {
                return "\(Int(m.rounded()))M"
            }
            let trimmed = String(format: "%.2f", m).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return "\(trimmed)M"
        }
        if tokens >= 1_000 {
            let k = Double(tokens) / 1_000.0
            if abs(k.rounded() - k) < 0.001 {
                return "\(Int(k.rounded()))K"
            }
            let trimmed = String(format: "%.1f", k).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return "\(trimmed)K"
        }
        return "\(tokens)"
    }

    /// Parse `1M`, `1.5M`, `272K`, `272k`, `1000000`, `1,000,000`.
    static func parse(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: " ", with: "")
        let upper = s.uppercased()
        if upper.hasSuffix("M") {
            let num = String(upper.dropLast())
            guard let value = Double(num), value > 0 else { return nil }
            return Int((value * 1_000_000).rounded())
        }
        if upper.hasSuffix("K") {
            let num = String(upper.dropLast())
            guard let value = Double(num), value > 0 else { return nil }
            return Int((value * 1_000).rounded())
        }
        guard let value = Int(upper), value > 0 else { return nil }
        return value
    }
}
