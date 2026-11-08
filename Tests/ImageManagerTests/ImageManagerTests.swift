import Testing
import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import ImageManagerCore

// MARK: - Fixtures

/// Writes a structurally valid PNG of the given size (solid colour, small
/// file) without depending on any image library.
@discardableResult
/// Convenience `ImageItem` for pure grouping tests (no file on disk).
func item(_ root: String, _ name: String, _ w: Int, _ h: Int, created: Date? = nil) -> ImageItem {
    let date = created ?? Date()
    return ImageItem(path: root + "/" + name, rootPath: root, relativePath: name,
                     fileName: (name as NSString).lastPathComponent,
                     pixelWidth: w, pixelHeight: h, fileSize: 100,
                     modifiedAt: date, createdAt: date, bitDepth: 8, colorType: 6)
}

@discardableResult
func writePNG(at url: URL, width: Int, height: Int, colorType: UInt8 = 6) throws -> URL {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    func appendChunk(_ type: String, _ data: [UInt8]) {
        var len = [UInt8](repeating: 0, count: 4)
        let n = UInt32(data.count)
        len[0] = UInt8(n >> 24); len[1] = UInt8(n >> 16 & 0xFF); len[2] = UInt8(n >> 8 & 0xFF); len[3] = UInt8(n & 0xFF)
        bytes += len
        let typeBytes = Array(type.utf8)
        bytes += typeBytes
        bytes += data
        var crc = crc32(typeBytes + data)
        var crcBytes = [UInt8](repeating: 0, count: 4)
        crcBytes[0] = UInt8(crc >> 24); crcBytes[1] = UInt8(crc >> 16 & 0xFF); crcBytes[2] = UInt8(crc >> 8 & 0xFF); crcBytes[3] = UInt8(crc & 0xFF)
        bytes += crcBytes
        _ = crc
    }
    var ihdr = [UInt8](repeating: 0, count: 13)
    ihdr[0] = UInt8(width >> 24 & 0xFF); ihdr[1] = UInt8(width >> 16 & 0xFF); ihdr[2] = UInt8(width >> 8 & 0xFF); ihdr[3] = UInt8(width & 0xFF)
    ihdr[4] = UInt8(height >> 24 & 0xFF); ihdr[5] = UInt8(height >> 16 & 0xFF); ihdr[6] = UInt8(height >> 8 & 0xFF); ihdr[7] = UInt8(height & 0xFF)
    ihdr[8] = 8
    ihdr[9] = colorType
    appendChunk("IHDR", ihdr)
    // A zlib stream containing a solid row is enough for ImageIO.
    appendChunk("IDAT", zlibStream(count: 64))
    appendChunk("IEND", [])
    try Data(bytes).write(to: url)
    return url
}

private func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in data {
        c ^= UInt32(b)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1
        }
    }
    return c ^ 0xFFFF_FFFF
}

/// Minimal zlib stored (uncompressed) stream.
private func zlibStream(count: Int) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01] // zlib header
    let blockSize = min(count, 65535)
    out.append(0x01) // final, stored
    out.append(UInt8(blockSize & 0xFF))
    out.append(UInt8(blockSize >> 8))
    out.append(UInt8(~blockSize & 0xFF))
    out.append(UInt8((~blockSize >> 8) & 0xFF))
    out += [UInt8](repeating: 0, count: blockSize)
    // adler32 of the data (all zeros → base value)
    var a: UInt32 = 1, b: UInt32 = 0
    for _ in 0..<blockSize {
        a = (a + 0) % 65521
        b = (b + a) % 65521
    }
    let adler = (b << 16) | a
    out.append(UInt8(adler >> 24 & 0xFF)); out.append(UInt8(adler >> 16 & 0xFF))
    out.append(UInt8(adler >> 8 & 0xFF)); out.append(UInt8(adler & 0xFF))
    return out
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageManagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Header reader

@Suite("PNG header reader")
struct PNGHeaderTests {
    @Test func readsSizeAndColorType() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writePNG(at: dir.appendingPathComponent("a.png"), width: 1920, height: 1080, colorType: 6)
        let header = PNGMetadataReader.readHeader(url: url)
        #expect(header?.width == 1920)
        #expect(header?.height == 1080)
        #expect(header?.colorType == 6)
        #expect(header?.bitDepth == 8)
    }

    @Test func rejectsNonPNG() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fake.png")
        try Data("hello world, definitely not a png".utf8).write(to: url)
        #expect(PNGMetadataReader.readHeader(url: url) == nil)
    }

    @Test func rejectsTruncatedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cut.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        #expect(PNGMetadataReader.readHeader(url: url) == nil)
    }
}

// MARK: - Scanner

@Suite("Directory scanner")
struct ScannerTests {
    @Test func findsPNGsRecursivelyAndSkipsNoise() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePNG(at: root.appendingPathComponent("top.png"), width: 100, height: 50)
        let sub = root.appendingPathComponent("icons/dark")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writePNG(at: sub.appendingPathComponent("gear.png"), width: 32, height: 32)
        try Data("nope".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("nope".utf8).write(to: root.appendingPathComponent("broken.png"))
        try writePNG(at: root.appendingPathComponent(".hidden.png"), width: 1, height: 1)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"),
                                                    withDestinationURL: root.appendingPathComponent("top.png"))

