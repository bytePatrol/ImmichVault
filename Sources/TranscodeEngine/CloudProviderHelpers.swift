import Foundation

// MARK: - Cloud Provider Helpers
// Shared utilities for all cloud transcode providers: HTTP requests, polling, timeouts.

public enum CloudProviderHelpers {

    // MARK: - HTTP Request

    /// Perform an HTTP request with standard error handling.
    /// - Parameters:
    ///   - url: The request URL.
    ///   - method: HTTP method (GET, POST, PUT, DELETE).
    ///   - headers: Additional headers to include.
    ///   - body: Optional request body data.
    ///   - session: URLSession to use (defaults to shared).
    ///   - timeout: Request timeout in seconds (defaults to 60).
    /// - Returns: Tuple of response data and HTTP response.
    public static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 60
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudProviderError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudProviderError.networkError("Invalid response type")
        }

        // Handle common HTTP errors
        switch httpResponse.statusCode {
        case 200...299:
            return (data, httpResponse)
        case 401, 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudProviderError.authenticationFailed(body)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw CloudProviderError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudProviderError.unexpectedResponse(
                statusCode: httpResponse.statusCode,
                body: body
            )
        }
    }

    /// Perform a JSON POST request and return parsed response.
    public static func postJSON<T: Decodable>(
        url: URL,
        body: Any,
        headers: [String: String] = [:],
        session: URLSession = .shared,
        responseType: T.Type
    ) async throws -> T {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"

        let (data, _) = try await request(
            url: url,
            method: "POST",
            headers: allHeaders,
            body: bodyData,
            session: session
        )

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CloudProviderError.invalidResponse(
                "Failed to decode \(T.self): \(error.localizedDescription). Body: \(rawBody.prefix(500))"
            )
        }
    }

    /// Upload a file via PUT request with raw binary body.
    public static func uploadFile(
        url: URL,
        fileURL: URL,
        contentType: String = "application/octet-stream",
        headers: [String: String] = [:],
        session: URLSession = .shared,
        timeout: TimeInterval = 600
    ) async throws {
        let fileData = try Data(contentsOf: fileURL)

        var allHeaders = headers
        allHeaders["Content-Type"] = contentType

        let _ = try await request(
            url: url,
            method: "PUT",
            headers: allHeaders,
            body: fileData,
            session: session,
            timeout: timeout
        )
    }

    /// Download a file from a URL to a local destination.
    public static func downloadFile(
        from url: URL,
        to destinationURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 600
    ) async throws {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch {
            throw CloudProviderError.downloadFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudProviderError.downloadFailed("HTTP \(code)")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tempURL, to: destinationURL)
    }

    // MARK: - Polling

    /// Poll a cloud job with exponential backoff until completion or failure.
    /// - Parameters:
    ///   - initialInterval: Starting poll interval in seconds.
    ///   - maxInterval: Maximum poll interval in seconds.
    ///   - maxAttempts: Maximum number of poll attempts before timing out.
    ///   - providerName: Name of the provider (for error messages).
    ///   - check: Closure that polls the provider and returns current status.
    /// - Returns: The final `CloudJobStatus` (completed or failed).
    public static func pollWithBackoff(
        initialInterval: TimeInterval = 5.0,
        maxInterval: TimeInterval = 15.0,
        maxAttempts: Int = 360,
        providerName: String = "Cloud provider",
        check: @Sendable () async throws -> CloudJobStatus
    ) async throws -> CloudJobStatus {
        var interval = initialInterval
        var attempts = 0

        while attempts < maxAttempts {
            if Task.isCancelled {
                throw CancellationError()
            }

            let status = try await check()

            if status.state.isTerminal {
                return status
            }

            attempts += 1

            // Wait before next poll
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            // Increase interval up to max
            interval = min(interval * 1.3, maxInterval)
        }

        throw CloudProviderError.pollingTimeout(
            jobId: "unknown",
            maxAttempts: maxAttempts
        )
    }

    // MARK: - JSON Helpers

    /// Safely extract a string value from a JSON dictionary.
    public static func jsonString(_ dict: [String: Any], key: String) -> String? {
        dict[key] as? String
    }

    /// Safely extract an integer value from a JSON dictionary.
    public static func jsonInt(_ dict: [String: Any], key: String) -> Int? {
        if let intVal = dict[key] as? Int { return intVal }
        if let doubleVal = dict[key] as? Double { return Int(doubleVal) }
        if let strVal = dict[key] as? String { return Int(strVal) }
        return nil
    }

    /// Safely extract a double value from a JSON dictionary.
    public static func jsonDouble(_ dict: [String: Any], key: String) -> Double? {
        if let doubleVal = dict[key] as? Double { return doubleVal }
        if let intVal = dict[key] as? Int { return Double(intVal) }
        if let strVal = dict[key] as? String { return Double(strVal) }
        return nil
    }

    /// Parse a JSON response body into a dictionary.
    public static func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudProviderError.invalidResponse("Expected JSON object")
        }
        return dict
    }

    /// Parse a JSON response body that has a `data` wrapper.
    public static func parseJSONData(_ data: Data) throws -> [String: Any] {
        let root = try parseJSON(data)
        guard let dataDict = root["data"] as? [String: Any] else {
            throw CloudProviderError.invalidResponse("Missing 'data' key in response")
        }
        return dataDict
    }
}
