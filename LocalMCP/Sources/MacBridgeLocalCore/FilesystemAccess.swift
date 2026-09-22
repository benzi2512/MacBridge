import Foundation

// Shared by direct file operations and the command sandbox. Broad access is
// access as the current user, not permission to read credentials or bypass TCC.
enum LocalFilesystemAccess {
    private struct TraversalFailure {
        let stage: String
        let relativePath: String
        let domain: String
        let code: Int

        var error: LocalMCPError {
            .filesystemPreflight(stage: stage, relativePath: relativePath,
                                 osDomain: domain, osCode: code)
        }
    }
    private static let policyLocale = Locale(identifier: "en_US_POSIX")
    static let maximumReadOnlyRootPathBytes = 128 * 1_024

    static func policyFold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive], locale: policyLocale
        )
    }
    static let readableEnvironmentTemplates = [
        ".env.dist", ".env.example", ".env.sample", ".env.template",
    ]
    static let blockedComponents = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", "keychains",
        ".netrc", ".npmrc", "id_rsa", "id_ed25519", "login.keychain-db",
        "tunnel-api-key", ".git-credentials",
    ]
    static let reservedMutationPrefixes = [
        ".macbridge-copy-", ".macbridge-write-", ".macbridge-directory-",
        ".macbridge-undo-",
    ]
    static let blockedFragments = [
        "library/safari",
        "library/containers/com.apple.safari",
        "library/application support/google/chrome",
        "library/application support/chromium",
        "library/application support/bravesoftware",
        "library/application support/firefox",
        "library/application support/microsoft edge",
        "library/application support/arc",
        ".config/gh/hosts.yml",
        ".config/git/credentials",
        ".config/gcloud",
        ".docker/config.json",
        ".config/macbridge",
        ".codex/auth.json",
    ]

    static func isSensitive(_ path: String) -> Bool {
        let parts = policyFold(path).split(separator: "/").map(String.init)
        for (index, component) in parts.enumerated() {
            if blockedComponents.contains(component) { return true }
            if reservedMutationPrefixes.contains(where: component.hasPrefix) { return true }
            if component == ".env" || component.hasPrefix(".env.") {
                let isReadableTemplate = index == parts.indices.last
                    && readableEnvironmentTemplates.contains(component)
                if !isReadableTemplate { return true }
            }
        }
        let normalized = "/" + parts.joined(separator: "/") + "/"
        return blockedFragments.contains { normalized.contains("/" + $0 + "/") }
    }

    static func sanitizedTraversalPath(_ url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        let raw: String
        if path == rootPath { raw = "." }
        else if rootPath == "/", path.hasPrefix("/") { raw = String(path.dropFirst()) }
        else if path.hasPrefix(rootPath + "/") { raw = String(path.dropFirst(rootPath.count + 1)) }
        else { raw = "[outside-root]" }
        if raw != ".", isSensitive(raw) { return "[protected]" }
        let clean = raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
        return String(String.UnicodeScalarView(clean)).prefix(512).description
    }

    private static func traversalFailure(stage: String, url: URL, rootPath: String,
                                         error: NSError) -> TraversalFailure {
        TraversalFailure(stage: stage,
            relativePath: sanitizedTraversalPath(url, rootPath: rootPath),
            domain: String(error.domain.prefix(128)), code: error.code)
    }

    // Seatbelt regexes are case-sensitive. Expand ASCII letters so the policy
    // also matches alternate casing on case-insensitive macOS volumes.
    static func sandboxDenyRules() -> String {
        func literalPattern(_ value: String) -> String {
            value.map { character -> String in
                if character.isASCII && character.isLetter {
                    return "[\(String(character).lowercased())\(String(character).uppercased())]"
                }
                if character == "." { return "[.]" }
                return String(character)
            }.joined()
        }
        let patterns = (blockedComponents + blockedFragments).map {
            "(^|/)\(literalPattern($0))(/|$)"
        } + reservedMutationPrefixes.map {
            "(^|/)\(literalPattern($0))[^/]*(/|$)"
        }
        let environmentPattern = "(^|/)[.][eE][nN][vV]([.][^/]*)?(/|$)"
        let readableTemplatePattern = "(^|/)(\(readableEnvironmentTemplates.map(literalPattern).joined(separator: "|")))$"
        let filters = patterns.map { "(regex #\"\($0)\")" }.joined(separator: "\n    ")
        return """
            (deny file-read* file-write* file-map-executable
                \(filters)
                (require-all
                    (regex #"\(environmentPattern)")
                    (require-not (regex #"\(readableTemplatePattern)"))))
            """
    }

    /// Build the narrow read grant used when a command explicitly selects a
    /// protected user-data root such as Downloads. The command may enumerate
    /// that directory and read ordinary files directly inside it, but it does
    /// not receive a recursive subtree grant. Symlinks, multi-link files,
    /// sensitive names and non-regular objects are omitted from the profile.
    /// A caller that needs a real project subtree must select that child as cwd.
    static func sandboxReadOnlyRootRules(root: URL) throws -> String {
        let rootPath = try canonicalExistingPath(root.standardizedFileURL.path)
        let canonicalRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard !rootPath.contains("\n"), !rootPath.contains("\0") else {
            throw LocalMCPError.invalidPath("sandbox path")
        }
        var traversalFailure: TraversalFailure?
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                let value = error as NSError
                if (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
                    || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)) {
                    return true
                }
                traversalFailure = Self.traversalFailure(
                    stage: "read_only_root_enumeration", url: url,
                    rootPath: rootPath, error: value
                )
                return false
            }
        ) else {
            throw LocalMCPError.operationFailed("read-only root could not be inspected")
        }
        var inspected = 0
        var inspectedBytes = 0
        var readable = Set<String>()
        for case let url as URL in enumerator {
            inspected += 1
            inspectedBytes += url.path.utf8.count
            // The generated profile is passed as one sandbox-exec argument.
            // Stay well below macOS ARG_MAX after adding the fixed profile,
            // executable arguments and environment.
            guard inspected <= 10_000,
                  inspectedBytes <= maximumReadOnlyRootPathBytes else {
                throw LocalMCPError.limitExceeded(
                    "read-only root inspection; select a narrower child folder"
                )
            }
            let relative = String(url.path.dropFirst(rootPath.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard !relative.isEmpty, !url.path.contains("\n"), !url.path.contains("\0"),
                  !isSensitive(relative) else { continue }
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                if errno == ENOENT { continue }
                let value = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                traversalFailure = Self.traversalFailure(
                    stage: "read_only_root_lstat", url: url,
                    rootPath: rootPath, error: value
                )
                break
            }
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { continue }
            readable.insert(url.path)
        }
        if let traversalFailure { throw traversalFailure.error }
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let objects = ([rootPath] + readable.sorted()).map {
            "(literal \(quote($0)))"
        }.joined(separator: "\n    ")
        return """
            (allow file-read* file-test-existence
                \(objects))
            """
    }

    /// Seatbelt path filters follow the current pathname. Protect the namespace
    /// ancestors of sensitive entries that already exist when a command starts,
    /// otherwise renaming an enclosing directory can make the same vnode appear
    /// under an unblocked spelling. Newly created data is command-owned.
    static func sandboxExistingSensitiveRules(root: URL) throws -> String {
        let rootPath = root.path
        var traversalFailure: TraversalFailure?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { url, error in
                let value = error as NSError
                if (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
                    || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)) {
                    return true
                }
                traversalFailure = Self.traversalFailure(
                    stage: "protected_path_enumeration", url: url,
                    rootPath: rootPath, error: value
                )
                return false
            }
        ) else { throw LocalMCPError.operationFailed("workspace could not be inspected for protected paths") }
        var inspected = 0
        var inspectedBytes = 0
        var sensitive = Set<String>()
        var ancestors = Set<String>()
        for case let url as URL in enumerator {
            inspected += 1
            inspectedBytes += url.path.utf8.count
            guard inspected <= 100_000, inspectedBytes <= 32 * 1_024 * 1_024 else {
                throw LocalMCPError.limitExceeded(
                    "workspace protected-path inspection; narrow the command cwd"
                )
            }
            let relative = String(url.path.dropFirst(rootPath.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard isSensitive(relative) else { continue }
            sensitive.insert(url.path)
            var parent = url.deletingLastPathComponent()
            while parent.path != rootPath, parent.path.hasPrefix(rootPath + "/") {
                ancestors.insert(parent.path)
                parent.deleteLastPathComponent()
            }
        }
        if let traversalFailure { throw traversalFailure.error }
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let protectedVnodes = sensitive.sorted().map {
            "(deny file-read* file-write* file-map-executable (literal \(quote($0))) (subpath \(quote($0))))"
        }
        let protectedNamespace = ancestors.union(sensitive).sorted().map {
            "(deny file-write-unlink (literal \(quote($0))))"
        }
        return (protectedVnodes + protectedNamespace).joined(separator: "\n")
    }
}
