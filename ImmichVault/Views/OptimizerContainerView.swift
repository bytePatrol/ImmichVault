import SwiftUI

// MARK: - Optimizer Container View
// Owns both ViewModels and provides a unified toolbar with segmented picker.
// Uses ZStack with opacity toggling so both sub-views stay alive across tab switches.

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
        ZStack {
            OptimizerView(viewModel: optimizerVM)
                .opacity(selectedTab == .autoOptimizer ? 1 : 0)
                .allowsHitTesting(selectedTab == .autoOptimizer)
            ManualEncodeView(viewModel: manualEncodeVM)
                .opacity(selectedTab == .manualEncode ? 1 : 0)
                .allowsHitTesting(selectedTab == .manualEncode)
        }
        .modifier(
            OptimizerInspectorModifier(
                isPresented: inspectorPresented,
                candidate: optimizerVM.selectedCandidate,
                preset: optimizerVM.effectivePreset,
                provider: optimizerVM.selectedProvider,
                ruleMatches: optimizerVM.ruleMatches,
                estimatedCost: { candidate in
                    candidateEstimatedCost(candidate)
                },
                onTranscodeNow: { candidateId in
                    optimizerVM.transcodeNow(candidateId)
                }
            )
        )
        .toolbar {
            // Guard all items so they only appear on the Optimizer tab
            if appState.selectedNavItem == .optimizer {
                // Center: segmented picker
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $selectedTab) {
                        ForEach(OptimizerTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .labelsHidden()
                }

                // Primary: Queue Selected on the right (trailing)
                ToolbarItemGroup(placement: .primaryAction) {
                    if selectedTab == .autoOptimizer {
                        if optimizerVM.isProcessing {
                            Button {
                                optimizerVM.stopTranscoding()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                            .tint(.ivError)
                        } else if !optimizerVM.candidates.isEmpty && optimizerVM.selectedCandidateCount > 0 {
                            Button {
                                optimizerVM.startTranscoding()
                            } label: {
                                Text("Queue Selected (\(optimizerVM.selectedCandidateCount))")
                                    .fontWeight(.medium)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(KeyEquivalent.return, modifiers: [.command])
                        }

                        Button {
                            Task { await optimizerVM.scanForCandidates() }
                        } label: {
                            HStack(spacing: IVSpacing.xxs) {
                                Image(systemName: "arrow.clockwise")
                                Text(optimizerVM.isDiscovering ? "Scanning..." : "Scan Immich")
                            }
                            .font(IVFont.bodyMedium)
                        }
                        .buttonStyle(.borderless)
                        .disabled(optimizerVM.isDiscovering || optimizerVM.isProcessing)
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Scan Immich for candidates")
                    }
                }

                // Secondary: Rules + Inspector + Scan on the left
                ToolbarItem(placement: .secondaryAction) {
                    if selectedTab == .autoOptimizer {
                        HStack(spacing: IVSpacing.xs) {
                            Button {
                                optimizerVM.showRulesEditor = true
                            } label: {
                                HStack(spacing: IVSpacing.xxs) {
                                    Image(systemName: "list.bullet.rectangle")
                                    Text("Rules")
                                }
                                .font(IVFont.bodyMedium)
                            }
                            .buttonStyle(.borderless)
                            .help("Edit Transcode Rules")

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    optimizerVM.showInspector.toggle()
                                }
                            } label: {
                                HStack(spacing: IVSpacing.xxs) {
                                    Image(systemName: "sidebar.trailing")
                                    Text("Inspector")
                                }
                                .font(IVFont.bodyMedium)
                                .foregroundColor(optimizerVM.showInspector ? .ivAccent : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Toggle Inspector")
                            .keyboardShortcut("i", modifiers: .command)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $optimizerVM.showRulesEditor) {
            RulesEditorView()
        }
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
