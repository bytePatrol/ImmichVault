import SwiftUI

// MARK: - Manual Encode View
// Direct encode workflow: enter an Immich asset ID, validate, configure
// encoding parameters, and queue a transcode + replace job.
// Title lives in OptimizerContainerView's unified toolbar.

struct ManualEncodeView: View {
    @ObservedObject var viewModel: ManualEncodeViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: IVSpacing.xl) {
                IVGroupedPanel("ASSET") {
                    assetContent
                }
                if viewModel.validatedAsset != nil {
                    IVGroupedPanel("ENCODING") {
                        encodingContent
                    }
                    estimatedOutputSection
                    actionSection
                }
            }
            .padding(.horizontal, IVSpacing.xxl)
            .padding(.vertical, IVSpacing.xl)
            .frame(maxWidth: 560, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Asset Content

    private var assetContent: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack(spacing: IVSpacing.sm) {
                TextField("Immich asset ID or URL", text: $viewModel.assetInput)
                    .textFieldStyle(.roundedBorder)
                    .font(IVFont.mono)
                    .onSubmit {
                        if viewModel.canValidate {
                            Task { await viewModel.validateAsset() }
                        }
                    }

                Button {
                    Task { await viewModel.validateAsset() }
                } label: {
                    if viewModel.isValidating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Text("Validate")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canValidate)
            }

            if let error = viewModel.validationError {
                errorBanner(error)
            }

            if let asset = viewModel.validatedAsset {
                assetDetailCard(asset)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.validatedAsset?.id)
        .animation(.easeInOut(duration: 0.2), value: viewModel.validationError)
    }

    // MARK: - Asset Detail Card

    private func assetDetailCard(_ asset: ImmichClient.ImmichAssetDetail) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(.purple)
                Text(asset.originalFileName ?? "Unknown")
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                IVStatusBadge("Video", status: .info)
            }

            Divider().opacity(0.4)

            Grid(alignment: .leading, horizontalSpacing: IVSpacing.lg, verticalSpacing: IVSpacing.xs) {
                if let w = asset.width, let h = asset.height {
                    GridRow {
                        metaLabel("Resolution")
                        metaValue("\(w) x \(h)")
                    }
                }
                if let codec = asset.codec {
                    GridRow {
                        metaLabel("Codec")
                        metaValue(codec.uppercased())
                    }
                }
                if let dur = asset.duration {
                    GridRow {
                        metaLabel("Duration")
                        metaValue(formatDuration(dur))
                    }
                }
                if let size = asset.fileSize {
                    GridRow {
                        metaLabel("Size")
                        metaValue(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                if let make = asset.make {
                    GridRow {
                        metaLabel("Camera")
                        metaValue(make + (asset.model.map { " \($0)" } ?? ""))
                    }
                }

                let hasGPS = asset.latitude != nil && asset.longitude != nil
                GridRow {
                    metaLabel("GPS")
                    metaValue(hasGPS ? "Yes" : "No")
                }

                if let date = asset.dateTimeOriginal {
                    GridRow {
                        metaLabel("Date")
                        metaValue(date)
                    }
                }
            }
        }
        .padding(IVSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.purple.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.purple.opacity(0.15), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Encoding Content

    private var encodingContent: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Grid(alignment: .leading, horizontalSpacing: IVSpacing.sm, verticalSpacing: IVSpacing.sm) {
                GridRow {
                    Text("Codec")
                        .gridColumnAlignment(.trailing)
                    Picker("Codec", selection: $viewModel.selectedCodec) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("HEVC").tag(VideoCodec.h265)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }

                GridRow {
                    Text("Resolution")
                    Picker("Resolution", selection: $viewModel.selectedResolution) {
                        ForEach(TargetResolution.allCases) { res in
                            Text(resolutionLabel(res)).tag(res)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(IVFont.caption)
                }

                GridRow {
                    Text("CRF")
                    HStack(spacing: IVSpacing.sm) {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.selectedCRF) },
                                set: { viewModel.selectedCRF = Int($0) }
                            ),
                            in: 18...36,
                            step: 1
                        )
                        .frame(minWidth: 100, maxWidth: .infinity)

                        Text("\(viewModel.selectedCRF)")
                            .font(IVFont.mono)
                            .foregroundColor(.ivTextPrimary)
                            .frame(width: 24, alignment: .trailing)
                            .monospacedDigit()
                    }
                }

                GridRow {
                    Text("Speed")
                    Picker("Speed", selection: $viewModel.selectedSpeed) {
                        Text("Slow").tag(EncodeSpeed.slow)
                        Text("Medium").tag(EncodeSpeed.medium)
                        Text("Fast").tag(EncodeSpeed.fast)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }

                GridRow {
                    Text("Provider")
                    HStack(spacing: IVSpacing.xs) {
                        Circle()
                            .fill(Color.ivSuccess)
                            .frame(width: 6, height: 6)
                        Picker("Provider", selection: $viewModel.selectedProvider) {
                            ForEach(TranscodeProviderType.allCases, id: \.self) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(IVFont.caption)
                    }
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(.ivTextSecondary)
            .controlSize(.small)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Estimated Output (three-column layout matching mockup)

    @ViewBuilder
    private var estimatedOutputSection: some View {
        if let estimated = viewModel.estimatedOutputSize, let asset = viewModel.validatedAsset,
           let originalSize = asset.fileSize, originalSize > 0 {
            HStack(spacing: 0) {
                // Est. Output column
                VStack(spacing: IVSpacing.xxs) {
                    Text("EST. OUTPUT")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.ivTextSecondary)
                        .tracking(0.5)
                    Text("~\(ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file))")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(.ivSuccess)
                    Text("from \(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file))")
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextTertiary)
                }
                .frame(maxWidth: .infinity)

                // Savings column
                if let savings = viewModel.estimatedSavingsPercent {
                    VStack(spacing: IVSpacing.xxs) {
                        Text("SAVINGS")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.ivTextSecondary)
                            .tracking(0.5)
                        Text(String(format: "%.0f%%", savings))
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(savings > 0 ? .ivSuccess : .ivWarning)
                        Text("~\(ByteCountFormatter.string(fromByteCount: originalSize - estimated, countStyle: .file)) saved")
                            .font(IVFont.monoSmall)
                            .foregroundColor(.ivTextTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }

                // Est. Time column
                VStack(spacing: IVSpacing.xxs) {
                    Text("EST. TIME")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.ivTextSecondary)
                        .tracking(0.5)
                    Text(estimatedTimeLabel(asset))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(.ivSuccess)
                    Text(viewModel.selectedProvider == .local ? "VideoToolbox" : viewModel.selectedProvider.label)
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextTertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(IVSpacing.lg)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.md)
                    .fill(Color.ivSuccess.opacity(0.06))
            }
            .animation(.easeInOut(duration: 0.15), value: estimated)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: IVSpacing.md) {
            if let error = viewModel.jobError {
                errorBanner(error)
            }

            if viewModel.jobCreated {
                jobCreatedBanner
            } else {
                Button {
                    Task { await viewModel.startEncode() }
                } label: {
                    HStack(spacing: IVSpacing.sm) {
                        if viewModel.isCreatingJob {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(viewModel.isCreatingJob ? "Creating Job..." : "Start Encode")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, IVSpacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canStartEncode)
            }

            Button("Reset") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.reset()
                }
            }
            .font(IVFont.caption)
            .buttonStyle(.borderless)
            .foregroundColor(.ivTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Job Created Banner

    private var jobCreatedBanner: some View {
        HStack(spacing: IVSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.ivSuccess)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Job Queued")
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
                Text("View progress in the Jobs tab.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }
            Spacer()
            Button("Go to Jobs") {
                appState.selectedNavItem = .jobs
            }
            .font(IVFont.captionMedium)
            .buttonStyle(.bordered)
        }
        .padding(IVSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSuccess.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivSuccess.opacity(0.2), lineWidth: 0.5)
                )
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - Helpers

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(IVFont.captionMedium)
            .foregroundColor(.ivTextSecondary)
            .frame(width: 70, alignment: .trailing)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text)
            .font(IVFont.mono)
            .foregroundColor(.ivTextPrimary)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: IVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.ivError)
            Text(message)
                .font(IVFont.caption)
                .foregroundColor(.ivError)
            Spacer()
        }
        .padding(IVSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                .fill(Color.ivError.opacity(0.08))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    /// Resolution label with original dimensions when available.
    private func resolutionLabel(_ res: TargetResolution) -> String {
        if res == .keepSame, let asset = viewModel.validatedAsset,
           let w = asset.width, let h = asset.height {
            return "Original (\(w)x\(h))"
        }
        return res.label
    }

    /// Estimated encode time based on duration and speed setting.
    private func estimatedTimeLabel(_ asset: ImmichClient.ImmichAssetDetail) -> String {
        guard let duration = asset.duration, duration > 0 else { return "~? min" }
        // Rough estimate: local HW encode ~2-4x realtime, SW ~0.5-1x
        let speedMultiplier: Double
        switch viewModel.selectedSpeed {
        case .slow, .slower, .veryslow: speedMultiplier = 0.5
        case .medium: speedMultiplier = 1.0
        case .fast, .faster, .veryfast: speedMultiplier = 2.0
        case .ultrafast, .superfast: speedMultiplier = 3.0
        }

        let isHardware = viewModel.selectedCodec == .h265
        let baseMultiplier = isHardware ? 3.0 : 1.0
        let estimatedSeconds = duration / (baseMultiplier * speedMultiplier)
        let mins = Int(estimatedSeconds / 60)

        if mins < 1 { return "~1 min" }
        return "~\(mins) min"
    }

    private func crfQualityLabel(_ crf: Int) -> String {
        switch crf {
        case ...20: return "Excellent"
        case 21...24: return "High"
        case 25...28: return "Good"
        case 29...32: return "Fair"
        default: return "Low"
        }
    }

    private func crfQualityColor(_ crf: Int) -> Color {
        switch crf {
        case ...20: return .ivSuccess.opacity(0.7)
        case 21...24: return .ivSuccess.opacity(0.6)
        case 25...28: return .ivAccent.opacity(0.7)
        case 29...32: return .ivWarning.opacity(0.7)
        default: return .ivError.opacity(0.7)
        }
    }
}
