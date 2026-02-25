import SwiftUI
import AVFoundation
import AVKit
import Combine

// MARK: - Video Preview Player
// Streams video directly from Immich via AVURLAsset with custom HTTP headers.
// AVPlayer handles progressive buffering — playback begins as soon as enough
// data is available, no full download required.

struct VideoPreviewPlayer: View {
    let assetId: String
    let duration: Double?
    let serverURL: String
    let apiKey: String
    let thumbhash: String?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isBuffering = false
    @State private var posterImage: NSImage?
    @State private var isLoadingPoster = true
    @State private var errorMessage: String?
    @State private var statusObserver: AnyCancellable?
    @State private var bufferObserver: AnyCancellable?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black)

            // Poster image (shown before playback starts)
            if !isPlaying {
                posterView
            }

            // Video player
            if let player = player {
                VideoPlayerView(player: player)
                    .opacity(isPlaying ? 1 : 0)
            }

            // Overlays
            if !isPlaying {
                if let errorMessage = errorMessage {
                    errorOverlay(errorMessage)
                } else if isBuffering {
                    bufferingOverlay
                } else {
                    playButtonOverlay
                }
            }

            // Duration badge — bottom right (before playback)
            if !isPlaying && !isBuffering && errorMessage == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        durationBadge
                            .padding(IVSpacing.sm)
                    }
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: IVCornerRadius.lg))
        .onChange(of: assetId) { _ in
            stopPlayback()
            errorMessage = nil
        }
        // .task(id:) auto-cancels the previous task when assetId changes,
        // preventing stale poster images from overwriting the current one.
        .task(id: assetId) {
            posterImage = nil
            isLoadingPoster = true
            await loadPoster()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    // MARK: - Poster View

    private var posterView: some View {
        Group {
            if let posterImage = posterImage {
                Image(nsImage: posterImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if isLoadingPoster {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.ivTextTertiary)
            }
        }
    }

    // MARK: - Play Button

    private var playButtonOverlay: some View {
        Button {
            startStreaming()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 48, height: 48)

                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .offset(x: 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Buffering Overlay

    private var bufferingOverlay: some View {
        VStack(spacing: IVSpacing.sm) {
            ProgressView()
                .scaleEffect(0.9)
                .tint(.white)

            Text("Buffering...")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: IVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(.ivWarning)

            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, IVSpacing.md)

            Button("Retry") {
                errorMessage = nil
                startStreaming()
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.borderless)
            .foregroundColor(.ivAccent)
        }
    }

    // MARK: - Duration Badge

    private var durationBadge: some View {
        let d = duration ?? 0
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

    // MARK: - Streaming Playback

    private func startStreaming() {
        errorMessage = nil
        isBuffering = true

        let normalizedServer = normalizeURL(serverURL)
        guard let baseURL = URL(string: normalizedServer) else {
            errorMessage = "Invalid server URL"
            isBuffering = false
            return
        }

        let videoURL = baseURL.appendingPathComponent("api/assets/\(assetId)/original")

        LogManager.shared.debug(
            "Video preview: streaming \(videoURL.absoluteString)",
            category: .transcode
        )

        // AVURLAsset with custom HTTP headers for Immich API key auth.
        // AVPlayer handles progressive buffering — playback starts as soon as
        // enough data is available, no full download required.
        let asset = AVURLAsset(url: videoURL, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["x-api-key": apiKey]
        ])

        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        // Observe player item status to detect when playback is ready or failed
        statusObserver = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                switch status {
                case .readyToPlay:
                    isBuffering = false
                    isPlaying = true
                    newPlayer.play()
                case .failed:
                    isBuffering = false
                    let desc = playerItem.error?.localizedDescription ?? "Unknown playback error"
                    errorMessage = desc
                    LogManager.shared.error(
                        "Video preview stream failed for \(assetId): \(desc)",
                        category: .transcode
                    )
                default:
                    break
                }
            }

        // Observe buffering state so we can show indicator if rebuffering mid-stream
        bufferObserver = playerItem.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { isEmpty in
                if isEmpty && isPlaying {
                    isBuffering = true
                } else if !isEmpty {
                    isBuffering = false
                }
            }
    }

    private func stopPlayback() {
        statusObserver?.cancel()
        statusObserver = nil
        bufferObserver?.cancel()
        bufferObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        isBuffering = false
    }

    private func loadPoster() async {
        let targetId = assetId
        isLoadingPoster = true
        let image = await ThumbnailCache.shared.thumbnail(
            for: targetId,
            serverURL: serverURL,
            apiKey: apiKey,
            size: .preview,
            thumbhash: thumbhash
        )
        // Only apply if this is still the current asset (guards against race conditions
        // where a previous load completes after a new assetId was set).
        guard !Task.isCancelled, assetId == targetId else { return }
        posterImage = image
        isLoadingPoster = false
    }

    private func normalizeURL(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        return normalized
    }
}

// MARK: - AVPlayer SwiftUI Wrapper

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
