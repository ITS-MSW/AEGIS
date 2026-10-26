import XCTest
@testable import Aegis

final class RegressionBaselineTests: XCTestCase {
    func testSessionDisplayNamePrefersProviderTitle() {
        var session = makeSession(cwd: "/tmp/aegis-project")
        session.firstPrompt = "Fallback prompt"
        session.sessionTitle = "Provider task title"

        XCTAssertEqual(session.displayName, "Provider task title")
    }

    func testSessionDisplayNameFallsBackToMeaningfulDirectory() {
        let session = makeSession(cwd: "/tmp/aegis-project")

        XCTAssertEqual(session.displayName, "aegis-project")
    }

    private func makeSession(cwd: String) -> Session {
        Session(
            id: UUID().uuidString,
            cwd: cwd,
            startedAt: Date(),
            status: .idle,
            source: "codex"
        )
    }
}
