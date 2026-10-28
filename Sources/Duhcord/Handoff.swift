/// Carries a value from the background task that made it to the main thread. Safe because the sender never
/// touches the value again: it's handed over exactly once, not shared.
struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

/// A weak reference a background task can carry, only dereferenced back on the main thread.
struct WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}
