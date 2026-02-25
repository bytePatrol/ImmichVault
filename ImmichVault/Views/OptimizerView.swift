import SwiftUI

// MARK: - Optimizer View
// Video optimization screen: discover oversized videos in Immich, review candidates,
// and queue transcode + replace jobs. Title and action buttons live in the container toolbar.

struct OptimizerView: View {
    @ObservedObject var viewModel: OptimizerViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState

    // Uniform 11px mono font for all table data cells (matches mockup)
    private let cellMono = Font.system(size: 11, weight: .regular, design: .monospaced)
    // 12px font for config labels (matches mockup's 12px)
    private let configLabel = Font.system(size: 12, weight: .medium)

    var body: some View {
        VStack(spacing: 0) {
            configPanel
            Divider()
            headerBanners

            if viewModel.candidates.isEmpty && !viewModel.isDiscovering {
                emptyState
            } else if viewModel.isDiscovering {
                discoveryProgressView
            } else {
                // Sort bar (list view only)
                if viewModel.viewMode == .list && !viewModel.filteredCandidates.isEmpty {
                    sortBar
                    Divider()
                }
                candidateTable
            }

            // Bottom status bar
            if !viewModel.candidates.isEmpty || viewModel.isProcessing {
                statusBar
            }
        }
        .frame(minWidth: 560)
    }

