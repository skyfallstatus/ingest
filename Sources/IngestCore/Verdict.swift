import Foundation

/// The only place that can say a card is safe to format.
public enum CardVerdict: Hashable, Sendable {
    case empty                          // nothing on the card worth keeping
    case notSafe(remaining: Int, total: Int, reasons: [String])
    case hold([CardIssue])              // every byte verified, but a person must look first
    case safe
}

enum Verdict {
    /// Green requires all of it:
    /// the listing finished with no errors, every listed file opened, every file was proved identical by reading
    /// both sides, nothing is a blocker, and the card still lists exactly what was verified.
    static func evaluate(listing: CardListing, unreadable: [ListingError], states: [String: FileState],
                         issues: [CardIssue], cardUnchanged: Bool) -> CardVerdict {
        if listing.files.isEmpty && listing.errors.isEmpty && unreadable.isEmpty { return .empty }

        var reasons: [String] = listing.errors.map { "\($0.path): \($0.reason)" }
        reasons += unreadable.map { "\($0.path): \($0.reason)" }
        var remaining = 0
        for f in listing.files {
            switch states[f.relPath] {
            case .verified: break
            case .failed(let why): remaining += 1; reasons.append("\(f.relPath): \(why)")
            default: remaining += 1
            }
        }
        let blockers = issues.filter { $0.severity == .blocker }
        reasons += blockers.map(\.message)
        if !cardUnchanged { reasons.append("The card changed while it was being checked.") }

        let total = listing.files.count + listing.errors.count
        if remaining > 0 || !reasons.isEmpty {
            return .notSafe(remaining: remaining + listing.errors.count, total: total, reasons: reasons)
        }
        let holds = issues.filter { $0.severity == .hold }
        return holds.isEmpty ? .safe : .hold(holds)
    }
}
