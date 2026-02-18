import XCTest
@testable import ImmichVault

final class AssetHasherTests: XCTestCase {

    // MARK: - SHA-256 Correctness

    func testSHA256EmptyData() {
        let hash = AssetHasher.sha256(Data())
        // SHA-256 of empty string is well-known
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256KnownInput() {
        let data = "Hello, ImmichVault!".data(using: .utf8)!
        let hash = AssetHasher.sha256(data)
        // Must be 64 hex chars
        XCTAssertEqual(hash.count, 64, "SHA-256 hex should be 64 characters")
        // Must be lowercase hex
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) }, "Hash should be lowercase hex")
    }

    func testSHA256Stability() {
        // Same input must always produce same output
        let data = "Stable hash test with some binary bytes: \u{00}\u{01}\u{ff}".data(using: .utf8)!
        let hash1 = AssetHasher.sha256(data)
        let hash2 = AssetHasher.sha256(data)
        let hash3 = AssetHasher.sha256(data)
        XCTAssertEqual(hash1, hash2, "Same data must produce same hash")
        XCTAssertEqual(hash2, hash3, "Same data must produce same hash across calls")
    }

    func testSHA256DifferentInputs() {
        let data1 = "File contents version 1".data(using: .utf8)!
        let data2 = "File contents version 2".data(using: .utf8)!
        let hash1 = AssetHasher.sha256(data1)
        let hash2 = AssetHasher.sha256(data2)
        XCTAssertNotEqual(hash1, hash2, "Different data must produce different hashes")
    }

    func testSHA256LargeData() {
        // Test with 10MB of data to ensure no issues with larger files
        let size = 10 * 1024 * 1024
        var data = Data(count: size)
        for i in 0..<size {
            data[i] = UInt8(i % 256)
        }
        let hash = AssetHasher.sha256(data)
        XCTAssertEqual(hash.count, 64, "SHA-256 of large data should be 64 hex chars")
        // Must be deterministic
        let hash2 = AssetHasher.sha256(data)
        XCTAssertEqual(hash, hash2, "SHA-256 of same large data must be identical")
    }

    func testSHA256SingleByteDifference() {
        var data1 = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        var data2 = Data([0x00, 0x01, 0x02, 0x03, 0x05]) // Last byte different
        let hash1 = AssetHasher.sha256(data1)
        let hash2 = AssetHasher.sha256(data2)
        XCTAssertNotEqual(hash1, hash2, "Even single-byte difference should produce different hash")
    }
}