        var found: [ImageItem] = []
        let result = DirectoryScanner.scan(root: root) { event in
            if case .found(let item) = event { found.append(item) }
        }
        #expect(result.items.count == 2)
        #expect(found.count == 2)
        let gear = result.items.first { $0.fileName == "gear.png" }
        #expect(gear?.relativePath == "icons/dark/gear.png", "got \(gear?.relativePath ?? "nil") for root \(root.path)")
        #expect(gear?.rootPath == DirectoryScanner.canonicalPath(root.path), "根目录必须用真实路径（/private/var/...）")
        #expect(gear?.pixelWidth == 32)
    }

    @Test func nonRecursiveModeOnlyLooksAtTopLevel() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePNG(at: root.appendingPathComponent("a.png"), width: 10, height: 10)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writePNG(at: sub.appendingPathComponent("b.png"), width: 10, height: 10)
        let result = DirectoryScanner.scan(root: root, includeSubfolders: false) { _ in }
        #expect(result.items.count == 1)
    }

    @Test func cancellationStopsEarly() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<50 {
            try writePNG(at: root.appendingPathComponent("p\(i).png"), width: 10, height: 10)
        }
        let result = DirectoryScanner.scan(root: root, isCancelled: { true }) { _ in }
        #expect(result.items.isEmpty)
    }

    @Test func measuresThroughputOnLargeTree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<2000 {
            try writePNG(at: root.appendingPathComponent("img\(i).png"), width: 512 + i % 7, height: 512)
        }
        let start = Date()
        let result = DirectoryScanner.scan(root: root) { _ in }
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "scanned %d files in %.1f ms (%.3f ms/file)", result.items.count, ms, ms / 2000))
        #expect(result.items.count == 2000)
        #expect(ms < 2000, "scanning 2 000 files should take well under 2 s")
    }
}

// MARK: - Grouping

@Suite("Size grouping")
struct GroupingTests {
    @Test(arguments: [
        (1920, 1080, AspectCategory.landscape16x9),
        (2560, 1440, AspectCategory.landscape16x9),
        (3840, 2160, AspectCategory.landscape16x9),
        (1024, 1024, AspectCategory.square),
        (512, 512, AspectCategory.square),
        (2048, 2048, AspectCategory.square),
        (800, 600, AspectCategory.landscape4x3),
        (1600, 1200, AspectCategory.landscape4x3),
        (1200, 900, AspectCategory.landscape4x3),
        (3440, 1440, AspectCategory.ultrawide),
        (2560, 1080, AspectCategory.ultrawide),
        (1080, 1920, AspectCategory.portrait9x16),
        (1440, 2560, AspectCategory.portrait9x16),
        (600, 800, AspectCategory.portrait4x3),
        (300, 900, AspectCategory.tall),
        (1000, 1200, AspectCategory.portrait4x3),
        (1400, 1000, AspectCategory.landscape4x3),
    ])
    func classifiesAspectRatios(width: Int, height: Int, expected: AspectCategory) {
        #expect(AspectCategory.classify(width: width, height: height) == expected)
    }

    @Test func widthBucketsCoverBoundaries() {
        #expect(WidthBucket(width: 512) == .tiny)
        #expect(WidthBucket(width: 513) == .small)
        #expect(WidthBucket(width: 1024) == .small)
        #expect(WidthBucket(width: 1025) == .medium)
        #expect(WidthBucket(width: 2048) == .medium)
        #expect(WidthBucket(width: 4096) == .large)
        #expect(WidthBucket(width: 4097) == .huge)
    }

    @Test func statisticsAggregate() {
        let items = [
            item(w: 1920, h: 1080, size: 1000, alpha: true),
            item(w: 1920, h: 1080, size: 2000, alpha: false),
            item(w: 2560, h: 1440, size: 3000, alpha: true),
            item(w: 256, h: 256, size: 400, alpha: false),
        ]
        let stats = LibraryStatistics.make(from: items)
        #expect(stats.totalCount == 4)
        #expect(stats.totalBytes == 6400)
        #expect(stats.aspectCounts[.landscape16x9] == 3)
        #expect(stats.aspectCounts[.square] == 1)
        #expect(stats.exactSizeGroups.first?.label == "1920 × 1080")
        #expect(stats.exactSizeGroups.first?.count == 2)
        #expect(stats.largest?.pixelCount == 2560 * 1440)
        #expect(stats.smallest?.pixelCount == 256 * 256)
    }

    @Test func groupKeyRoundTrips() {
        let key = GroupKey.exactSize(SizeGroup(width: 1024, height: 1024, count: 3, totalBytes: 100))
        #expect(key.id == "size:1024x1024")
        #expect(key.title == "1024 × 1024")
        #expect(key.matches(item(w: 1024, h: 1024, size: 1, alpha: false)))
        #expect(!key.matches(item(w: 1025, h: 1024, size: 1, alpha: false)))
        #expect(GroupKey.aspect(.portrait9x16).matches(item(w: 1080, h: 1920, size: 1, alpha: true)))
    }

    private func item(w: Int, h: Int, size: Int64, alpha: Bool) -> ImageItem {
        ImageItem(path: "/tmp/\(w)x\(h)-\(size).png", rootPath: "/tmp", relativePath: "x.png",
                  fileName: "x.png", pixelWidth: w, pixelHeight: h, fileSize: size,
                  modifiedAt: Date(), bitDepth: 8, colorType: alpha ? 6 : 2)
    }
}

// MARK: - Thumbnails

@Suite("Thumbnail pipeline")
struct ThumbnailTests {
    @Test func fullPipelineThumbnailsRealPNGAndCachesToDisk() async throws {
        // Solid 1200×600 RGBA PNG written through ImageIO so it is guaranteed
        // decodable in any environment.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wide.png")
        let ctx = CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let item = ImageItem(path: url.path, rootPath: dir.path, relativePath: "wide.png", fileName: "wide.png",
                             pixelWidth: 1200, pixelHeight: 600, fileSize: attrs[.size] as? Int64 ?? 0,
                             modifiedAt: attrs[.modificationDate] as? Date ?? Date(), bitDepth: 8, colorType: 6)

        // A cold service instance (own memory cache) forces the full disk path.
        let service = ThumbnailService()
        let expectation = XCTestExpectation(description: "thumbnail produced")
        service.load(item) { image in
            #expect(image.width == ThumbnailService.maxPixelSize)
            #expect(image.height == 160)
            expectation.fulfill()
        }
        service.prewarm([item])
        _ = await XCTWaiter().fulfillment(of: [expectation], timeout: 15)

        // Second call must hit the disk cache (file written on first pass).
        let renderStart = Date()
        let again = service.cachedImage(for: item)
        #expect(again != nil, "preview should be in the memory cache after load")
        #expect(Date().timeIntervalSince(renderStart) < 0.05)

        let key = ThumbnailService.cacheKey(for: item)
        // Write the same preview through an explicit temp path: this exercises
        // the PNG encoder independently of whether ~/Library/Caches is
        // writable in the current test environment (CI and sandboxes may deny it).
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(key).png")
        service.resetDiskWritesAllowed()
        let wrotePreview = service.writeToDisk(again!, url: probeURL)
        let previewReadable = CGImageSourceCreateWithURL(probeURL as CFURL, nil) != nil
        #expect(wrotePreview, "PNG preview writer should succeed when the cache dir is writable")
        #expect(previewReadable)
        try? FileManager.default.removeItem(at: probeURL)

        guard FileManager.default.isWritableFile(atPath: service.diskDirectoryURL.deletingLastPathComponent().path) else {
            return // sandboxed runner cannot write the shared cache; covered above
        }
        let diskFile = service.diskDirectoryURL.appendingPathComponent(String(key.prefix(2))).appendingPathComponent(key + ".png")
        #expect(FileManager.default.fileExists(atPath: diskFile.path), "preview should be written to the disk cache")
        let cachedSource = CGImageSourceCreateWithURL(diskFile as CFURL, nil)
        #expect(cachedSource != nil)
    }

