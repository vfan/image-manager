import Foundation

/// One numeric range: `[min, max]`. Both ends are optional, so the user can
/// set only "≥ 1920" or only "≤ 512". Everything is stored in **pixels**;
/// the UI converts to/from the selected unit.
public struct DimensionRange: Codable, Hashable, Sendable {
    public var min: Int?
    public var max: Int?

    public init(min: Int? = nil, max: Int? = nil) {
        self.min = min
        self.max = max
    }

    public var isEmpty: Bool { min == nil && max == nil }

    /// Inclusive on both ends.
    public func isSatisfied(by value: Int) -> Bool {
        if let min, value < min { return false }
        if let max, value > max { return false }
        return true
    }

    /// Swap the bounds if the user typed them the wrong way round.
    public func normalized() -> DimensionRange {
        guard let min, let max, min > max else { return self }
        return DimensionRange(min: max, max: min)
    }
}

/// Which measurement of the image a range applies to.
public enum DimensionAxis: String, Codable, CaseIterable, Identifiable, Sendable {
    case longSide    // 长边 (max(w, h))
    case shortSide   // 短边 (min(w, h))
    case width       // 宽
    case height      // 高

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .longSide: "长边"
        case .shortSide: "短边"
        case .width: "宽"
        case .height: "高"
        }
    }

    public var help: String {
        switch self {
        case .longSide: "max(宽, 高)，横图竖图通用，适合限定分辨率档位"
        case .shortSide: "min(宽, 高)"
        case .width: "只看宽度"
        case .height: "只看高度"
        }
    }

    public func value(of item: ImageItem) -> Int {
        switch self {
        case .longSide: max(item.pixelWidth, item.pixelHeight)
        case .shortSide: min(item.pixelWidth, item.pixelHeight)
        case .width: item.pixelWidth
        case .height: item.pixelHeight
        }
    }
}

/// How the numbers the user types are interpreted.
public enum DimensionUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case pixel
    case thousand = "k"
    case dp

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pixel: "px"
        case .thousand: "K"
        case .dp: "dp"
        }
    }

    public var help: String {
        switch self {
        case .pixel: "像素"
        case .thousand: "千像素（1K = 1000px）"
        case .dp: "逻辑点，按当前屏幕的 @2x/@3x 换算（需要显示器信息）"
        }
    }

    /// Convert a user-facing value into pixels.
    public func toPixels(_ value: Int, scale: Int) -> Int {
        switch self {
        case .pixel: return value
        case .thousand: return value * 1000
        case .dp: return value * max(1, scale)
        }
    }

    /// Convert pixels back into the user-facing unit, rounded.
    public func fromPixels(_ pixels: Int, scale: Int) -> Int {
        switch self {
        case .pixel: return pixels
        case .thousand: return Int((Double(pixels) / 1000).rounded())
        case .dp: return Int((Double(pixels) / Double(max(1, scale))).rounded())
        }
    }

    /// Values used to seed the "less than" stepper.
    public var stepSuggestion: [Int] {
        switch self {
        case .pixel: [256, 512, 1024, 1536, 2048, 2560, 3000, 4096, 5000]
        case .thousand: [1, 2, 3, 4, 5, 8, 10]
        case .dp: [160, 240, 320, 375, 414, 768, 834, 1024]
        }
    }
}

/// A saved filter, applied to the library (all folders).
///
/// Every range is opt-in via its `isEnabled` flag so the user can leave a
/// half-filled row around without narrowing the result by accident.
public struct DimensionFilter: Codable, Hashable, Sendable {
    public var longSide = DimensionRange()
    public var longSideEnabled = false
    public var shortSide = DimensionRange()
    public var shortSideEnabled = false
    public var width = DimensionRange()
    public var widthEnabled = false
    public var height = DimensionRange()
    public var heightEnabled = false
    /// Pixel unit the typed numbers were entered in.
    public var unit: DimensionUnit = .pixel
    /// Screen scale (2 for Retina) used for `.dp` conversions.
    public var scale: Int = 2
    /// Also require width ≥ height (横图) or width ≤ height (竖图).
    public var orientation: OrientationPreference = .any

