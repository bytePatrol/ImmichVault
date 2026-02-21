import SwiftUI

// MARK: - Optimizer View
// Video optimization screen: discover oversized videos in Immich, review candidates,
// and queue transcode + replace jobs. Title and action buttons live in the container toolbar.

struct OptimizerView: View {
    @ObservedObject var viewModel: OptimizerViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            configPanel
            headerBanners
            Divider()

            if !viewModel.candidates.isEmpty {
                headerSearchRow
                Divider()
            }

            if viewModel.candidates.isEmpty && !viewModel.isDiscovering {
                emptyState
            } else if viewModel.isDiscovering {
                discoveryProgressView
            } else {
                candidateTable
            }

            // Bottom status bar
            if !viewModel.candidates.isEmpty || viewModel.isProcessing {
                statusBar
            }
        }
        .frame(minWidth: 560)
    }

    // MARK: - Config Panel

    private var configPanel: some View {
        HStack(alignment: .top, spacing: IVSpacing.lg) {
            IVGroupedPanel("FILTERS") {
                filtersContent
            }
            IVGroupedPanel("ENCODING") {
                encodingContent
            }
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.lg)
    }

    // MARK: - Filters Content

    private var filtersContent: some View {
        Grid(alignment: .leading, horizontalSpacing: IVSpacing.sm, verticalSpacing: IVSpacing.sm) {
            GridRow {
                Text("Min Size")
                    .gridColumnAlignment(.trailing)
                Stepper(
                    "\(viewModel.sizeThresholdMB) MB",
                    value: $viewModel.sizeThresholdMB,
                    in: 50...5000,
                    step: 50
                )
                .font(IVFont.mono)
            }

            GridRow {
                Text("After")
                datePickerOrClear(
                    date: $viewModel.dateAfter,
                    placeholder: "Any"
                )
            }

            GridRow {
                Text("Before")
                datePickerOrClear(
                    date: $viewModel.dateBefore,
                    placeholder: "Any"
                )
            }
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextSecondary)
        .controlSize(.small)
    }

    // MARK: - Encoding Content

    private var encodingContent: some View {
        Grid(alignment: .leading, horizontalSpacing: IVSpacing.sm, verticalSpacing: IVSpacing.sm) {
            GridRow {
                Text("Preset")
                    .gridColumnAlignment(.trailing)
                Picker("Preset", selection: $viewModel.selectedPreset) {
                    ForEach(TranscodePreset.allPresets) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(IVFont.caption)
            }

            GridRow {
                Text("Provider")
                HStack(spacing: IVSpacing.xs) {
                    Picker("Provider", selection: $viewModel.selectedProvider) {
                        ForEach(TranscodeProviderType.allCases, id: \.self) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(IVFont.caption)

                    Circle()
                        .fill(providerHealthColor)
                        .frame(width: 6, height: 6)
                        .help(providerHealthTooltip)
                        .accessibilityLabel(providerHealthTooltip)

                    Button {
                        Task { await viewModel.checkProviderHealth() }
                    } label: {
                        Text("Test")
                            .font(IVFont.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.ivAccent)
                }
            }

            // Custom preset controls — rendered inside encoding when active
            if viewModel.isCustomPreset {
                GridRow {
                    Text("Codec")
                    Picker("Codec", selection: $viewModel.customCodec) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("H.265").tag(VideoCodec.h265)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                }

                GridRow {
                    Text("Resolution")
                    Picker("Resolution", selection: $viewModel.customResolution) {
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
                                get: { Double(viewModel.customCRF) },
                                set: { viewModel.customCRF = Int($0) }
                            ),
                            in: 18...35,
                            step: 1
                        )
                        .frame(minWidth: 80, maxWidth: 120)

                        Text("\(viewModel.customCRF)")
                            .font(IVFont.mono)
                            .foregroundColor(.ivTextPrimary)
                            .frame(width: 20, alignment: .trailing)
                            .monospacedDigit()

                        Text(crfQualityLabel(viewModel.customCRF))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(crfQualityColor(viewModel.customCRF))
                            .textCase(.uppercase)
                            .frame(width: 52, alignment: .leading)
                    }
                }
            }
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextSecondary)
        .controlSize(.small)
    }

    // MARK: - Header: Search & Sort Row

    private var headerSearchRow: some View {
        HStack(spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.ivTextTertiary)
                    .font(.system(size: 11))
                TextField("Search by filename or codec...", text: $viewModel.filterText)
                    .textFieldStyle(.plain)
                    .font(IVFont.body)
            }
            .padding(.horizontal, IVSpacing.sm)
            .padding(.vertical, IVSpacing.xs)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                    .fill(Color.ivSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                            .stroke(Color.ivBorder, lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: 260)

            Spacer()

            selectionControls

            Picker("Sort", selection: $viewModel.sortOrder) {
                ForEach(OptimizerViewModel.CandidateSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .font(IVFont.caption)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
    }

    /// Unified Select All / Deselect All (single definition).
    private var selectionControls: some View {
        HStack(spacing: IVSpacing.xs) {
            Button("Select All") {
                viewModel.selectAll()
            }
            .font(IVFont.caption)
            .buttonStyle(.borderless)

            Button("Deselect All") {
                viewModel.deselectAll()
            }
            .font(IVFont.caption)
            .buttonStyle(.borderless)
        }
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

    // MARK: - Date Picker Helper

    private func datePickerOrClear(date: Binding<Date?>, placeholder: String) -> some View {
        HStack(spacing: IVSpacing.xxs) {
            if let currentDate = date.wrappedValue {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { currentDate },
                        set: { date.wrappedValue = $0 }
                    ),
                    displayedComponents: [.date]
                )
                .labelsHidden()
                .frame(width: 100)

                Button {
                    date.wrappedValue = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.ivTextTertiary)
                }
                .buttonStyle(.borderless)
            } else {
                Button(placeholder) {
                    date.wrappedValue = Date()
                }
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        IVEmptyState(
            icon: "wand.and.stars",
            title: "Ready to Optimize",
            message: "Configure your size threshold and date range, then click \"Scan Immich\" to find oversized videos that can be transcoded to save space.",
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
        VStack(spacing: 0) {
            candidateTableHeader
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredCandidates) { candidate in
                        candidateRow(candidate)
                            .background(
                                viewModel.selectedCandidateID == candidate.id
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

                        Divider()
                            .padding(.leading, IVSpacing.lg)
                    }
                }
            }
        }
    }

    private var candidateTableHeader: some View {
        HStack(spacing: 0) {
            Image(systemName: "checkmark.square")
                .font(.system(size: 11))
                .foregroundColor(.ivTextTertiary)
                .frame(width: 36, alignment: .center)

            Text("Filename")
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text("Size")
                .frame(width: 80, alignment: .trailing)
            Text("Codec")
                .frame(width: 70, alignment: .center)
            Text("Resolution")
                .frame(width: 90, alignment: .trailing)
            Text("Duration")
                .frame(width: 70, alignment: .trailing)
            Text("Est. Output")
                .frame(width: 80, alignment: .trailing)
            Text("Savings")
                .frame(width: 60, alignment: .trailing)
            Text("Rule")
                .frame(width: 90, alignment: .leading)
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextTertiary)
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background(Color.ivSurface.opacity(0.5))
    }

    private func candidateRow(_ candidate: TranscodeCandidate) -> some View {
        let isSelected = viewModel.selectedCandidateIDs.contains(candidate.id)

        return HStack(spacing: 0) {
            // Checkbox
            Button {
                viewModel.toggleCandidateSelection(candidate.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .ivAccent : .ivTextTertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 36, alignment: .center)

            // Filename + device info
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(candidate.detail.originalFileName ?? "Unknown")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let make = candidate.detail.make, let model = candidate.detail.model {
                    Text("\(make) \(model)")
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextTertiary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            // Original size
            Text(candidate.originalSizeFormatted)
                .font(IVFont.mono)
                .foregroundColor(.ivTextPrimary)
                .frame(width: 80, alignment: .trailing)

            // Codec badge
            codecBadge(candidate.detail.codec)
                .frame(width: 70, alignment: .center)

            // Resolution
            Text(candidate.resolution ?? "--")
                .font(IVFont.monoSmall)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 90, alignment: .trailing)

            // Duration
            Text(candidate.durationFormatted)
                .font(IVFont.monoSmall)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 70, alignment: .trailing)

            // Estimated output
            Text(candidate.estimatedOutputFormatted)
                .font(IVFont.mono)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 80, alignment: .trailing)

            // Savings %
            Text(String(format: "-%.0f%%", candidate.savingsPercent))
                .font(IVFont.captionMedium)
                .foregroundColor(.ivSuccess)
                .frame(width: 60, alignment: .trailing)

            // Matched rule
            Text(viewModel.ruleMatches[candidate.id]?.name ?? "\u{2014}")
                .font(IVFont.caption)
                .foregroundColor(viewModel.ruleMatches[candidate.id] != nil ? .ivAccent : .ivTextTertiary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.detail.originalFileName ?? "Unknown"), \(candidate.originalSizeFormatted), \(isSelected ? "selected" : "not selected")")
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

    // MARK: - Status Bar

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

            // Main status bar — plain text with middle-dot separators
            HStack(spacing: IVSpacing.sm) {
                statusItems
                Spacer()
            }
            .padding(.horizontal, IVSpacing.lg)
            .padding(.vertical, IVSpacing.xs)
            .background(Color.ivBackground)
        }
    }

    @ViewBuilder
    private var statusItems: some View {
        let items = buildStatusItems()
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if index > 0 {
                Text("\u{00B7}")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }
            Text(item.text)
                .font(IVFont.caption)
                .foregroundColor(item.color)
        }
    }

    private struct StatusItem {
        let text: String
        let color: Color
    }

    private func buildStatusItems() -> [StatusItem] {
        var items: [StatusItem] = []

        items.append(StatusItem(
            text: "\(viewModel.candidates.count) candidates",
            color: .ivTextTertiary
        ))

        items.append(StatusItem(
            text: "\(viewModel.selectedCandidateCount) selected",
            color: .ivTextTertiary
        ))

        if !viewModel.rules.isEmpty {
            items.append(StatusItem(
                text: "\(viewModel.matchedCandidateCount) matched rules",
                color: .ivTextTertiary
            ))
        }

        if viewModel.selectedCandidateCount > 0 {
            items.append(StatusItem(
                text: "Est. savings: \(formattedBytes(viewModel.totalEstimatedSavings))",
                color: .ivSuccess
            ))
        }

        if isCloudProvider && viewModel.estimatedTotalCost > 0 {
            items.append(StatusItem(
                text: "Est. cost: \(CostLedger.formatCost(viewModel.estimatedTotalCost))",
                color: .ivWarning
            ))
        }

        if viewModel.isProcessing {
            items.append(StatusItem(
                text: "Processing",
                color: .ivAccent
            ))
        }

        // Only show filtered count when a filter is active
        if viewModel.filteredCandidates.count != viewModel.candidates.count {
            items.append(StatusItem(
                text: "Showing \(viewModel.filteredCandidates.count) of \(viewModel.candidates.count)",
                color: .ivTextTertiary
            ))
        }

        return items
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

        return Text(isHEVC ? "HEVC" : label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(badgeColor)
            .padding(.horizontal, IVSpacing.xs)
            .padding(.vertical, IVSpacing.xxxs)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(badgeColor.opacity(0.12))
            }
    }

    // MARK: - CRF Quality Helpers

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