    @Test func downscaleKeepsAspectRatio() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
        let full = ctx.makeImage()!
        let thumb = ThumbnailService.downscale(full, maxPixel: 256)
        #expect(thumb?.width == 256)
        #expect(thumb?.height == 128)
    }

    @Test func smallImagesAreNotUpscaled() throws {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let small = ctx.makeImage()!
        let thumb = ThumbnailService.downscale(small, maxPixel: 256)
        #expect(thumb?.width == 40)
    }

    @Test func cacheKeyChangesWithModification() {
        let a = ImageItem(path: "/x/a.png", rootPath: "/x", relativePath: "a.png", fileName: "a.png",
                          pixelWidth: 10, pixelHeight: 10, fileSize: 1,
                          modifiedAt: Date(timeIntervalSince1970: 100), bitDepth: 8, colorType: 6)
        var b = a
        b.modifiedAt = Date(timeIntervalSince1970: 200)
        #expect(ThumbnailService.cacheKey(for: a) != ThumbnailService.cacheKey(for: b))
    }
}

// MARK: - Dimension filter

@Suite("Dimension filter")
struct DimensionFilterTests {
    private func make(_ w: Int, _ h: Int, _ name: String = "a.png") -> ImageItem {
        ImageItem(path: "/lib/\(name)", rootPath: "/lib", relativePath: name, fileName: name,
                  pixelWidth: w, pixelHeight: h, fileSize: 1000, modifiedAt: Date(timeIntervalSince1970: 0),
                  bitDepth: 8, colorType: 6)
    }

    @Test func longSideAndShortSideAreOrientationProof() {
        var f = DimensionFilter()
        f.set(.longSide, min: 1000, max: 2000)      // 1080p / 1440p long side
        f.set(.shortSide, max: 1100)                // 1080p short side
        #expect(f.matches(make(1920, 1080)))        // 横图
        #expect(f.matches(make(1080, 1920)))        // 竖图同样通过
        #expect(!f.matches(make(3840, 2160)))       // 4K 长边超出
        #expect(!f.matches(make(800, 600)), "短边 600 在范围内，但长边 800 太短")
    }

    @Test func rangesAreInclusiveAndCanBeHalfOpen() {
        var f = DimensionFilter()
        f.set(.width, min: 100, max: 200)
        #expect(f.matches(make(100, 50)))
        #expect(f.matches(make(200, 50)))
        #expect(!f.matches(make(99, 50)))
        #expect(!f.matches(make(201, 50)))

        var onlyMin = DimensionFilter()
        onlyMin.set(.height, min: 720)
        #expect(onlyMin.matches(make(10, 720)))
        #expect(!onlyMin.matches(make(5000, 719)))
    }

    @Test func disabledRowsDoNotFilterButEmptyEnabledRowsAreInactive() {
        var f = DimensionFilter()
        f.set(.longSide, min: 5000, enabled: false)
        #expect(f.isInactive)
        #expect(f.matches(make(10, 10)))

        f.setEnabled(.longSide, true)
        #expect(f.enabledRanges().count == 1)
        f.setRange(.longSide, DimensionRange())
        #expect(f.isInactive, "enabled but empty range should not narrow")
    }

    @Test func orientationPreference() {
        var f = DimensionFilter()
        f.orientation = .portrait
        #expect(!f.matches(make(1920, 1080)))
        #expect(f.matches(make(1080, 1920)))
        f.orientation = .landscape
        #expect(f.matches(make(1920, 1080)))
    }

    @Test func invertedBoundsAreSwapped() {
        var f = DimensionFilter()
        f.set(.longSide, min: 4000, max: 100)
        let n = f.normalized()
        #expect(n.longSide.min == 100 && n.longSide.max == 4000)
        #expect(n.matches(make(2000, 1000)))
    }

    @Test func unitsConvertBothWays() {
        #expect(DimensionUnit.pixel.toPixels(1080, scale: 2) == 1080)
        #expect(DimensionUnit.thousand.toPixels(2, scale: 2) == 2000)
        #expect(DimensionUnit.dp.toPixels(540, scale: 2) == 1080)
        #expect(DimensionUnit.dp.fromPixels(1080, scale: 2) == 540)
        #expect(DimensionUnit.thousand.fromPixels(2048, scale: 2) == 2)

        var f = DimensionFilter()
        f.unit = .dp
        f.set(.shortSide, max: DimensionUnit.dp.toPixels(540, scale: 2))
        #expect(f.matches(make(1920, 1080)))
        #expect(!f.matches(make(4000, 3000)))
        #expect(f.summary.contains("短边"))
    }

    @Test func quickBoundsCoverTheFiveWantedRanges() {
        #expect(DimensionFilter.QuickLongSide.allCases.count == 5)
        #expect(DimensionFilter.QuickLongSide.allCases.map(\.label)
                == ["小于 100", "小于 300", "大于 300", "大于 500", "大于 1000"])

        let small = DimensionFilter.QuickLongSide.under100.filter()
        #expect(small.matches(make(96, 96)))
        #expect(!small.matches(make(101, 96)))

