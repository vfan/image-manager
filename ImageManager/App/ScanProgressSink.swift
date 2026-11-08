import Foundation

/// Cross-actor progress bridge.
///
/// `DirectoryScanner.scan` runs on a background task and pushes every item
/// through `@Sendable` closures. Those closures feed a thread-safe buffer that
/// the main actor drains on a 100 ms cadence, so SwiftUI sees smooth progress
/// without one main-thread hop per file.
public final class ScanProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ImageItem] = []
    private var finished = false
    private(set) var totalFound = 0

    func append(_ item: ImageItem) {
        lock.lock()
        pending.append(item)
        totalFound += 1
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func drain() -> [ImageItem] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }
}
