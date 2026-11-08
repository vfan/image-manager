import Foundation
import os

/// File-system side of "move to another library folder".
///
/// Kept separate from `AppStore` so it can be tested without a UI: it only
/// deals with URLs and never invents a destination that does not exist.
public enum FileMover {
    private static let logger = Logger(subsystem: "com.local.ImageManager", category: "move")

    /// `folder/<name>.png`, or `folder/<name> 2.png` when the name is taken.
    /// Never overwrites an existing file.
    public static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    public struct Result: Sendable {
        public let source: URL
        public let destination: URL
    }

    /// Move one file into `folder`. Throws when the source is missing, the
    /// destination is not a directory, or the move itself fails.
    @discardableResult
    public static func move(_ source: URL, to folder: URL) throws -> Result {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MoveError.destinationMissing(folder.path)
        }
        guard fm.fileExists(atPath: source.path) else {
            throw MoveError.sourceMissing(source.path)
        }
        let destination = uniqueDestination(for: source, in: folder)
        try fm.moveItem(at: source, to: destination)
        logger.debug("Moved \(source.lastPathComponent, privacy: .public) -> \(folder.lastPathComponent, privacy: .public)")
        return Result(source: source, destination: destination)
    }

    /// A filename the app is willing to write: trimmed, no path separators,
    /// no leading dot, `.png` appended when there is no extension at all.
    public static func sanitizedFileName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        guard !name.contains("/"), !name.contains(":"), !name.contains("\0") else { return nil }
        guard !name.hasPrefix(".") else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".png" }
        return name
    }

    public enum RenameError: LocalizedError, Equatable {
        case invalidName
        case alreadyExists(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName: "文件名不能为空，也不能包含 / 或 :"
            case .alreadyExists(let name): "这个目录里已经有「\(name)」了"
            case .failed(let reason): reason
            }
        }
    }

    /// Rename in place. Case-only changes (`a.png` → `A.png`) need a two-step
    /// move on case-insensitive volumes, otherwise the move is a silent no-op.
    @discardableResult
    public static func rename(_ source: URL, to rawName: String) throws -> URL {
        guard let name = sanitizedFileName(rawName) else { throw RenameError.invalidName }
        let fm = FileManager.default
        let directory = source.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(name)

        if destination.path == source.path { return destination }
        let sameIgnoringCase = destination.path.lowercased() == source.path.lowercased()
        if !sameIgnoringCase, fm.fileExists(atPath: destination.path) {
            throw RenameError.alreadyExists(name)
        }

        do {
            if sameIgnoringCase {
                let temp = directory.appendingPathComponent(".rename-\(UUID().uuidString).png")
                try fm.moveItem(at: source, to: temp)
                try fm.moveItem(at: temp, to: destination)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
        } catch let error as RenameError {
            throw error
        } catch {
            throw RenameError.failed(error.localizedDescription)
        }
        logger.debug("Renamed \(source.lastPathComponent, privacy: .public) -> \(name, privacy: .public)")
        return destination
    }

    public enum MoveError: LocalizedError, Equatable {
        case sourceMissing(String)
        case destinationMissing(String)

        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let path): "找不到文件：\(path)"
            case .destinationMissing(let path): "目标目录不存在：\(path)"
            }
        }
    }
}