        let medium = DimensionFilter.QuickLongSide.under300.filter()
        #expect(medium.matches(make(300, 200)))
        #expect(!medium.matches(make(301, 200)))

        let big = DimensionFilter.QuickLongSide.over1000.filter()
        #expect(big.matches(make(1000, 800)))
        #expect(big.matches(make(4000, 3000)))
        #expect(!big.matches(make(999, 999)))
        #expect(big.matches(make(800, 1200)), "长边 1200，竖图也算大图")

        let over500 = DimensionFilter.QuickLongSide.over500.filter()
        #expect(over500.matches(make(500, 400)))
        #expect(!over500.matches(make(499, 400)))
    }

    @Test func activeQuickBoundIsDetected() {
        #expect(DimensionFilter.QuickLongSide.over1000.filter().matchingQuickBound() == .over1000)
        #expect(DimensionFilter().matchingQuickBound() == nil)

        var custom = DimensionFilter()
        custom.set(.longSide, min: 640)
        #expect(custom.matchingQuickBound() == nil, "自定义范围不算任何一个快捷项")

        var plusOrientation = DimensionFilter.QuickLongSide.over500.filter()
        plusOrientation.orientation = .landscape
        #expect(plusOrientation.matchingQuickBound() == nil)
    }

    @Test func summaryDescribesBounds() {
        var f = DimensionFilter()
        f.set(.longSide, min: 512, max: 1920)
        f.orientation = .landscape
        #expect(f.summary == "长边 512 – 1920 px · 横图")
    }

    @Test func rememberedCombosRoundTripThroughJSON() throws {
        var f = DimensionFilter()
        f.set(.longSide, max: 2048)
        f.set(.shortSide, max: 1080)
        let saved = Persistence.SavedFilters(applied: f, draft: f, isShowingDraft: false,
                                             recentCombos: ["2048x1024"])
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(Persistence.SavedFilters.self, from: data)
        #expect(restored.applied == f)
        #expect(restored.draft == f)
        #expect(restored.applied?.matches(make(1920, 1080)) == true)
        #expect(restored.applied?.matches(make(2560, 1440)) == false)
        #expect(restored.applied?.matches(make(2048, 1080)) == true)
        #expect(restored.recentCombos == ["2048x1024"])
    }

    @Test func savedFiltersPersistThroughPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString).json")
        Persistence.filtersOverrideURL = url
        defer {
            Persistence.filtersOverrideURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        var f = DimensionFilter()
        f.set(.longSide, min: 2048)
        Persistence.saveFilters(.init(applied: f, draft: f, isShowingDraft: false, recentCombos: ["4096x2160"]))
        let loaded = Persistence.loadFilters()
        #expect(loaded?.applied == f)
        #expect(loaded?.recentCombos == ["4096x2160"])
    }

    @Test func parsesCommandLineFilterSpec() {
        let f = AppStore.parseFilterArgument("longSide>=2048, shortSide<=2176,orientation=landscape")
        #expect(f?.longSide.min == 2048)
        #expect(f?.shortSide.max == 2176)
        #expect(f?.orientation == .landscape)
        #expect(f?.matches(make(3840, 2160)) == true)
        #expect(f?.matches(make(3840, 2400)) == false, "短边 2400 超过上限")

        let exact = AppStore.parseFilterArgument("width=1920")
        #expect(exact?.matches(make(1920, 1080)) == true)
        #expect(exact?.matches(make(1919, 1080)) == false)
        #expect(AppStore.parseFilterArgument("nonsense") == nil)
    }
}

// MARK: - Grouping defaults

@Suite("Grouping defaults")
struct GroupingDefaultTests {
    @Test func defaultsToPixelSizeNotAspectRatio() {
        #expect(AppStore.defaultGroupingMode == .exactSize)
        let suite = UserDefaults(suiteName: "grouping-tests-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        #expect(AppStore.storedGroupingMode(in: suite) == .exactSize)

        suite.set("aspect", forKey: AppStore.groupingModeDefaultsKey)
        #expect(AppStore.storedGroupingMode(in: suite) == .aspect)

        suite.set("bogus", forKey: AppStore.groupingModeDefaultsKey)
        #expect(AppStore.storedGroupingMode(in: suite) == .exactSize, "unknown value falls back to size")
    }

    @Test func exactSizeKeyMatchesOnlyThatSize() {
        let key = GroupKey.exactSize(width: 1024, height: 768)
        let a = ImageItem(path: "/l/a.png", rootPath: "/l", relativePath: "a.png", fileName: "a.png",
                          pixelWidth: 1024, pixelHeight: 768, fileSize: 1,
                          modifiedAt: Date(timeIntervalSince1970: 0), bitDepth: 8, colorType: 6)
        var b = a
        b.pixelWidth = 768
        b.pixelHeight = 1024
        #expect(key.matches(a))
        #expect(!key.matches(b), "同一比例但宽高互换是另一个尺寸")
        #expect(key.title == "1024 × 768")
        #expect(GroupKey.exactSize(width: 1024, height: 768).id == key.id)
    }

    @Test func modeTitlesCoverAllModes() {
        #expect(GroupKey.Mode.exactSize.title == "尺寸")
        #expect(GroupKey.Mode.exactSize.help.contains("像素尺寸"))
        #expect(GroupKey.Mode.allCases.count == 4)
    }
}

// MARK: - Group notes

@MainActor
@Suite("Group notes")
struct GroupNoteTests {
    private func key(_ w: Int, _ h: Int) -> GroupKey { .exactSize(width: w, height: h) }

    private func withTempNotes(_ body: (AppStore) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).json")
        Persistence.notesOverrideURL = url
        defer {
            Persistence.notesOverrideURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        let store = AppStore()
        try body(store)
    }

    @Test func addEditAndRemoveNote() {
        withTempNotes { store in
            let ios = key(1170, 2532)
            #expect(store.note(for: ios) == nil)

            store.setNote("iOS 截屏", for: ios)
            #expect(store.noteText(for: ios) == "iOS 截屏")

            store.setNote("  iOS 截屏 / 刘海屏  ", for: ios)
            #expect(store.noteText(for: ios) == "iOS 截屏 / 刘海屏", "首尾空白会被裁掉")

            store.removeNote(for: ios)
            #expect(store.note(for: ios) == nil)
        }
    }

