import SwiftUI

// MARK: - Asset Inspector Panel
// Shows detailed information about a selected asset, including:
// - Metadata (type, date, resolution, subtypes)
// - iCloud status
// - Skip reasons with full explanations
// - Quick actions (queue, mark never, force re-upload)

struct AssetInspectorPanel: View {
    let asset: ScannedAsset
    let onQueueUpload: () -> Void
    let onMarkNever: () -> Void
    let onForceReupload: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xl) {
                // Header
                inspectorHeader

                Divider()

                // Metadata
                metadataSection

                // iCloud Status
                if asset.isICloudPlaceholder {
                    icloudSection
                }

                // Skip Reasons
                if !asset.skipReasons.isEmpty {
                    skipReasonsSection
                } else {
                    readySection
                }

                Divider()

                // Actions
                actionsSection
            }
            .padding(IVSpacing.lg)
        }
        .background(Color.ivBackground)
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.md) {
                RoundedRectangle(cornerRadius: IVCornerRadius.md)
                    .fill(Color.ivSurface)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: asset.assetType.icon)
                            .font(.system(size: 20, weight: .light))
                            .foregroundColor(.ivTextSecondary)
                    }

                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text(asset.metadata.originalFilename ?? "Unknown File")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.ivTextPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text(asset.assetType.label)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }
            }

            // Status
            if asset.isIncluded {
                IVStatusBadge("Ready for Upload", status: .success)
            } else {
                IVStatusBadge("Skipped (\(asset.skipReasons.count) reason\(asset.skipReasons.count == 1 ? "" : "s"))", status: .idle)
            }
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("METADATA")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "Date", value: asset.metadata.creationDate.map {
                Self.detailDateFormatter.string(from: $0)
            } ?? "Unknown")

            metadataRow(label: "Resolution", value: asset.metadata.resolutionString)

            if let sizeStr = asset.metadata.fileSizeString {
                metadataRow(label: "File Size", value: sizeStr)
            }

            if let dur = asset.metadata.durationString {
                metadataRow(label: "Duration", value: dur)
            }

            metadataRow(label: "GPS", value: asset.metadata.hasGPS ? "Yes" : "No")
            metadataRow(label: "Favorite", value: asset.metadata.isFavorite ? "Yes" : "No")
            metadataRow(label: "Hidden", value: asset.metadata.isHidden ? "Yes" : "No")

            if asset.metadata.hasEdits {
                metadataRow(label: "Edited", value: "Yes")
            }

            // Subtypes
            if !asset.metadata.subtypeLabels.isEmpty {
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Subtypes")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)

                    FlowLayout(spacing: IVSpacing.xxs) {
                        ForEach(asset.metadata.subtypeLabels, id: \.self) { label in
                            Text(label)
                                .font(IVFont.monoSmall)
                                .foregroundColor(.ivTextSecondary)
                                .padding(.horizontal, IVSpacing.sm)
                                .padding(.vertical, IVSpacing.xxxs)
                                .background {
                                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                        .fill(Color.ivAccent.opacity(0.08))
                                }
                        }
                    }
                }
            }

            // Local identifier (for debugging)
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Local ID")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextSecondary)
                Text(asset.localIdentifier)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(IVFont.caption)
                .foregroundColor(.ivTextPrimary)
            Spacer()
        }
    }

    // MARK: - iCloud Section

    private var icloudSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundColor(.ivInfo)
                    .font(.system(size: 14))
                Text("iCloud Placeholder")
                    .font(IVFont.subheadline)
                    .foregroundColor(.ivTextPrimary)
            }

            Text("This asset's original file is stored in iCloud and not currently downloaded to this Mac. You can download it from iCloud before uploading to Immich.")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            IVStatusBadge("Needs Download", status: .info)
        }
        .padding(IVSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivInfo.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivInfo.opacity(0.15), lineWidth: 0.5)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud placeholder. Asset needs to be downloaded from iCloud before upload.")
    }

    // MARK: - Skip Reasons Section

    private var skipReasonsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "info.circle")
                    .foregroundColor(.ivWarning)
                    .font(.system(size: 14))
                Text("WHY SKIPPED")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextTertiary)
                    .tracking(0.5)
            }

            ForEach(asset.skipReasons) { reason in
                SkipReasonCard(reason: reason)
            }
        }
    }

    // MARK: - Ready Section

    private var readySection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.ivSuccess)
                    .font(.system(size: 14))
                Text("READY")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextTertiary)
                    .tracking(0.5)
            }

            Text("This asset passed all configured filters and is ready to be queued for upload.")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(IVSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSuccess.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivSuccess.opacity(0.2), lineWidth: 0.5)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready for upload. Asset passed all filters.")
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            Text("ACTIONS")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            Button {
                onQueueUpload()
            } label: {
                Label("Queue for Upload", systemImage: "arrow.up.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                onMarkNever()
            } label: {
                Label("Mark Never Upload", systemImage: "hand.raised")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button(role: .destructive) {
                onForceReupload()
            } label: {
                Label("Force Re-Upload...", systemImage: "exclamationmark.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Helpers

    private static let detailDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        return df
    }()
}

// MARK: - Skip Reason Card

struct SkipReasonCard: View {
    let reason: SkipReason

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            // Header (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: IVSpacing.sm) {
                    Image(systemName: reason.icon)
                        .font(.system(size: 12))
                        .foregroundColor(.ivWarning)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                        Text(reason.title)
                            .font(IVFont.bodyMedium)
                            .foregroundColor(.ivTextPrimary)
                        Text("Filter: \(reason.filterName)")
                            .font(IVFont.monoSmall)
                            .foregroundColor(.ivTextTertiary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.ivTextTertiary)
                }
            }
            .buttonStyle(.plain)

            // Expanded explanation
            if isExpanded {
                Text(reason.explanation)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, IVSpacing.xl + IVSpacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(IVSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Skip reason: \(reason.title). Filter: \(reason.filterName)")
        .accessibilityHint("Tap to expand explanation")
    }
}

// MARK: - Flow Layout (for subtype tags)

struct FlowLayout: Layout {
    var spacing: CGFloat = IVSpacing.xxs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = y + rowHeight
        }

        return (positions, CGSize(width: maxWidth, height: totalHeight))
    }
}
