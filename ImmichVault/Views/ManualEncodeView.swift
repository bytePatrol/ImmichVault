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
                        Text("H.265").tag(VideoCodec.h265)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }

                GridRow {
                    Text("Resolution")
                    Picker("Resolution", selection: $viewModel.selectedResolution) {
                        ForEach(TargetResolution.allCases) { res in
                            Text(res.label).tag(res)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(IVFont.caption)
                }

                GridRow {
                    Text("CRF")
                    HStack(spacing: IVSpacing.xxs) {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.selectedCRF) },
                                set: { viewModel.selectedCRF = Int($0) }
                            ),
                            in: 18...35,
                            step: 1
                        )
                        .frame(minWidth: 100, maxWidth: 160)

                        Text("\(viewModel.selectedCRF)")
                            .font(IVFont.mono)
                            .foregroundColor(.ivTextPrimary)
                            .frame(width: 20, alignment: .trailing)
                            .monospacedDigit()

                        Text(crfQualityLabel(viewModel.selectedCRF))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(crfQualityColor(viewModel.selectedCRF))
                            .textCase(.uppercase)
                            .frame(width: 52, alignment: .leading)
                    }
                }

                GridRow {
                    Text("Speed")
                    Picker("Speed", selection: $viewModel.selectedSpeed) {
                        ForEach(EncodeSpeed.allCases) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(IVFont.caption)
                }

                GridRow {
                    Text("Provider")
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
            .font(IVFont.captionMedium)
            .foregroundColor(.ivTextSecondary)
            .controlSize(.small)

            // Speed hint
            Text(viewModel.selectedSpeed.hint)
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
                .padding(.top, IVSpacing.xxxs)

            // Estimated output
            if let estimated = viewModel.estimatedOutputSize, let asset = viewModel.validatedAsset,
               let originalSize = asset.fileSize, originalSize > 0 {
                Divider().opacity(0.3).padding(.vertical, IVSpacing.xxs)

                HStack(spacing: IVSpacing.lg) {
                    VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                        Text("ESTIMATED OUTPUT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.ivTextTertiary)
                            .tracking(1.0)
                        Text(ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file))
                            .font(IVFont.headline)
                            .foregroundColor(.ivTextPrimary)
                    }

                    if let savings = viewModel.estimatedSavingsPercent {
                        VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                            Text("SAVINGS")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.ivTextTertiary)
                                .tracking(1.0)
                            Text(String(format: "%.0f%%", savings))
                                .font(IVFont.headline)
                                .foregroundColor(savings > 0 ? .ivSuccess : .ivWarning)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: IVSpacing.xxxs) {
                        Text("ORIGINAL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.ivTextTertiary)
                            .tracking(1.0)
                        Text(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file))
                            .font(IVFont.body)
                            .foregroundColor(.ivTextSecondary)
                    }
                }
                .padding(IVSpacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                        .fill(Color.ivSuccess.opacity(0.05))
                }
                .animation(.easeInOut(duration: 0.15), value: estimated)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
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
                        Label(
                            viewModel.isCreatingJob ? "Creating Job..." : "Start Encode",
                            systemImage: "wand.and.stars"
                        )
                        .font(IVFont.bodyMedium)
                    }
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
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
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
