import XCTest
@testable import ImmichVault

// MARK: - Mock URL Protocol for FreeConvert Tests

private class MockFreeConvertURLProtocol: URLProtocol {
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

// MARK: - FreeConvert Provider Tests

final class FreeConvertProviderTests: XCTestCase {
    private var provider: FreeConvertProvider!
    private let testAPIKey = "test-freeconvert-key-12345"

    override func setUp() {
        super.setUp()
        MockFreeConvertURLProtocol.reset()

        // Save a test API key in Keychain so the provider can read it
        try! KeychainManager.shared.save(testAPIKey, for: .freeConvertAPIKey)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFreeConvertURLProtocol.self]
        let session = URLSession(configuration: config)
        provider = FreeConvertProvider(session: session)
    }

    override func tearDown() {
        MockFreeConvertURLProtocol.reset()
        try? KeychainManager.shared.delete(.freeConvertAPIKey)
        provider = nil
        super.tearDown()
    }

    // MARK: - Health Check

    func testHealthCheckSuccess() async throws {
        MockFreeConvertURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.contains("/v1/process/jobs") ?? false)
            XCTAssertEqual(request.httpMethod, "GET")

            let responseJSON: [String: Any] = [
                "data": [] as [Any],
                "meta": [
                    "total": 0
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let result = try await provider.healthCheck()
        XCTAssertTrue(result, "Health check should return true for 200 response")

        // Verify auth header was sent
        let request = MockFreeConvertURLProtocol.capturedRequests.first
        XCTAssertNotNil(request)
        let authHeader = request?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer \(testAPIKey)")
    }

    func testHealthCheckAuthFailed() async throws {
        MockFreeConvertURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return ("Unauthorized".data(using: .utf8), response, nil)
        }

        // FreeConvert's healthCheck catches authenticationFailed and returns false
        let result = try await provider.healthCheck()
        XCTAssertFalse(result, "Health check should return false for 401 response")
    }

    // MARK: - Submit Job