    @Test func blankNoteRemovesIt() {
        withTempNotes { store in
            store.setNote("图标", for: key(128, 128))
            store.setNote("   ", for: key(128, 128))
            #expect(store.note(for: key(128, 128)) == nil)
        }
    }

    @Test func notesAreIndependentPerGroupKind() {
        withTempNotes { store in
            let size = GroupKey.exactSize(width: 1920, height: 1080)
            let ratio = GroupKey.aspect(.classify(width: 1920, height: 1080))
            store.setNote("桌面壁纸", for: size)
            store.setNote("宽屏素材", for: ratio)
            #expect(store.noteText(for: size) == "桌面壁纸")
            #expect(store.noteText(for: ratio) == "宽屏素材")
            #expect(size.noteID != ratio.noteID)
        }
    }

    @Test func notesSurviveRelaunch() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).json")
        Persistence.notesOverrideURL = url
        defer {
            Persistence.notesOverrideURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        let first = AppStore()
        first.setNote("公众号封面", for: key(900, 383))

        let saved = Persistence.loadNotes()
        #expect(saved.count == 1)
        #expect(saved.first?.text == "公众号封面")
        #expect(saved.first?.id == key(900, 383).noteID)

        // A second instance reads the same file, as on next launch.
        let second = AppStore()
        second.restoreNotesForTesting()
        #expect(second.noteText(for: key(900, 383)) == "公众号封面")
    }

    @Test func noteTextIsSearchable() {
        withTempNotes { store in
            let ios = key(1170, 2532)
            store.setNote("iOS 截屏", for: ios)
            #expect(store.groupKeysMatchingNote(["ios"]).contains(ios.noteID))
            #expect(store.groupKeysMatchingNote(["ios", "截屏"]).contains(ios.noteID))
            #expect(store.groupKeysMatchingNote(["安卓"]).isEmpty)
        }
    }

    @Test func groupKeyForItemFollowsMode() {
        let item = ImageItem(path: "/l/a.png", rootPath: "/l", relativePath: "a.png", fileName: "a.png",
                             pixelWidth: 1170, pixelHeight: 2532, fileSize: 1,
                             modifiedAt: Date(timeIntervalSince1970: 0), bitDepth: 8, colorType: 6)
        #expect(AppStore.groupKey(for: item, mode: .exactSize).title == "1170 × 2532")
        #expect(AppStore.groupKey(for: item, mode: .aspect).title == "9:16")
    }
}

// MARK: - Sidebar list filtering

@Suite("Sidebar list filtering")
struct SidebarListFilterTests {
    private func make(_ w: Int, _ h: Int, _ name: String) -> ImageItem {
        ImageItem(path: "/lib/\(name)", rootPath: "/lib", relativePath: name, fileName: name,
                  pixelWidth: w, pixelHeight: h, fileSize: 1, modifiedAt: Date(timeIntervalSince1970: 0),
                  bitDepth: 8, colorType: 6)
    }

    private var library: [ImageItem] {
        [make(1920, 1080, "a.png"), make(1920, 1080, "b.png"),
         make(2560, 1440, "c.png"),
         make(1024, 1024, "d.png"), make(1024, 1024, "e.png"), make(1024, 1024, "f.png"),
         make(4000, 3000, "g.png"),
         make(512, 512, "h.png")]
    }

    private func rows(_ items: [ImageItem], threshold: Int = 1) -> [(key: GroupKey, count: Int)] {
        AppStore.makeGroupRows(base: items, mode: .exactSize, threshold: threshold, notes: [:])
    }

    @Test func sizeRowsDropWhenTheRangeNarrows() {
        var f = DimensionFilter()
        f.set(.longSide, min: 2000)
        let filtered = library.filter(f.matches)
        let keys = rows(filtered).map(\.key.title)
        #expect(keys == ["4000 × 3000", "2560 × 1440"], "只剩长边 ≥ 2000 的尺寸，按像素总量从大到小")
        #expect(rows(library).count == 5)
    }

    @Test func countsReflectMatchingImagesOnly() {
        var f = DimensionFilter()
        f.set(.longSide, max: 1920)
        let row = rows(library.filter(f.matches)).first { $0.key.title == "1920 × 1080" }
        #expect(row?.count == 2)
        var square = DimensionFilter()
        square.set(.shortSide, min: 1000, max: 1100)
        let squareRow = rows(library.filter(square.matches)).first { $0.key.title == "1024 × 1024" }
        #expect(squareRow?.count == 3)
    }

    @Test func annotatedSmallGroupSurvivesTheSidebarThreshold() {
        let items = [make(725, 2169, "rare.png")] + library
        let key = GroupKey.exactSize(width: 725, height: 2169)
        #expect(AppStore.makeGroupRows(base: items, mode: .exactSize, threshold: 5, notes: [:])
            .contains { $0.key == key } == false)
        let notes = [key.noteID: GroupNote(id: key.noteID, text: "iOS 截屏")]
        #expect(AppStore.makeGroupRows(base: items, mode: .exactSize, threshold: 5, notes: notes)
            .contains { $0.key == key }, "有备注的小组不受张数阈值限制")
    }

    @Test func aspectRowsFilterByTheirMembers() {
        var f = DimensionFilter()
        f.set(.longSide, max: 1024)
        let rows = AppStore.makeGroupRows(base: library.filter(f.matches), mode: .aspect, threshold: 1, notes: [:])
        #expect(rows.map(\.key.title).contains("1:1"))
        #expect(!rows.map(\.key.title).contains("16:9"), "16:9 组里最低的 1920 长边也超过了 1024")
    }
}

// MARK: - Remembered sidebar selection

@Suite("Remembered selection")
struct RememberedSelectionTests {
    private func folder(_ path: String) -> LibraryFolder { LibraryFolder(id: path) }

