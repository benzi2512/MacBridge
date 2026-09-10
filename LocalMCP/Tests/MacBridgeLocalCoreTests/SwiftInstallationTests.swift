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
}
