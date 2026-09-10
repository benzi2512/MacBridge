import Foundation

// Shared by direct file operations and the command sandbox. Broad access is
// access as the current user, not permission to read credentials or bypass TCC.
enum LocalFilesystemAccess {
    static let readableEnvironmentTemplates = [
        ".env.dist", ".env.example", ".env.sample", ".env.template",
    ]
    static let blockedComponents = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", "keychains",
        ".netrc", ".npmrc", "id_rsa", "id_ed25519", "login.keychain-db",
        "tunnel-api-key", ".git-credentials",
    ]
    static let reservedMutationPrefixes = [".macbridge-copy-", ".macbridge-write-"]
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
        let parts = path.lowercased().split(separator: "/").map(String.init)
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
}
