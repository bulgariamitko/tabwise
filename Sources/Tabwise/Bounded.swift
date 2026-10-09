import Foundation

/// File access that can't freeze the app. Folders in Dropbox, iCloud Drive and other cloud storage are served by
/// File Provider: a read there may first download the file, and when the provider stalls it can wait for minutes or
/// never return. On the main thread that freezes the whole window. `Bounded.run` does the work on a background
/// thread and gives up after `timeout`, returning `fallback`; a stuck read is left to finish on its own.
enum Bounded {
    private static let queue = DispatchQueue(label: "tabwise.bounded-io", qos: .userInitiated, attributes: .concurrent)

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run<T>(timeout: TimeInterval = 0.5, fallback: T, _ work: @escaping () -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        queue.async { box.set(work()); done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success else { return fallback }
        return box.get() ?? fallback
    }

    /// Whether a path exists; when the disk doesn't answer in time, assumes it does (whatever runs there reports
    /// the problem itself, instead of the app freezing).
    static func exists(_ path: String, timeout: TimeInterval = 0.5) -> Bool {
        run(timeout: timeout, fallback: true) { FileManager.default.fileExists(atPath: path) }
    }
}
