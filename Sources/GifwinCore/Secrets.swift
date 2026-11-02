import Foundation

/// Recognises text that looks like a credential or personal data. Pattern-based and deliberately
/// conservative about false negatives rather than false positives: a masked commit hash is an annoyance,
/// a leaked API key is not. It is best effort, not a guarantee, and says so in the manifest.
public enum Secrets {
    public struct Match: Equatable, Sendable {
        public var range: Range<String.Index>
        public var kind: String
    }

    private struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// Capture group to mask, or 0 for the whole match.
        let group: Int
    }

    private static let rules: [Rule] = {
        let table: [(String, String, Int)] = [
            ("aws_key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, 0),
            ("github_token", #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, 0),
            ("github_token", #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, 0),
            ("api_key", #"\bsk-[A-Za-z0-9_\-]{20,}"#, 0),
            ("slack_token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, 0),
            ("stripe_key", #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\b"#, 0),
            ("google_key", #"\bAIza[0-9A-Za-z_\-]{30,}"#, 0),
            ("jwt", #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, 0),
            ("bearer_token", #"(?i)\bbearer\s+([A-Za-z0-9._~+/=\-]{16,})"#, 1),
            ("private_key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, 0),
            ("email", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, 0),
            ("credential", #"(?i)\b(?:password|passwd|pwd|secret|token|api[_\-]?key|apikey)\b\s*[:=]\s*(\S{6,})"#, 1),
        ]
        return table.compactMap { kind, pattern, group in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(kind: kind, regex: $0, group: group) }
        }
    }()

    private static let cardCandidate = try! NSRegularExpression(pattern: #"(?<![\d])(?:\d[ \-]?){13,19}(?![\d])"#)

    public static func matches(in text: String) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Match] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: whole) {
                let r = m.range(at: rule.group == 0 || m.numberOfRanges <= rule.group ? 0 : rule.group)
                if let range = Range(r, in: text) { found.append(Match(range: range, kind: rule.kind)) }
            }
        }
        for m in cardCandidate.matches(in: text, range: whole) {
            guard let range = Range(m.range, in: text) else { continue }
            let digits = text[range].filter(\.isNumber)
            if (13...19).contains(digits.count), luhn(digits) { found.append(Match(range: range, kind: "card_number")) }
        }
        return merged(found)
    }

    /// `text` with every match replaced by `[REDACTED]`.
    public static func mask(_ text: String) -> (text: String, count: Int) {
        let hits = matches(in: text)
        guard !hits.isEmpty else { return (text, 0) }
        var out = text
        for hit in hits.reversed() { out.replaceSubrange(hit.range, with: "[REDACTED]") }
        return (out, hits.count)
    }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// Overlapping matches become one, so the same characters are not masked twice.
    private static func merged(_ matches: [Match]) -> [Match] {
        var out: [Match] = []
        for m in matches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = out.last, m.range.lowerBound < last.range.upperBound {
                if m.range.upperBound > last.range.upperBound { out[out.count - 1].range = last.range.lowerBound..<m.range.upperBound }
            } else {
                out.append(m)
            }
        }
        return out
    }
}