    // MARK: - Config Panel (Figma: p-4 border-b, section headers + inline rows)

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: IVSpacing.lg) {
            // FILTERS: section header + horizontal row of controls
            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                Text("FILTERS")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.ivTextSecondary)
                    .tracking(0.5)

                HStack(spacing: IVSpacing.xl) {
                    // Min Size
                    HStack(spacing: IVSpacing.xs) {
                        Text("Min Size")
                            .font(configLabel)
                            .foregroundColor(.ivTextSecondary)
                        InlineStepper(value: $viewModel.sizeThresholdMB, range: 50...5000, step: 50, suffix: "MB")
                    }

                    // After date
                    HStack(spacing: IVSpacing.xs) {
                        Text("After")
                            .font(configLabel)
                            .foregroundColor(.ivTextSecondary)
                        FilterDateField(date: $viewModel.dateAfter, placeholder: "Any")
                    }

                    // Before date
                    HStack(spacing: IVSpacing.xs) {
                        Text("Before")
                            .font(configLabel)
                            .foregroundColor(.ivTextSecondary)
                        FilterDateField(date: $viewModel.dateBefore, placeholder: "Any")
                    }

                    Spacer()
                }
            }

            // ENCODING: section header + inline rows
            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                Text("ENCODING")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.ivTextSecondary)
                    .tracking(0.5)

                // Preset + Provider side-by-side
                HStack(spacing: IVSpacing.xl) {
                    // Preset
                    HStack(spacing: IVSpacing.xs) {
                        Text("Preset")
                            .font(configLabel)
                            .foregroundColor(.ivTextSecondary)
                            .frame(minWidth: 48, alignment: .leading)
                        Picker("Preset", selection: $viewModel.selectedPreset) {
                            ForEach(TranscodePreset.allPresets) { preset in
                                Text(preset.name).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Provider
                    HStack(spacing: IVSpacing.xs) {
                        Text("Provider")
                            .font(configLabel)
                            .foregroundColor(.ivTextSecondary)
                            .frame(minWidth: 54, alignment: .leading)
                        Circle()
                            .fill(providerHealthColor)
                            .frame(width: 6, height: 6)
                            .help(providerHealthTooltip)
                            .accessibilityLabel(providerHealthTooltip)
                        Picker("Provider", selection: $viewModel.selectedProvider) {
                            ForEach(TranscodeProviderType.allCases, id: \.self) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.system(size: 12))
                        Button {
                            Task { await viewModel.checkProviderHealth() }
                        } label: {
                            Text("Test")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.ivAccent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Custom preset controls (conditional, with left accent border)
                if viewModel.isCustomPreset {
                    VStack(alignment: .leading, spacing: IVSpacing.sm) {
                        HStack(spacing: IVSpacing.xs) {
                            Text("Codec")
                                .font(configLabel)
                                .foregroundColor(.ivTextSecondary)
                                .frame(minWidth: 60, alignment: .leading)
                            Picker("Codec", selection: $viewModel.customCodec) {
                                Text("H.264").tag(VideoCodec.h264)
                                Text("H.265").tag(VideoCodec.h265)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 140)
                        }

                        HStack(spacing: IVSpacing.xs) {
                            Text("Resolution")
                                .font(configLabel)
                                .foregroundColor(.ivTextSecondary)
                                .frame(minWidth: 60, alignment: .leading)
                            Picker("Resolution", selection: $viewModel.customResolution) {
                                ForEach(TargetResolution.allCases) { res in
                                    Text(res.label).tag(res)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.system(size: 12))
                            .frame(width: 200)
                        }

                        HStack(spacing: IVSpacing.xs) {
                            Text("CRF")
                                .font(configLabel)
                                .foregroundColor(.ivTextSecondary)
                                .frame(minWidth: 60, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(viewModel.customCRF) },
                                    set: { viewModel.customCRF = Int($0) }
                                ),
                                in: 18...35,
                                step: 1
                            )
                            .frame(maxWidth: 400)

                            Text("\(viewModel.customCRF)")
                                .font(IVFont.mono)
                                .foregroundColor(.ivTextPrimary)
                                .frame(width: 20, alignment: .trailing)
                                .monospacedDigit()

                            crfQualityBadge(viewModel.customCRF)
                        }
                    }
                    .padding(.leading, IVSpacing.lg)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.ivAccent.opacity(0.2))
                            .frame(width: 2)
                    }
                }
            }
        }
        .padding(IVSpacing.lg)
        .background(Color.ivBackground)
        .controlSize(.small)
    }

    // MARK: - Header: Banners

    @ViewBuilder
    private var headerBanners: some View {
        if viewModel.errorMessage != nil || (isCloudProvider && !TranscodeEngine.isProviderConfigured(viewModel.selectedProvider)) {
            VStack(spacing: IVSpacing.xs) {
                if let error = viewModel.errorMessage {
                    HStack(spacing: IVSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.ivError)
                        Text(error)
                            .font(IVFont.caption)
                            .foregroundColor(.ivError)
                        Spacer()
                        Button("Dismiss") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.errorMessage = nil
                            }
                        }
                        .font(IVFont.caption)
                        .buttonStyle(.borderless)
                    }
                    .padding(IVSpacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                            .fill(Color.ivError.opacity(0.08))
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if isCloudProvider && !TranscodeEngine.isProviderConfigured(viewModel.selectedProvider) {
                    HStack(spacing: IVSpacing.sm) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.ivWarning)
                        Text("\(viewModel.selectedProvider.label) requires an API key. Configure it in Settings \u{2192} Provider API Keys.")
                            .font(IVFont.caption)
                            .foregroundColor(.ivWarning)
                        Spacer()
                    }
                    .padding(IVSpacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                            .fill(Color.ivWarning.opacity(0.08))
                    }
                }
            }
            .padding(.horizontal, IVSpacing.lg)
            .padding(.top, IVSpacing.xs)
        }
    }

    // MARK: - Sort Bar (Figma: between config panel and table, list view only)

    private var sortBar: some View {
        HStack {
            Text("\(viewModel.filteredCandidates.count) candidates")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)

            Spacer()

            HStack(spacing: IVSpacing.xs) {
                Text("Sort by")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(OptimizerViewModel.CandidateSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 12))
                .frame(width: 160)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.xs)
        .background(Color.ivSurface)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        IVEmptyState(
            icon: "sparkles",
            title: "Ready to Optimize",
            message: "Scan your Immich library to find large videos that can be re-encoded to save space. Configure your size threshold and date range above, then scan to discover candidates.",
            actionTitle: "Scan Immich"
        ) {
            Task { await viewModel.scanForCandidates() }
        }
    }

    // MARK: - Discovery Progress

    private var discoveryProgressView: some View {
        VStack(spacing: IVSpacing.xl) {
            ProgressView()
                .scaleEffect(1.2)

            if let progress = viewModel.discoveryProgress {
                VStack(spacing: IVSpacing.sm) {
                    Text(progress.message)
                        .font(IVFont.bodyMedium)
                        .foregroundColor(.ivTextPrimary)

                    HStack(spacing: IVSpacing.lg) {
                        Label("Page \(progress.page)", systemImage: "doc.on.doc")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                        Label("\(progress.candidatesFound) candidates", systemImage: "film")
                            .font(IVFont.caption)
                            .foregroundColor(.ivSuccess)
                    }
                }
            } else {
                Text("Preparing scan...")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Candidate Table

    private var candidateTable: some View {
        Group {
            if viewModel.viewMode == .grid {
                candidateGrid
            } else {
                candidateList
            }
        }
    }

    private var candidateGrid: some View {
        CandidateGridView(
            candidates: viewModel.filteredCandidates,
            serverURL: viewModel.cachedServerURL,
            apiKey: viewModel.cachedAPIKey,
            selectedCandidateID: $viewModel.selectedCandidateID,
            selectedCandidateIDs: $viewModel.selectedCandidateIDs,
            onInspect: { id in
                viewModel.selectedCandidateID = id
                if !viewModel.showInspector {
                    viewModel.showInspector = true
                }
            },
            onOpenInImmich: { id in openInImmich(id) },
            onTranscodeNow: { id in viewModel.transcodeNow(id) },
            onToggleSelection: { id in viewModel.toggleCandidateSelection(id) }
        )
    }

    private var candidateList: some View {
        VStack(spacing: 0) {
            candidateTableHeader

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredCandidates) { candidate in
                        let isChecked = viewModel.selectedCandidateIDs.contains(candidate.id)
                        let isFocused = viewModel.selectedCandidateID == candidate.id

                        candidateRow(candidate)
                            .background(
                                (isChecked || isFocused)
                                    ? Color.ivAccent.opacity(0.08)
                                    : Color.clear
                            )
                            .onTapGesture(count: 2) {
                                openInImmich(candidate.id)
                            }
                            .onTapGesture {
                                viewModel.selectedCandidateID = candidate.id
                                if !viewModel.showInspector {
                                    viewModel.showInspector = true
                                }
                            }
                            .contextMenu {
                                candidateContextMenu(candidate)
                            }

                        // Full-width subtle divider between rows
                        Rectangle()
                            .fill(Color.white.opacity(0.04))
                            .frame(height: 0.5)
                    }
                }
            }
        }
    }

    private var allFilteredSelected: Bool {
        let ids = Set(viewModel.filteredCandidates.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: viewModel.selectedCandidateIDs)
    }

    private var candidateTableHeader: some View {
        HStack(spacing: IVSpacing.sm) {
            Button {
                if allFilteredSelected {
                    viewModel.deselectAll()
                } else {
                    viewModel.selectAll()
                }
            } label: {
                Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(allFilteredSelected ? .ivAccent : .ivTextTertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 32, alignment: .center)

            Text("Filename")
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text("Size")
                .frame(width: 72, alignment: .trailing)
            Text("Codec")
                .frame(width: 64, alignment: .center)
            Text("Resolution")
                .frame(width: 84, alignment: .trailing)
            Text("Duration")
                .frame(width: 64, alignment: .trailing)
            Text("Est. Output")
                .frame(width: 76, alignment: .trailing)
            Text("Savings")
                .frame(width: 56, alignment: .trailing)
            Text("Rule")
                .frame(width: 80, alignment: .leading)
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextSecondary)
        .padding(.horizontal, IVSpacing.sm)
        .padding(.vertical, IVSpacing.xs)
        .background(Color.ivSurface.opacity(0.5))
    }

    private func candidateRow(_ candidate: TranscodeCandidate) -> some View {
        let isSelected = viewModel.selectedCandidateIDs.contains(candidate.id)

        return HStack(spacing: IVSpacing.sm) {
            // Checkbox
            Button {
                viewModel.toggleCandidateSelection(candidate.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .ivAccent : .ivTextTertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 32, alignment: .center)

            // Filename + device subtitle
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.detail.originalFileName ?? "Unknown")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidateSubtitle(candidate))
                    .font(.system(size: 10))
                    .foregroundColor(.ivTextTertiary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            // Original size — 11px mono, secondary color
            Text(candidate.originalSizeFormatted)
                .font(cellMono)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 72, alignment: .trailing)

            // Codec badge
            codecBadge(candidate.detail.codec)
                .frame(width: 64, alignment: .center)

            // Resolution — 11px mono, secondary
            Text(candidate.resolution ?? "--")
                .font(cellMono)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 84, alignment: .trailing)

            // Duration — 11px mono, secondary
            Text(compactDuration(candidate.detail.duration))
                .font(cellMono)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 64, alignment: .trailing)

            // Estimated output — 11px mono, secondary
            Text("~\(candidate.estimatedOutputFormatted)")
                .font(cellMono)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 76, alignment: .trailing)

            // Savings % — mono, green
            Text(String(format: "-%.0f%%", candidate.savingsPercent))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.ivSuccess)
                .frame(width: 56, alignment: .trailing)

            // Matched rule — tag pill style
            ruleTag(viewModel.ruleMatches[candidate.id]?.name)
                .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, IVSpacing.sm)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.detail.originalFileName ?? "Unknown"), \(candidate.originalSizeFormatted), \(isSelected ? "selected" : "not selected")")
    }

    // MARK: - Rule Tag (pill with subtle background per mockup)

    @ViewBuilder
    private func ruleTag(_ name: String?) -> some View {
        if let name = name {
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.ivTextSecondary)
                .padding(.horizontal, IVSpacing.xs)
                .padding(.vertical, IVSpacing.xxxs)
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                }
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("\u{2014}")
                .font(.system(size: 10))
                .foregroundColor(.ivTextTertiary)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func candidateContextMenu(_ candidate: TranscodeCandidate) -> some View {
        Button {
            openInImmich(candidate.id)
        } label: {
            Label("Open in Immich", systemImage: "safari")
        }

        Button {
            viewModel.transcodeNow(candidate.id)
        } label: {
            Label("Queue Transcode Now", systemImage: "wand.and.stars")
        }

        Divider()

        if viewModel.selectedCandidateIDs.contains(candidate.id) {
            Button {
                viewModel.toggleCandidateSelection(candidate.id)
            } label: {
                Label("Deselect", systemImage: "square")
            }
        } else {
            Button {
                viewModel.toggleCandidateSelection(candidate.id)
            } label: {
                Label("Select", systemImage: "checkmark.square")
            }
        }

        Divider()

        Button {
            viewModel.selectedCandidateID = candidate.id
            viewModel.showInspector = true
        } label: {
            Label("Inspect", systemImage: "info.circle")
        }
    }

    // MARK: - Status Bar (Figma: left = counts, right = savings)

    private var statusBar: some View {
        VStack(spacing: 0) {
            // Processing progress bar
            if viewModel.isProcessing, let progress = viewModel.processingProgress {
                HStack(spacing: IVSpacing.sm) {
                    ProgressView()
                        .scaleEffect(0.6)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                    Text(progress.description)
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivAccent)
                    Spacer()
                }
                .padding(.horizontal, IVSpacing.lg)
                .padding(.vertical, IVSpacing.xs)
                .background(Color.ivAccent.opacity(0.06))
            }

            Divider()

            // Main status bar
            HStack {
                // Left: counts separated by middle dots
                HStack(spacing: IVSpacing.sm) {
                    Text("\(viewModel.candidates.count) candidates")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    Text("\u{00B7}")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)

                    Text("\(viewModel.selectedCandidateCount) selected")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    if !viewModel.rules.isEmpty {
                        Text("\u{00B7}")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextTertiary)
                        Text("\(viewModel.matchedCandidateCount) rules matched")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                    }

                    if viewModel.isProcessing {
                        Text("\u{00B7}")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextTertiary)
                        Text("Processing")
                            .font(IVFont.caption)
                            .foregroundColor(.ivAccent)
                    }
                }

                Spacer()

                // Right: savings + cost
                HStack(spacing: IVSpacing.sm) {
                    if viewModel.selectedCandidateCount > 0 {
                        Text("Est. savings: \(formattedBytes(viewModel.totalEstimatedSavings))")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivSuccess)
                    }

                    if isCloudProvider && viewModel.estimatedTotalCost > 0 {
                        Text("Est. cost: \(CostLedger.formatCost(viewModel.estimatedTotalCost))")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivWarning)
                    }
                }
            }
            .padding(.horizontal, IVSpacing.lg)
            .padding(.vertical, IVSpacing.xs)
            .background(Color.ivSurface)
        }
    }

    // MARK: - Helpers

    private func openInImmich(_ assetId: String) {
        let serverURL = settings.immichServerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/photos/\(assetId)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var providerHealthColor: Color {
        switch viewModel.providerHealthy {
        case .some(true): return .ivSuccess
        case .some(false): return .ivError
        case .none: return .gray
        }
    }

    private var providerHealthTooltip: String {
        switch viewModel.providerHealthy {
        case .some(true): return "\(viewModel.selectedProvider.label) is healthy"
        case .some(false): return "\(viewModel.selectedProvider.label) is unavailable"
        case .none: return "Health not checked — click Test"
        }
    }

    private var isCloudProvider: Bool {
        viewModel.selectedProvider != .local
    }

    // MARK: - Codec Badge

    private func codecBadge(_ codec: String?) -> some View {
        let label = codec?.uppercased() ?? "--"
        let isHEVC = label.contains("HEVC") || label.contains("H265") || label.contains("H.265")
        let badgeColor: Color = isHEVC ? .purple : .orange

        return Text(isHEVC ? "HEVC" : (label.contains("H264") || label.contains("AVC") ? "H.264" : label))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(badgeColor)
            .padding(.horizontal, IVSpacing.xs)
            .padding(.vertical, IVSpacing.xxxs)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(badgeColor.opacity(0.12))
            }
    }

    // MARK: - Table Row Helpers

    private func candidateSubtitle(_ candidate: TranscodeCandidate) -> String {
        if let make = candidate.detail.make, let model = candidate.detail.model {
            return "\(make) \(model)"
        }
        if let make = candidate.detail.make {
            return make
        }
        let codec = candidate.detail.codec?.uppercased() ?? "Video"
        let res = candidate.resolution ?? ""
        return res.isEmpty ? codec : "\(codec) \(res)"
    }

    private func compactDuration(_ seconds: Double?) -> String {
        guard let d = seconds, d > 0 else { return "0:00" }
        let totalSeconds = Int(d)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - CRF Quality Helpers (Figma: colored pill badge)

    private func crfQualityBadge(_ crf: Int) -> some View {
        let (label, color) = crfQualityInfo(crf)
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .textCase(.uppercase)
            .padding(.horizontal, IVSpacing.xs)
            .padding(.vertical, IVSpacing.xxxs)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.12))
            }
    }

    private func crfQualityInfo(_ crf: Int) -> (String, Color) {
        switch crf {
        case ...21: return ("BEST", .ivSuccess)
        case 22...24: return ("HIGH", .ivInfo)
        case 25...28: return ("GOOD", .ivWarning)
        case 29...31: return ("LOW", .ivTextSecondary)
        default: return ("MIN", .ivError)
        }
    }
}

