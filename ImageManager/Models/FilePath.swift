import Foundation

/// Path normalisation helpers.
///
/// `URL.resolvingSymlinksInPath()` deliberately leaves `/var` and `/tmp`
/// untouched for directory roots, while `FileManager.enumerator` hands back
/// `/private/var/...`. Mixing the two spellings breaks cache lookups, folder
/// matching and relative paths, so every stored path goes through `realpath`.
public enum FilePath {
    public static func canonical(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }
}
