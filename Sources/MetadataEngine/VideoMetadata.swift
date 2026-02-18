import Foundation

// MARK: - Video Metadata

/// Holds video metadata extracted by ffprobe.
/// Used for metadata validation before and after transcoding.
public struct VideoMetadata: Codable, Sendable, Equatable {

    // MARK: - Stream Properties

    /// Duration in seconds.
    public var duration: Double?

    /// Video width in pixels.
    public var width: Int?

    /// Video height in pixels.
    public var height: Int?

    /// Video codec name (e.g. "h264", "hevc").
    public var videoCodec: String?

    /// Audio codec name (e.g. "aac").
    public var audioCodec: String?

    /// Overall bitrate in bits/sec.
    public var bitrate: Int64?

    /// Video stream bitrate in bits/sec.
    public var videoBitrate: Int64?

    /// Audio stream bitrate in bits/sec.
    public var audioBitrate: Int64?

    // MARK: - Tags / Metadata

    /// Creation date from container metadata.
    public var creationDate: Date?

    /// GPS latitude (decimal degrees).
    public var gpsLatitude: Double?

    /// GPS longitude (decimal degrees).
    public var gpsLongitude: Double?

    /// Rotation in degrees (0, 90, 180, 270).
    public var rotation: Int?

    /// Camera make (e.g. "Apple").
    public var make: String?

    /// Camera model (e.g. "iPhone 15 Pro").
    public var model: String?

    // MARK: - Container

    /// Container format name (e.g. "mov", "mp4").
    public var containerFormat: String?

    /// File size in bytes.
    public var fileSize: Int64?

    /// Frames per second.
    public var fps: Double?

    // MARK: - Computed Helpers

    /// Resolution string (e.g. "1920x1080"), or nil if width/height unavailable.
    public var resolution: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w)x\(h)"
    }

    /// Whether GPS coordinates are present.
    public var hasGPS: Bool {
        gpsLatitude != nil && gpsLongitude != nil
    }

    /// Human-readable duration (e.g. "1h 30m 15s", "2m 5s", "45s").
    public var durationFormatted: String {
        guard let d = duration, d > 0 else { return "0s" }

        let totalSeconds = Int(d)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds)s") }
        return parts.joined(separator: " ")
    }

    // MARK: - Init

    public init(
        duration: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        bitrate: Int64? = nil,
        videoBitrate: Int64? = nil,
        audioBitrate: Int64? = nil,
        creationDate: Date? = nil,
        gpsLatitude: Double? = nil,
        gpsLongitude: Double? = nil,
        rotation: Int? = nil,
        make: String? = nil,
        model: String? = nil,
        containerFormat: String? = nil,
        fileSize: Int64? = nil,
        fps: Double? = nil
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.bitrate = bitrate
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.creationDate = creationDate
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.rotation = rotation
        self.make = make
        self.model = model
        self.containerFormat = containerFormat
        self.fileSize = fileSize
        self.fps = fps
    }
}

// MARK: - CustomStringConvertible

extension VideoMetadata: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if let res = resolution { parts.append(res) }
        if let vc = videoCodec { parts.append(vc) }
        if let dur = durationFormatted as String? { parts.append(dur) }
        if let size = fileSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append(formatter.string(fromByteCount: size))
        }
        if let br = bitrate {
            parts.append("\(br / 1000) kbps")
        }
        return parts.joined(separator: " | ")
    }
}