// MARK: - Candidate Inspector Panel

struct CandidateInspectorPanel: View {
    let candidate: TranscodeCandidate
    let preset: TranscodePreset
    let provider: TranscodeProviderType
    let estimatedCost: Double?
    let matchedRule: TranscodeRule?
    let serverURL: String
    let apiKey: String
    let onTranscodeNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Video preview player
                if !serverURL.isEmpty && !apiKey.isEmpty {
                    VideoPreviewPlayer(
                        assetId: candidate.id,
                        duration: candidate.detail.duration,
                        serverURL: serverURL,
                        apiKey: apiKey,
                        thumbhash: candidate.detail.thumbhash
                    )
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: IVCornerRadius.lg))
                    .padding(.horizontal, IVSpacing.lg)
                    .padding(.top, IVSpacing.lg)
                    .padding(.bottom, IVSpacing.md)
                }

                inspectorHeader
                    .padding(IVSpacing.lg)

                dividerLine

                videoMetadataSection
                    .padding(IVSpacing.lg)

                dividerLine

                transcodeSettingsSection
                    .padding(IVSpacing.lg)

                actionsSection
                    .padding(.horizontal, IVSpacing.lg)
                    .padding(.bottom, IVSpacing.lg)
            }
        }
        .background(Color.ivBackground)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.ivBorder.opacity(0.3))
            .frame(height: 0.5)
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        HStack(spacing: IVSpacing.md) {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.ivTextSecondary)
                }

            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(candidate.detail.originalFileName ?? "Unknown Video")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.id)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Video Metadata

    private var videoMetadataSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            inspectorSectionTitle("ORIGINAL VIDEO")

            Grid(alignment: .leading, horizontalSpacing: IVSpacing.sm, verticalSpacing: IVSpacing.xxs) {
                inspectorGridRow("File Size", candidate.originalSizeFormatted, mono: true)
                inspectorGridRow("Codec", formatCodecDisplay(candidate.detail.codec))
                inspectorGridRow("Resolution", candidate.resolution ?? "Unknown", mono: true)

                if let fps = candidate.detail.fps, fps > 0 {
                    inspectorGridRow("Frame Rate", "\(Int(fps)) fps", mono: true)
                }

                if let bitrate = candidate.detail.bitrate {
                    inspectorGridRow("Bitrate", String(format: "%.1f Mbps", Double(bitrate) / 1_000_000), mono: true)
                }

                inspectorGridRow("Duration", formatCompactDuration(candidate.detail.duration), mono: true)

                if let dateStr = candidate.detail.dateTimeOriginal {
                    inspectorGridRow("Date", formatInspectorDate(dateStr))
                }

                if let make = candidate.detail.make {
                    inspectorGridRow("Camera", make + (candidate.detail.model.map { " \($0)" } ?? ""))
                }

                let hasGPS = candidate.detail.latitude != nil && candidate.detail.longitude != nil
                if hasGPS, let lat = candidate.detail.latitude, let lon = candidate.detail.longitude {
                    inspectorGridRow("GPS", String(format: "%.4f, %.4f", lat, lon), mono: true)
                } else {
                    inspectorGridRow("GPS", hasGPS ? "Yes" : "No")
                }
            }
        }
    }

    // MARK: - Transcode Settings + Estimated

    private var transcodeSettingsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            inspectorSectionTitle("TRANSCODE SETTINGS")

            Grid(alignment: .leading, horizontalSpacing: IVSpacing.sm, verticalSpacing: IVSpacing.xxs) {
                inspectorGridRow("Preset", preset.name)
                inspectorGridRow("Codec", "\(preset.videoCodec.label)")
                inspectorGridRow("CRF", "\(preset.crf)", mono: true)
                inspectorGridRow("Speed", preset.encodeSpeed.label)
                inspectorGridRow("Provider", provider.label)
            }

            estimatedBox
        }
    }

    private var estimatedBox: some View {
        VStack(spacing: IVSpacing.xxs) {
            HStack {
                Text("Estimated output")
                    .font(.system(size: 12))
                    .foregroundColor(.ivTextSecondary)
                Spacer()
                Text("~\(candidate.estimatedOutputFormatted)")
                    .font(IVFont.mono)
                    .fontWeight(.semibold)
                    .foregroundColor(.ivSuccess)
            }
            HStack {
                Text("Space saved")
                    .font(.system(size: 12))
                    .foregroundColor(.ivTextSecondary)
                Spacer()
                Text("~\(candidate.estimatedSavingsFormatted) (\(String(format: "%.0f%%", candidate.savingsPercent)))")
                    .font(IVFont.mono)
                    .fontWeight(.semibold)
                    .foregroundColor(.ivSuccess)
            }

            if let cost = estimatedCost, cost > 0 {
                HStack {
                    Text("Estimated cost")
                        .font(.system(size: 12))
                        .foregroundColor(.ivTextSecondary)
                    Spacer()
                    Text(CostLedger.formatCost(cost))
                        .font(IVFont.mono)
                        .fontWeight(.semibold)
                        .foregroundColor(.ivWarning)
                }
            }
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                .fill(Color.ivSuccess.opacity(0.06))
        }
        .padding(.top, IVSpacing.sm)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Button {
            onTranscodeNow()
        } label: {
            Text("Queue Transcode Now")
                .font(IVFont.bodyMedium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Helpers

    private func inspectorSectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.ivTextTertiary)
            .tracking(0.5)
    }

    private func inspectorGridRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(mono ? IVFont.monoSmall : IVFont.caption)
                .foregroundColor(.ivTextPrimary)
        }
    }

    private func formatCompactDuration(_ seconds: Double?) -> String {
        guard let d = seconds, d > 0 else { return "0:00" }
        let totalSeconds = Int(d)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func formatInspectorDate(_ isoDate: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: isoDate) {
            let df = DateFormatter()
            df.dateFormat = "MMM d, yyyy h:mm a"
            return df.string(from: date)
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: isoDate) {
            let df = DateFormatter()
            df.dateFormat = "MMM d, yyyy h:mm a"
            return df.string(from: date)
        }
        return isoDate
    }

    private func formatCodecDisplay(_ codec: String?) -> String {
        guard let codec = codec else { return "Unknown" }
        let upper = codec.uppercased()
        if upper.contains("HEVC") || upper.contains("H265") || upper.contains("H.265") {
            return "HEVC"
        }
        if upper.contains("H264") || upper.contains("H.264") || upper.contains("AVC") {
            return "H.264"
        }
        return codec
    }
}

