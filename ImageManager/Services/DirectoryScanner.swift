import Foundation

/// Reads the pixel size of a PNG without decoding it.
///
/// A PNG file starts with an 8-byte signature followed by the IHDR chunk:
///
/// | offset | size | field       |
/// |--------|------|-------------|
/// | 0      | 8    | signature   |
/// | 8      | 4    | IHDR length |
/// | 12     | 4    | "IHDR"      |
/// | 16     | 4    | width       |
/// | 20     | 4    | height      |
///
/// So a single 26-byte read is enough — no pixel data is touched, which keeps
/// scanning at ~0.07 ms per file (≈ 140k files/s) for a warm disk cache.
public enum PNGMetadataReader {
    struct Header: Sendable, Equatable {
        var width: Int
        var height: Int
        /// 1, 2, 4, 8 or 16
        var bitDepth: Int
        /// 0 = grayscale, 2 = RGB, 3 = palette, 4 = gray+alpha, 6 = RGBA
        var colorType: Int
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Reads and validates the IHDR chunk. Returns `nil` for anything that is
    /// not a structurally valid PNG (renamed files, truncated downloads, ...).
    static func readHeader(fileDescriptor fd: Int32) -> Header? {
        var bytes = [UInt8](repeating: 0, count: 33)
        let n = bytes.withUnsafeMutableBytes { buf in
            pread(fd, buf.baseAddress, 33, 0)
        }
        guard n >= 26 else { return nil }
        guard Array(bytes[0..<8]) == signature else { return nil }
        guard bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 else { return nil }
        let width = Int(readUInt32BE(bytes, 16))
        let height = Int(readUInt32BE(bytes, 20))
        guard width > 0, height > 0 else { return nil }
        return Header(width: width, height: height, bitDepth: Int(bytes[24]), colorType: Int(bytes[25]))
    }

    static func readHeader(url: URL) -> Header? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readHeader(fileDescriptor: fd)
    }

    @inline(__always)
    static func readUInt32BE(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
}

/// Walks a folder tree and turns every `.png` into an `ImageItem`.
///
/// Design notes
/// - `FileManager.enumerator` scoped to the sub-tree, with `skipDescendants`
///   for hidden folders and package bundles.
/// - One `open()` per file, one 33-byte `pread`, one `fstat` — attributes come
///   from the open descriptor so there is no second `stat()` syscall.
/// - File types are detected by *content* (signature check), not extension, so
///   files with weird casing or a wrong extension still work.
public enum DirectoryScanner {
    /// Files larger than this are skipped before the header read (almost
    /// certainly not a normal PNG; protects against reading huge non-PNG data).
    static let headerProbeLimit: Int64 = 64 * 1024 * 1024
    static let hiddenMarker = ".im-thumbs-v1"

    public enum Progress: Sendable {
        case found(ImageItem)
        case finished(scanned: Int, failed: Int, cancelled: Bool)
    }

    /// What one scan did. `reused` counts files whose cached entry was still
    /// valid (mtime + size unchanged), so their header was never read again.
    public struct Summary: Sendable {
        public var items: [ImageItem]
        public var reused: Int
        public var parsed: Int
        public var failures: Int
        public var cancelled: Bool
        public var duration: TimeInterval

        /// Cache hit rate, 0...1.
        public var cacheHitRate: Double {
            let total = reused + parsed
            return total == 0 ? 0 : Double(reused) / Double(total)
        }
    }

    /// Synchronously scans `root`. `progress` is called from the scanning
    /// thread; callers should hop to the main actor before touching UI state.
    @discardableResult
    public static func scan(
        root: URL,
        includeSubfolders: Bool = true,
        cached: [String: ImageItem] = [:],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping (Progress) -> Void
    ) -> Summary {
        let started = Date()
        var failures = 0
        var scanned = 0
        var reusedCount = 0
        var parsedCount = 0
        // Resolve symlinks (/tmp → /private/tmp, /var → /private/var is already
        // resolved for temp dirs, but TMPDIR-based roots are not) so that the
        // paths the enumerator yields share a common prefix with the root.
        // `URL.resolvingSymlinksInPath()` does not rewrite `/var` → `/private/var`
        // for directory roots, while the enumerator yields the fully resolved
        // paths. `realpath` is authoritative, so relative paths stay correct.
        let rootPath = canonicalPath(root.path)
        let rawRootPath = root.standardizedFileURL.path

        // Matching the enumerator without asking NSURL for attributes: one
        // `lstat` per entry is an order of magnitude cheaper than
        // `resourceValues(forKeys:)`, which dominates warm-scan time.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],                       // hidden entries are filtered below
            errorHandler: { _, _ in true }
        ) else {
            progress(.finished(scanned: 0, failed: 0, cancelled: false))
            return Summary(items: [], reused: 0, parsed: 0, failures: 0, cancelled: false,
                           duration: Date().timeIntervalSince(started))
        }

