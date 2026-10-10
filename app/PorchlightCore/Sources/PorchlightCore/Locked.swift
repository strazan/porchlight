import Foundation

/// A value shared with `@Sendable` callbacks, guarded by a lock.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) { stored = value }

    public var value: Value { lock.withLock { stored } }

    public func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&stored) }
    }
}
