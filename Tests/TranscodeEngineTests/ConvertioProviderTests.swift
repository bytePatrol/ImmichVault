import XCTest
@testable import ImmichVault

// MARK: - Mock URL Protocol for Convertio Tests

private class MockConvertioURLProtocol: URLProtocol {
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

// MARK: - Convertio Provider Tests

final class ConvertioProviderTests: XCTestCase {
    private var provider: ConvertioProvider!
    private let testAPIKey = "test-convertio-key-12345"

    override func setUp() {
        super.setUp()
        MockConvertioURLProtocol.reset()

        // Save a test API key in Keychain so the provider can read it
        try! KeychainManager.shared.save(testAPIKey, for: .convertioAPIKey)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockConvertioURLProtocol.self]
        let session = URLSession(configuration: config)
        provider = ConvertioProvider(session: session)
    }

    override func tearDown() {
        MockConvertioURLProtocol.reset()
        try? KeychainManager.shared.delete(.convertioAPIKey)
        provider = nil
        super.tearDown()
    }

    // MARK: - Health Check

    func testHealthCheckSuccess() async throws {
        MockConvertioURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.contains("/convert") ?? false)
            XCTAssertEqual(request.httpMethod, "POST")

            let responseJSON: [String: Any] = [
                "code": 200,
                "status": "ok",
                "data": [
                    "id": "test-health-id",
                    "minutes": 25
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let result = try await provider.healthCheck()
        XCTAssertTrue(result, "Health check should return true for 200 response")

        // Verify the API key was sent in the request body (not in headers for Convertio)
        let request = MockConvertioURLProtocol.capturedRequests.first
        XCTAssertNotNil(request)
        let bodyData = Self.readRequestBody(request!)
        if let bodyData,
           let bodyJSON = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            XCTAssertEqual(bodyJSON["apikey"] as? String, testAPIKey)
        }
    }

    func testHealthCheckAuthFailure() async throws {
        MockConvertioURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return ("Unauthorized".data(using: .utf8), response, nil)
        }

        // Convertio's healthCheck catches authenticationFailed and returns false
        let result = try await provider.healthCheck()
        XCTAssertFalse(result, "Health check should return false for 401 response")
    }

    // MARK: - Submit Job

    func testSubmitJobSuccess() async throws {
        var calledConvertEndpoint = false
        var calledUploadEndpoint = false

        MockConvertioURLProtocol.requestHandler = { request in
            let urlPath = request.url?.path ?? ""

            // Step 1: POST /convert to create conversion
            if urlPath == "/convert" && request.httpMethod == "POST" && !calledConvertEndpoint {
                calledConvertEndpoint = true
                let responseJSON: [String: Any] = [
                    "code": 200,
                    "status": "ok",
                    "data": [
                        "id": "conv-abc-123",
                        "minutes": 25
                    ]
                ]
                let data = try! JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response, nil)
            }

            // Step 2: PUT /convert/{id}/{filename} to upload file
            if urlPath.contains("/convert/conv-abc-123/") && request.httpMethod == "PUT" {
                calledUploadEndpoint = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(), response, nil)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }

        // Create a temp file to use as source
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_source_\(UUID().uuidString).mp4")
        try Data(repeating: 0xBB, count: 512).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let conversionId = try await provider.submitJob(
            sourceURL: tempFile,
            preset: .default,
            filename: "test_video.mp4"
        )

        XCTAssertEqual(conversionId, "conv-abc-123", "Should return the conversion ID")
        XCTAssertTrue(calledConvertEndpoint, "Should have called the convert endpoint")
        XCTAssertTrue(calledUploadEndpoint, "Should have called the upload endpoint")
    }

    // MARK: - Poll Job

    func testPollJobConverting() async throws {
        MockConvertioURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.contains("/convert/") ?? false)
            XCTAssertTrue(request.url?.path.hasSuffix("/status") ?? false)

            let responseJSON: [String: Any] = [
                "code": 200,
                "status": "ok",
                "data": [
                    "id": "conv-poll-123",
                    "step": "convert",
                    "step_percent": 50.0
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("conv-poll-123")

        XCTAssertEqual(status.state, .processing, "Status should be processing during convert step")
        XCTAssertNotNil(status.progress, "Progress should be available")
        // Convert phase: 30% + (50% * 0.65) = 30% + 32.5% = 62.5%
        XCTAssertEqual(status.progress!, 0.625, accuracy: 0.01)
        XCTAssertNil(status.downloadURL, "No download URL while converting")
        XCTAssertNil(status.errorMessage, "No error while converting")
    }

    func testPollJobFinished() async throws {
        MockConvertioURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "code": 200,
                "status": "ok",
                "data": [
                    "id": "conv-done-123",
                    "step": "finish",
                    "step_percent": 100.0,
                    "output": [
                        "url": "https://storage.convertio.co/download/output.mp4",
                        "size": 50_000_000
                    ]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("conv-done-123")

        XCTAssertEqual(status.state, .completed, "Status should be completed for 'finish' step")
        XCTAssertNotNil(status.downloadURL, "Should have a download URL")
        XCTAssertEqual(
            status.downloadURL?.absoluteString,
            "https://storage.convertio.co/download/output.mp4"
        )
        XCTAssertNil(status.errorMessage, "No error on completion")
    }

    func testPollJobFailed() async throws {
        MockConvertioURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "code": 200,
                "status": "ok",
                "data": [
                    "id": "conv-err-123",
                    "step": "error",
                    "error": "File format not supported"
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let status = try await provider.pollJob("conv-err-123")

        XCTAssertEqual(status.state, .failed, "Status should be failed for 'error' step")
        XCTAssertNotNil(status.errorMessage, "Should have an error message")
        XCTAssertTrue(
            status.errorMessage!.contains("File format not supported"),
            "Error message should contain the error detail: \(status.errorMessage!)"
        )
    }

    // MARK: - Cost Estimation

    func testCostEstimation() {
        // Convertio pricing: ceil(duration_seconds / 60) * $0.10, min 1 minute
        // For a 5-minute video: 5 * $0.10 = $0.50
        let cost = provider.estimateCost(
            fileSizeBytes: 500_000_000,
            durationSeconds: 300.0,  // 5 minutes
            preset: .default
        )

        XCTAssertEqual(cost, 0.50, accuracy: 0.001, "5-minute video should cost $0.50")
    }

    func testCostEstimationShortVideo() {
        // For a 30-second video: ceil(30/60) = 1 minute, so 1 * $0.10 = $0.10
        let cost = provider.estimateCost(
            fileSizeBytes: 50_000_000,
            durationSeconds: 30.0,
            preset: .default
        )

        XCTAssertEqual(cost, 0.10, accuracy: 0.001, "30-second video should cost $0.10")
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

    // MARK: - Helpers

    private static func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            return data
        }
        return nil
    }
}
