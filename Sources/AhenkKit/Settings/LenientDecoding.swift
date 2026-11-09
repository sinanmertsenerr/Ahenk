import Foundation

// Settings are decoded field by field: a missing key (a setting added in a
// later version), a value of the wrong type or an unknown enum case falls
// back to that one field's default instead of failing the whole document.

extension KeyedDecodingContainer {
    /// The decoded value for `key`, or `fallback` when it is missing or invalid.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return value
    }

    /// An optional value; missing, `null` or invalid all decode to `nil`.
    func lenientOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// A number clamped into `range`; non-finite values use `fallback`.
    func lenient(_ key: Key, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        let value = lenient(key, fallback)
        return value.isFinite ? value.clamped(to: range) : fallback
    }

    /// An integer clamped into `range`.
    func lenient(_ key: Key, _ fallback: Int, in range: ClosedRange<Int>) -> Int {
        lenient(key, fallback).clamped(to: range)
    }

    /// A set of string-backed enum values, dropping unknown members instead
    /// of discarding the whole set.
    func lenientSet<T: RawRepresentable & Hashable>(_ key: Key, _ fallback: Set<T>) -> Set<T>
    where T.RawValue == String {
        guard let raw = try? decodeIfPresent([String].self, forKey: key) else { return fallback }
        return Set(raw.compactMap(T.init(rawValue:)))
    }

    /// An array of elements decoded one by one; invalid elements are dropped.
    func lenientArray<T: Decodable>(_ key: Key, _ fallback: [T]) -> [T] {
        guard contains(key), var items = try? nestedUnkeyedContainer(forKey: key) else { return fallback }
        var result: [T] = []
        while !items.isAtEnd {
            if let element = try? items.decode(T.self) {
                result.append(element)
            } else {
                // Step over the invalid element so the loop can continue.
                _ = try? items.decode(DiscardedValue.self)
            }
        }
        return result
    }
}

/// Decodes and throws away any JSON value.
private struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
