import SwiftUI
import os

// MARK: - ThumbHash Decoder
// Decodes Immich ThumbHash (base64) to NSImage. Based on the ThumbHash spec by Evan Wallace.

enum ThumbHashDecoder {
    /// Decodes an Immich ThumbHash (base64) to a small blurred placeholder NSImage.
    /// Full algorithm: decodes all AC coefficients via inverse DCT.
    /// Based on the ThumbHash spec by Evan Wallace (https://evanw.github.io/thumbhash/).
    static func decode(_ base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64), data.count >= 5 else { return nil }
        let hash = [UInt8](data)

        // Read packed header (24 bits from bytes 0-2, 16 bits from bytes 3-4)
        let header24 = Int(hash[0]) | (Int(hash[1]) << 8) | (Int(hash[2]) << 16)
        let header16 = Int(hash[3]) | (Int(hash[4]) << 8)

        let lDC = Float(header24 & 63) / 63.0
        let pDC = Float((header24 >> 6) & 63) / 31.5 - 1.0
        let qDC = Float((header24 >> 12) & 63) / 31.5 - 1.0
        let lScale = Float((header24 >> 18) & 31) / 31.0
        let hasAlpha = ((header24 >> 23) & 1) != 0
        let pScale = Float((header16 >> 3) & 63) / 63.0
        let qScale = Float((header16 >> 9) & 63) / 63.0
        let isLandscape = ((header16 >> 15) & 1) != 0

        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : (header16 & 7))
        let ly = max(3, isLandscape ? (header16 & 7) : (hasAlpha ? 5 : 7))

        var aDC: Float = 1.0
        var aScale: Float = 0.0
        if hasAlpha {
            aDC = Float(hash[5] & 15) / 15.0
            aScale = Float(hash[5] >> 4) / 15.0
        }

        // Decode AC coefficients from nibble stream
        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0

        func decodeChannel(nx: Int, ny: Int, scale: Float) -> [Float] {
            var ac = [Float]()
            for cy in 0..<ny {
                var cx = cy > 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let byteIdx = acStart + (acIndex >> 1)
                    guard byteIdx < hash.count else {
                        ac.append(0)
                        acIndex += 1
                        cx += 1
                        continue
                    }
                    let nibble = (Int(hash[byteIdx]) >> ((acIndex & 1) << 2)) & 15
                    ac.append((Float(nibble) / 7.5 - 1.0) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return ac
        }

        let lAC = decodeChannel(nx: lx, ny: ly, scale: lScale)
        let pAC = decodeChannel(nx: 3, ny: 3, scale: pScale * 1.25)
        let qAC = decodeChannel(nx: 3, ny: 3, scale: qScale * 1.25)
        let aAC = hasAlpha ? decodeChannel(nx: 5, ny: 5, scale: aScale) : []

        // Compute output image dimensions from aspect ratio
        let ratio = Float(lx) / Float(ly)
        let imgW = Int(round(ratio > 1 ? 32 : 32 * ratio))
        let imgH = Int(round(ratio > 1 ? 32 / ratio : 32))
        guard imgW > 0, imgH > 0 else { return nil }

        // Inverse DCT reconstruction
        let fxMax = max(lx, hasAlpha ? 5 : 3)
        let fyMax = max(ly, hasAlpha ? 5 : 3)
        var fx = [Float](repeating: 0, count: fxMax)
        var fy = [Float](repeating: 0, count: fyMax)

        var pixels = [UInt8](repeating: 0, count: imgW * imgH * 4)

        for y in 0..<imgH {
            for x in 0..<imgW {
                var l = lDC
                var p = pDC
                var q = qDC
                var a = aDC

                // Precompute cosine basis
                for i in 0..<fxMax {
                    fx[i] = cos(Float.pi / Float(imgW) * (Float(x) + 0.5) * Float(i))
                }
                for i in 0..<fyMax {
                    fy[i] = cos(Float.pi / Float(imgH) * (Float(y) + 0.5) * Float(i))
                }

                // Luminance
                var j = 0
                for cy in 0..<ly {
                    let fy2 = fy[cy] * 2.0
                    var cx = cy > 0 ? 0 : 1
                    while cx * ly < lx * (ly - cy) {
                        l += lAC[j] * fx[cx] * fy2
                        j += 1
                        cx += 1
                    }
                }

                // Chrominance P and Q (3x3)
                j = 0
                for cy in 0..<3 {
                    let fy2 = fy[cy] * 2.0
                    var cx = cy > 0 ? 0 : 1
                    while cx * 3 < 3 * (3 - cy) {
                        let f = fx[cx] * fy2
                        p += pAC[j] * f
                        q += qAC[j] * f
                        j += 1
                        cx += 1
                    }
                }

                // Alpha (5x5)
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        let fy2 = fy[cy] * 2.0
                        var cx = cy > 0 ? 0 : 1
                        while cx * 5 < 5 * (5 - cy) {
                            a += aAC[j] * fx[cx] * fy2
                            j += 1
                            cx += 1
                        }
                    }
                }

                // LPQ → RGB
                let b = l - 2.0 / 3.0 * p
                let r = (3.0 * l - b + q) / 2.0
                let g = r - q

                let idx = (y * imgW + x) * 4
                pixels[idx + 0] = UInt8(max(0, min(255, Int(r * 255))))
                pixels[idx + 1] = UInt8(max(0, min(255, Int(g * 255))))
                pixels[idx + 2] = UInt8(max(0, min(255, Int(b * 255))))
                pixels[idx + 3] = UInt8(max(0, min(255, Int(a * 255))))
            }
        }

        // Create NSImage from RGBA pixel data
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: imgW, height: imgH,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: imgW * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
                  provider: provider,
                  decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: imgW, height: imgH))
    }
}

