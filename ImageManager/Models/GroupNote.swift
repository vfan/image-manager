import Foundation

/// A free-form note the user attaches to a size / ratio / width / area group,
/// e.g. `2048 × 2048 → iOS 截屏`. Notes are keyed by `GroupKey.id` so the same
/// pixel size and the same ratio can carry different notes.
public struct GroupNote: Codable, Identifiable, Hashable, Sendable {
    /// `GroupKey.id`, e.g. `size:1170x2532` or `aspect:portrait9x16`.
    public var id: String
    public var text: String
    public var updatedAt: Date

    public init(id: String, text: String, updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
    }
}

public extension GroupKey {
    /// Stable key used in `notes.json`.
    var noteID: String { id }
}
