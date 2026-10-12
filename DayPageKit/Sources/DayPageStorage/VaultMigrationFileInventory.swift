import Foundation

/// Copy and verification use the same inventory. Screenshot manifests are
/// durable user state; other hidden metadata/cache trees stay excluded.
public enum VaultMigrationFileInventory {
    public enum InventoryError: Error {
        case unreadableDirectory
        case unsafeEntry
    }

    public static let screenshotManifestDirectory = "raw/assets/.screenshot-captures"

    /// Validate every existing component before a copy can create, replace,
    /// or delete its leaf. Missing descendants are allowed; symlinks below
    /// the captured root and non-directory parents are never followed.
    public static func validateFilePath(_ relative: String, in root: URL,
        fileManager: FileManager = .default) throws {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw InventoryError.unsafeEntry }
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fileManager.attributesOfItem(atPath: current.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            catch { throw InventoryError.unreadableDirectory }
            guard let type = attributes[.type] as? FileAttributeType,
                  type != .typeSymbolicLink,
                  index == components.count - 1 ? type == .typeRegular : type == .typeDirectory
            else { throw InventoryError.unsafeEntry }
        }
    }

    public static func relativeFiles(
        in root: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw InventoryError.unreadableDirectory }
        var enumerationFailed = false
        guard let entries = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw InventoryError.unreadableDirectory }
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var files: [String] = []
        for case let url as URL in entries {
            // FileManager may spell /private/tmp while URL standardization
            // spells /tmp. Compare both sides using the same normalization.
            let entryPath = url.standardizedFileURL.path
            guard entryPath.hasPrefix(prefix) else { throw InventoryError.unsafeEntry }
            let relative = String(entryPath.dropFirst(prefix.count))
            let components = relative.split(separator: "/")
            let permitted = components.indices.allSatisfy { index in
                !components[index].hasPrefix(".")
                    || components[...index].joined(separator: "/") == screenshotManifestDirectory
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard permitted else {
                if values.isDirectory == true { entries.skipDescendants() }
                continue
            }
            // Never migrate a selected symlink to another vault's state or an
            // external file. The root itself may be a normal directory alias.
            guard values.isSymbolicLink != true else { throw InventoryError.unsafeEntry }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw InventoryError.unsafeEntry }
            files.append(relative)
        }
        guard !enumerationFailed else { throw InventoryError.unreadableDirectory }
        return files.sorted()
    }
}
