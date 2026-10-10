import XCTest
@testable import Aegis

final class DictationTranscriptionConfigurationTests: XCTestCase {
    func testInstallationResolverFindsStandardHermesVenv() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let expected = "/Users/tester/.hermes/hermes-agent/venv/bin/python"

        let installation = DictationTranscriptionConfiguration.installation(
            homeDirectory: home,
            fileExists: { $0.path == expected }
        )

        XCTAssertEqual(installation?.pythonExecutable.path, expected)
        XCTAssertEqual(installation?.rootDirectory.path, "/Users/tester/.hermes/hermes-agent")
    }
}
