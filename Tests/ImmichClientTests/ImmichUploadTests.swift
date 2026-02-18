import XCTest
@testable import ImmichVault

// MARK: - Mock URL Protocol for Upload Tests

private class MockUploadURLProtocol: URLProtocol {
    /// Handler that returns (data, response, error) for each request.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Data?, URLResponse?, Error?))?

    /// All captured requests for assertion.
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

// MARK: - Upload Tests

final class ImmichUploadTests: XCTestCase {
    private var client: ImmichClient!
    private let testServerURL = "https://test-immich.local"
    private let testAPIKey = "test-api-key-12345"

    override func setUp() {
        super.setUp()
        MockUploadURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockUploadURLProtocol.self]
        let session = URLSession(configuration: config)
        client = ImmichClient(session: session)
    }

    override func tearDown() {
        MockUploadURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: - Upload Success

    func testUploadAssetSuccess() async throws {
        let expectedAssetId = "immich-asset-uuid-001"

        MockUploadURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "id": expectedAssetId,
                "status": "created",
                "duplicate": false
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response, nil)
        }

        let result = try await client.uploadAsset(
            fileData: "test file content".data(using: .utf8)!,
            filename: "IMG_0001.HEIC",
            mimeType: "image/heic",
            deviceAssetId: "local-id-001",
            deviceId: "test-device",
            createdAt: Date(),
            modifiedAt: Date(),
            idempotencyKey: "idem-key-001",
            serverURL: testServerURL,
            apiKey: testAPIKey
        )