// MARK: - Thumbnail Cache

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let state = OSAllocatedUnfairLock(initialState: [String: Task<NSImage?, Never>]())

    private init() {
        cache.countLimit = 500
    }

    /// Fetch thumbnail: tries Immich API first, falls back to ThumbHash decode.
    func thumbnail(
        for assetId: String,
        serverURL: String,
        apiKey: String,
        size: ImmichClient.ThumbnailSize = .thumbnail,
        thumbhash: String? = nil
    ) async -> NSImage? {
        let keyStr = "\(assetId)-\(size.rawValue)"

        if let cached = cache.object(forKey: keyStr as NSString) {
            return cached
        }

        // Deduplicate in-flight requests
        let existing = state.withLock { inFlight in
            inFlight[keyStr]
        }
        if let existing {
            return await existing.value
        }

        let cache = self.cache
        let task = Task<NSImage?, Never> { [keyStr] in
            // Try Immich thumbnail API first
            do {
                let data = try await ImmichClient().fetchThumbnail(
                    assetId: assetId,
                    size: size,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                if let image = NSImage(data: data) {
                    cache.setObject(image, forKey: keyStr as NSString)
                    return image
                } else {
                    LogManager.shared.warning(
                        "Thumbnail: got \(data.count) bytes for \(assetId) but NSImage decode failed",
                        category: .transcode
                    )
                }
            } catch {
                LogManager.shared.debug(
                    "Thumbnail API failed for \(assetId): \(error.localizedDescription)",
                    category: .transcode
                )
            }

            // Fallback: decode ThumbHash
            if let thumbhash, let image = ThumbHashDecoder.decode(thumbhash) {
                cache.setObject(image, forKey: keyStr as NSString)
                return image
            }

            return nil
        }

        state.withLock { inFlight in
            inFlight[keyStr] = task
        }

        let result = await task.value

        state.withLock { inFlight in
            inFlight.removeValue(forKey: keyStr)
        }

        return result
    }
}

// MARK: - Candidate Tile View

struct CandidateTileView: View {
    let candidate: TranscodeCandidate
    let isSelected: Bool
    let isFocused: Bool
    let serverURL: String
    let apiKey: String
    let onToggleSelection: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isLoadingThumbnail = false

    var body: some View {
        VStack(alignment: .leading, spacing: IVSpacing.xs) {
            thumbnailArea
            fileInfoArea
        }
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .stroke(
                    isFocused ? Color.ivAccent.opacity(0.6) : Color.ivBorder.opacity(0.3),
                    lineWidth: isFocused ? 2 : 0.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: IVCornerRadius.md))
        .task(id: candidate.id) {
            await loadThumbnail()
        }
    }

    // MARK: - Thumbnail Area

    private var thumbnailArea: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Color.black

            // Thumbnail image (GeometryReader constrains .fill to exact bounds)
            if let thumbnail = thumbnail {
                GeometryReader { geo in
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                if isLoadingThumbnail {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.ivTextTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Codec badge — top left
            codecBadge
                .padding(IVSpacing.xs)

            // Checkbox — top right
            VStack {
                HStack {
                    Spacer()
                    Button {
                        onToggleSelection()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundColor(isSelected ? .ivAccent : .white.opacity(0.7))
                            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(IVSpacing.xs)
                }
                Spacer()
            }

            // Duration badge — bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    durationBadge
                        .padding(IVSpacing.xs)
                }
            }
        }
        .frame(height: 120)
        .clipped()
    }

    // MARK: - File Info Area

    private var fileInfoArea: some View {
        VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
            Text(candidate.detail.originalFileName ?? "Unknown")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.ivTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(ByteCountFormatter.string(fromByteCount: candidate.originalFileSize, countStyle: .file))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.ivTextTertiary)
        }
        .padding(.horizontal, IVSpacing.sm)
        .padding(.bottom, IVSpacing.sm)
    }

    // MARK: - Badges

    private var codecBadge: some View {
        let codec = candidate.detail.codec?.uppercased() ?? ""
        let isHEVC = codec.contains("HEVC") || codec.contains("H265") || codec.contains("H.265")
        let badgeColor: Color = isHEVC ? .purple : .orange
        let label = isHEVC ? "HEVC" : (codec.contains("H264") || codec.contains("AVC") ? "H.264" : (codec.isEmpty ? "" : codec))

        return Group {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, IVSpacing.xs)
                    .padding(.vertical, IVSpacing.xxxs)
                    .background {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(badgeColor.opacity(0.85))
                    }
            }
        }
    }

    private var durationBadge: some View {
        let d = candidate.detail.duration ?? 0
        let totalSeconds = Int(d)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)

        return Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, IVSpacing.xs)
            .padding(.vertical, IVSpacing.xxxs)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.6))
            }
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() async {
        guard thumbnail == nil, !isLoadingThumbnail else { return }
        isLoadingThumbnail = true
        thumbnail = await ThumbnailCache.shared.thumbnail(
            for: candidate.id,
            serverURL: serverURL,
            apiKey: apiKey,
            thumbhash: candidate.detail.thumbhash
        )
        isLoadingThumbnail = false
    }
}

