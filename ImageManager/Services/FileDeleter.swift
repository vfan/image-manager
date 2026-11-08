import Foundation

/// Thin wrapper around the Trash so deleting is testable and never calls
/// `removeItem` (which would be unrecoverable).
public enum FileDeleter {
    @discardableResult
    public static func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