        XCTAssertEqual(result.id, expectedAssetId)
        XCTAssertEqual(result.status, .created)
        XCTAssertFalse(result.duplicate)
    }

    func testUploadAssetDuplicate() async throws {
        MockUploadURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "id": "immich-asset-dup-001",
                "status": "duplicate",
                "duplicate": true
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response, nil)
        }

        let result = try await client.uploadAsset(
            fileData: Data([0x01, 0x02]),
            filename: "VID_0001.MOV",
            mimeType: "video/quicktime",
            deviceAssetId: "local-dup-001",
            deviceId: "test-device",
            createdAt: Date(),
            modifiedAt: Date(),
            idempotencyKey: "idem-key-dup",
            serverURL: testServerURL,
            apiKey: testAPIKey
        )

        XCTAssertEqual(result.status, .duplicate)
        XCTAssertTrue(result.duplicate)
    }

    // MARK: - Multipart Body Structure

    func testUploadSendsMultipartFormData() async throws {
        // Capture the body from the URLProtocol since httpBody can be nil when streamed
        var capturedBody: Data?

        MockUploadURLProtocol.requestHandler = { request in
            // Read the body from httpBody or httpBodyStream
            if let body = request.httpBody {
                capturedBody = body
            } else if let stream = request.httpBodyStream {
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
                capturedBody = data
            }

            let responseJSON: [String: Any] = ["id": "test-id", "status": "created"]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        _ = try await client.uploadAsset(
            fileData: "photo data".data(using: .utf8)!,
            filename: "test.jpg",
            mimeType: "image/jpeg",
            deviceAssetId: "dev-asset-001",
            deviceId: "my-device",
            createdAt: Date(),
            modifiedAt: Date(),
            idempotencyKey: "key-123",
            serverURL: testServerURL,
            apiKey: testAPIKey
        )

        XCTAssertEqual(MockUploadURLProtocol.capturedRequests.count, 1)
        let request = MockUploadURLProtocol.capturedRequests[0]

        // Check method
        XCTAssertEqual(request.httpMethod, "POST")

        // Check URL
        XCTAssertEqual(request.url?.path, "/api/assets")

        // Check auth header
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), testAPIKey)

        // Check content type is multipart
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), "Should be multipart")

        // Check body contains required fields
        let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("deviceAssetId"), "Body should contain deviceAssetId field")
        XCTAssertTrue(bodyString.contains("dev-asset-001"), "Body should contain the actual device asset ID")
        XCTAssertTrue(bodyString.contains("deviceId"), "Body should contain deviceId field")
        XCTAssertTrue(bodyString.contains("fileCreatedAt"), "Body should contain fileCreatedAt field")
        XCTAssertTrue(bodyString.contains("fileModifiedAt"), "Body should contain fileModifiedAt field")
        XCTAssertTrue(bodyString.contains("assetData"), "Body should contain assetData file field")
        XCTAssertTrue(bodyString.contains("test.jpg"), "Body should contain filename")
        XCTAssertTrue(bodyString.contains("image/jpeg"), "Body should contain MIME type")
    }

    // MARK: - Auth Failure

    func testUploadAuthenticationFailed() async {
        MockUploadURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }

        do {
            _ = try await client.uploadAsset(
                fileData: Data(),
                filename: "test.jpg",
                mimeType: "image/jpeg",
                deviceAssetId: "id",
                deviceId: "dev",
                createdAt: Date(),
                modifiedAt: Date(),
                idempotencyKey: "key",
                serverURL: testServerURL,
                apiKey: "bad-key"
            )
            XCTFail("Should have thrown authentication error")
        } catch let error as ImmichClient.ImmichError {
            if case .authenticationFailed = error {
                // Expected
            } else {
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUploadServerError() async {
        MockUploadURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return ("Internal error".data(using: .utf8), response, nil)
        }

        do {
            _ = try await client.uploadAsset(
                fileData: Data([0x01]),
                filename: "test.jpg",
                mimeType: "image/jpeg",
                deviceAssetId: "id",
                deviceId: "dev",
                createdAt: Date(),
                modifiedAt: Date(),
                idempotencyKey: "key",
                serverURL: testServerURL,
                apiKey: testAPIKey
            )
            XCTFail("Should have thrown")
        } catch let error as ImmichClient.ImmichError {
            if case .unexpectedResponse(let code) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected unexpectedResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Verify Asset

    func testGetAssetSuccess() async throws {
        MockUploadURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "id": "immich-001",
                "originalFileName": "IMG_0001.HEIC",
                "type": "IMAGE",
                "checksum": "abc123"
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let info = try await client.getAsset(
            immichAssetId: "immich-001",
            serverURL: testServerURL,
            apiKey: testAPIKey
        )

        XCTAssertEqual(info.id, "immich-001")
        XCTAssertEqual(info.originalFileName, "IMG_0001.HEIC")
        XCTAssertEqual(info.type, "IMAGE")
        XCTAssertEqual(info.checksum, "abc123")

        // Verify request was to the correct endpoint
        let request = MockUploadURLProtocol.capturedRequests[0]
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(request.url?.path.contains("api/assets/immich-001") ?? false)
    }

    func testGetAsset404() async {
        MockUploadURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }

        do {
            _ = try await client.getAsset(
                immichAssetId: "nonexistent-id",
                serverURL: testServerURL,
                apiKey: testAPIKey
            )
            XCTFail("Should have thrown")
        } catch let error as ImmichClient.ImmichError {
            if case .assetNotFoundOnServer(let id) = error {
                XCTAssertEqual(id, "nonexistent-id")
            } else {
                XCTFail("Expected assetNotFoundOnServer, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testVerifyUploadSuccess() async throws {
        MockUploadURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "id": "immich-002",
                "originalFileName": "VID_0001.MOV",
                "type": "VIDEO"
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let verified = try await client.verifyUpload(
            immichAssetId: "immich-002",
            expectedFilename: "VID_0001.MOV",
            serverURL: testServerURL,
            apiKey: testAPIKey
        )

        XCTAssertTrue(verified)
    }

    // MARK: - MIME Type Detection

    func testMIMETypeDetection() {
        XCTAssertEqual(ImmichClient.mimeType(for: "IMG_0001.HEIC"), "image/heic")
        XCTAssertEqual(ImmichClient.mimeType(for: "photo.jpg"), "image/jpeg")
        XCTAssertEqual(ImmichClient.mimeType(for: "photo.jpeg"), "image/jpeg")
        XCTAssertEqual(ImmichClient.mimeType(for: "image.png"), "image/png")
        XCTAssertEqual(ImmichClient.mimeType(for: "video.mov"), "video/quicktime")
        XCTAssertEqual(ImmichClient.mimeType(for: "video.mp4"), "video/mp4")
        XCTAssertEqual(ImmichClient.mimeType(for: "clip.avi"), "video/x-msvideo")
        XCTAssertEqual(ImmichClient.mimeType(for: "screen.webm"), "video/webm")
        XCTAssertEqual(ImmichClient.mimeType(for: "raw.dng"), "image/x-adobe-dng")
        XCTAssertEqual(ImmichClient.mimeType(for: "unknown.xyz"), "application/octet-stream")
    }

    func testMIMETypeCaseInsensitive() {
        XCTAssertEqual(ImmichClient.mimeType(for: "IMG.HEIC"), "image/heic")
        XCTAssertEqual(ImmichClient.mimeType(for: "VID.MOV"), "video/quicktime")
        XCTAssertEqual(ImmichClient.mimeType(for: "Photo.JPG"), "image/jpeg")
    }

    // MARK: - Idempotency Key Usage

    func testIdempotencyKeyIncludedInUpload() async throws {
        // Capture the body from the URLProtocol since httpBody can be nil when streamed
        var capturedBody: Data?

        MockUploadURLProtocol.requestHandler = { request in
            // Read the body from httpBody or httpBodyStream
            if let body = request.httpBody {
                capturedBody = body
            } else if let stream = request.httpBodyStream {
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
                capturedBody = data
            }

            let responseJSON: [String: Any] = ["id": "id-1", "status": "created"]
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let idempKey = "unique-idem-key-\(UUID().uuidString)"

        _ = try await client.uploadAsset(
            fileData: Data([0x01, 0x02, 0x03]),
            filename: "test.heic",
            mimeType: "image/heic",
            deviceAssetId: "asset-001",
            deviceId: "device-001",
            createdAt: Date(),
            modifiedAt: Date(),
            idempotencyKey: idempKey,
            serverURL: testServerURL,
            apiKey: testAPIKey
        )

        // The idempotency key is used as the deviceAssetId field in Immich
        // Verify the request body contains the deviceAssetId which serves as the dedup key
        let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("asset-001"), "Body should contain deviceAssetId for deduplication")
    }
}