// MARK: - Candidate Grid View

struct CandidateGridView: View {
    let candidates: [TranscodeCandidate]
    let serverURL: String
    let apiKey: String
    @Binding var selectedCandidateID: String?
    @Binding var selectedCandidateIDs: Set<String>
    let onInspect: (String) -> Void
    let onOpenInImmich: (String) -> Void
    let onTranscodeNow: (String) -> Void
    let onToggleSelection: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: IVSpacing.md)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: IVSpacing.lg) {
                ForEach(groupedByDate, id: \.date) { group in
                    sectionHeader(group)

                    LazyVGrid(columns: columns, spacing: IVSpacing.md) {
                        ForEach(group.candidates) { candidate in
                            let isFocused = selectedCandidateID == candidate.id
                            let isChecked = selectedCandidateIDs.contains(candidate.id)

                            CandidateTileView(
                                candidate: candidate,
                                isSelected: isChecked,
                                isFocused: isFocused,
                                serverURL: serverURL,
                                apiKey: apiKey,
                                onToggleSelection: { onToggleSelection(candidate.id) }
                            )
                            .onTapGesture(count: 2) {
                                onOpenInImmich(candidate.id)
                            }
                            .onTapGesture {
                                onInspect(candidate.id)
                            }
                            .contextMenu {
                                Button {
                                    onOpenInImmich(candidate.id)
                                } label: {
                                    Label("Open in Immich", systemImage: "safari")
                                }
                                Button {
                                    onTranscodeNow(candidate.id)
                                } label: {
                                    Label("Queue Transcode Now", systemImage: "wand.and.stars")
                                }
                                Divider()
                                if selectedCandidateIDs.contains(candidate.id) {
                                    Button {
                                        onToggleSelection(candidate.id)
                                    } label: {
                                        Label("Deselect", systemImage: "square")
                                    }
                                } else {
                                    Button {
                                        onToggleSelection(candidate.id)
                                    } label: {
                                        Label("Select", systemImage: "checkmark.square")
                                    }
                                }
                                Divider()
                                Button {
                                    onInspect(candidate.id)
                                } label: {
                                    Label("Inspect", systemImage: "info.circle")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, IVSpacing.lg)
            .padding(.vertical, IVSpacing.md)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ group: DateGroup) -> some View {
        HStack(spacing: IVSpacing.sm) {
            Text(group.dateLabel)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.ivTextPrimary)

            Text("\(group.candidates.count) items")
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)

            Text("\u{00B7}")
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)

            Text(ByteCountFormatter.string(fromByteCount: group.totalSize, countStyle: .file))
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)

            Spacer()
        }
        .padding(.top, IVSpacing.xs)
    }

    // MARK: - Date Grouping

    private struct DateGroup {
        let date: String
        let dateLabel: String
        let candidates: [TranscodeCandidate]
        let totalSize: Int64
    }

    private var groupedByDate: [DateGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterSimple = ISO8601DateFormatter()
        isoFormatterSimple.formatOptions = [.withInternetDateTime]
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d, yyyy"

        var grouped: [String: [TranscodeCandidate]] = [:]
        var dateForKey: [String: Date] = [:]

        for candidate in candidates {
            var parsed: Date?
            if let dateStr = candidate.detail.dateTimeOriginal {
                parsed = isoFormatter.date(from: dateStr) ?? isoFormatterSimple.date(from: dateStr)
            }
            let date = parsed ?? Date.distantPast
            let dayStart = calendar.startOfDay(for: date)
            let key = displayFormatter.string(from: dayStart)
            grouped[key, default: []].append(candidate)
            dateForKey[key] = dayStart
        }

        return grouped.map { key, candidates in
            let dayStart = dateForKey[key] ?? .distantPast
            let label: String
            if calendar.isDate(dayStart, inSameDayAs: today) {
                label = "Today"
            } else if calendar.isDate(dayStart, inSameDayAs: yesterday) {
                label = "Yesterday"
            } else {
                label = key
            }
            let totalSize = candidates.reduce(Int64(0)) { $0 + $1.originalFileSize }
            return DateGroup(date: key, dateLabel: label, candidates: candidates, totalSize: totalSize)
        }
        .sorted { ($0.candidates.first?.detail.dateTimeOriginal ?? "") > ($1.candidates.first?.detail.dateTimeOriginal ?? "") }
    }
}
