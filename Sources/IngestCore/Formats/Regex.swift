import Foundation

func regex(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern) }

/// Capture groups of the first match, or nil. Groups that matched nothing are empty.
func captures(_ re: NSRegularExpression?, _ s: String) -> [String]? {
    guard let re else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (1 ..< max(m.numberOfRanges, 1)).map {
        let r = m.range(at: $0)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}
