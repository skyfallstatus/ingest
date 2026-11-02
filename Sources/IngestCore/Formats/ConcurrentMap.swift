import Foundation

/// Runs `body` over `items` on all cores. One result per item, in order: a body that returns nil keeps its slot.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], _ body: @Sendable @escaping (T) -> R) -> [R] {
    guard items.count > 1 else { return items.map(body) }
    let box = ResultBox<R>(items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let r = body(items[i])
        box.lock.lock(); box.out[i] = r; box.lock.unlock()
    }
    return box.out.compactMap { $0 }
}

private final class ResultBox<R>: @unchecked Sendable {
    var out: [R?]
    let lock = NSLock()
    init(_ n: Int) { out = Array(repeating: nil, count: n) }
}
