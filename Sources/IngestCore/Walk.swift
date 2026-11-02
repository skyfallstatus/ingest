import CIngest
import Foundation

private final class WalkBox {
    let rootLen: Int
    var handler: (ci_entry, String) -> Int32
    init(rootLen: Int, handler: @escaping (ci_entry, String) -> Int32) { self.rootLen = rootLen; self.handler = handler }
}

/// `strict` is for cards: every failure is reported, at the cost of a stat per file.
/// `FileManager` silently hides entries on exFAT, so it must never be used for a card.
func walkTree(_ root: String, strict: Bool = false, _ handler: @escaping (ci_entry, String) -> Int32) {
    let trimmed = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
    let box = WalkBox(rootLen: trimmed.utf8.count + 1, handler: handler)
    let ctx = Unmanaged.passUnretained(box).toOpaque()
    let callback: ci_walk_cb = { entryPtr, ctx -> Int32 in
        guard let entryPtr, let ctx, let cPath = entryPtr.pointee.path else { return 0 }
        let box = Unmanaged<WalkBox>.fromOpaque(ctx).takeUnretainedValue()
        // The root itself has no relative path. It still has to be heard when it fails.
        let rel = strlen(cPath) >= box.rootLen ? String(cString: cPath + box.rootLen) : ""
        return box.handler(entryPtr.pointee, rel)
    }
    withExtendedLifetime(box) {
        if strict { ci_walk_strict(trimmed, callback, ctx) } else { ci_walk(trimmed, callback, ctx) }
    }
}
