import Foundation
import CoreGraphics

/// A PNG file that has been discovered inside one of the user's folders.
///
/// The struct is `Sendable` and cheap to copy, so it can cross actor /
/// thread boundaries without locking.
public struct ImageItem: Identifiable, Hashable, Sendable {
    /// Absolute file path. Also used as the stable identity.
    let path: String
    /// The folder (workspace root) this image was found under.
    let rootPath: String
    /// Path relative to `rootPath`, e.g. `icons/dark/gear.png`.
    let relativePath: String
    let fileName: String

    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var modifiedAt: Date
    /// File birth time — when the image landed in this folder. Falls back to
    /// the modification date on filesystems that do not track birth time.
    var createdAt: Date

    /// Header bytes of the PNG, used to persist the exact colour type (alpha?).
    var bitDepth: Int
    var colorType: Int

    public init(path: String, rootPath: String, relativePath: String, fileName: String,
                pixelWidth: Int, pixelHeight: Int, fileSize: Int64,
                modifiedAt: Date, createdAt: Date? = nil,
                bitDepth: Int, colorType: Int) {
        self.path = path
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt ?? modifiedAt
        self.bitDepth = bitDepth
        self.colorType = colorType
    }

    public var id: String { path }

    var pixelCount: Int { pixelWidth * pixelHeight }

    var hasAlpha: Bool { [4, 6].contains(colorType) }

    var url: URL { URL(fileURLWithPath: path) }

    /// `1920 × 1080`
    var dimensionDescription: String { "\(pixelWidth) × \(pixelHeight)" }

    /// Compact caption shown under every thumbnail. `DateFormatter` is
    /// expensive to build, so the two shapes are created once.
    private nonisolated(unsafe) static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private nonisolated(unsafe) static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private nonisolated(unsafe) static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    var createdCaption: String {
        let sameYear = Self.yearFormatter.string(from: createdAt)
            == Self.yearFormatter.string(from: Date())
        let formatter = sameYear ? Self.sameYearFormatter : Self.otherYearFormatter
        return formatter.string(from: createdAt)
    }

    /// Full timestamp for the inspector and tooltips.
    var createdDescription: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// `1920x1080`, handy for filtering and filenames.
    var dimensionKey: String { "\(pixelWidth)x\(pixelHeight)" }

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var aspectCategory: AspectCategory {
        .classify(width: pixelWidth, height: pixelHeight)
    }

    var widthBucket: WidthBucket { WidthBucket(width: pixelWidth) }

    var areaBucket: AreaBucket { AreaBucket(pixelCount: pixelCount) }

    var fileSizeDescription: String {
        Self.byteFormatter.string(fromByteCount: fileSize)
    }

    nonisolated(unsafe) private static let byteFormatter = ByteCountFormatter()
}

/// Coarse aspect-ratio family. Exact ratios like 16:9 are approximated with a
/// small tolerance so "1920×1080", "2560×1440" and "3840×2160" all land in
/// the same bucket.
public enum AspectCategory: String, CaseIterable, Identifiable, Sendable {
    case landscape16x9 = "16:9"
    case ultrawide = "超宽 (≥2.39:1)"
    case landscape4x3 = "4:3"
    case landscapeOther = "其他横图"
    case square = "1:1"
    case portrait4x3 = "3:4"
    case portrait9x16 = "9:16"
    case portraitOther = "其他竖图"
    case tall = "竖长图 (≤1:2.39)"

    public var id: String { rawValue }

    var isLandscape: Bool { self == .landscape16x9 || self == .ultrawide || self == .landscape4x3 || self == .landscapeOther }
    var isPortrait: Bool { self == .portrait4x3 || self == .portrait9x16 || self == .portraitOther || self == .tall }

    var symbolName: String {
        switch self {
        case .landscape16x9: "rectangle"
        case .ultrawide: "rectangle.split.3x1"
        case .landscape4x3: "rectangle.inset.filled"
        case .landscapeOther: "rectangle.dashed"
        case .square: "square"
        case .portrait4x3: "rectangle.portrait.inset.filled"
        case .portrait9x16: "rectangle.portrait"
        case .tall: "rectangle.portrait.arrowtriangle.2.outward"
        case .portraitOther: "rectangle.portrait.dashed"
        }
    }

    /// Horizontal badge / preview frame ratio. `nil` = no fixed frame.
    var displayAspect: Double? {
        switch self {
        case .landscape16x9: 16.0 / 9.0
        case .ultrawide: 2.39
        case .landscape4x3: 4.0 / 3.0
        case .square: 1
        case .portrait4x3: 3.0 / 4.0
        case .portrait9x16: 9.0 / 16.0
        case .tall: 1.0 / 2.39
        case .landscapeOther, .portraitOther: nil
        }
    }

    /// Order in which categories are listed in the sidebar: widest first,
    /// then squares, then portraits.
    static let displayOrder: [AspectCategory] = [
        .ultrawide, .landscape16x9, .landscape4x3, .landscapeOther,
        .square,
        .portrait4x3, .portrait9x16, .portraitOther, .tall,
    ]