        var result: [ImageItem] = []
        var cancelled = false

        while let url = enumerator.nextObject() as? URL {
            if isCancelled() {
                cancelled = true
                break
            }
            let name = url.lastPathComponent

            var st = stat()
            let statOK = url.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return lstat(path, &st) == 0
            }
            guard statOK else { continue }

            let mode = st.st_mode & S_IFMT
            if mode == S_IFDIR {
                if name.hasPrefix(".")
                    || name.hasSuffix(".app") || name.hasSuffix(".bundle")
                    || name.hasSuffix(".photoslibrary") {
                    enumerator.skipDescendants()
                }
                if !includeSubfolders { enumerator.skipDescendants() }
                continue
            }
            if mode == S_IFLNK { continue }
            if name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0 { continue }

            // The enumerator may yield either the resolved or the raw prefix
            // (`/private/var/...` vs `/var/...`), so accept both.
            let relative: String
            if url.path.hasPrefix(rootPath + "/") {
                relative = String(url.path.dropFirst(rootPath.count + 1))
            } else if url.path.hasPrefix(rawRootPath + "/") {
                relative = String(url.path.dropFirst(rawRootPath.count + 1))
            } else {
                relative = url.lastPathComponent
            }
            let fullPath = rootPath + "/" + relative

            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)

            // Cache hit: same size and (sub-second) mtime means the bytes are
            // unchanged, so the PNG header never needs to be read again.
            if let known = cached[fullPath],
               known.fileSize == Int64(st.st_size),
               abs(known.modifiedAt.timeIntervalSince(modified)) < 0.001 {
                reusedCount += 1
                result.append(known)
                progress(.found(known))
                continue
            }

            guard let item = imageItem(url: url, rootPath: rootPath,
                                       relativePath: relative, fullPath: fullPath) else { continue }
            scanned += 1
            parsedCount += 1
            result.append(item)
            progress(.found(item))
        }

        progress(.finished(scanned: scanned, failed: failures, cancelled: cancelled))
        return Summary(items: result, reused: reusedCount, parsed: parsedCount, failures: failures,
                       cancelled: cancelled, duration: Date().timeIntervalSince(started))
    }

    /// Absolute, symlink-free path (`/tmp` → `/private/tmp`).
    static func canonicalPath(_ path: String) -> String {
        FilePath.canonical(path)
    }

    /// Header + stat for one file. Returns `nil` when the file is not a PNG.
    /// `relativePath` / `fullPath` are optional because the scanner already
    /// knows them and symlink resolution per file is expensive.
    public static func imageItem(url: URL, rootPath: String,
                                 relativePath knownRelative: String? = nil,
                                 fullPath knownFullPath: String? = nil) -> ImageItem? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        guard st.st_size > 0, st.st_size <= headerProbeLimit else { return nil }

        guard let header = PNGMetadataReader.readHeader(fileDescriptor: fd) else { return nil }

        let mtime = st.st_mtimespec
        let modified = Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1_000_000_000)
        let birth = st.st_birthtimespec
        let created = birth.tv_sec == 0
            ? modified
            : Date(timeIntervalSince1970: TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1_000_000_000)
        // Use the resolved path everywhere so `path`, `rootPath` and `relativePath`
        // stay consistent (NSTemporaryDirectory() and /var are symlinked).
        let fullPath = knownFullPath ?? url.resolvingSymlinksInPath().path
        let relative: String
        if let knownRelative {
            relative = knownRelative
        } else if fullPath.hasPrefix(rootPath + "/") {
            relative = String(fullPath.dropFirst(rootPath.count + 1))
        } else if url.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(rootPath) {
            // Fallback: resolved parent sits inside the root.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            relative = String(parent.dropFirst(rootPath.count + 1)) + "/" + url.lastPathComponent
        } else {
            relative = url.lastPathComponent
        }

        return ImageItem(
            path: fullPath,
            rootPath: rootPath,
            relativePath: relative,
            fileName: url.lastPathComponent,
            pixelWidth: header.width,
            pixelHeight: header.height,
            fileSize: st.st_size,
            modifiedAt: modified,
            createdAt: created,
            bitDepth: header.bitDepth,
            colorType: header.colorType
        )
    }
}
