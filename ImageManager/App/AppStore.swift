import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit
import os

/// Single source of truth for the whole app. Everything mutating runs on the
/// main actor; scanning and thumbnail work happens off it.
@MainActor
public final class AppStore: ObservableObject {
    // MARK: Library state

    @Published public private(set) var folders: [LibraryFolder] = []
    @Published public private(set) var items: [ImageItem] = []
    @Published public private(set) var statistics = LibraryStatistics()
    @Published public private(set) var isScanning = false
    /// Number of folder scans currently running (several may overlap).
    private var activeScans = 0
    @Published public private(set) var scanProgress = ScanProgress()
    /// Which folder is being scanned right now (for the progress banner).
    @Published public private(set) var scanningFolderPath: String?

    // MARK: UI state

    /// How the browser groups images: by pixel size (default), aspect ratio,
    /// width band or pixel-area band. Persisted in UserDefaults.
    @Published public var groupingMode: GroupKey.Mode = AppStore.storedGroupingMode() {
        didSet {
            guard groupingMode != oldValue else { return }
            UserDefaults.standard.set(groupingMode.rawValue, forKey: Self.groupingModeDefaultsKey)
        }
    }

    /// The file whose rename sheet is open.
    @Published public var renamingItem: ImageItem?
    @Published public var renameError: String?

    /// A short-lived "已移动 1 张到 A" note shown in the status bar.
    /// Result of the most recent folder scan: how much of it came from the
    /// on-disk index instead of re-reading PNG headers.
    public struct ScanStats: Sendable, Equatable {
        public var folderName: String
        public var reused: Int
        public var parsed: Int
        public var seconds: TimeInterval      // wall clock of the whole scan step
        public var pureSeconds: TimeInterval  // time inside the file walker only
        public var cacheHitRate: Double
        public var strings: String {
            String(format: "索引命中 %d · 新解析 %d · 扫描 %.0f ms", reused, parsed, pureSeconds * 1000)
        }
    }
    @Published public private(set) var lastScanStats: ScanStats?
    /// Aggregated over every folder scanned since launch.
    public private(set) var sessionReused = 0
    public private(set) var sessionParsed = 0
    public private(set) var sessionWalkerSeconds: TimeInterval = 0

    @Published public private(set) var moveMessage: String?