    @Test func selectionIDsRoundTrip() {
        let cases: [LibraryScope] = [
            .folder("/tmp/imgmgr/imgs"),
            .group(.aspect(.classify(width: 16, height: 9))),
            .group(.exactSize(width: 1170, height: 2532)),
            .group(.width(.medium)),
            .group(.area(.large)),
        ]
        for scope in cases {
            #expect(LibraryScope(selectionID: scope.sidebarSelectionID) == scope)
        }
        #expect(LibraryScope(selectionID: "all") == .all)
        #expect(LibraryScope(selectionID: "nonsense") == nil)
        #expect(LibraryScope(selectionID: "group:bogus") == nil)
    }

    @Test func restoresLastFolderWhenItStillExists() {
        let defaults = UserDefaults(suiteName: "scope-\(UUID().uuidString)")!
        let folders = [folder("/a"), folder("/b")]
        AppStore.store(scope: .folder("/b"), in: defaults)
        #expect(AppStore.restoredScope(in: defaults, folders: folders) == .folder("/b"))
    }

    @Test func restoresLastGroupRow() {
        let defaults = UserDefaults(suiteName: "scope-\(UUID().uuidString)")!
        let key = GroupKey.exactSize(width: 2048, height: 2048)
        AppStore.store(scope: .group(key), in: defaults)
        #expect(AppStore.restoredScope(in: defaults, folders: [folder("/a")]) == .group(key))
    }

    @Test func missingFolderFallsBackToFirstFolder() {
        let defaults = UserDefaults(suiteName: "scope-\(UUID().uuidString)")!
        AppStore.store(scope: .folder("/gone"), in: defaults)
        #expect(AppStore.restoredScope(in: defaults, folders: [folder("/a"), folder("/b")]) == .folder("/a"))
    }

    @Test func firstLaunchNeverPicksAllImages() {
        let defaults = UserDefaults(suiteName: "scope-\(UUID().uuidString)")!
        #expect(AppStore.restoredScope(in: defaults, folders: [folder("/a"), folder("/b")]) == .folder("/a"))
        #expect(AppStore.restoredScope(in: defaults, folders: []) == .all, "没有目录时才回落到全部图片")
    }

    @Test func legacyAllSelectionIsUpgradedToFirstFolder() {
        let defaults = UserDefaults(suiteName: "scope-\(UUID().uuidString)")!
        defaults.set("all", forKey: AppStore.scopeDefaultsKey)
        #expect(AppStore.restoredScope(in: defaults, folders: [folder("/a")]) == .folder("/a"))
    }
}

@Suite("Creation date")
struct CreationDateTests {
    @Test func scannerReadsBirthTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writePNG(at: dir.appendingPathComponent("shot.png"), width: 4, height: 4)

        let item = try #require(DirectoryScanner.imageItem(url: url, rootPath: dir.path))
        #expect(abs(item.createdAt.timeIntervalSinceNow) < 120, "创建时间应接近刚刚写文件的时间")
        #expect(item.createdAt <= Date().addingTimeInterval(5))
    }

    @Test func cachedIndexKeepsCreationDate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-created-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writePNG(at: dir.appendingPathComponent("shot.png"), width: 4, height: 4)
        _ = url
        let cold = DirectoryScanner.scan(root: dir, includeSubfolders: true, progress: { _ in })
        let first = try #require(cold.items.first)

        let scan = DirectoryScanner.scan(root: dir, includeSubfolders: true,
                                         cached: [first.path: first], progress: { _ in })
        let second = try #require(scan.items.first)
        #expect(scan.reused == 1, "未改动的文件应命中索引，不需要重新读头")
        #expect(abs(second.createdAt.timeIntervalSince(first.createdAt)) < 0.001)
    }
}

// MARK: - Moving between subdirectories

@Suite("Moving files")
struct FileMoverTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func uniqueDestinationNeverOverwrites() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("shot.png"), width: 8, height: 8)
        let target = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        #expect(FileMover.uniqueDestination(for: source, in: target).lastPathComponent == "shot.png")
        try writePNG(at: target.appendingPathComponent("shot.png"), width: 4, height: 4)
        #expect(FileMover.uniqueDestination(for: source, in: target).lastPathComponent == "shot 2.png")
        try writePNG(at: target.appendingPathComponent("shot 2.png"), width: 4, height: 4)
        #expect(FileMover.uniqueDestination(for: source, in: target).lastPathComponent == "shot 3.png")
    }

    @Test func movePutsTheFileInTheTargetFolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("a.png"), width: 16, height: 16)
        let target = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let result = try FileMover.move(source, to: target)
        #expect(result.destination.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: result.destination.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let item = try #require(DirectoryScanner.imageItem(url: result.destination, rootPath: root.path))
        #expect(item.pixelWidth == 16)
        #expect(item.relativePath == "B/a.png")
    }

    @Test func moveIntoMissingFolderFails() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("a.png"), width: 8, height: 8)
        #expect(throws: FileMover.MoveError.self) {
            try FileMover.move(source, to: root.appendingPathComponent("nope"))
        }
        #expect(FileManager.default.fileExists(atPath: source.path), "失败时源文件必须留在原地")
    }

    @Test func onlySubdirectoriesInTheCurrentListAreTargets() {
        let root = "/lib"
        let items = [
            item(root, "A/shot.png", 500, 500),
            item(root, "B/shot.png", 500, 500),
            item(root, "C/shot.png", 500, 500),
            item(root, "D/other.png", 800, 600),   // 不同尺寸，不属于当前分组
        ]
        let scoped = items.filter { $0.pixelWidth == 500 }
        let targets = AppStore.moveTargets(for: items[2], in: scoped, root: root)  // C 里的图
        #expect(targets.map(\.title) == ["A", "B"], "C 里的图只能去 A、B；D 没有这个尺寸，不是候选")
        #expect(!targets.contains { $0.relativePath == "C" }, "不能移动到它自己所在的子目录")
    }

    @Test func targetsAreSortedByPath() {
        let root = "/lib"
        let items = [item(root, "z/作品集/a.png", 100, 100),
                     item(root, "a/截图/b.png", 100, 100),
                     item(root, "m/素材/c.png", 100, 100)]
        let subs = AppStore.subdirectories(in: items, root: root)
        #expect(subs.map(\.title) == ["a/截图", "m/素材", "z/作品集"])
    }

    @Test func rootLevelFilesTargetEverySubdirectory() {
        let root = "/lib"
        let items = [item(root, "home.png", 100, 100), item(root, "A/a.png", 100, 100)]
        let targets = AppStore.moveTargets(for: items[0], in: items, root: root)
        #expect(targets.map(\.title) == ["A"], "根目录的文件可以进任何子目录")
        let subs = AppStore.subdirectories(in: items, root: root)
        #expect(subs.map(\.title) == ["根目录", "A"])
    }
}

