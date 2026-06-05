// SPDX-License-Identifier: MIT
import Foundation

/// A lock-guarded cache shared by value copies of an Apple dictionary.
/// All stored values used by this package are Sendable.
final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var map: [Key: Value] = [:]
    private var order: [Key] = []   // ascending recency; front = least-recently used

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let v = map[key] else { return nil }
        touch(key)
        return v
    }

    func insert(_ value: Value, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if map[key] == nil, map.count >= capacity, let evict = order.first {
            order.removeFirst()
            map[evict] = nil
        }
        map[key] = value
        touch(key)
    }

    private func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