    /// Lower is wider. Mirrors `displayOrder`, used for "widest → tallest" sorts.
    var sortRank: Int {
        Self.displayOrder.firstIndex(of: self) ?? Self.displayOrder.count
    }

    static func classify(width: Int, height: Int) -> AspectCategory {
        guard width > 0, height > 0 else { return .square }
        let r = Double(width) / Double(height)

        // A category owns ratios within ±20 % (relative) of its nominal ratio;
        // 1:1 gets a tighter ±5 % so 1000×1050 stays square but 1200×1050
        // becomes 4:3. Order matters: widest → square → tallest.
        func within(_ nominal: Double, _ tolerance: Double = 0.20) -> Bool {
            abs(r / nominal - 1) < tolerance
        }

        if within(2.39) || r > 2.39 { return .ultrawide }
        if within(16.0 / 9.0) { return .landscape16x9 }
        if within(4.0 / 3.0) { return .landscape4x3 }
        if abs(r - 1) <= 0.05 { return .square }
        if within(3.0 / 4.0) { return .portrait4x3 }
        if within(9.0 / 16.0) { return .portrait9x16 }
        if r < 1.0 / 2.39 { return .tall }
        return r > 1 ? .landscapeOther : .portraitOther
    }
}

/// Width bands (long side matters for textures / icons / backgrounds).
public enum WidthBucket: Int, CaseIterable, Identifiable, Sendable {
    case tiny = 0      // ≤ 512
    case small = 1     // 513 – 1024
    case medium = 2    // 1025 – 2048
    case large = 3     // 2049 – 4096
    case huge = 4      // > 4096

    public var id: Int { rawValue }

    init(width: Int) {
        switch width {
        case ...512: self = .tiny
        case ...1024: self = .small
        case ...2048: self = .medium
        case ...4096: self = .large
        default: self = .huge
        }
    }

    var label: String {
        switch self {
        case .tiny: "≤ 512 px"
        case .small: "513 – 1024 px"
        case .medium: "1025 – 2048 px"
        case .large: "2049 – 4096 px"
        case .huge: "> 4096 px"
        }
    }

    var shortLabel: String {
        switch self {
        case .tiny: "≤512"
        case .small: "1K"
        case .medium: "2K"
        case .large: "4K"
        case .huge: ">4K"
        }
    }
}

/// Pixel-area bands, useful for "is this texture heavy?" questions.
public enum AreaBucket: Int, CaseIterable, Identifiable, Sendable {
    case small = 0     // ≤ 0.5 MP
    case medium = 1    // ≤ 2 MP
    case large = 2     // ≤ 4 MP
    case veryLarge = 3 // > 4 MP

    public var id: Int { rawValue }

    init(pixelCount: Int) {
        switch pixelCount {
        case ...500_000: self = .small
        case ...2_000_000: self = .medium
        case ...4_000_000: self = .large
        default: self = .veryLarge
        }
    }

    var label: String {
        switch self {
        case .small: "≤ 0.5 MP"
        case .medium: "0.5 – 2 MP"
        case .large: "2 – 4 MP"
        case .veryLarge: "> 4 MP"
        }
    }
}

/// A concrete pixel size, e.g. `1024 × 1024` with 37 images.
public struct SizeGroup: Identifiable, Hashable, Sendable {
    let width: Int
    let height: Int
    var count: Int
    var totalBytes: Int64

    public var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }
    var aspectCategory: AspectCategory { .classify(width: width, height: height) }
}

/// A folder the user added. Uniquely identified by its absolute path.
public struct LibraryFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: String     // absolute path
    public var bookmark: Data? // security-scoped bookmark (sandbox-friendly)

    public init(id: String, bookmark: Data? = nil) {
        // Canonical spelling only: `/tmp/x` becomes `/private/tmp/x`, which is
        // what the file system (and the index) actually stores.
        self.id = FilePath.canonical(id)
        self.bookmark = bookmark
    }

    public var path: String { id }
    public var name: String { URL(fileURLWithPath: id).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: id) }
}

/// Where images are filtered from in the browser.
public enum LibraryScope: Hashable, Sendable {
    case all
    case folder(String)
    case group(GroupKey)

    var title: String {
        switch self {
        case .all: return "全部图片"
        case .folder(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .group(let key): return key.title
        }
    }

    var sidebarSelectionID: String {
        switch self {
        case .all: return "all"
        case .folder(let path): return "folder:" + path
        case .group(let key): return "group:" + key.id
        }
    }

    /// Parse a sidebar selection tag (`all` / `folder:<path>` / `group:<key>`).
    public init?(selectionID: String) {
        if selectionID == "all" {
            self = .all
            return
        }
        if selectionID.hasPrefix("folder:") {
            let path = String(selectionID.dropFirst("folder:".count))
            guard !path.isEmpty else { return nil }
            self = .folder(path)
            return
        }
        guard selectionID.hasPrefix("group:") else { return nil }
        guard let key = GroupKey(id: String(selectionID.dropFirst("group:".count))) else { return nil }
        self = .group(key)
    }
}

/// One row in the "按尺寸分类" sidebar.
public struct GroupKey: Identifiable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case aspect      // 宽高比分类
        case exactSize   // 完全相同的像素尺寸
        case width       // 宽度档位
        case area        // 像素面积档位

