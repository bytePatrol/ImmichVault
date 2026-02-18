import XCTest
@testable import ImmichVault

// MARK: - Mock URL Protocol for CloudConvert Tests

private class MockCloudConvertURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Data?, URLResponse?, Error?))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, response, error) = handler(request)
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - CloudConvert Provider Tests

final class CloudConvertProviderTests: XCTestCase {
    private var provider: CloudConvertProvider!
    private let testAPIKey = "test-cloudconvert-key-12345"

    override func setUp() {
        super.setUp()
        MockCloudConvertURLProtocol.reset()

        // Save a test API key in Keychain so the provider can read it
        try! KeychainManager.shared.save(testAPIKey, for: .cloudConvertAPIKey)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockCloudConvertURLProtocol.self]
        let session = URLSession(configuration: config)
        provider = CloudConvertProvider(session: session)
    }

    override func tearDown() {
        MockCloudConvertURLProtocol.reset()
        try? KeychainManager.shared.delete(.cloudConvertAPIKey)
        provider = nil
        super.tearDown()
    }

    // MARK: - Health Check

    func testHealthCheckSuccess() async throws {
        MockCloudConvertURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.contains("/v2/users/me") ?? false)
            XCTAssertEqual(request.httpMethod, "GET")

            let responseJSON: [String: Any] = [
                "data": [
                    "id": 12345,
                    "username": "testuser",
                    "email": "test@example.com",
                    "credits": 100
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let result = try await provider.healthCheck()
        XCTAssertTrue(result, "Health check should return true for 200 response")

        // Verify auth header was sent
        let request = MockCloudConvertURLProtocol.capturedRequests.first
        XCTAssertNotNil(request)
        let authHeader = request?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer \(testAPIKey)")
    }

    func testHealthCheckAuthFailure() async throws {
        MockCloudConvertURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return ("Unauthorized".data(using: .utf8), response, nil)
        }

        // healthCheck catches the authenticationFailed error thrown by CloudProviderHelpers.request
        // and re-throws it. We expect the error to propagate.
        do {
            let result = try await provider.healthCheck()
            // If it doesn't throw, it should return false
            XCTAssertFalse(result, "Health check should return false for 401 response")
        } catch {
            // CloudProviderHelpers.request throws authenticationFailed for 401
            // The provider's healthCheck may or may not catch it depending on implementation.
            // Either outcome is acceptable as long as it indicates failure.
        }
    }

    // MARK: - Submit Job

    func testSubmitJobSuccess() async throws {
        // Track which URLs have been called
        var calledJobsEndpoint = false
        var calledUploadEndpoint = false

        MockCloudConvertURLProtocol.requestHandler = { request in
            let urlPath = request.url?.path ?? ""

            if urlPath.contains("/v2/jobs") && request.httpMethod == "POST" && !calledJobsEndpoint {
                calledJobsEndpoint = true
                // Return job creation response with tasks including import task with form
                let responseJSON: [String: Any] = [
                    "data": [
                        "id": "job-abc-123",
                        "status": "waiting",
                        "tasks": [
                            [
                                "id": "task-import-1",
                                "operation": "import/upload",
                                "status": "waiting",
                                "result": [
                                    "form": [
                                        "url": "https://storage.cloudconvert.com/upload/abc",
                                        "parameters": [
                                            "key": "uploads/abc",
                                            "policy": "base64policy"
                                        ]
                                    ]
                                ]
                            ] as [String: Any],
                            [
                                "id": "task-convert-1",
                                "operation": "convert",
                                "status": "waiting"
                            ] as [String: Any],
                            [
                                "id": "task-export-1",
                                "operation": "export/url",
                                "status": "waiting"
                            ] as [String: Any]
                        ]
                    ]
                ]
                let data = try! JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response, nil)
            }

            if request.url?.host == "storage.cloudconvert.com" {
                calledUploadEndpoint = true
                // Form upload returns 201 Created
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (Data(), response, nil)
            }

            // Fallback
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }

        // Create a temp file to use as source
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_source_\(UUID().uuidString).mp4")
        try Data(repeating: 0xAA, count: 1024).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let jobId = try await provider.submitJob(
            sourceURL: tempFile,
            preset: .default,
            filename: "test_video.mp4"
        )

        XCTAssertEqual(jobId, "job-abc-123", "Should return the job ID from the response")
        XCTAssertTrue(calledJobsEndpoint, "Should have called the jobs endpoint")
        XCTAssertTrue(calledUploadEndpoint, "Should have called the upload endpoint")
    }

    // MARK: - Poll Job

    func testPollJobProcessing() async throws {
        MockCloudConvertURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.contains("/v2/jobs/") ?? false)

            let responseJSON: [String: Any] = [
                "data": [
                    "id": "job-poll-123",
                    "status": "processing",
                    "tasks": [
                        [
                            "id": "task-convert-1",
                            "operation": "convert",
                            "status": "processing",
                            "percent": 50.0
                        ] as [String: Any]
                    ]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("job-poll-123")

        XCTAssertEqual(status.state, .processing, "Status should be processing")
        XCTAssertNotNil(status.progress, "Progress should be available")
        XCTAssertEqual(status.progress!, 0.5, accuracy: 0.01, "Progress should be 50%")
        XCTAssertNil(status.downloadURL, "No download URL while processing")
        XCTAssertNil(status.errorMessage, "No error while processing")
    }

    func testPollJobCompleted() async throws {
        MockCloudConvertURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "data": [
                    "id": "job-done-123",
                    "status": "finished",
                    "tasks": [
                        [
                            "id": "task-export-1",
                            "operation": "export/url",
                            "status": "finished",
                            "result": [
                                "files": [
                                    [
                                        "filename": "output.mp4",
                                        "url": "https://storage.cloudconvert.com/download/output.mp4"
                                    ]
                                ]
                            ]
                        ] as [String: Any]
                    ]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("job-done-123")

        XCTAssertEqual(status.state, .completed, "Status should be completed")
        XCTAssertNotNil(status.downloadURL, "Should have a download URL")
        XCTAssertEqual(
            status.downloadURL?.absoluteString,
            "https://storage.cloudconvert.com/download/output.mp4"
        )
        XCTAssertNil(status.errorMessage, "No error on completion")
    }

    func testPollJobFailed() async throws {
        MockCloudConvertURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "data": [
                    "id": "job-err-123",
                    "status": "error",
                    "tasks": [
                        [
                            "id": "task-convert-1",
                            "operation": "convert",
                            "status": "error",
                            "message": "Unsupported codec"
                        ] as [String: Any]
                    ]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("job-err-123")

        XCTAssertEqual(status.state, .failed, "Status should be failed")
        XCTAssertNotNil(status.errorMessage, "Should have an error message")
        XCTAssertTrue(
            status.errorMessage!.contains("Unsupported codec"),
            "Error message should contain the task error: \(status.errorMessage!)"
        )
    }

    // MARK: - Cost Estimation

    func testCostEstimation() {
        // CloudConvert pricing: (1 base credit + ceil(duration/60) credits) x $0.02
        // For a 5-minute video: (1 + 5) * $0.02 = $0.12
        let cost = provider.estimateCost(
            fileSizeBytes: 500_000_000,
            durationSeconds: 300.0,  // 5 minutes
            preset: .default
        )

        XCTAssertEqual(cost, 0.12, accuracy: 0.001, "5-minute video should cost $0.12")
    }

    func testCostEstimationShortVideo() {
        // For a 30-second video: ceil(30/60) = 1 minute, so (1 + 1) * $0.02 = $0.04
        let cost = provider.estimateCost(
            fileSizeBytes: 50_000_000,
            durationSeconds: 30.0,
            preset: .default
        )

        XCTAssertEqual(cost, 0.04, accuracy: 0.001, "30-second video should cost $0.04")
    }

    func testCostEstimationLongVideo() {
        // For a 90-minute video: ceil(5400/60) = 90 minutes, so (1 + 90) * $0.02 = $1.82
        let cost = provider.estimateCost(
            fileSizeBytes: 5_000_000_000,
            durationSeconds: 5400.0,
            preset: .default
        )

        XCTAssertEqual(cost, 1.82, accuracy: 0.001, "90-minute video should cost $1.82")
    }

    // MARK: - Output Size Estimation

    func testEstimateOutputSize() {
        let metadata = VideoMetadata(
            duration: 180.0,
            width: 1920,
            height: 1080,
            videoCodec: "h264",
            fileSize: 1_073_741_824  // 1 GB
        )

        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .default)

        // Default preset is H.265 CRF 28 -> base ratio ~0.40
        // Estimated: ~429 MB (1 GB * 0.40)
        XCTAssertGreaterThan(estimated, 0, "Estimated output size should be positive")
        XCTAssertLessThan(
            estimated, 1_073_741_824,
            "Estimated output should be smaller than input for H.265"
        )
        // Should be roughly 40% of input (within a range)
        let ratio = Double(estimated) / 1_073_741_824.0
        XCTAssertGreaterThan(ratio, 0.2, "Ratio should be reasonable (> 20%)")
        XCTAssertLessThan(ratio, 0.8, "Ratio should be reasonable (< 80%)")
    }

    func testEstimateOutputSizeZeroFileSize() {
        let metadata = VideoMetadata(
            duration: 180.0,
            width: 1920,
            height: 1080,
            videoCodec: "h264",
            fileSize: 0
        )

        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .default)

        // No file size and no bitrate means we can't estimate
        XCTAssertEqual(estimated, 0, "Should return 0 when no file size available")
    }

    func testEstimateOutputSizeFromBitrate() {
        let metadata = VideoMetadata(
            duration: 120.0,
            width: 1920,
            height: 1080,
            videoCodec: "h264",
            bitrate: 8_000_000  // 8 Mbps
        )

        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .default)

        // Source size from bitrate: 8_000_000 / 8 * 120 = 120_000_000 bytes
        // H.265 CRF 28 ratio ~0.40 -> ~48 MB
        XCTAssertGreaterThan(estimated, 0, "Should estimate from bitrate when fileSize missing")
    }
}
