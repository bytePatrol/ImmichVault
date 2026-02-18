import Foundation

// MARK: - Immich API Client
// Handles all communication with the Immich server.
// Supports connection testing, asset upload, upload verification, and asset queries.

public final class ImmichClient: Sendable {
    private let session: URLSession
    private let keychain: KeychainManager

    public struct ServerInfo: Sendable {
        public let version: String
        public let isHealthy: Bool
    }

    public struct UserInfo: Sendable {
        public let id: String
        public let email: String
        public let name: String
    }

    /// Response from asset upload (POST /api/assets).
    public struct UploadResponse: Sendable {
        public let id: String              // Immich asset ID
        public let status: UploadStatus
        public let duplicate: Bool

        public enum UploadStatus: String, Sendable {
            case created
            case duplicate
        }
    }

    /// Minimal info returned when checking if an asset exists.
    public struct AssetInfo: Sendable {
        public let id: String
        public let originalFileName: String?
        public let type: String?           // "IMAGE" or "VIDEO"
        public let checksum: String?       // Base64-encoded checksum from Immich
    }

    public enum ImmichError: LocalizedError, Sendable {
        case noServerURL
        case noAPIKey
        case invalidURL
        case serverUnreachable(String)
        case authenticationFailed
        case unexpectedResponse(Int)
        case decodingError(String)
        case uploadFailed(String)
        case assetNotFoundOnServer(String)
        case verificationFailed(String)
        case downloadFailed(String)
        case replaceFailed(String)
        case searchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noServerURL:
                return "No Immich server URL configured"
            case .noAPIKey:
                return "No Immich API key configured"
            case .invalidURL:
                return "Invalid server URL"
            case .serverUnreachable(let detail):
                return "Server unreachable: \(detail)"
            case .authenticationFailed:
                return "Authentication failed. Check your API key."
            case .unexpectedResponse(let code):
                return "Unexpected response (HTTP \(code))"
            case .decodingError(let detail):
                return "Failed to decode response: \(detail)"
            case .uploadFailed(let detail):
                return "Upload failed: \(detail)"
            case .assetNotFoundOnServer(let id):
                return "Asset not found on Immich server: \(id)"
            case .verificationFailed(let detail):
                return "Upload verification failed: \(detail)"
            case .downloadFailed(let detail):
                return "Download failed: \(detail)"
            case .replaceFailed(let detail):
                return "Asset replace failed: \(detail)"
            case .searchFailed(let detail):
                return "Search failed: \(detail)"
            }
        }
    }

    public init(session: URLSession = .shared, keychain: KeychainManager = .shared) {
        self.session = session
        self.keychain = keychain
    }

    // MARK: - Connection Test

    /// Tests connection by pinging the server and validating the API key.
    /// Returns server info and user info on success.
    public func testConnection(serverURL: String, apiKey: String) async throws -> (server: ServerInfo, user: UserInfo) {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        // Step 1: Ping (no auth required)
        let pingURL = baseURL.appendingPathComponent("api/server/ping")
        var pingRequest = URLRequest(url: pingURL)
        pingRequest.httpMethod = "GET"
        pingRequest.timeoutInterval = 10

        let log = LogManager.shared

        do {
            let (data, response) = try await session.data(for: pingRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.serverUnreachable("Invalid response type")
            }

            guard httpResponse.statusCode == 200 else {
                throw ImmichError.serverUnreachable("HTTP \(httpResponse.statusCode)")
            }

            // Parse ping response: {"res":"pong"}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let res = json["res"] as? String, res == "pong" {
                log.info("Server ping successful", category: .immichAPI)
            } else {
                throw ImmichError.serverUnreachable("Unexpected ping response")
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.serverUnreachable(error.localizedDescription)
        }

        // Step 2: Get server version
        let aboutURL = baseURL.appendingPathComponent("api/server/about")
        var aboutRequest = URLRequest(url: aboutURL)
        aboutRequest.httpMethod = "GET"
        aboutRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        aboutRequest.timeoutInterval = 10

        var serverVersion = "unknown"

        do {
            let (data, response) = try await session.data(for: aboutRequest)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = json["version"] as? String {
                    serverVersion = version
                    log.info("Immich server version: \(version)", category: .immichAPI)
                }
            }
        } catch {
            // Non-fatal: version info is nice-to-have
            log.warning("Could not fetch server version: \(error.localizedDescription)", category: .immichAPI)
        }

        // Step 3: Validate API key via /api/users/me
        let userURL = baseURL.appendingPathComponent("api/users/me")
        var userRequest = URLRequest(url: userURL)
        userRequest.httpMethod = "GET"
        userRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        userRequest.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: userRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.serverUnreachable("Invalid response type")
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 {
                    throw ImmichError.authenticationFailed
                }
                throw ImmichError.unexpectedResponse(httpResponse.statusCode)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userId = json["id"] as? String,
                  let email = json["email"] as? String,
                  let name = json["name"] as? String else {
                throw ImmichError.decodingError("Could not parse user info")
            }

            log.info("Authenticated as \(name) (\(email))", category: .immichAPI)

            let serverInfo = ServerInfo(version: serverVersion, isHealthy: true)
            let userInfo = UserInfo(id: userId, email: email, name: name)

            return (server: serverInfo, user: userInfo)
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.serverUnreachable(error.localizedDescription)
        }
    }

    // MARK: - Upload Asset

    /// Uploads an asset file to Immich via POST /api/assets (multipart/form-data).
    ///
    /// - Parameters:
    ///   - fileData: The raw file data to upload
    ///   - filename: Original filename (e.g., "IMG_0001.HEIC")
    ///   - mimeType: MIME type (e.g., "image/heic", "video/mp4")
    ///   - deviceAssetId: Unique client-side ID (typically PHAsset.localIdentifier)
    ///   - deviceId: Device identifier (app instance ID)
    ///   - createdAt: File creation date
    ///   - modifiedAt: File modification date
    ///   - idempotencyKey: Client-generated key to prevent duplicate uploads
    ///   - serverURL: Immich server URL
    ///   - apiKey: Immich API key
    /// - Returns: Upload response with Immich asset ID and duplicate status
    public func uploadAsset(
        fileData: Data,
        filename: String,
        mimeType: String,
        deviceAssetId: String,
        deviceId: String,
        createdAt: Date,
        modifiedAt: Date,
        idempotencyKey: String,
        serverURL: String,
        apiKey: String
    ) async throws -> UploadResponse {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        let uploadURL = baseURL.appendingPathComponent("api/assets")
        let boundary = "ImmichVault-\(UUID().uuidString)"
        let iso = ISO8601DateFormatter()

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5 minutes for large files

        // Build multipart body
        var body = Data()

        // deviceAssetId
        body.appendMultipartField(name: "deviceAssetId", value: deviceAssetId, boundary: boundary)
        // deviceId
        body.appendMultipartField(name: "deviceId", value: deviceId, boundary: boundary)
        // fileCreatedAt
        body.appendMultipartField(name: "fileCreatedAt", value: iso.string(from: createdAt), boundary: boundary)
        // fileModifiedAt
        body.appendMultipartField(name: "fileModifiedAt", value: iso.string(from: modifiedAt), boundary: boundary)

        // File data
        body.appendMultipartFile(name: "assetData", filename: filename, mimeType: mimeType, data: fileData, boundary: boundary)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let log = LogManager.shared
        log.info("Uploading asset: \(filename) (\(fileData.count) bytes, key: \(idempotencyKey))", category: .immichAPI)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.uploadFailed("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 200, 201:
                // Success — parse response
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let assetId = json["id"] as? String else {
                    throw ImmichError.decodingError("Could not parse upload response")
                }

                let statusStr = json["status"] as? String ?? "created"
                let isDuplicate = json["duplicate"] as? Bool ?? (statusStr == "duplicate")
                let status: UploadResponse.UploadStatus = isDuplicate ? .duplicate : .created

                log.info("Upload successful: \(filename) → \(assetId) (status: \(statusStr))", category: .immichAPI)

                return UploadResponse(id: assetId, status: status, duplicate: isDuplicate)

            case 401:
                throw ImmichError.authenticationFailed

            default:
                let bodyStr = String(data: data, encoding: .utf8) ?? "No body"
                log.error("Upload failed HTTP \(httpResponse.statusCode): \(bodyStr)", category: .immichAPI)
                throw ImmichError.unexpectedResponse(httpResponse.statusCode)
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.uploadFailed(error.localizedDescription)
        }
    }

    // MARK: - Verify Asset

    /// Verifies that an uploaded asset exists on the Immich server.
    /// Uses GET /api/assets/:id to check.
    ///
    /// - Parameters:
    ///   - immichAssetId: The Immich asset ID returned from upload
    ///   - serverURL: Immich server URL
    ///   - apiKey: Immich API key
    /// - Returns: Asset info if found
    public func getAsset(
        immichAssetId: String,
        serverURL: String,
        apiKey: String
    ) async throws -> AssetInfo {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        let assetURL = baseURL.appendingPathComponent("api/assets/\(immichAssetId)")
        var request = URLRequest(url: assetURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.serverUnreachable("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String else {
                    throw ImmichError.decodingError("Could not parse asset info")
                }

                return AssetInfo(
                    id: id,
                    originalFileName: json["originalFileName"] as? String,
                    type: json["type"] as? String,
                    checksum: json["checksum"] as? String
                )

            case 401:
                throw ImmichError.authenticationFailed

            case 404:
                throw ImmichError.assetNotFoundOnServer(immichAssetId)

            default:
                throw ImmichError.unexpectedResponse(httpResponse.statusCode)
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.serverUnreachable(error.localizedDescription)
        }
    }

    /// Verifies an uploaded asset matches expectations.
    /// Checks that the asset exists on the server with the expected filename.
    public func verifyUpload(
        immichAssetId: String,
        expectedFilename: String?,
        serverURL: String,
        apiKey: String
    ) async throws -> Bool {
        let info = try await getAsset(
            immichAssetId: immichAssetId,
            serverURL: serverURL,
            apiKey: apiKey
        )

        // Basic verification: asset exists with matching ID
        guard info.id == immichAssetId else {
            throw ImmichError.verificationFailed("Asset ID mismatch: expected \(immichAssetId), got \(info.id)")
        }

        // Optional filename check (Immich may normalize filenames)
        if let expected = expectedFilename, let actual = info.originalFileName {
            if actual != expected {
                LogManager.shared.warning(
                    "Filename mismatch after upload: expected '\(expected)', got '\(actual)'",
                    category: .immichAPI
                )
                // This is a warning, not a failure — Immich may normalize filenames
            }
        }

        return true
    }

    // MARK: - Detailed Asset Info (for video metadata)

    public struct ImmichAssetDetail: Sendable {
        public let id: String
        public let originalFileName: String?
        public let type: String?               // "IMAGE" or "VIDEO"
        public let fileSize: Int64?
        public let checksum: String?
        // Video-specific from exifInfo
        public let duration: Double?           // seconds (from exifInfo.duration or parsed)
        public let width: Int?
        public let height: Int?
        public let fps: Double?
        public let codec: String?              // from videoCodec field or exifInfo
        public let bitrate: Int64?
        public let make: String?
        public let model: String?
        public let latitude: Double?
        public let longitude: Double?
        public let dateTimeOriginal: String?   // ISO8601 string from exifInfo
    }

    // MARK: - Search Result

    public struct ImmichSearchResult: Sendable {
        public let total: Int
        public let nextPage: String?
        public let assets: [ImmichAssetDetail]
    }

    // MARK: - Search Assets

    /// Searches Immich assets via POST /api/search/metadata.
    ///
    /// - Parameters:
    ///   - type: Asset type filter (default: "VIDEO")
    ///   - takenAfter: Only include assets taken after this date (optional)
    ///   - takenBefore: Only include assets taken before this date (optional)
    ///   - page: Page number (1-based, default: 1)
    ///   - size: Page size (default: 100)
    ///   - serverURL: Immich server URL
    ///   - apiKey: Immich API key
    /// - Returns: Search result with total count, pagination info, and asset details
    public func searchAssets(
        type: String = "VIDEO",
        takenAfter: Date? = nil,
        takenBefore: Date? = nil,
        page: Int = 1,
        size: Int = 100,
        serverURL: String,
        apiKey: String
    ) async throws -> ImmichSearchResult {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        let searchURL = baseURL.appendingPathComponent("api/search/metadata")
        let iso = ISO8601DateFormatter()

        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build JSON body
        var bodyDict: [String: Any] = [
            "type": type,
            "page": page,
            "size": size
        ]
        if let takenAfter = takenAfter {
            bodyDict["takenAfter"] = iso.string(from: takenAfter)
        }
        if let takenBefore = takenBefore {
            bodyDict["takenBefore"] = iso.string(from: takenBefore)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let log = LogManager.shared
        log.info("Searching assets: type=\(type), page=\(page), size=\(size)", category: .immichAPI)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.searchFailed("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let assetsObj = json["assets"] as? [String: Any],
                      let items = assetsObj["items"] as? [[String: Any]] else {
                    throw ImmichError.decodingError("Could not parse search response")
                }

                let total = assetsObj["total"] as? Int ?? 0
                let nextPage = assetsObj["nextPage"] as? String

                let assets = items.map { parseAssetDetail($0) }

                log.info("Search returned \(assets.count) assets (total: \(total))", category: .immichAPI)

                return ImmichSearchResult(total: total, nextPage: nextPage, assets: assets)

            case 401:
                throw ImmichError.authenticationFailed

            default:
                let bodyStr = String(data: data, encoding: .utf8) ?? "No body"
                log.error("Search failed HTTP \(httpResponse.statusCode): \(bodyStr)", category: .immichAPI)
                throw ImmichError.searchFailed("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.searchFailed(error.localizedDescription)
        }
    }

    // MARK: - Get Asset Details (Full)

    /// Retrieves full asset details including exifInfo for video metadata.
    /// Uses GET /api/assets/{id}.
    ///
    /// - Parameters:
    ///   - immichAssetId: The Immich asset ID
    ///   - serverURL: Immich server URL
    ///   - apiKey: Immich API key
    /// - Returns: Full asset detail including video codec, duration, resolution, GPS, etc.
    public func getAssetDetails(
        immichAssetId: String,
        serverURL: String,
        apiKey: String
    ) async throws -> ImmichAssetDetail {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        let assetURL = baseURL.appendingPathComponent("api/assets/\(immichAssetId)")
        var request = URLRequest(url: assetURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.serverUnreachable("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ImmichError.decodingError("Could not parse asset details")
                }

                return parseAssetDetail(json)

            case 401:
                throw ImmichError.authenticationFailed

            case 404:
                throw ImmichError.assetNotFoundOnServer(immichAssetId)

            default:
                throw ImmichError.unexpectedResponse(httpResponse.statusCode)
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.serverUnreachable(error.localizedDescription)
        }
    }

    // MARK: - Download Asset Original

    /// Downloads the original file for an asset via GET /api/assets/{id}/original.
    /// Uses streaming download for efficiency with large video files.
    ///
    /// - Parameters:
    ///   - immichAssetId: The Immich asset ID
    ///   - destinationURL: Local file URL where the downloaded file will be saved
    ///   - serverURL: Immich server URL
    ///   - apiKey: Immich API key
    /// - Returns: The destination URL where the file was saved
    public func downloadAssetOriginal(
        immichAssetId: String,
        destinationURL: URL,
        serverURL: String,
        apiKey: String
    ) async throws -> URL {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        let downloadURL = baseURL.appendingPathComponent("api/assets/\(immichAssetId)/original")
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 600 // 10 minutes for large videos

        let log = LogManager.shared
        log.info("Downloading asset original: \(immichAssetId)", category: .immichAPI)

        do {
            let (tempURL, response) = try await session.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.downloadFailed("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 200:
                // Remove existing file at destination if present
                let fm = FileManager.default
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }

                // Ensure parent directory exists
                let parentDir = destinationURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parentDir.path) {
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }

                // Move downloaded temp file to destination
                try fm.moveItem(at: tempURL, to: destinationURL)

                let fileSize = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                log.info("Downloaded asset \(immichAssetId): \(fileSize) bytes → \(destinationURL.lastPathComponent)", category: .immichAPI)

                return destinationURL

            case 401:
                throw ImmichError.authenticationFailed

            case 404:
                throw ImmichError.assetNotFoundOnServer(immichAssetId)

            default:
                throw ImmichError.downloadFailed("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Replace Asset

    /// Replaces the original file of an existing Immich asset via PUT /api/assets/{id}/original.
    /// Uses multipart/form-data with the `assetData` field.
    ///
    /// - Parameters:
    ///   - immichAssetId: The Immich asset ID to replace
    ///   - fileData: The new file data (transcoded video)
    ///   - filename: Filename for the replacement file
    ///   - serverURL: Immich server URL
    ///   - apiKey: Immich API key
    /// - Returns: Updated asset info
    public func replaceAsset(
        immichAssetId: String,
        fileData: Data,
        filename: String,
        serverURL: String,
        apiKey: String
    ) async throws -> AssetInfo {
        guard let baseURL = URL(string: normalizeURL(serverURL)) else {
            throw ImmichError.invalidURL
        }

        let replaceURL = baseURL.appendingPathComponent("api/assets/\(immichAssetId)/original")
        let boundary = "ImmichVault-\(UUID().uuidString)"
        let mimeType = ImmichClient.mimeType(for: filename)

        var request = URLRequest(url: replaceURL)
        request.httpMethod = "PUT"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5 minutes for large files

        // Build multipart body
        var body = Data()

        // File data
        body.appendMultipartFile(name: "assetData", filename: filename, mimeType: mimeType, data: fileData, boundary: boundary)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let log = LogManager.shared
        log.info("Replacing asset \(immichAssetId) with \(filename) (\(fileData.count) bytes)", category: .immichAPI)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.replaceFailed("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String else {
                    throw ImmichError.decodingError("Could not parse replace response")
                }

                log.info("Replace successful: \(immichAssetId) → \(filename)", category: .immichAPI)

                return AssetInfo(
                    id: id,
                    originalFileName: json["originalFileName"] as? String,
                    type: json["type"] as? String,
                    checksum: json["checksum"] as? String
                )

            case 401:
                throw ImmichError.authenticationFailed

            case 404:
                throw ImmichError.assetNotFoundOnServer(immichAssetId)

            default:
                let bodyStr = String(data: data, encoding: .utf8) ?? "No body"
                log.error("Replace failed HTTP \(httpResponse.statusCode): \(bodyStr)", category: .immichAPI)
                throw ImmichError.replaceFailed("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as ImmichError {
            throw error
        } catch {
            throw ImmichError.replaceFailed(error.localizedDescription)
        }
    }

    // MARK: - Asset Detail Parsing

    /// Parses a JSON dictionary from the Immich API into an ImmichAssetDetail.
    private func parseAssetDetail(_ json: [String: Any]) -> ImmichAssetDetail {
        let exifInfo = json["exifInfo"] as? [String: Any]

        // Parse duration from top-level "duration" string like "0:01:30.000000"
        let durationStr = json["duration"] as? String
        let duration = durationStr.flatMap { parseDuration($0) }

        // Parse file size from exifInfo.fileSizeInByte
        let fileSize = exifInfo?["fileSizeInByte"] as? Int64
            ?? (exifInfo?["fileSizeInByte"] as? Int).map { Int64($0) }

        // Parse codec: try videoCodec field first, then infer from originalPath extension
        var codec = json["videoCodec"] as? String
        if codec == nil, let originalPath = json["originalPath"] as? String {
            let ext = (originalPath as NSString).pathExtension.lowercased()
            switch ext {
            case "mp4", "m4v": codec = "h264"
            case "mov": codec = "hevc"
            case "avi": codec = "mpeg4"
            case "mkv": codec = "h264"
            case "webm": codec = "vp9"
            default: break
            }
        }

        // Parse bitrate from exifInfo (not always present)
        let bitrate = exifInfo?["bitrate"] as? Int64
            ?? (exifInfo?["bitrate"] as? Int).map { Int64($0) }

        return ImmichAssetDetail(
            id: json["id"] as? String ?? "",
            originalFileName: json["originalFileName"] as? String,
            type: json["type"] as? String,
            fileSize: fileSize,
            checksum: json["checksum"] as? String,
            duration: duration,
            width: exifInfo?["exifImageWidth"] as? Int,
            height: exifInfo?["exifImageHeight"] as? Int,
            fps: exifInfo?["fps"] as? Double
                ?? (exifInfo?["fps"] as? Int).map { Double($0) },
            codec: codec,
            bitrate: bitrate,
            make: exifInfo?["make"] as? String,
            model: exifInfo?["model"] as? String,
            latitude: exifInfo?["latitude"] as? Double,
            longitude: exifInfo?["longitude"] as? Double,
            dateTimeOriginal: exifInfo?["dateTimeOriginal"] as? String
        )
    }

    // MARK: - Duration Parsing

    /// Parses Immich duration strings like "0:01:30.000000" to seconds.
    /// Supports formats: "H:MM:SS.ffffff", "MM:SS.ffffff", "SS.ffffff"
    private func parseDuration(_ str: String) -> Double? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":")
        switch parts.count {
        case 1:
            // Just seconds (possibly with fractional part)
            return Double(parts[0])
        case 2:
            // MM:SS.ffffff
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60.0 + seconds
        case 3:
            // H:MM:SS.ffffff
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600.0 + minutes * 60.0 + seconds
        default:
            return nil
        }
    }

    // MARK: - URL Normalization

    private func normalizeURL(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slash
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }

        // Add scheme if missing
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }

        return normalized
    }
}

// MARK: - Multipart Form Data Helpers

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n".data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n".data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}

// MARK: - MIME Type Helpers

public extension ImmichClient {
    /// Determines MIME type from filename extension.
    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        // Images
        case "heic", "heif": return "image/heic"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        case "raw", "dng": return "image/x-adobe-dng"
        case "cr2": return "image/x-canon-cr2"
        case "nef": return "image/x-nikon-nef"
        case "arw": return "image/x-sony-arw"

        // Videos
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "wmv": return "video/x-ms-wmv"
        case "webm": return "video/webm"
        case "3gp": return "video/3gpp"

        default: return "application/octet-stream"
        }
    }
}
