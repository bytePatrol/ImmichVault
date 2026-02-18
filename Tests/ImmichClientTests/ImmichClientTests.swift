import XCTest
@testable import ImmichVault

final class ImmichClientTests: XCTestCase {
    func testInvalidURLThrowsError() async {
        let client = ImmichClient()

        do {
            _ = try await client.testConnection(serverURL: "", apiKey: "test")
            XCTFail("Should have thrown")
        } catch {
            // Expected: invalid URL or unreachable
        }
    }

    func testURLNormalizationAddsScheme() async {
        // This will fail to connect but tests that we don't crash on scheme-less URLs
        let client = ImmichClient()

        do {
            _ = try await client.testConnection(serverURL: "not-a-real-server.local", apiKey: "test")
            XCTFail("Should have thrown - server doesn't exist")
        } catch {
            // Expected: unreachable is fine; we just verify no crash from URL normalization
        }
    }
}