// MARK: - Inline Stepper (custom −/+ buttons matching mockup)

struct InlineStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if value - step >= range.lowerBound { value -= step }
            } label: {
                Text("\u{2212}")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.ivTextSecondary)

            Text("\(value) \(suffix)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.ivTextPrimary)
                .frame(minWidth: 64)
                .frame(height: 26)

            Button {
                if value + step <= range.upperBound { value += step }
            } label: {
                Text("+")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.ivTextSecondary)
        }
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                .stroke(Color.ivBorder, lineWidth: 0.5)
        }
    }
}

// MARK: - Filter Date Field

struct FilterDateField: View {
    @Binding var date: Date?
    let placeholder: String
    @State private var showPopover = false

    var body: some View {
        HStack {
            Group {
                if let d = date {
                    Text(formatDate(d))
                        .font(.system(size: 12))
                        .foregroundColor(.ivTextPrimary)
                } else {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundColor(.ivTextTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if date == nil { date = Date() }
                showPopover = true
            }

            if date != nil {
                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.ivTextTertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, IVSpacing.sm)
        .padding(.vertical, IVSpacing.xxs)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
        .popover(isPresented: $showPopover) {
            DatePicker(
                "",
                selection: Binding(
                    get: { date ?? Date() },
                    set: { date = $0 }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
