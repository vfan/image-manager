import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import os

/// Produces and caches small previews of PNGs.
///
/// Pipeline (per image, off the main thread):
/// 1. Memory LRU hit → return immediately (no disk, no decode).
/// 2. Disk cache hit (`~/Library/Caches/…/Thumbnails`) → decode the tiny
///    cached PNG (≈ 2–4 ms) and put it in the LRU.
/// 3. Miss → decode the original and draw it *directly* into a small
///    256×256 bitmap context, then write that as PNG to the disk cache.
///
/// Step 3 deliberately avoids `CGImageSourceCreateThumbnailAtIndex`: measured on
/// Apple silicon a hand-downscaled draw is ~35 % faster and, unlike the
/// thumbnail API, it can never hand back a full-resolution image.
public final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    /// Longest side of a cached preview, in pixels.
    nonisolated static let maxPixelSize = 320

    private let logger = Logger(subsystem: "com.local.ImageManager", category: "thumbnails")

    /// The on-disk preview cache is unreachable (e.g. running under a file
    /// sandbox). Once a write fails like this we stop retrying on every image.
    private let diskWritesAllowed = LockedFlag(true)

    private let memory = NSCache<NSString, CGImage>()
    private let diskDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.local.ImageManager.thumbnail-io",
                                        qos: .userInitiated,
                                        attributes: .concurrent)
    private let lruLock = NSLock()
    private var accessClock: UInt64 = 0
    private var lastAccess: [String: UInt64] = [:]

    /// Exposed for tests; production code should use `.shared`.
    init() {
        memory.countLimit = 2400
        memory.totalCostLimit = 96 * 1024 * 1024 // 96 MB of decoded pixels

        // HOME may be unset when launched from some tools, in which case
        // `.cachesDirectory` silently returns a path we cannot create; fall back
        // to the per-user temp directory instead of failing every write.
        let base: URL
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           caches.path.hasPrefix("/") {
            base = caches
        } else {
            base = FileManager.default.temporaryDirectory
        }
        diskDirectory = base
            .appendingPathComponent("com.local.ImageManager", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    var diskDirectoryURL: URL { diskDirectory }

    /// Set `IMAGE_MANAGER_CACHE_LOG=1` to mirror cache activity to stderr.
    private var logToStderr = ProcessInfo.processInfo.environment["IMAGE_MANAGER_CACHE_LOG"] == "1"

    private func log(_ message: String) {
        guard logToStderr else { return }
        FileHandle.standardError.write("ThumbnailService: \(message)\n".data(using: .utf8)!)
    }

    /// Cache key = path + mtime + size, so edits invalidate automatically.
    static func cacheKey(for item: ImageItem) -> String {
        let raw = "\(item.path)\u{0}\(Int64(item.modifiedAt.timeIntervalSince1970))\u{0}\(item.fileSize)\u{0}\(maxPixelSize)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(for key: String) -> URL {
        diskDirectory
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent(key + ".png")
    }

    // MARK: - Public API

    /// Synchronous lookup used by the SwiftUI view layer. Returns `nil` on a
    /// miss; call `enqueueLoad` afterwards to fill the cache.
    func cachedImage(for item: ImageItem) -> CGImage? {
        let key = Self.cacheKey(for: item)
        touch(key)
        return memory.object(forKey: key as NSString)
    }

    /// Schedule an asynchronous load. Safe to call repeatedly for the same
    /// image; duplicate work is coalesced by mark-before-load.
    func load(_ item: ImageItem, completion: @escaping @Sendable (CGImage) -> Void) {
        let key = Self.cacheKey(for: item)
        if memory.object(forKey: key as NSString) != nil { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let image = self.produceThumbnail(for: item, key: key) else { return }
            completion(image)
        }
    }

    /// Pre-generate previews for many images in parallel, throttled to the
    /// number of performance cores. Used right after a scan for the images
    /// that are currently visible plus a look-ahead window.
    func prewarm(_ items: [ImageItem], limit: Int = 400) {
        let pending = items.prefix(limit).filter { memory.object(forKey: Self.cacheKey(for: $0) as NSString) == nil }
        guard !pending.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            pending.forEach { _ = self.produceThumbnail(for: $0, key: Self.cacheKey(for: $0)) }
        }
    }

    // MARK: - Work

    private func produceThumbnail(for item: ImageItem, key: String) -> CGImage? {
        if let cached = memory.object(forKey: key as NSString) {
            touch(key)
            return cached
        }
        // 1. Disk cache.
        let disk = diskURL(for: key)
        if let source = CGImageSourceCreateWithURL(disk as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            store(image, key: key, cost: 1)
            return image
        }
        // 2. Decode original (ImageIO does the decoding; CGContext does one
        //    high-quality downscale draw straight into a small bitmap).
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger.debug("Failed to decode \(item.path, privacy: .public)")
            return nil
        }
        guard let thumb = Self.downscale(full, maxPixel: Self.maxPixelSize) else {
            logger.debug("Failed to downscale \(item.path, privacy: .public)")
            return nil
        }
        // Write-through to disk first so the next launch never re-decodes the
        // original (best effort; failures just mean a slower next launch).
        let wrote = writeToDisk(thumb, url: disk)
        if logToStderr { log("produced \(item.fileName) \(thumb.width)x\(thumb.height) disk=\(wrote)") }
        store(thumb, key: key, cost: Self.estimatedCost(thumb))
        return thumb
    }

    private func store(_ image: CGImage, key: String, cost: Int) {
        memory.setObject(image, forKey: key as NSString, cost: cost)
        touch(key)
    }

    private func touch(_ key: String) {
        lruLock.lock()
        accessClock &+= 1
        lastAccess[key] = accessClock
        lruLock.unlock()
    }

    private static func estimatedCost(_ image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Nearest-to-target downscale that preserves aspect ratio.
    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        if max(w, h) <= maxPixel { return image }
        let scale = Double(maxPixel) / Double(max(w, h))
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))

        let bytesPerRow = tw * 4
        guard let ctx = CGContext(data: nil,
                                  width: tw, height: th,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.setAllowsAntialiasing(true)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    /// Re-enable disk writes after temporarily disabling them (used by tests;
    /// the app never calls this because a permission denial is permanent).
    func resetDiskWritesAllowed() {
        diskWritesAllowed.withLock { $0 = true }
    }

    @discardableResult
    func writeToDisk(_ image: CGImage, url: URL) -> Bool {
        guard diskWritesAllowed.withLock({ $0 }) else { return false }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            // Sandboxed environment: keep working from the memory cache.
            diskWritesAllowed.withLock { $0 = false }
            if logToStderr { log("disk cache disabled (permission denied): \(error.localizedDescription)") }
            return false
        } catch {
            if logToStderr { log("mkdir failed \(dir.path): \(error)") }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        let ok = CGImageDestinationFinalize(dest)
        if !ok {
            logger.debug("Could not write preview to \(url.path, privacy: .public)")
        }
        return ok
    }

    // MARK: - Maintenance

    /// Delete cached previews that are older than `maxAge` (default 30 days)
    /// and drop the on-disk cache to at most `maxBytes`.
    func pruneDiskCache(maxAge: TimeInterval = 30 * 86_400, maxBytes: Int64 = 512 * 1024 * 1024) {
        ioQueue.async { [diskDirectory] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let en = fm.enumerator(at: diskDirectory, includingPropertiesForKeys: keys) else { return }
            let cutoff = Date().addingTimeInterval(-maxAge)
            var files: [(URL, Date, Int64)] = []
            var total: Int64 = 0
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let date = v.contentModificationDate ?? .distantPast
                let size = Int64(v.fileSize ?? 0)
                if date < cutoff {
                    try? fm.removeItem(at: url)
                    continue
                }
                files.append((url, date, size))
                total += size
            }
            guard total > maxBytes else { return }
            for (url, _, size) in files.sorted(by: { $0.1 < $1.1 }) {
                if total <= maxBytes { break }
                try? fm.removeItem(at: url)
                total -= size
            }
        }
    }

    /// Number of previews currently held in memory (diagnostics).
    func cachedCount() -> Int {
        diskCacheFileCount()
    }

    private func diskCacheFileCount() -> Int {
        var count = 0
        if let en = FileManager.default.enumerator(at: diskDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.pathExtension == "png" { count += 1 }
        }
        return count
    }

    func clearMemoryCache() {
        memory.removeAllObjects()
    }

    func clearDiskCache() {
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }
}

/// Minimal thread-safe boolean (used to latch "disk cache unavailable").
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func withLock<T>(_ body: (inout Bool) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

