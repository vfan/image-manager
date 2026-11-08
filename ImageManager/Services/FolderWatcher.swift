import Foundation

/// Thin wrapper over FSEvents for recursive, low-latency folder watching.
///
/// The callback is delivered on a private serial queue; it reports which paths
/// changed (best effort — FSEvents may coalesce and report a parent directory).
public final class FolderWatcher {
    struct Event: Sendable {
        var changedPaths: [String]
        var flags: FSEventStreamEventFlags
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.local.ImageManager.fsevents", qos: .utility)
    private var onChange: (@Sendable ([Event]) -> Void)?

    deinit { stop() }

    /// Start watching `paths`. Replacing an existing watcher is supported.
    func start(paths: [String], latency: TimeInterval = 1.5, onChange: @escaping @Sendable ([Event]) -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let cfPaths = unsafeBitCast(paths, to: NSArray.self) as! [String]
                let cfFlags = UnsafeBufferPointer(start: flags, count: count)
                var events: [Event] = []
                for i in 0..<count {
                    events.append(Event(changedPaths: [cfPaths[i]], flags: cfFlags[i]))
                }
                watcher.onChange?(events)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }

    var isRunning: Bool { stream != nil }
}

public extension FSEventStreamEventFlags {
    /// True when the path itself was written to / created / removed.
    var isItemLevelChange: Bool {
        self & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                      kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed) != 0
    }

    var isDirectoryEvent: Bool {
        self & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
    }

    var isRootChange: Bool {
        self & UInt32(kFSEventStreamEventFlagRootChanged) != 0
    }
}
