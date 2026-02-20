import SwiftUI

// MARK: - Optimizer Container View
// Wraps Auto Optimizer and Manual Encode in a segmented sub-tab picker.

struct OptimizerContainerView: View {
    enum OptimizerTab: String, CaseIterable {
        case autoOptimizer = "Auto Optimizer"
        case manualEncode = "Manual Encode"
    }

    @State private var selectedTab: OptimizerTab = .autoOptimizer

    var body: some View {
        VStack(spacing: 0) {
            // Segmented picker
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(OptimizerTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .labelsHidden()
            }
            .padding(.horizontal, IVSpacing.lg)
            .padding(.top, IVSpacing.md)
            .padding(.bottom, IVSpacing.xs)

            Divider()

            // Content
            switch selectedTab {
            case .autoOptimizer:
                OptimizerView()
            case .manualEncode:
                ManualEncodeView()
            }
        }
    }
}