    public enum OrientationPreference: String, Codable, CaseIterable, Identifiable, Sendable {
        case any, landscape, portrait

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .any: "不限"
            case .landscape: "只看横图"
            case .portrait: "只看竖图"
            }
        }
    }

    public init() {}

    // MARK: Access helpers

    public func isEnabled(_ axis: DimensionAxis) -> Bool { self[keyPath: enabledKeyPath(axis)] }

    public mutating func setEnabled(_ axis: DimensionAxis, _ value: Bool) {
        self[keyPath: enabledKeyPath(axis)] = value
    }

    public func range(for axis: DimensionAxis) -> DimensionRange { self[keyPath: rangeKeyPath(axis)] }

    public mutating func setRange(_ axis: DimensionAxis, _ value: DimensionRange) {
        self[keyPath: rangeKeyPath(axis)] = value
    }

    private func rangeKeyPath(_ axis: DimensionAxis) -> WritableKeyPath<DimensionFilter, DimensionRange> {
        switch axis {
        case .longSide: \.longSide
        case .shortSide: \.shortSide
        case .width: \.width
        case .height: \.height
        }
    }

    private func enabledKeyPath(_ axis: DimensionAxis) -> WritableKeyPath<DimensionFilter, Bool> {
        switch axis {
        case .longSide: \.longSideEnabled
        case .shortSide: \.shortSideEnabled
        case .width: \.widthEnabled
        case .height: \.heightEnabled
        }
    }

    /// Turn a row on together with a range, in one call.
    public mutating func set(_ axis: DimensionAxis, min: Int? = nil, max: Int? = nil, enabled: Bool = true) {
        self[keyPath: rangeKeyPath(axis)] = DimensionRange(min: min, max: max)
        self[keyPath: enabledKeyPath(axis)] = enabled
    }

    public func enabledRanges() -> [(axis: DimensionAxis, range: DimensionRange)] {
        DimensionAxis.allCases.compactMap { axis in
            let r = range(for: axis)
            return isEnabled(axis) && !r.isEmpty ? (axis, r.normalized()) : nil
        }
    }

    /// True when the filter would not narrow anything.
    public var isInactive: Bool {
        enabledRanges().isEmpty && orientation == .any
    }

    // MARK: Matching

    public func matches(_ item: ImageItem) -> Bool {
        switch orientation {
        case .any: break
        case .landscape: guard item.pixelWidth >= item.pixelHeight else { return false }
        case .portrait: guard item.pixelWidth <= item.pixelHeight else { return false }
        }
        for (axis, range) in enabledRanges() where !range.isSatisfied(by: axis.value(of: item)) {
            return false
        }
        return true
    }

    // MARK: Display

    public func boundsText(_ range: DimensionRange) -> String {
        let r = range.normalized()
        switch (r.min, r.max) {
        case let (min?, max?): return "\(min) – \(max) \(unit.label)"
        case let (min?, nil): return "≥ \(min) \(unit.label)"
        case let (nil, max?): return "≤ \(max) \(unit.label)"
        case (nil, nil): return ""
        }
    }

    /// Compact description for the filter chip, e.g. `长边 512 – 1920px · 横图`.
    public var summary: String {
        var parts = enabledRanges().map { "\($0.axis.label) \(boundsText($0.range))" }
        switch orientation {
        case .any: break
        case .landscape: parts.append("横图")
        case .portrait: parts.append("竖图")
        }
        return parts.joined(separator: " · ")
    }

    /// Swap inverted bounds and clamp out-of-reasonable-range values.
    public func normalized() -> DimensionFilter {
        var f = self
        f.longSide = longSide.normalized()
        f.shortSide = shortSide.normalized()
        f.width = width.normalized()
        f.height = height.normalized()
        return f
    }

    /// The five one-tap bounds the app shows: mostly "big images only".
    public enum QuickLongSide: String, CaseIterable, Identifiable, Sendable {
        case under100, under300, over300, over500, over1000

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .under100: "小于 100"
            case .under300: "小于 300"
            case .over300: "大于 300"
            case .over500: "大于 500"
            case .over1000: "大于 1000"
            }
        }

        /// Bounds are inclusive (≤ / ≥), so "大于 500" keeps 500 px images too.
        public var range: DimensionRange {
            switch self {
            case .under100: DimensionRange(min: nil, max: 100)
            case .under300: DimensionRange(min: nil, max: 300)
            case .over300: DimensionRange(min: 300, max: nil)
            case .over500: DimensionRange(min: 500, max: nil)
            case .over1000: DimensionRange(min: 1000, max: nil)
            }
        }

        public var help: String {
            switch self {
            case .under100: "长边 ≤ 100 px：只留超小图标"
            case .under300: "长边 ≤ 300 px：小图标、表情包素材"
            case .over300: "长边 ≥ 300 px：去掉小图标"
            case .over500: "长边 ≥ 500 px：只看正常尺寸以上的图"
            case .over1000: "长边 ≥ 1000 px：只看大图"
            }
        }

        /// A filter that keeps only this bound.
        public func filter(scale: Int = 2) -> DimensionFilter {
            var f = DimensionFilter()
            f.scale = scale
            f.set(.longSide, min: range.min, max: range.max)
            return f
        }
    }

    /// Which quick bound the current filter corresponds to, if any.
    public func matchingQuickBound() -> QuickLongSide? {
        guard isEnabled(.longSide), enabledRanges().count == 1,
              orientation == .any else { return nil }
        let r = range(for: .longSide).normalized()
        return QuickLongSide.allCases.first { $0.range.normalized() == r }
    }
}