// MARK: - Right-hand grouping by subdirectory

@Suite("Section grouping")
struct SectionGroupingTests {
    private func item(_ root: String, _ name: String, _ w: Int, _ h: Int,
                      _ day: Int = 1) -> ImageItem {
        let date = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        return ImageItem(path: root + "/" + name, rootPath: root, relativePath: name,
                         fileName: (name as NSString).lastPathComponent,
                         pixelWidth: w, pixelHeight: h, fileSize: 100,
                         modifiedAt: date, createdAt: date, bitDepth: 8, colorType: 6)
    }

    @Test func selectedGroupSplitsBySubdirectory() {
        let root = "/lib"
        let items = [item(root, "C/c1.png", 500, 500, 5),
                     item(root, "A/a1.png", 500, 500, 3),
                     item(root, "B/b1.png", 500, 500, 4),
                     item(root, "A/deep/a2.png", 500, 500, 2),
                     item(root, "top.png", 500, 500, 1)]
        let sections = AppStore.subdirectorySections(items: items, root: root)
        #expect(Set(sections.map(\.directory.title)) == Set(["A", "B", "C", "A/deep", "根目录"]))
        #expect(sections.count == 5)
        #expect(sections.allSatisfy { $0.items.count == 1 })
        #expect(sections.allSatisfy { $0.items.allSatisfy { $0.pixelWidth == 500 } })
        // C holds the newest image (day 5), then B (4), A (3), A/deep (2), root (1).
        #expect(sections.map(\.directory.title) == ["C", "B", "A", "A/deep", "根目录"])
    }

    @Test func newestPhotoDecidesFolderOrder() {
        let root = "/lib"
        // A has many old images; Z has one brand-new image and must still be first.
        var items = (1...20).map { item(root, "A/old\($0).png", 100, 100, 1) }
        items.append(item(root, "Z/new.png", 100, 100, 9))
        let sections = AppStore.subdirectorySections(items: items, root: root)
        #expect(sections.map(\.directory.title) == ["Z", "A"])
    }

    @Test func itemsInsideASectionKeepTheChosenOrder() {
        let root = "/lib"
        let items = [item(root, "A/new.png", 100, 100, 9),
                     item(root, "A/mid.png", 100, 100, 5),
                     item(root, "A/old.png", 100, 100, 1)]
        let sections = AppStore.subdirectorySections(items: items, root: root)
        #expect(sections.first?.items.map(\.fileName) == ["new.png", "mid.png", "old.png"])
    }

    @Test func nestedSubdirectoriesStayDistinct() {
        let root = "/lib"
        let items = [item(root, "A/a.png", 100, 100, 1), item(root, "A/deep/b.png", 100, 100, 2)]
        let sections = AppStore.subdirectorySections(items: items, root: root)
        #expect(Set(sections.map(\.directory.title)) == ["A", "A/deep"])
        #expect(sections.first?.directory.title == "A/deep", "deeper folder holds the newer photo")
    }

    @Test func emptySubdirectoriesNeverAppear() {
        let root = "/lib"
        let items = [item(root, "C/c1.png", 800, 600)]
        let sections = AppStore.subdirectorySections(items: items, root: root)
        #expect(sections.map(\.directory.title) == ["C"])
    }

    @Test func creationOrderSortsNewestFirst() {
        let root = "/lib"
        let items = [item(root, "old.png", 10, 10, 1),
                     item(root, "new.png", 10, 10, 7),
                     item(root, "mid.png", 10, 10, 4)]
        let sorted = AppStore.sorted(items, by: .createdNewest)
        #expect(sorted.map(\.fileName) == ["new.png", "mid.png", "old.png"])
    }
}

// MARK: - Renaming

@Suite("Renaming files")
struct RenameTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func namesAreSanitized() {
        #expect(FileMover.sanitizedFileName("  hero  ") == "hero.png")
        #expect(FileMover.sanitizedFileName("hero.png") == "hero.png")
        #expect(FileMover.sanitizedFileName("iOS 截屏") == "iOS 截屏.png")
        #expect(FileMover.sanitizedFileName("") == nil)
        #expect(FileMover.sanitizedFileName("   ") == nil)
        #expect(FileMover.sanitizedFileName("a/b.png") == nil)
        #expect(FileMover.sanitizedFileName("a:b.png") == nil)
        #expect(FileMover.sanitizedFileName(".hidden") == nil)
    }

    @Test func renamesOnDiskAndAppendsExtension() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("old.png"), width: 12, height: 12)

        let url = try FileMover.rename(source, to: "新名字")
        #expect(url.lastPathComponent == "新名字.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let item = try #require(DirectoryScanner.imageItem(url: url, rootPath: root.path))
        #expect(item.fileName == "新名字.png")
        #expect(item.pixelWidth == 12)
    }

    @Test func keepsExistingExtension() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("old.png"), width: 8, height: 8)
        let url = try FileMover.rename(source, to: "banner.png")
        #expect(url.lastPathComponent == "banner.png")
    }

    @Test func refusesToOverwriteAnotherFile() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("a.png"), width: 8, height: 8)
        try writePNG(at: root.appendingPathComponent("b.png"), width: 9, height: 9)

        #expect(throws: FileMover.RenameError.self) {
            try FileMover.rename(source, to: "b.png")
        }
        #expect(FileManager.default.fileExists(atPath: source.path), "冲突时源文件不能被改动")
        #expect(try Data(contentsOf: root.appendingPathComponent("b.png")).count > 0)
    }

    @Test func supportsCaseOnlyRename() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("shot.png"), width: 8, height: 8)
        let url = try FileMover.rename(source, to: "SHOT.png")
        #expect(url.lastPathComponent == "SHOT.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Case-insensitive volumes still answer true for the old spelling,
        // so compare the actual directory listing instead.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names == ["SHOT.png"], "大小写改名后目录里只有新名字，没有残留临时文件")
    }

    @Test func rejectsInvalidName() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writePNG(at: root.appendingPathComponent("a.png"), width: 8, height: 8)
        #expect(throws: FileMover.RenameError.self) {
            try FileMover.rename(source, to: "bad/name")
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

