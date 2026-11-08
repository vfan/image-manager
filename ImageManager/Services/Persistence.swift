import Foundation

/// A tiny, dependency-free store for the folder list and the file index.
///
/// - Folders: `~/Library/Application Support/com.local.ImageManager/folders.json`
/// - Filters: `~/Library/Application Support/com.local.ImageManager/filters.json`
/// - Notes:   `~/Library/Application Support/com.local.ImageManager/notes.json`
/// - Index:   cached in memory only; rebuilt by scanning (0.07 ms/file).
///   Persistence matters much less than having a correct cache, so the index
///   is written next to the folder list so relaunches are instant.
public enum Persistence {
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.local.ImageManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Directory that holds folders.json / index.json / filters.json.
    /// `IMAGE_MANAGER_SUPPORT_DIR` lets scripts and tests use a throwaway
    /// directory (the GUI process otherwise ignores `HOME` for NSSearchPath).
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["IMAGE_MANAGER_SUPPORT_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return supportDirectory
    }

    private static var foldersURL: URL { dataDirectory.appendingPathComponent("folders.json") }
    private static var indexURL: URL { dataDirectory.appendingPathComponent("index.json") }
    private static var filtersURL: URL { dataDirectory.appendingPathComponent("filters.json") }
    nonisolated(unsafe) static var notesOverrideURL: URL?
    private static var notesURL: URL { notesOverrideURL ?? dataDirectory.appendingPathComponent("notes.json") }

    /// Test-only override so the suite never touches the real filters.json.
    nonisolated(unsafe) static var filtersOverrideURL: URL?

    // MARK: Folders

    static func loadFolders() -> [LibraryFolder] {
        guard let data = try? Data(contentsOf: foldersURL) else { return [] }
        return (try? JSONDecoder().decode([LibraryFolder].self, from: data)) ?? []
    }

    static func saveFolders(_ folders: [LibraryFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }

    // MARK: Filters

    /// What to remember about the dimension filter between launches: the last
    /// applied filter, the draft the user was typing, and the matching list of
    /// long-side / short-side bounds they use most.
    struct SavedFilters: Codable {
        var applied: DimensionFilter?
        var draft: DimensionFilter?
        var isShowingDraft = false
        var recentCombos: [String] = []
    }

    static func loadFilters() -> SavedFilters? {
        guard let data = try? Data(contentsOf: filtersOverrideURL ?? filtersURL) else { return nil }
        return try? JSONDecoder().decode(SavedFilters.self, from: data)
    }

    static func saveFilters(_ saved: SavedFilters) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: filtersOverrideURL ?? filtersURL, options: .atomic)
    }

    // MARK: Group notes

    static func loadNotes() -> [GroupNote] {
        guard let data = try? Data(contentsOf: notesURL) else { return [] }
        return (try? JSONDecoder().decode([GroupNote].self, from: data)) ?? []
    }

    static func saveNotes(_ notes: [GroupNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: notesURL, options: .atomic)
    }

    // MARK: Index cache

    private struct CachedItem: Codable {
        var path: String
        var rootPath: String
        var relativePath: String
        var fileName: String
        var width: Int
        var height: Int
        var fileSize: Int64
        var modifiedAt: Double
        /// Added later than the first index format; older caches omit it and
        /// are re-read once so creation times stay accurate.
        var createdAt: Double?
        var bitDepth: Int
        var colorType: Int

        init(_ item: ImageItem) {
            path = item.path
            rootPath = item.rootPath
            relativePath = item.relativePath
            fileName = item.fileName
            width = item.pixelWidth
            height = item.pixelHeight
            fileSize = item.fileSize
            modifiedAt = item.modifiedAt.timeIntervalSince1970
            createdAt = item.createdAt.timeIntervalSince1970
            bitDepth = item.bitDepth
            colorType = item.colorType
        }

        var item: ImageItem {
            ImageItem(path: path, rootPath: rootPath, relativePath: relativePath, fileName: fileName,
                      pixelWidth: width, pixelHeight: height, fileSize: fileSize,
                      modifiedAt: Date(timeIntervalSince1970: modifiedAt),
                      createdAt: createdAt.map { Date(timeIntervalSince1970: $0) },
                      bitDepth: bitDepth, colorType: colorType)
        }
    }

    static func loadIndex() -> [ImageItem]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return (try? JSONDecoder().decode([CachedItem].self, from: data))?
            .filter { $0.createdAt != nil }   // legacy rows get re-read once
            .map(\.item)
    }

    static func saveIndex(_ items: [ImageItem]) {
        guard let data = try? JSONEncoder().encode(items.map(CachedItem.init)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Drop the cached index when a folder is removed from the library.
    static func invalidateIndex() {
        try? FileManager.default.removeItem(at: indexURL)
    }
}