    /// Selected sidebar row. Remembered across launches: the app opens on the
    /// same folder / size group you left it on instead of dumping the whole
    /// library into the window.
    @Published public var scope: LibraryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            Self.store(scope: scope)
        }
    }
    @Published public var searchText = "" {
        didSet { if oldValue != searchText { clearSelection() } }
    }
    @Published public var sortOrder: ImageSortOrder = .createdNewest
    @Published public var showsThumbnailInfo = false
    @Published public var thumbnailSize: Double = 148
    @Published public var exactSizeThreshold: Int = 5
    /// Multi-selection: paths of every selected thumbnail.
    @Published public var selection: Set<String> = []
    /// The "primary" selection (last clicked) — drives the inspector, rename
    /// and quick look when more than one item is selected.
    @Published public var selectedItemID: String?
    /// Files awaiting a destructive-action confirmation.
    @Published public var pendingDeletion: [ImageItem] = []
    /// Last Trash error, surfaced in the status bar and the diagnostic report.
    @Published public var lastDeleteError: String?
    @Published public var quickLookItem: ImageItem?

    // MARK: Dimension filter
    //
    // "Applied" is what actually narrows the grid; "draft" is what the user is
    // editing in the popover/sheet. Both are persisted (filters.json) so the
    // filter survives quitting the app.

    @Published public private(set) var filter = DimensionFilter()
    @Published public var draftFilter = DimensionFilter()
    @Published public var isFilterShowingDraft = false
    /// Most recent "长边 × 短边" bounds, newest first (remembered across launches).
    @Published public private(set) var recentCombos: [String] = []

    // MARK: Group notes
    //
    // A note per group ("2048 × 2048 → iOS 截屏"). Persisted in notes.json and
    // shown in the sidebar next to the size / ratio.

    @Published private(set) var groupNotes: [String: GroupNote] = [:]
    /// Group whose note is being edited; drives the shared editor sheet.
    @Published public var editingNoteKey: GroupKey?

    // MARK: Infrastructure

    nonisolated static let scopeDefaultsKey = "selectedScope"
    nonisolated static let groupingModeDefaultsKey = "groupingMode"
    /// Pixel sizes by default ("按尺寸展示"), ratio only when asked for.
    nonisolated static let defaultGroupingMode: GroupKey.Mode = .exactSize

    nonisolated static func storedGroupingMode(in defaults: UserDefaults = .standard) -> GroupKey.Mode {
        guard let raw = defaults.string(forKey: groupingModeDefaultsKey),
              let mode = GroupKey.Mode(rawValue: raw) else { return defaultGroupingMode }
        return mode
    }

    /// Persist the current sidebar selection ("folder:/x" or "group:size:1x1").
    nonisolated static func store(scope: LibraryScope, in defaults: UserDefaults = .standard) {
        defaults.set(scope.sidebarSelectionID, forKey: scopeDefaultsKey)
    }

    /// The selection to open with: last time's row when it still exists,
    /// otherwise the first folder. Never `.all` unless there are no folders.
    nonisolated static func restoredScope(in defaults: UserDefaults, folders: [LibraryFolder]) -> LibraryScope {
        if let raw = defaults.string(forKey: scopeDefaultsKey),
           let saved = LibraryScope(selectionID: raw) {
            switch saved {
            case .folder(let path):
                if folders.contains(where: { $0.path == path }) { return saved }
            case .group:
                return saved
            case .all:
                break
            }
        }
        if let first = folders.first { return .folder(first.path) }
        return .all
    }

    private let logger = Logger(subsystem: "com.local.ImageManager", category: "app")
    private let watcher = FolderWatcher()
    private var indexSaveTask: Task<Void, Never>?
    private var filterSaveTask: Task<Void, Never>?
    private var moveMessageTask: Task<Void, Never>?
    private var started = false
    /// Set when `--scope` pinned the selection before the window appeared.
    private var scopePinnedByLaunchArgument = false
    /// Set when `--add-folder` already chose the root, so `start()` must not
    /// reload/replace it (and must not seed Downloads).
    private var folderPinnedByLaunchArgument = false
    private var launchArgumentsApplied = false

    public struct ScanProgress: Equatable, Sendable {
        public var files: Int = 0
        public var folderName: String = ""

        public init(files: Int = 0, folderName: String = "") {
            self.files = files
            self.folderName = folderName
        }
    }

    public init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // Must happen before anything is loaded/scanned: `--add-folder` picks
        // the root instead of the first-launch Downloads fallback.
        runLaunchArguments()

        // Restore the folder list and the cached index (instant relaunch), then
        // rescan in the background to pick up whatever changed while closed.
        // Re-normalise stored paths so old indexes with `/tmp` spelling keep
        // matching the canonical paths the scanner produces.
        if !folderPinnedByLaunchArgument {
            folders = Self.uniqueFolders(Persistence.loadFolders().map {
                LibraryFolder(id: $0.path, bookmark: $0.bookmark)
            })
            if let cached = Persistence.loadIndex(), !cached.isEmpty {
                apply(items: cached)
            }
        }

        if folders.isEmpty {
            // Never leave a first launch with an empty sheet: start from Downloads.
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            if FileManager.default.fileExists(atPath: downloads.path) {
                folders = [LibraryFolder(id: downloads.path)]
            }
        }

        restoreFilters()
        if !scopePinnedByLaunchArgument {
            scope = Self.restoredScope(in: .standard, folders: folders)
        }
        groupNotes = Dictionary(Persistence.loadNotes().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        ThumbnailService.shared.pruneDiskCache()
        rescanAll()
        restartWatcher()
    }

    /// Entry point for diagnostic launch arguments. Safe to call twice; the
    /// window also calls it first so `--add-folder` wins over the Downloads seed.
    public func runLaunchArguments() {
        guard !launchArgumentsApplied else { return }
        launchArgumentsApplied = true
        enforceLaunchArguments()
    }


    /// Debug / diagnostic launch arguments (see README):
    ///   --add-folder <path>      add a folder without the open panel
    ///   --scan-and-export <out>  scan all folders, write a JSON report, quit
    private func enforceLaunchArguments() {
        let args = CommandLine.arguments
        func value(for flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        if let path = value(for: "--add-folder") {
            // One root at a time, exactly like the picker.
            let folder = LibraryFolder(id: FilePath.canonical((path as NSString).expandingTildeInPath))
            folders = [folder]
            items = []
            folderPinnedByLaunchArgument = true
            Persistence.saveFolders(folders)
            Persistence.invalidateIndex()
            scope = .folder(folder.path)
        }

        if let scopeID = value(for: "--scope") {
            scope = SidebarView.scope(from: scopeID)
            scopePinnedByLaunchArgument = true
            if let sort = value(for: "--sort"), let order = ImageSortOrder(rawValue: sort) {
                sortOrder = order
            }
        }

        if let size = value(for: "--thumb-size").flatMap(Double.init) {
            thumbnailSize = min(max(size, 72), 320)
        }

        if let search = value(for: "--search") {
            searchText = search
        }

        if let filterSpec = value(for: "--filter") {
            applyFilter(Self.parseFilterArgument(filterSpec) ?? DimensionFilter())
            Persistence.saveFilters(Persistence.SavedFilters(applied: filter, draft: filter,
                                                             isShowingDraft: false,
                                                             recentCombos: recentCombos))
        }

        if let out = value(for: "--scan-and-export") {
            let exportURL = URL(fileURLWithPath: out)
            let target = value(for: "--add-folder").map { LibraryFolder(id: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
            Task {
                let launchScope = scope.sidebarSelectionID
                let started = Date()
                while isScanning && Date().timeIntervalSince(started) < 60 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let target {
                    await scan(folder: target)
                    while isScanning && Date().timeIntervalSince(started) < 60 {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                let elapsed = Date().timeIntervalSince(started)
                var movedTo: String?
                if let source = value(for: "--move"), let target = value(for: "--to"),
                   let sourceItem = self.item(forPath: source), let root = currentFolder?.path {
                    let destination = FilePath.canonical((target as NSString).expandingTildeInPath)
                    let relative = destination == root
                        ? ""
                        : String(destination.dropFirst(root.count + 1))
                    movedTo = move(sourceItem, to: Subdirectory(relativePath: relative,
                                                                url: URL(fileURLWithPath: destination)))?.path
                }

                var deleted: [String] = []
                if let victims = value(for: "--delete") {
                    let targets = victims
                        .split(separator: ",")
                        .compactMap { self.item(forPath: String($0).trimmingCharacters(in: .whitespaces)) }
                    if !targets.isEmpty, delete(targets) > 0 {
                        deleted = targets.map(\.path)
                    }
                }

                var renamedTo: String?
                if let source = value(for: "--rename"), let name = value(for: "--name"),
                   let sourceItem = self.item(forPath: source) {
                    if rename(sourceItem, to: name) == nil {
                        renamedTo = items.first {
                            $0.rootPath == sourceItem.rootPath
                                && $0.fileName == FileMover.sanitizedFileName(name)
                        }?.path ?? sourceItem.path
                    }
                }

                let snapshot = items
                // Don't touch `scope` here: it is persisted, and diagnostics
                // must not overwrite the row the user left selected.
                let visible = snapshot
                // Give thumbnails a moment to be generated for the first page.
                try? await Task.sleep(for: .milliseconds(500))
                let thumbs = ThumbnailService.shared.cachedCount()
                let report: [String: Any] = [
                    "scanSeconds": elapsed,
                    "count": snapshot.count,
                    "totalBytes": snapshot.reduce(0) { $0 + $1.fileSize },
                    "cachedThumbnails": thumbs,
                    "scanReused": sessionReused,
                    "scanParsed": sessionParsed,
                    "scanCacheHitRate": (sessionReused + sessionParsed) == 0 ? 0
                        : Double(sessionReused) / Double(sessionReused + sessionParsed),
                    "scanPureMs": sessionWalkerSeconds * 1000,
                    "scope": launchScope,
                    "subdirectories": AppStore.subdirectorySections(
                        items: scopedItems,
                        root: currentFolder?.path ?? ""
                    ).map(\.directory.title),
                    "movedTo": movedTo ?? "",
                    "deleted": deleted,
                    "deleteError": self.lastDeleteError ?? "",
                    "renamedTo": renamedTo ?? "",
                    "groupingMode": groupingMode.rawValue,
                    "notesCount": groupNotes.count,
                    "notes": groupNotes.values.map { ["id": $0.id, "text": $0.text] },
                    "groupCount": groupRows(for: groupingMode, folder: nil).count,
                    "filteredCount": visible.count,
                    "searchCount": visible.count,
                    "filterSummary": filter.summary,
                    "filterActive": !filter.isInactive,
                    "hiddenGroups": groupRowCounts(folder: nil).total - groupRowCounts(folder: nil).shown,
                    "aspect": Dictionary(grouping: snapshot, by: { $0.aspectCategory.rawValue }).mapValues(\.count),
                    "exactSizes": statistics.exactSizeGroups.prefix(30).map { ["size": $0.label, "count": $0.count] },
                    "ordered": filteredItems.prefix(12).map(\.relativePath),
                    "items": snapshot.prefix(5000).map {
                        ["path": $0.path, "relative": $0.relativePath, "w": $0.pixelWidth, "h": $0.pixelHeight,
                         "aspect": $0.aspectCategory.rawValue, "alpha": $0.hasAlpha,
                         "created": $0.createdAt.timeIntervalSince1970,
                         "modified": $0.modifiedAt.timeIntervalSince1970]
                    },
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: exportURL)
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Folders

    /// The app works on **one** directory at a time; picking a new one replaces
    /// the old one instead of growing a list.
    public func presentDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.title = currentFolder == nil ? "选择图片目录" : "更换图片目录"
        panel.message = "选中的目录（含子目录）里的所有 PNG 会被索引；分类看的是这个目录下的子目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = currentFolder == nil ? "选择" : "更换"
        if panel.runModal() == .OK, let url = panel.url {
            selectFolder(url)
        }
    }

    public var currentFolder: LibraryFolder? { folders.first }

    /// Replace the single root folder and reload the library from it.
    func selectFolder(_ url: URL) {
        let resolved = url
        let folder = LibraryFolder(id: FilePath.canonical(resolved.path),
                                   bookmark: try? resolved.bookmarkData(options: [.withSecurityScope],
                                                                        includingResourceValuesForKeys: nil,
                                                                        relativeTo: nil))
        folders = [folder]
        items = []
        scope = .folder(folder.path)
        recomputeStatistics()
        Persistence.saveFolders(folders)
        Persistence.invalidateIndex()

        Task { @MainActor in
            await scan(folder: folder)
            if case .group = scope { scope = .folder(folder.path) }
            restartWatcher()
        }
    }

    func removeFolder(_ id: String) {
        folders.removeAll { $0.path == id }
        Persistence.saveFolders(folders)
        items.removeAll { $0.rootPath == id }
        recomputeStatistics()
        if case .folder(let path) = scope, path == id {
            // Fall back to another folder instead of the (heavy) all-images view.
            scope = folders.first.map { .folder($0.path) } ?? .all
        }
        scheduleIndexSave()
        restartWatcher()
    }

    func revealFolders(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
    }

    public func rescanCurrentFolder(forceRefresh: Bool = false) {
        switch scope {
        case .folder(let path):
            if let folder = folders.first(where: { $0.path == path }) {
                Task { await scan(folder: folder, forceRefresh: forceRefresh) }
            }
        default:
            rescanAll(forceRefresh: forceRefresh)
        }
    }

    func rescanAll(forceRefresh: Bool = false) {
        let snapshot = folders
        Task {
            for folder in snapshot {
                await scan(folder: folder, forceRefresh: forceRefresh)
            }
        }
    }

    // MARK: - Scanning

    /// Scans one folder in the background, streaming partial results into the
    /// library every ~100 ms so the grid fills in while the scan is running.
    /// `forceRefresh` ignores the cached entries and re-reads every PNG header
    /// (what the “重新扫描（忽略缓存）” menu item does).
    func scan(folder: LibraryFolder, isIncremental: Bool = false, forceRefresh: Bool = false) async {
        let rootPath = folder.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("Folder missing: \(rootPath, privacy: .public)")
            return
        }

        activeScans += 1
        isScanning = true
        scanningFolderPath = rootPath
        scanProgress = ScanProgress(files: 0, folderName: folder.name)

        let started = Date()
        let url = folder.url
        let didAccess = url.startAccessingSecurityScopedResource()
        let sink = ScanProgressSink()
        // Feed the scanner the entries we already know about so unchanged files
        // are reused from the index instead of being re-read from disk.
        var cached: [String: ImageItem] = [:]
        if !forceRefresh {
            for item in items where item.rootPath == rootPath { cached[item.path] = item }
        }
        let scanTask = Task.detached(priority: .userInitiated) { [sink, cached] in
            let result = DirectoryScanner.scan(root: url, cached: cached) { event in
                switch event {
                case .found(let item): sink.append(item)
                case .finished: sink.markFinished()
                }
            }
            return result
        }

        var scanned = 0
        while !sink.isFinished {
            try? await Task.sleep(for: .milliseconds(120))
            let batch = sink.drain()
            if !batch.isEmpty {
                scanned += batch.count
                merge(batch, rootPath: rootPath)
                scanProgress = ScanProgress(files: scanned, folderName: folder.name)
            }
        }
        let result = await scanTask.value
        if didAccess { url.stopAccessingSecurityScopedResource() }
        let leftover = sink.drain()
        if !leftover.isEmpty { merge(leftover, rootPath: rootPath) }

        if !isIncremental {
            removeMissingFiles(in: rootPath)
        }

        let elapsed = Date().timeIntervalSince(started)
        sessionReused += result.reused
        sessionParsed += result.parsed
        sessionWalkerSeconds += result.duration
        lastScanStats = ScanStats(folderName: folder.name, reused: result.reused, parsed: result.parsed,
                                  seconds: elapsed, pureSeconds: result.duration,
                                  cacheHitRate: result.cacheHitRate)
        logger.info("Scanned \(result.items.count) PNGs in \(rootPath, privacy: .public) in \(Int(elapsed * 1000)) ms (reused \(result.reused), parsed \(result.parsed))")
        scanProgress = ScanProgress(files: items.filter { $0.rootPath == rootPath }.count, folderName: folder.name)
        activeScans = max(0, activeScans - 1)
        isScanning = activeScans > 0
        if !isScanning { scanningFolderPath = nil }
        scheduleIndexSave()
        ThumbnailService.shared.prewarm(filteredItems)
    }

    /// Path → index, tolerant of duplicates (a duplicate key never crashes).
    private nonisolated static func indexByPath(_ list: [ImageItem]) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(list.count)
        for (offset, item) in list.enumerated() { map[item.path] = offset }
        return map
    }

    /// Insert or replace a batch of items belonging to `rootPath`.
    private func merge(_ batch: [ImageItem], rootPath: String) {
        var indexByPath = Self.indexByPath(items)
        var mutated = false
        for item in batch {
            if let idx = indexByPath[item.path] {
                if items[idx] != item {
                    items[idx] = item
                    mutated = true
                }
            } else {
                indexByPath[item.path] = items.count
                items.append(item)
                mutated = true
            }
        }
        if mutated { recomputeStatistics() }
    }

    /// Remove entries for this folder whose file disappeared.
    private func removeMissingFiles(in rootPath: String) {
        let candidates = items.filter { $0.rootPath == rootPath }
        let missing = candidates
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        guard !missing.isEmpty else { return }
        let gone = Set(missing)
        items.removeAll { gone.contains($0.path) }
        recomputeStatistics()
    }

    /// Called by FSEvents with a debounce. Cheap: only touched paths are re-read.
    private func handleFileSystemEvents(_ events: [FolderWatcher.Event]) {
        var changed = Set<String>()
        for event in events {
            for path in event.changedPaths {
                changed.insert(path)
            }
        }
        guard !changed.isEmpty else { return }

        let known = Set(items.map(\.path))
        var updated = items
        var indexByPath = Self.indexByPath(updated)
        var mutated = false

        for path in changed {
            if URL(fileURLWithPath: path).pathExtension.lowercased() != "png",
               known.contains(path) == false { continue }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

            if exists, !isDirectory.boolValue {
                guard let root = folders.first(where: { path.hasPrefix($0.path + "/") }) else { continue }
                guard let item = DirectoryScanner.imageItem(url: URL(fileURLWithPath: path), rootPath: root.path) else {
                    // Became invalid or non-PNG → drop it.
                    if let idx = indexByPath[path] {
                        updated.remove(at: idx)
                        indexByPath = Self.indexByPath(updated)
                        mutated = true
                    }
                    continue
                }
                if let idx = indexByPath[path] {
                    if updated[idx] != item {
                        updated[idx] = item
                        mutated = true
                    }
                } else {
                    updated.append(item)
                    indexByPath[path] = updated.count - 1
                    mutated = true
                }
            } else if let idx = indexByPath[path] {
                // Deleted or turned into a directory.
                updated.remove(at: idx)
                indexByPath = Self.indexByPath(updated)
                mutated = true
            }
        }

        if mutated {
            // Preserve current order where possible to avoid grid jumps:
            // appending is fine because views sort explicitly.
            apply(items: updated.sorted { $0.path < $1.path })
            scheduleIndexSave()
        }
    }

    // MARK: - Derived data

    var filteredItems: [ImageItem] {
        var pool = scopedItems
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let tokens = query.split(separator: " ").map(String.init)
            let noteMatchedGroups = groupKeysMatchingNote(tokens)
            pool = pool.filter { item in
                let haystack = (item.fileName + " " + item.relativePath + " " + item.dimensionKey).lowercased()
                if tokens.allSatisfy({ haystack.contains($0.lowercased()) }) { return true }
                // "搜备注" should surface every image in the annotated group.
                guard !noteMatchedGroups.isEmpty else { return false }
                return noteMatchedGroups.contains(Self.groupKey(for: item, mode: groupingMode).noteID)
            }
        }
        return sorted(pool)
    }

    /// Items in the current scope (used for thumbnail prewarm).
    var scopedItems: [ImageItem] {
        switch scope {
        case .all: return items
        case .folder(let path): return items.filter { $0.rootPath == path }
        case .group(let key): return items.filter { key.matches($0) }
        }
    }

    var folderCounts: [(folder: LibraryFolder, count: Int, bytes: Int64)] {
        folders.map { folder in
            let fs = items.filter { $0.rootPath == folder.path }
            return (folder, fs.count, fs.reduce(0) { $0 + $1.fileSize })
        }
    }

    /// Sidebar sections for the chosen grouping mode.
    func groupRows(for mode: GroupKey.Mode, folder: LibraryFolder?,
                   applyingFilter: Bool = true) -> [(key: GroupKey, count: Int)] {
        let all = folder.map { f in items.filter { $0.rootPath == f.path } } ?? items
        let active = effectiveFilter
        let base = (applyingFilter && !active.isInactive) ? all.filter(active.matches) : all
        var rows = Self.makeGroupRows(base: base, mode: mode,
                                      threshold: exactSizeThreshold, notes: groupNotes)
        // The row you selected last time must stay selectable even if it fell
        // below the "at least N images" threshold.
        if case let .group(selected) = scope, selected.groupMode == mode,
           !rows.contains(where: { $0.key == selected }) {
            let count = base.reduce(0) { $0 + (selected.matches($1) ? 1 : 0) }
            if count > 0 { rows.append((selected, count)) }
        }
        return rows
    }

    /// Pure grouping used by both the sidebar and the tests.
    nonisolated static func makeGroupRows(base: [ImageItem], mode: GroupKey.Mode,
                                          threshold: Int,
                                          notes: [String: GroupNote]) -> [(key: GroupKey, count: Int)] {
        switch mode {
        case .aspect:
            var counts: [AspectCategory: Int] = [:]
            for item in base { counts[item.aspectCategory, default: 0] += 1 }
            return AspectCategory.displayOrder.compactMap { category in
                guard let n = counts[category], n > 0 else { return nil }
                return (.aspect(category), n)
            }
        case .exactSize:
            let stats = LibraryStatistics.make(from: base)
            return stats.exactSizeGroups
                // Keep small groups that the user annotated: a note is worthless
                // if the row it belongs to never shows up in the sidebar.
                // No arbitrary row cap: the sidebar gets too long to browse
                // exactly when a size is rare, and a hidden row would make both
                // `列表筛选` and notes unreliable.
                .filter { $0.count >= max(1, threshold) || notes[GroupKey.exactSize($0).noteID] != nil }
                .map { (.exactSize($0), $0.count) }
        case .width:
            var counts: [WidthBucket: Int] = [:]
            for item in base { counts[item.widthBucket, default: 0] += 1 }
            return WidthBucket.allCases.compactMap { bucket in
                guard let n = counts[bucket], n > 0 else { return nil }
                return (.width(bucket), n)
            }
        case .area:
            var counts: [AreaBucket: Int] = [:]
            for item in base { counts[item.areaBucket, default: 0] += 1 }
            return AreaBucket.allCases.compactMap { bucket in
                guard let n = counts[bucket], n > 0 else { return nil }
                return (.area(bucket), n)
            }
        }
    }

    /// Load notes from disk (also used by tests to simulate a relaunch).
    public func restoreNotesForTesting() {
        groupNotes = Dictionary(Persistence.loadNotes().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Renaming

    public func beginRename(_ item: ImageItem) {
        renameError = nil
        renamingItem = item
    }

    public func cancelRename() {
        renamingItem = nil
        renameError = nil
    }

    /// Rename on disk and in the index. Returns nil on success, or a message
    /// the sheet shows under the text field.
    @discardableResult
    public func rename(_ item: ImageItem, to rawName: String) -> String? {
        let wanted = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted == (item.fileName as NSString).deletingPathExtension
            || wanted == item.fileName {
            cancelRename()
            return nil
        }
        do {
            let url = try FileMover.rename(item.url, to: wanted)
            guard let index = items.firstIndex(where: { $0.path == item.path }) else {
                cancelRename()
                return nil
            }
            guard let renamed = DirectoryScanner.imageItem(url: url, rootPath: item.rootPath) else {
                throw FileMover.RenameError.failed("重命名后无法读取这个文件")
            }
            items[index] = renamed
            if selectedItemID == item.path { selectedItemID = renamed.path }
            if selection.contains(item.path) {
                selection.remove(item.path)
                selection.insert(renamed.path)
            }
            scheduleIndexSave()
            renamingItem = nil
            renameError = nil
            moveMessage = "已重命名为「\(renamed.fileName)」"
            clearMoveMessageSoon()
            return nil
        } catch {
            let message = error.localizedDescription
            renameError = message
            return message
        }
    }

    // MARK: - Moving files between subdirectories

    /// A subdirectory of the current root folder. This is what the right-hand
    /// list groups by, and the only kind of place a file may be moved to.
    public struct Subdirectory: Identifiable, Hashable, Sendable {
        public let relativePath: String   // "" means the root itself
        public let url: URL

        public var id: String { url.path }
        public var title: String { relativePath.isEmpty ? "根目录" : relativePath }
    }

    /// Distinct subdirectories (relative to the root) the given images live in.
    nonisolated static func subdirectories(in items: [ImageItem], root: String) -> [Subdirectory] {
        var names = Set<String>()
        for item in items {
            names.insert((item.relativePath as NSString).deletingLastPathComponent)
        }
        let base = URL(fileURLWithPath: root)
        return names.map { relative in
            Subdirectory(relativePath: relative,
                         url: relative.isEmpty ? base : base.appendingPathComponent(relative))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Groups images by their subdirectory, for the right-hand list.
    nonisolated static func subdirectorySections(items: [ImageItem], root: String)
        -> [(directory: Subdirectory, items: [ImageItem])] {
        var map: [String: [ImageItem]] = [:]
        for item in items {
            map[(item.relativePath as NSString).deletingLastPathComponent, default: []].append(item)
        }
        let base = URL(fileURLWithPath: root)
        return map.map { relative, groupItems in
            (Subdirectory(relativePath: relative,
                          url: relative.isEmpty ? base : base.appendingPathComponent(relative)),
             groupItems)   // already in display order (newest first by default)
        }
        .sorted { lhs, rhs in
            // The folder holding the most recent image comes first.
            let left = lhs.items.map(\.createdAt).max() ?? .distantPast
            let right = rhs.items.map(\.createdAt).max() ?? .distantPast
            if left != right { return left > right }
            return lhs.directory.title.localizedStandardCompare(rhs.directory.title) == .orderedAscending
        }
    }

    /// Subdirectories that actually appear in the current right-hand list.
    var moveTargetDirectories: [Subdirectory] {
        guard let root = currentFolder?.path else { return [] }
        return Self.subdirectories(in: scopedItems, root: root)
    }

    nonisolated static func moveTargets(for item: ImageItem, in items: [ImageItem], root: String)
        -> [Subdirectory] {
        let own = (item.relativePath as NSString).deletingLastPathComponent
        return subdirectories(in: items, root: root).filter { $0.relativePath != own }
    }

    /// Where this file may go: every subdirectory in the current list except
    /// the one it already lives in.
    public func moveTargets(for item: ImageItem) -> [Subdirectory] {
        guard let root = currentFolder?.path else { return [] }
        return Self.moveTargets(for: item, in: scopedItems, root: root)
    }

    /// Can `item` be moved to `target` right now?
    public func canMove(_ item: ImageItem, to target: Subdirectory) -> Bool {
        let own = (item.relativePath as NSString).deletingLastPathComponent
        return target.relativePath != own
            && moveTargetDirectories.contains { $0.url == target.url }
    }

    /// Move one image into another subdirectory of the current list.
    @discardableResult
    public func move(_ item: ImageItem, to target: Subdirectory) -> ImageItem? {
        guard canMove(item, to: target) else { return nil }
        do {
            let result = try FileMover.move(item.url, to: target.url)
            guard let index = items.firstIndex(where: { $0.path == item.path }) else { return nil }
            guard let moved = DirectoryScanner.imageItem(url: result.destination,
                                                         rootPath: item.rootPath) else {
                items.remove(at: index)
                recomputeStatistics()
                scheduleIndexSave()
                return nil
            }
            items[index] = moved
            recomputeStatistics()
            scheduleIndexSave()
            announceMove(count: 1, folderName: target.title)
            return moved
        } catch {
            moveMessage = "移动失败：\(error.localizedDescription)"
            clearMoveMessageSoon()
            return nil
        }
    }

    /// Move several images (drag & drop can hand us a batch). Files outside the
    /// current selection are ignored, as are destinations not in the list.
    @discardableResult
    public func moveFiles(_ urls: [URL], to target: Subdirectory) -> Int {
        var moved = 0
        for url in urls {
            let resolved = url.resolvingSymlinksInPath().path
            guard let item = items.first(where: { $0.path == resolved }) else { continue }
            if move(item, to: target) != nil { moved += 1 }
        }
        if moved > 1 { announceMove(count: moved, folderName: target.title) }
        return moved
    }

    /// The result of a drop, without mutating anything when it is not allowed.
    public func canMoveFileURLs(_ urls: [URL], to target: Subdirectory) -> Bool {
        urls.contains { url in
            let path = url.resolvingSymlinksInPath().path
            guard let item = items.first(where: { $0.path == path }) else { return false }
            return canMove(item, to: target)
        }
    }

    // MARK: - Deleting

    /// Ask before destroying more than one file; a single file goes straight to
    /// the Trash (it is recoverable there anyway).
    public func requestDelete(_ targets: [ImageItem]) {
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            delete(targets)
        } else {
            pendingDeletion = targets
        }
    }

    public func cancelDeletion() {
        pendingDeletion = []
    }

    /// Move files to the Trash and drop them from the index.
    @discardableResult
    public func delete(_ targets: [ImageItem]) -> Int {
        var removed: Set<String> = []
        var failures = 0
        lastDeleteError = nil
        for item in targets {
            do {
                try FileDeleter.trash(item.url)
                removed.insert(item.path)
            } catch {
                failures += 1
                lastDeleteError = error.localizedDescription
                logger.error("Trash failed for \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !removed.isEmpty {
            items.removeAll { removed.contains($0.path) }
            selection.subtract(removed)
            if let id = selectedItemID, removed.contains(id) { selectedItemID = selection.first }
            recomputeStatistics()
            scheduleIndexSave()
            moveMessage = "已删除 \(removed.count) 张（移到废纸篓）"
            clearMoveMessageSoon()
        }
        if failures > 0 {
            moveMessage = "\(failures) 张删除失败\(lastDeleteError.map { "：\($0)" } ?? "")"
            clearMoveMessageSoon()
        }
        pendingDeletion = []
        return removed.count
    }

    private func announceMove(count: Int, folderName: String) {
        moveMessage = "已移动 \(count) 张到「\(folderName)」"
        clearMoveMessageSoon()
    }

    private func clearMoveMessageSoon() {
        moveMessageTask?.cancel()
        moveMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.moveMessage = nil
        }
    }


    /// Match a user/CLI supplied path against indexed items, tolerant of
    /// `/tmp` vs `/private/tmp` spellings.
    func item(forPath path: String) -> ImageItem? {
        let raw = (path as NSString).expandingTildeInPath
        let canonical = FilePath.canonical(raw)
        return items.first {
            $0.path == raw || $0.path == canonical || FilePath.canonical($0.path) == canonical
        }
    }

    // MARK: - Group notes

    /// Note attached to a group, or nil when there is none.
    public func note(for key: GroupKey) -> GroupNote? {
        guard let note = groupNotes[key.noteID] else { return nil }
        let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : note
    }

    public func noteText(for key: GroupKey) -> String? { note(for: key)?.text }

    /// Save a note; an empty/whitespace-only string removes it.
    public func setNote(_ text: String, for key: GroupKey) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            groupNotes.removeValue(forKey: key.noteID)
        } else {
            groupNotes[key.noteID] = GroupNote(id: key.noteID, text: trimmed)
        }
        Persistence.saveNotes(groupNotes.values.sorted { $0.id < $1.id })
    }

    public func removeNote(for key: GroupKey) {
        setNote("", for: key)
    }

    public func beginEditingNote(for key: GroupKey) {
        editingNoteKey = key
    }

    /// Groups whose note matches the search query (used to make notes searchable).
    func groupKeysMatchingNote(_ tokens: [String]) -> Set<String> {
        guard !tokens.isEmpty else { return [] }
        return groupNotes.values.reduce(into: Set<String>()) { result, note in
            let haystack = note.text.lowercased()
            if tokens.allSatisfy({ haystack.contains($0.lowercased()) }) {
                result.insert(note.id)
            }
        }
    }

    /// The group an item belongs to under a grouping mode.
    nonisolated static func groupKey(for item: ImageItem, mode: GroupKey.Mode) -> GroupKey {
        switch mode {
        case .aspect: .aspect(item.aspectCategory)
        case .exactSize: .exactSize(width: item.pixelWidth, height: item.pixelHeight)
        case .width: .width(item.widthBucket)
        case .area: .area(item.areaBucket)
        }
    }

    // MARK: - Dimension filter

    /// How many images the current scope holds before filtering.
    var scopeItemCount: Int { scopedItems.count }

    /// Sidebar rows removed by the dimension filter (for the current mode).
    func hiddenGroupCount(folder: LibraryFolder?) -> Int {
        guard !effectiveFilter.isInactive else { return 0 }
        let all = groupRows(for: groupingMode, folder: folder, applyingFilter: false).count
        let shown = groupRows(for: groupingMode, folder: folder).count
        return max(0, all - shown)
    }

    /// Rows the sidebar shows / would show without the filter.
    func groupRowCounts(folder: LibraryFolder?) -> (shown: Int, total: Int) {
        (groupRows(for: groupingMode, folder: folder).count,
         groupRows(for: groupingMode, folder: folder, applyingFilter: false).count)
    }

    /// Which filter is in effect for display purposes.
    var effectiveFilter: DimensionFilter { isFilterShowingDraft ? draftFilter : filter }

    /// Open the full filter panel from the menu (the detail view owns the sheet).
    public func presentFilterPanel() {
        beginFilterEditing()
        NotificationCenter.default.post(name: .openDimensionFilterPanel, object: nil)
    }

    /// Start editing from the filter currently in effect.
    func beginFilterEditing() {
        draftFilter = filter
        isFilterShowingDraft = false
    }

    /// Show a live preview of the draft on the grid as the user types.
    func toggleDraftPreview() {
        guard !isFilterShowingDraft else {
            isFilterShowingDraft = false
            scheduleFilterSave()
            return
        }
        draftFilter = filter
        isFilterShowingDraft = true
        scheduleFilterSave()
    }

    public func applyFilter(_ newValue: DimensionFilter) {
        filter = newValue.normalized()
        draftFilter = filter
        isFilterShowingDraft = false
        rememberRecentCombo(from: filter)
        scheduleFilterSave()
    }

    func applyDraftFilter() {
        draftFilter = draftFilter.normalized()
        applyFilter(draftFilter)
    }

    public func clearFilter() {
        filter = DimensionFilter()
        draftFilter = filter
        isFilterShowingDraft = false
        scheduleFilterSave()
    }

    /// Revert the draft and stop previewing.
    func cancelFilterEditing() {
        draftFilter = filter
        isFilterShowingDraft = false
        scheduleFilterSave()
    }

    /// One-tap "只看大图" bounds from the toolbar / menu.
    public func applyQuickBound(_ bound: DimensionFilter.QuickLongSide) {
        if filter.matchingQuickBound() == bound {
            clearFilter()
        } else {
            applyFilter(bound.filter(scale: currentScale))
        }
    }

    /// Quick alternative for the "长边" row: one click, immediately applied.
    func toggleLongSideBound(_ bound: Int) {
        var next = filter
        if next.longSideEnabled, next.longSide.max == bound, next.longSide.min == nil {
            next.set(.longSide, enabled: false)
        } else {
            next.set(.longSide, max: bound)
        }
        applyFilter(next)
    }

    /// The sizes this library actually contains, offered as one-click targets
    /// (e.g. every distinct 长边 × 短边 pair, or the long sides in use).
    func inUseLongSides(limit: Int = 8) -> [Int] {
        let counts = items.reduce(into: [Int: Int]()) { $0[max($1.pixelWidth, $1.pixelHeight), default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
            .prefix(limit).map(\.key)
    }

    func inUseShortSides(limit: Int = 8) -> [Int] {
        let counts = items.reduce(into: [Int: Int]()) { $0[min($1.pixelWidth, $1.pixelHeight), default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
            .prefix(limit).map(\.key)
    }

    /// A remembered 长边 × 短边 pair, parsed back into a filter.
    struct BoundsCombo: Identifiable, Sendable {
        let longSide: Int
        let shortSide: Int

        var id: String { "\(longSide)x\(shortSide)" }
        var label: String { "\(longSide) × \(shortSide)" }

        var filter: DimensionFilter {
            var f = DimensionFilter()
            f.set(.longSide, max: longSide)
            f.set(.shortSide, max: shortSide)
            return f
        }

        init?(id: String) {
            let parts = id.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            longSide = parts[0]
            shortSide = parts[1]
        }

        init(longSide: Int, shortSide: Int) {
            self.longSide = longSide
            self.shortSide = shortSide
        }
    }

    var recentCombosParsed: [BoundsCombo] { recentCombos.compactMap(BoundsCombo.init(id:)) }

    /// Remember a filter whose "长边/短边 上限" pair is set (e.g. 2048 × 1024).
    private func rememberRecentCombo(from value: DimensionFilter) {
        guard value.longSideEnabled, value.shortSideEnabled,
              value.longSide.min == nil, value.shortSide.min == nil,
              let long = value.longSide.max, let short = value.shortSide.max else { return }
        let combo = BoundsCombo(longSide: long, shortSide: short).id
        recentCombos.removeAll { $0 == combo }
        recentCombos.insert(combo, at: 0)
        recentCombos = Array(recentCombos.prefix(8))
    }

    /// `longSide>=2048`, `shortSide<=512`, `width=1920`, `orientation=portrait`,
    /// joined with commas. Used by the diagnostics below.
    nonisolated static func parseFilterArgument(_ spec: String) -> DimensionFilter? {
        var filter = DimensionFilter()
        var matched = false
        for clause in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !clause.isEmpty {
            let body = clause.replacingOccurrences(of: " ", with: "")
            if body.hasPrefix("orientation=") {
                let raw = String(body.dropFirst("orientation=".count))
                if let o = DimensionFilter.OrientationPreference(rawValue: raw) {
                    filter.orientation = o
                    matched = true
                }
                continue
            }
            let ops = [">=", "<=", ">", "<", "="]
            guard let op = ops.first(where: { body.contains($0) }) else { continue }
            let parts = body.components(separatedBy: op)
            guard parts.count == 2,
                  let axis = DimensionAxis(rawValue: parts[0]),
                  let number = Int(parts[1]) else { continue }
            var range = filter.range(for: axis)
            switch op {
            case ">=", ">": range.min = number + (op == ">" ? 1 : 0)
            case "<=", "<": range.max = number - (op == "<" ? 1 : 0)
            default: range = DimensionRange(min: number, max: number)
            }
            filter.setRange(axis, range)
            filter.setEnabled(axis, true)
            matched = true
        }
        return matched ? filter : nil
    }

    // MARK: Filter persistence

    private func restoreFilters() {
        guard let saved = Persistence.loadFilters() else { return }
        filter = saved.applied ?? DimensionFilter()
        draftFilter = saved.draft ?? filter
        isFilterShowingDraft = saved.isShowingDraft
        recentCombos = saved.recentCombos
        if draftFilter.scale != currentScale {
            draftFilter.scale = currentScale
        }
    }

    /// Retina factor of the current screen; used only by the `dp` unit.
    var currentScale: Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return max(1, Int(scale.rounded()))
    }

    private func scheduleFilterSave() {
        filterSaveTask?.cancel()
        let snapshot = Persistence.SavedFilters(applied: filter, draft: draftFilter,
                                                isShowingDraft: isFilterShowingDraft,
                                                recentCombos: recentCombos)
        filterSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Persistence.saveFilters(snapshot)
        }
    }

    // MARK: - Item actions

    func reveal(_ item: ImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: ImageItem) {
        NSWorkspace.shared.open(item.url)
    }

    func copyPath(_ item: ImageItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    func copyDimensions(_ item: ImageItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.dimensionDescription, forType: .string)
    }

    public var selectedItem: ImageItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.path == id }
    }

    /// Selected images, in library order (so shift-ranges and menus are stable).
    public var selectedItems: [ImageItem] {
        guard !selection.isEmpty else { return [] }
        return items.filter { selection.contains($0.path) }
    }

    public func isSelected(_ item: ImageItem) -> Bool { selection.contains(item.path) }

    // MARK: - Selection

    public func selectOnly(_ item: ImageItem) {
        selection = [item.path]
        selectedItemID = item.path
    }

    public func clearSelection() {
        selection.removeAll()
        selectedItemID = nil
    }

    /// ⌘-click: toggle this item, keeping the rest.
    public func toggleSelection(_ item: ImageItem) {
        if selection.contains(item.path) {
            selection.remove(item.path)
            if selectedItemID == item.path {
                selectedItemID = selection.first
            }
        } else {
            selection.insert(item.path)
            selectedItemID = item.path
        }
    }

    /// ⇧-click: everything between the primary selection and this item, in the
    /// order currently displayed.
    public func extendSelection(to item: ImageItem, in ordered: [ImageItem]) {
        guard let anchor = selectedItemID,
              let from = ordered.firstIndex(where: { $0.path == anchor }),
              let to = ordered.firstIndex(where: { $0.path == item.path }) else {
            selectOnly(item)
            return
        }
        let range = from <= to ? from...to : to...from
        selection = Set(ordered[range].map(\.path))
        selectedItemID = item.path
    }

    /// Marquee / programmatic selection; `primary` keeps the inspector sane.
    public func replaceSelection(_ paths: Set<String>) {
        selection = paths
        if let current = selectedItemID, paths.contains(current) {
            return
        }
        selectedItemID = paths.first
    }

    /// Pure click semantics, so they can be unit-tested without a store.
    /// - plain click: select just this item
    /// - ⌘-click: toggle it
    /// - ⇧-click: select the range between the primary item and this one
    /// - plain click inside a multi-selection: keep the selection, move primary
    nonisolated static func selection(after click: String,
                                      on selection: Set<String>,
                                      primary: String?,
                                      command: Bool,
                                      shift: Bool,
                                      ordered: [String]) -> (selection: Set<String>, primary: String?) {
        if shift, let primary,
           let from = ordered.firstIndex(of: primary),
           let to = ordered.firstIndex(of: click) {
            let range = from <= to ? from...to : to...from
            return (Set(ordered[range]), click)
        }
        if command {
            if selection.contains(click) {
                var next = selection
                next.remove(click)
                return (next, primary == click ? next.first : primary)
            }
            return (selection.union([click]), click)
        }
        if selection.contains(click), selection.count > 1 {
            return (selection, click)
        }
        return ([click], click)
    }

    /// One entry point for every click on a thumbnail.
    public func clickSelect(_ item: ImageItem, command: Bool, shift: Bool,
                            in ordered: [ImageItem]) {
        let result = Self.selection(after: item.path, on: selection, primary: selectedItemID,
                                    command: command, shift: shift,
                                    ordered: ordered.map(\.path))
        selection = result.selection
        selectedItemID = result.primary
    }

    func toggleQuickLook() {
        quickLookItem = selectedItem
    }

    public func increaseThumbnailSize() { thumbnailSize = min(320, thumbnailSize + 24) }
    public func decreaseThumbnailSize() { thumbnailSize = max(72, thumbnailSize - 24) }

    // MARK: - Internals

    private func sorted(_ pool: [ImageItem]) -> [ImageItem] {
        Self.sorted(pool, by: sortOrder)
    }

    nonisolated static func sorted(_ pool: [ImageItem], by sortOrder: ImageSortOrder) -> [ImageItem] {
        switch sortOrder {
        case .name:
            return pool.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .sizeAscending:
            return pool.sorted {
                let a = $0.aspectCategory.sortRank, b = $1.aspectCategory.sortRank
                if a != b { return a < b }
                if $0.aspectRatio != $1.aspectRatio { return $0.aspectRatio > $1.aspectRatio }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .pixelsDescending:
            return pool.sorted {
                if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .pixelsAscending:
            return pool.sorted {
                if $0.pixelCount != $1.pixelCount { return $0.pixelCount < $1.pixelCount }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .largestFile:
            return pool.sorted {
                if $0.fileSize != $1.fileSize { return $0.fileSize > $1.fileSize }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .createdNewest:
            return pool.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .newest:
            return pool.sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        }
    }

    private func apply(items newItems: [ImageItem]) {
        items = newItems
        recomputeStatistics()
    }

    private func recomputeStatistics() {
        statistics = LibraryStatistics.make(from: items)
    }

    private func restartWatcher() {
        let paths = folders.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        watcher.start(paths: paths) { [weak self] events in
            Task { @MainActor in
                self?.handleFileSystemEvents(events)
            }
        }
    }

    private func scheduleIndexSave() {
        indexSaveTask?.cancel()
        indexSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persistIndexNow()
        }
    }

    /// Stop watching and flush the index (called when the window closes).
    public func shutdown() {
        watcher.stop()
        indexSaveTask?.cancel()
        filterSaveTask?.cancel()
        persistIndexNow()
        // Persist the filter synchronously too: a pending debounce would be lost
        // when the user quits right after typing.
        Self.store(scope: scope)
        Persistence.saveFilters(Persistence.SavedFilters(applied: filter, draft: draftFilter,
                                                         isShowingDraft: isFilterShowingDraft,
                                                         recentCombos: recentCombos))
    }

    private func persistIndexNow() {
        Persistence.saveFolders(folders)
        Persistence.saveIndex(items)
    }

    static func uniqueFolders(_ folders: [LibraryFolder]) -> [LibraryFolder] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.path).inserted }
    }
}