    func testSubmitJobSuccess() async throws {
        var calledJobsEndpoint = false
        var calledUploadEndpoint = false

        MockFreeConvertURLProtocol.requestHandler = { request in
            let urlPath = request.url?.path ?? ""

            // Step 1: POST /v1/process/jobs to create job
            if urlPath.contains("/v1/process/jobs") && request.httpMethod == "POST" && !calledJobsEndpoint {
                calledJobsEndpoint = true
                let responseJSON: [String: Any] = [
                    "id": "fc-job-123",
                    "status": "processing",
                    "tasks": [
                        [
                            "id": "task-import-1",
                            "operation": "import/upload",
                            "status": "waiting",
                            "result": [
                                "form": [
                                    "url": "https://storage.freeconvert.com/upload/abc",
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
                let data = try! JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response, nil)
            }

            // Step 2: Upload file to the form URL
            if request.url?.host == "storage.freeconvert.com" {
                calledUploadEndpoint = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (Data(), response, nil)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }

        // Create a temp file to use as source
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_source_\(UUID().uuidString).mp4")
        try Data(repeating: 0xCC, count: 512).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let jobId = try await provider.submitJob(
            sourceURL: tempFile,
            preset: .default,
            filename: "test_video.mp4"
        )

        XCTAssertEqual(jobId, "fc-job-123", "Should return the job ID from the response")
        XCTAssertTrue(calledJobsEndpoint, "Should have called the jobs endpoint")
        XCTAssertTrue(calledUploadEndpoint, "Should have called the upload endpoint")
    }

    // MARK: - Poll Job

    func testPollJobProcessing() async throws {
        MockFreeConvertURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.contains("/v1/process/jobs/") ?? false)

            let responseJSON: [String: Any] = [
                "id": "fc-poll-123",
                "status": "processing",
                "tasks": [
                    [
                        "id": "task-convert-1",
                        "operation": "convert",
                        "status": "processing",
                        "percent": 75.0
                    ] as [String: Any]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("fc-poll-123")

        XCTAssertEqual(status.state, .processing, "Status should be processing")
        XCTAssertNotNil(status.progress, "Progress should be available")
        XCTAssertEqual(status.progress!, 0.75, accuracy: 0.01, "Progress should be 75%")
        XCTAssertNil(status.downloadURL, "No download URL while processing")
        XCTAssertNil(status.errorMessage, "No error while processing")
    }

    func testPollJobCompleted() async throws {
        MockFreeConvertURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "id": "fc-done-123",
                "status": "completed",
                "tasks": [
                    [
                        "id": "task-export-1",
                        "operation": "export/url",
                        "status": "completed",
                        "result": [
                            "url": "https://storage.freeconvert.com/download/output.mp4"
                        ]
                    ] as [String: Any]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("fc-done-123")

        XCTAssertEqual(status.state, .completed, "Status should be completed")
        XCTAssertNotNil(status.downloadURL, "Should have a download URL")
        XCTAssertEqual(
            status.downloadURL?.absoluteString,
            "https://storage.freeconvert.com/download/output.mp4"
        )
        XCTAssertNil(status.errorMessage, "No error on completion")
    }

    func testPollJobFailed() async throws {
        MockFreeConvertURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "id": "fc-err-123",
                "status": "failed",
                "tasks": [
                    [
                        "id": "task-convert-1",
                        "operation": "convert",
                        "status": "failed",
                        "message": "Insufficient credits"
                    ] as [String: Any]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("fc-err-123")

        XCTAssertEqual(status.state, .failed, "Status should be failed")
        XCTAssertNotNil(status.errorMessage, "Should have an error message")
        XCTAssertTrue(
            status.errorMessage!.contains("Insufficient credits"),
            "Error message should contain the task error: \(status.errorMessage!)"
        )
    }

    // MARK: - Cost Estimation

    func testCostEstimation() {
        // FreeConvert pricing: ceil(duration_seconds / 60) * $0.008, min 1 minute
        // For a 5-minute video: 5 * $0.008 = $0.04
        let cost = provider.estimateCost(
            fileSizeBytes: 500_000_000,
            durationSeconds: 300.0,  // 5 minutes
            preset: .default
        )

        XCTAssertEqual(cost, 0.04, accuracy: 0.001, "5-minute video should cost $0.04")
    }

    func testCostEstimationShortVideo() {
        // For a 30-second video: ceil(30/60) = 1 minute, so 1 * $0.008 = $0.008
        let cost = provider.estimateCost(
            fileSizeBytes: 50_000_000,
            durationSeconds: 30.0,
            preset: .default
        )

        XCTAssertEqual(cost, 0.008, accuracy: 0.001, "30-second video should cost $0.008")
    }

    func testCostEstimationLongVideo() {
        // For a 60-minute video: 60 * $0.008 = $0.48
        let cost = provider.estimateCost(
            fileSizeBytes: 3_000_000_000,
            durationSeconds: 3600.0,
            preset: .default
        )

        XCTAssertEqual(cost, 0.48, accuracy: 0.001, "60-minute video should cost $0.48")
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

        XCTAssertGreaterThan(estimated, 0, "Estimated output size should be positive")
        XCTAssertLessThan(
            estimated, 1_073_741_824,
            "Estimated output should be smaller than input for H.265"
        )
        let ratio = Double(estimated) / 1_073_741_824.0
        XCTAssertGreaterThan(ratio, 0.2, "Ratio should be reasonable (> 20%)")
        XCTAssertLessThan(ratio, 0.8, "Ratio should be reasonable (< 80%)")
    }

    func testEstimateOutputSizeZeroFileSize() {
        let metadata = VideoMetadata(
            duration: 180.0,
            width: 1920,
            height: 1080,
            fileSize: 0
        )

        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .default)
        XCTAssertEqual(estimated, 0, "Should return 0 when no file size available")
    }

    func testEstimateOutputSizeH264Preset() {
        let metadata = VideoMetadata(
            duration: 120.0,
            width: 1920,
            height: 1080,
            fileSize: 500_000_000
        )

        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .screenRecording)

        // Screen recording preset uses H.264 CRF 26 -> base ratio 0.60
        XCTAssertGreaterThan(estimated, 0, "Should give a positive estimate")
        let ratio = Double(estimated) / 500_000_000.0
        // H.264 has a higher ratio than H.265 (0.60 vs 0.40)
        XCTAssertGreaterThan(ratio, 0.3, "H.264 ratio should be higher than H.265")
        XCTAssertLessThan(ratio, 1.0, "Should still be less than original")
    }
}
