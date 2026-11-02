import Foundation

/// Folder names that are safe on exFAT.
enum SafeName {
    private static let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    static let maxBytes = 200

    static func clean(_ name: String, maxBytes: Int = SafeName.maxBytes) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in name.unicodeScalars {
            if forbidden.contains(scalar) || scalar.properties.generalCategory == .control { continue }
            let isSpace = scalar == " "
            if isSpace && lastWasSpace { continue }
            lastWasSpace = isSpace
            scalars.append(scalar)
        }
        return trim(cap(String(scalars), maxBytes: maxBytes))
    }

    /// Cuts on a character boundary, so the result is still valid text.
    static func cap(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var out = ""
        var used = 0
        for character in name {
            let size = String(character).utf8.count
            guard used + size <= maxBytes else { break }
            out.append(character)
            used += size
        }
        return out
    }

    static func trim(_ name: String) -> String {
        var view = Substring(name)
        while let first = view.first, first == " " || first == "." { view.removeFirst() }
        while let last = view.last, last == " " || last == "." { view.removeLast() }
        return String(view)
    }
}