// MARK: - Candidate Inspector Panel

struct CandidateInspectorPanel: View {
    let candidate: TranscodeCandidate
    let preset: TranscodePreset
    let provider: TranscodeProviderType
    let estimatedCost: Double?
    let matchedRule: TranscodeRule?
    let onTranscodeNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xl) {
                inspectorHeader
                Divider()
                videoMetadataSection
                if let rule = matchedRule {
                    matchedRuleSection(rule)
                }
                transcodeSettingsSection
                estimatedResultSection
                Divider()
                actionsSection
            }
            .padding(IVSpacing.lg)
        }
        .background(Color.ivBackground)
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.ivTextSecondary)

                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text(candidate.detail.originalFileName ?? "Unknown Video")
                        .font(IVFont.headline)
                        .foregroundColor(.ivTextPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text("Video")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }
            }

            IVStatusBadge("Candidate", status: .info)
        }
    }

    // MARK: - Video Metadata

    private var videoMetadataSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("ORIGINAL VIDEO")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "File Size", value: candidate.originalSizeFormatted)
            metadataRow(label: "Codec", value: candidate.detail.codec?.uppercased() ?? "Unknown")
            metadataRow(label: "Resolution", value: candidate.resolution ?? "Unknown")
            metadataRow(label: "Duration", value: candidate.durationFormatted)

            if let bitrate = candidate.detail.bitrate {
                metadataRow(label: "Bitrate", value: "\(bitrate / 1000) kbps")
            }

            let hasGPS = candidate.detail.latitude != nil && candidate.detail.longitude != nil
            metadataRow(label: "GPS", value: hasGPS ? "Yes" : "No")

            if let make = candidate.detail.make {
                metadataRow(label: "Camera", value: make + (candidate.detail.model.map { " \($0)" } ?? ""))
            }

            if let dateStr = candidate.detail.dateTimeOriginal {
                metadataRow(label: "Date", value: dateStr)
            }

            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Immich ID")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextSecondary)
                Text(candidate.id)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Matched Rule

    private func matchedRuleSection(_ rule: TranscodeRule) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("MATCHED RULE")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "Rule", value: rule.name)
            metadataRow(label: "Preset", value: rule.presetName)
            metadataRow(label: "Priority", value: "\(rule.priority)")

            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Conditions")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextSecondary)
                Text(rule.conditionsSummary)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.orange.opacity(0.04))
        }
    }

    // MARK: - Transcode Settings

    private var transcodeSettingsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("TRANSCODE SETTINGS")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "Preset", value: preset.name)
            metadataRow(label: "Video Codec", value: preset.videoCodec.label)
            metadataRow(label: "CRF", value: "\(preset.crf)")
            if let resolution = preset.resolution, resolution != .keepSame {
                metadataRow(label: "Resolution", value: resolution.label)
            }
            metadataRow(label: "Audio", value: "\(preset.audioCodec.label) \(preset.audioBitrate)")
            metadataRow(label: "Container", value: preset.container.uppercased())
            metadataRow(label: "Provider", value: provider.label)
        }
    }

    // MARK: - Estimated Result

    private var estimatedResultSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("ESTIMATED RESULT")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "Output Size", value: candidate.estimatedOutputFormatted)
            metadataRow(label: "Savings", value: String(format: "%.0f%%", candidate.savingsPercent))
            metadataRow(label: "Space Freed", value: candidate.estimatedSavingsFormatted)

            if let cost = estimatedCost, cost > 0 {
                metadataRow(label: "Est. Cost", value: CostLedger.formatCost(cost))
            }

            Text("Estimates are approximate and based on typical compression ratios for the selected preset.")
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSuccess.opacity(0.04))
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            Text("ACTIONS")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            Button {
                onTranscodeNow()
            } label: {
                Label("Queue Transcode Now", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    // MARK: - Helpers

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(IVFont.body)
                .foregroundColor(.ivTextPrimary)
            Spacer()
        }
    }
}
