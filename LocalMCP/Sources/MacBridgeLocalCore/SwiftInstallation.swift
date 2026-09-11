import Foundation

/// Stock, already-installed Apple toolchains only. No download, xcode-select
/// mutation, shell/environment lookup or new sandbox access. Prefer full Xcode
/// because current CLT installations can provide Swift Testing but not XCTest.
struct SwiftInstallation {
    let developer: String
    let toolchain: String
    let platformDeveloper: String
    let sdk: String
    let frameworks: String

    var swift: String { toolchain + "/usr/bin/swift" }
    var swiftc: String { toolchain + "/usr/bin/swiftc" }
    var testingLibraries: String { platformDeveloper + "/usr/lib" }

    static let xcode = SwiftInstallation(
        developer: "/Applications/Xcode.app/Contents/Developer",
        toolchain: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
        platformDeveloper: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer",
        sdk: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
        frameworks: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks")
    static let commandLineTools = SwiftInstallation(
        developer: "/Library/Developer/CommandLineTools",
        toolchain: "/Library/Developer/CommandLineTools",
        platformDeveloper: "/Library/Developer/CommandLineTools/Library/Developer",
        sdk: "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        frameworks: "/Library/Developer/CommandLineTools/Library/Developer/Frameworks")

    static func select(
        executable: (String) -> Bool = isTrustedSystemExecutable,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> SwiftInstallation {
        if executable(xcode.swift), executable(xcode.swiftc),
           executable(xcode.developer + "/usr/bin/xctest"),
           exists(xcode.sdk), exists(xcode.frameworks + "/XCTest.framework") { return xcode }
        return commandLineTools
    }
}
