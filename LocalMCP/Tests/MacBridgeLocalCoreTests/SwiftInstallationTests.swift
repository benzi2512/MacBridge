import Darwin
import XCTest
@testable import MacBridgeLocalCore

final class SwiftInstallationTests: XCTestCase {
    func testCompleteStockXcodeUsesOneCoherentSDKCompilerAndTestingRoot() {
        let selected = SwiftInstallation.select(executable: { _ in true }, exists: { _ in true })
        XCTAssertEqual(selected.swift, SwiftInstallation.xcode.swift)
        XCTAssertTrue(selected.swiftc.hasPrefix(selected.developer + "/Toolchains/"))
        XCTAssertTrue(selected.sdk.hasPrefix(selected.platformDeveloper + "/SDKs/"))
        XCTAssertTrue(selected.frameworks.hasPrefix(selected.platformDeveloper + "/"))
        XCTAssertTrue(selected.testingLibraries.hasPrefix(selected.platformDeveloper + "/"))
    }

    func testIncompleteXcodeFallsBackWithoutSearchingUserPaths() {
        XCTAssertEqual(SwiftInstallation.commandLineTools.frameworks,
                       "/Library/Developer/CommandLineTools/Library/Developer/Frameworks")
        for missing in [SwiftInstallation.xcode.swift, SwiftInstallation.xcode.swiftc,
                        SwiftInstallation.xcode.developer + "/usr/bin/xctest"] {
            let result = SwiftInstallation.select(executable: { $0 != missing }, exists: { _ in true })
            XCTAssertEqual(result.swift, SwiftInstallation.commandLineTools.swift)
        }
        for missing in [SwiftInstallation.xcode.sdk, SwiftInstallation.xcode.frameworks + "/XCTest.framework"] {
            let result = SwiftInstallation.select(executable: { _ in true }, exists: { $0 != missing })
            XCTAssertEqual(result.swift, SwiftInstallation.commandLineTools.swift)
        }
    }

    func testUntrustedPreferredXcodeDoesNotHideSystemToolchain() {
        for mode: mode_t in [0o100755, 0o100775, 0o100757] {
            var preferred = stat()
            preferred.st_mode = mode
            preferred.st_uid = 501
            var system = stat()
            system.st_mode = 0o100755
            system.st_uid = 0
            let selected = SwiftInstallation.select(executable: { path in
                hasTrustedSystemExecutableMetadata(
                    path.hasPrefix(SwiftInstallation.xcode.developer + "/") ? preferred : system,
                    executable: true)
            }, exists: { _ in true })
            XCTAssertEqual(selected.swift, SwiftInstallation.commandLineTools.swift)
            XCTAssertEqual(selected.sdk, SwiftInstallation.commandLineTools.sdk)
        }
    }

    func testExecutableTrustStillRequiresRootRegularNonWritableAndExecutable() {
        var metadata = stat()
        metadata.st_uid = 0
        metadata.st_mode = 0o100755
        XCTAssertTrue(hasTrustedSystemExecutableMetadata(metadata, executable: true))
        XCTAssertFalse(hasTrustedSystemExecutableMetadata(metadata, executable: false))
        for mode: mode_t in [0o100775, 0o100757, 0o040755, 0o120755, 0o010755] {
            metadata.st_mode = mode
            XCTAssertFalse(hasTrustedSystemExecutableMetadata(metadata, executable: true))
        }
        metadata.st_mode = 0o100755
        metadata.st_uid = 501
        XCTAssertFalse(hasTrustedSystemExecutableMetadata(metadata, executable: true))
    }

    func testUnavailableExecutableFailsClosed() {
        XCTAssertFalse(isTrustedSystemExecutable("/nonexistent-macbridge-toolchain/swift"))
        XCTAssertFalse(isTrustedSystemExecutable("/bin"))
    }
}