// MARK: - Scan cache / incremental indexing

@Suite("Incremental scan")
struct IncrementalScanTests {
    private func makeFolder(_ count: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            try writePNG(at: dir.appendingPathComponent("p\(i).png"), width: 64 + i, height: 64)
        }
        return dir
    }

    @Test func secondScanReusesEveryHeader() throws {
        let root = try makeFolder(20)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = DirectoryScanner.scan(root: root) { _ in }
        #expect(first.parsed == 20)
        #expect(first.reused == 0, "首次扫描没有缓存可用")

        let cache = Dictionary(first.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let second = DirectoryScanner.scan(root: root, cached: cache) { _ in }

        #expect(second.items.count == 20)
        #expect(second.reused == 20, "文件没变，应该零次重新读头")
        #expect(second.parsed == 0)
        #expect(second.cacheHitRate == 1)
        #expect(second.duration <= first.duration + 0.2)
    }

    @Test func changedFileIsReparsedAndKeepsNewSize() throws {
        let root = try makeFolder(4)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DirectoryScanner.scan(root: root) { _ in }
        let cache = Dictionary(first.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        let target = root.appendingPathComponent("p1.png")
        try writePNG(at: target, width: 999, height: 111)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: target.path)

        let second = DirectoryScanner.scan(root: root, cached: cache) { _ in }
        #expect(second.parsed == 1)
        #expect(second.reused == 3)
        let updated = second.items.first { $0.fileName == "p1.png" }
        #expect(updated?.pixelWidth == 999)
        #expect(updated?.pixelHeight == 111)
    }

    @Test func newAndDeletedFilesAreReflected() throws {
        let root = try makeFolder(3)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DirectoryScanner.scan(root: root) { _ in }
        let cache = Dictionary(first.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        try FileManager.default.removeItem(at: root.appendingPathComponent("p0.png"))
        try writePNG(at: root.appendingPathComponent("fresh.png"), width: 12, height: 34)

        let second = DirectoryScanner.scan(root: root, cached: cache) { _ in }
        #expect(second.items.count == 3)
        #expect(second.items.contains { $0.fileName == "fresh.png" })
        #expect(!second.items.contains { $0.fileName == "p0.png" })
        #expect(second.parsed == 1, "只有新文件需要读头")
    }

    @Test func cachedItemIsReturnedUntouched() throws {
        let root = try makeFolder(1)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DirectoryScanner.scan(root: root) { _ in }
        let cache = Dictionary(first.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let second = DirectoryScanner.scan(root: root, cached: cache) { _ in }
        #expect(second.items == first.items, "命中缓存时返回的条目应与原来完全一致")
    }
}

// MARK: - Multi-selection & deletion

@Suite("Selection and deletion")
struct SelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func plainClickSelectsOnlyThatItem() {
        let r = AppStore.selection(after: "c", on: ["a", "b"], primary: "b",
                                   command: false, shift: false, ordered: order)
        #expect(r.selection == ["c"])
        #expect(r.primary == "c")
    }

    @Test func commandClickTogglesAndKeepsTheRest() {
        let added = AppStore.selection(after: "d", on: ["a", "b"], primary: "b",
                                       command: true, shift: false, ordered: order)
        #expect(added.selection == ["a", "b", "d"])

        let removed = AppStore.selection(after: "b", on: ["a", "b"], primary: "b",
                                         command: true, shift: false, ordered: order)
        #expect(removed.selection == ["a"])
        #expect(removed.primary == "a")
    }

    @Test func shiftClickSelectsInclusiveRangeInEitherDirection() {
        let forward = AppStore.selection(after: "d", on: ["b"], primary: "b",
                                         command: false, shift: true, ordered: order)
        #expect(forward.selection == ["b", "c", "d"])

        let backward = AppStore.selection(after: "a", on: ["d"], primary: "d",
                                          command: false, shift: true, ordered: order)
        #expect(backward.selection == ["a", "b", "c", "d"])
        #expect(backward.primary == "a")
    }

    @Test func clickingInsideAMultiSelectionKeepsIt() {
        let r = AppStore.selection(after: "b", on: ["a", "b", "c"], primary: "a",
                                   command: false, shift: false, ordered: order)
        #expect(r.selection == ["a", "b", "c"], "右键菜单要能作用在整个选区上")
        #expect(r.primary == "b")
    }

    @Test func clickingSingleSelectionReplacesIt() {
        let r = AppStore.selection(after: "b", on: ["b"], primary: "b",
                                   command: false, shift: false, ordered: order)
        #expect(r.selection == ["b"])
    }

    @Test func trashActuallyMovesTheFileAway() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = try writePNG(at: dir.appendingPathComponent("victim.png"), width: 8, height: 8)

        do {
            let trashed = try FileDeleter.trash(victim)
            #expect(!FileManager.default.fileExists(atPath: victim.path), "原路径应该已经不存在")
            if let trashed {
                #expect(FileManager.default.fileExists(atPath: trashed.path), "文件应出现在废纸篓里")
            }
        } catch {
            // The sandboxed test runner cannot write ~/.Trash; the app itself is
            // not sandboxed, and `--delete` verifies the real thing end to end.
            #expect(FileManager.default.fileExists(atPath: victim.path), "失败时绝不能误删源文件")
        }
    }

    @Test func deletingMissingFileThrowsWithoutCrashing() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).png")
        #expect(throws: (any Error).self) { try FileDeleter.trash(missing) }
    }
}