        public var title: String {
            switch self {
            case .aspect: "宽高比"
            case .exactSize: "尺寸"
            case .width: "宽度"
            case .area: "面积"
            }
        }

        public var help: String {
            switch self {
            case .aspect: "按图片的宽高比归类，例如 16:9、1:1、9:16"
            case .exactSize: "按完全相同的像素尺寸归类，例如 1024 × 1024"
            case .width: "按图片宽度分档"
            case .area: "按图片像素总量分档"
            }
        }
    }

    let mode: Mode
    /// AspectCategory rawValue — only used when `mode == .aspect`.
    var aspectRaw: String = ""
    var width: Int = 0
    var height: Int = 0
    /// WidthBucket / AreaBucket rawValue — used for `.width` / `.area`.
    var bucket: Int = 0

    init(mode: Mode, aspectRaw: String = "", width: Int = 0, height: Int = 0, bucket: Int = 0) {
        self.mode = mode
        self.aspectRaw = aspectRaw
        self.width = width
        self.height = height
        self.bucket = bucket
    }

    static func aspect(_ category: AspectCategory) -> GroupKey {
        GroupKey(mode: .aspect, aspectRaw: category.rawValue)
    }

    static func exactSize(_ group: SizeGroup) -> GroupKey {
        GroupKey(mode: .exactSize, width: group.width, height: group.height)
    }

    static func exactSize(width: Int, height: Int) -> GroupKey {
        GroupKey(mode: .exactSize, width: width, height: height)
    }

    static func width(_ bucket: WidthBucket) -> GroupKey {
        GroupKey(mode: .width, bucket: bucket.rawValue)
    }

    static func area(_ bucket: AreaBucket) -> GroupKey {
        GroupKey(mode: .area, bucket: bucket.rawValue)
    }

    /// Parse the stable string produced by `id`.
    public init?(id: String) {
        if id.hasPrefix("aspect:"),
           let category = AspectCategory(rawValue: String(id.dropFirst("aspect:".count))) {
            self = .aspect(category)
            return
        }
        if id.hasPrefix("size:") {
            let parts = id.dropFirst("size:".count).split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
            self = .exactSize(width: w, height: h)
            return
        }
        if id.hasPrefix("width:"), let raw = Int(id.dropFirst("width:".count)),
           let bucket = WidthBucket(rawValue: raw) {
            self = .width(bucket)
            return
        }
        if id.hasPrefix("area:"), let raw = Int(id.dropFirst("area:".count)),
           let bucket = AreaBucket(rawValue: raw) {
            self = .area(bucket)
            return
        }
        return nil
    }

    public var id: String {
        switch mode {
        case .aspect: "aspect:\(aspectRaw)"
        case .exactSize: "size:\(width)x\(height)"
        case .width: "width:\(bucket)"
        case .area: "area:\(bucket)"
        }
    }

    var category: AspectCategory? {
        mode == .aspect ? AspectCategory(rawValue: aspectRaw) : nil
    }

    var title: String {
        switch mode {
        case .aspect: AspectCategory(rawValue: aspectRaw)?.rawValue ?? "?"
        case .exactSize: "\(width) × \(height)"
        case .width: WidthBucket(rawValue: bucket)?.label ?? "?"
        case .area: AreaBucket(rawValue: bucket)?.label ?? "?"
        }
    }

    var subtitle: String { mode.title }

    /// The pixel size behind a `.exactSize` group, oriented w × h.
    var pixelSizeLabel: String { "\(width) × \(height)" }

    /// Grouping mode of this key (used to sort sections consistently).
    var groupMode: Mode { mode }

    /// Approximate display ratio for sidebar thumbnails.
    var displayAspect: Double? {
        switch mode {
        case .aspect: category?.displayAspect
        case .exactSize: height > 0 ? Double(width) / Double(height) : nil
        case .width: 4.0 / 3.0
        case .area: 1
        }
    }

    var symbolName: String {
        switch mode {
        case .aspect: category?.symbolName ?? "rectangle"
        case .exactSize: "arrow.up.left.and.arrow.down.right"
        case .width: "arrow.left.and.right"
        case .area: "square.grid.3x3"
        }
    }

    func matches(_ item: ImageItem) -> Bool {
        switch mode {
        case .aspect: return item.aspectCategory.rawValue == aspectRaw
        case .exactSize: return item.pixelWidth == width && item.pixelHeight == height
        case .width: return item.widthBucket.rawValue == bucket
        case .area: return item.areaBucket.rawValue == bucket
        }
    }
}

/// Sort orders for the grid and for the sidebar groups.
public enum ImageSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case sizeAscending
    case pixelsDescending
    case pixelsAscending
    case largestFile
    case createdNewest
    case newest

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "名称"
        case .sizeAscending: "宽高比 (宽→竖)"
        case .pixelsDescending: "像素 (多→少)"
        case .pixelsAscending: "像素 (少→多)"
        case .largestFile: "文件大小"
        case .createdNewest: "创建时间（新→旧）"
        case .newest: "修改时间（新→旧）"
        }
    }
}
