import SwiftUI

// MARK: - Optimizer Container View
// Owns both ViewModels and provides a unified in-content toolbar.
// Uses ZStack with opacity toggling so both sub-views stay alive across tab switches.
// Figma: custom toolbar bar (not native macOS toolbar) with Rules, List/Grid, Inspector
// on left; Auto/Manual toggle, Queue Selected, Scan Immich on right.

struct OptimizerContainerView: View {
    enum OptimizerTab: String, CaseIterable {
        case autoOptimizer = "Auto Optimizer"
        case manualEncode = "Manual Encode"
    }

    @EnvironmentObject var appState: AppState
    @State private var selectedTab: OptimizerTab = .autoOptimizer
    @StateObject private var optimizerVM = OptimizerViewModel()
    @StateObject private var manualEncodeVM = ManualEncodeViewModel()

    /// Inspector visibility computed binding: combines tab state with VM toggle.
    /// Switching to Manual Encode hides inspector without losing showInspector state.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { selectedTab == .autoOptimizer && optimizerVM.showInspector },
            set: { optimizerVM.showInspector = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom in-content toolbar (Figma: not in native titlebar)
            optimizerToolbar
            Divider()

            ZStack {
                OptimizerView(viewModel: optimizerVM)
                    .opacity(selectedTab == .autoOptimizer ? 1 : 0)
                    .allowsHitTesting(selectedTab == .autoOptimizer)
                ManualEncodeView(viewModel: manualEncodeVM)
                    .opacity(selectedTab == .manualEncode ? 1 : 0)
                    .allowsHitTesting(selectedTab == .manualEncode)
            }
        }
        .modifier(
            OptimizerInspectorModifier(
                isPresented: inspectorPresented,
                candidate: optimizerVM.selectedCandidate,
                preset: optimizerVM.effectivePreset,
                provider: optimizerVM.selectedProvider,
                ruleMatches: optimizerVM.ruleMatches,
                serverURL: optimizerVM.cachedServerURL,
                apiKey: optimizerVM.cachedAPIKey,
                estimatedCost: { candidate in
                    candidateEstimatedCost(candidate)
                },
                onTranscodeNow: { candidateId in
                    optimizerVM.transcodeNow(candidateId)
                }
            )
        )
        .sheet(isPresented: $optimizerVM.showRulesEditor) {
            RulesEditorView()
        }
    }

    // MARK: - Custom Toolbar (Figma: in-content bar)

    private var optimizerToolbar: some View {
        HStack(spacing: IVSpacing.md) {
            // Left group: Rules, divider, List/Grid, Inspector
            HStack(spacing: IVSpacing.xs) {
                if selectedTab == .autoOptimizer {
                    // Rules button
                    Button {
                        optimizerVM.showRulesEditor = true
                    } label: {
                        HStack(spacing: IVSpacing.xxs) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12))
                            Text("Rules")
                                .font(IVFont.captionMedium)
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
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.ivTextPrimary)
                    .help("Edit Transcode Rules")

                    // Divider
                    Rectangle()
                        .fill(Color.ivBorder)
                        .frame(width: 1, height: 16)

                    // List/Grid toggle group
                    HStack(spacing: 0) {
                        viewModeButton(icon: "list.bullet", mode: .list)
                        viewModeButton(icon: "square.grid.2x2", mode: .grid)
                    }
                    .background {
                        RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                            .fill(Color.ivSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                    .stroke(Color.ivBorder, lineWidth: 0.5)
                            )
                    }

                    // Inspector toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            optimizerVM.showInspector.toggle()
                        }
                    } label: {
                        HStack(spacing: IVSpacing.xxs) {
                            Image(systemName: "sidebar.trailing")
                                .font(.system(size: 12))
                            Text("Inspector")
                                .font(IVFont.captionMedium)
                        }
                        .padding(.horizontal, IVSpacing.sm)
                        .padding(.vertical, IVSpacing.xs)
                        .background {
                            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                .fill(optimizerVM.showInspector ? Color.ivAccent.opacity(0.12) : Color.ivSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                        .stroke(optimizerVM.showInspector ? Color.ivAccent.opacity(0.2) : Color.ivBorder, lineWidth: 0.5)
                                )
                        }
                        .foregroundColor(optimizerVM.showInspector ? .ivAccent : .ivTextPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Inspector")
                    .keyboardShortcut("i", modifiers: .command)
                }
            }

            Spacer()

            // Right group: Auto/Manual toggle, Queue Selected, Scan Immich
            HStack(spacing: IVSpacing.sm) {
                // Segmented tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(OptimizerTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .labelsHidden()

                if selectedTab == .autoOptimizer {
                    // Queue Selected / Stop button
                    if optimizerVM.isProcessing {
                        Button {
                            optimizerVM.stopTranscoding()
                        } label: {
                            HStack(spacing: IVSpacing.xxs) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 12))
                                Text("Stop")
                                    .font(IVFont.captionMedium)
                            }
                            .padding(.horizontal, IVSpacing.sm)
                            .padding(.vertical, IVSpacing.xs)
                            .background {
                                RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                    .fill(Color.ivError.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                            .stroke(Color.ivError.opacity(0.2), lineWidth: 0.5)
                                    )
                            }
                            .foregroundColor(.ivError)
                        }
                        .buttonStyle(.plain)
                    } else if !optimizerVM.candidates.isEmpty && optimizerVM.selectedCandidateCount > 0 {
                        Button {
                            optimizerVM.startTranscoding()
                        } label: {
                            HStack(spacing: IVSpacing.xxs) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                                Text("Queue Selected (\(optimizerVM.selectedCandidateCount))")
                                    .font(IVFont.captionMedium)
                            }
                            .padding(.horizontal, IVSpacing.md)
                            .padding(.vertical, IVSpacing.xs)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(KeyEquivalent.return, modifiers: [.command])
                    }

                    // Scan Immich button
                    Button {
                        Task { await optimizerVM.scanForCandidates() }
                    } label: {
                        HStack(spacing: IVSpacing.xxs) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                            Text(optimizerVM.isDiscovering ? "Scanning..." : "Scan Immich")
                                .font(IVFont.captionMedium)
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
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.ivTextPrimary)
                    .disabled(optimizerVM.isDiscovering || optimizerVM.isProcessing)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Scan Immich for candidates")
                }
            }
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background(Color.ivBackground)
    }

    // MARK: - View Mode Toggle Button

    private func viewModeButton(icon: String, mode: OptimizerViewModel.ViewMode) -> some View {
        let isActive = optimizerVM.viewMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                optimizerVM.viewMode = mode
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .padding(.horizontal, IVSpacing.sm)
                .padding(.vertical, IVSpacing.xs)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: IVCornerRadius.sm - 1)
                            .fill(Color.ivAccent.opacity(0.12))
                    }
                }
                .foregroundColor(isActive ? .ivAccent : .ivTextSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func candidateEstimatedCost(_ candidate: TranscodeCandidate) -> Double? {
        guard optimizerVM.selectedProvider != .local else { return nil }
        return CostLedger.shared.estimatedCostForCandidates(
            [candidate],
            providerType: optimizerVM.selectedProvider,
            preset: optimizerVM.effectivePreset
        )
    }
}

// MARK: - Inspector Modifier
// macOS 14+: native .inspector(); macOS 13: animated HStack fallback.

struct OptimizerInspectorModifier: ViewModifier {
    @Binding var isPresented: Bool
    let candidate: TranscodeCandidate?
    let preset: TranscodePreset
    let provider: TranscodeProviderType
    let ruleMatches: [String: TranscodeRule]
    let serverURL: String
    let apiKey: String
    let estimatedCost: (TranscodeCandidate) -> Double?
    let onTranscodeNow: (String) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .inspector(isPresented: $isPresented) {
                    inspectorContent
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        } else {
            HStack(spacing: 0) {
                content
                if isPresented {
                    Divider()
                    inspectorContent
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let candidate = candidate {
            CandidateInspectorPanel(
                candidate: candidate,
                preset: preset,
                provider: provider,
                estimatedCost: estimatedCost(candidate),
                matchedRule: ruleMatches[candidate.id],
                serverURL: serverURL,
                apiKey: apiKey,
                onTranscodeNow: {
                    onTranscodeNow(candidate.id)
                }
            )
        } else {
            VStack(spacing: IVSpacing.lg) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.ivTextTertiary)
                Text("Select a candidate to inspect")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.ivBackground)
        }
    }
}
