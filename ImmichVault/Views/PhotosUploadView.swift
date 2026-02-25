import SwiftUI
import Photos

// MARK: - Photos Upload View
// Main screen for scanning the Photos library, applying filters, and managing uploads.
// Follows native macOS patterns: toolbar, table, inspector panel.

struct PhotosUploadView: View {
    @StateObject private var viewModel = PhotosViewModel()
    @EnvironmentObject var settings: AppSettings
    @State private var showInspector = false
    @State private var showForceReuploadConfirmation = false
    @State private var pendingForceReuploadID: String?
    @State private var columnWidths = ColumnWidths()

    var body: some View {
        Group {
            switch viewModel.authorizationStatus {
            case .authorized, .limited:
                authorizedContent
            case .notDetermined:
                authorizationRequestView
            case .denied, .restricted:
                authorizationDeniedView
            @unknown default:
                authorizationRequestView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Authorization Views

    private var authorizationRequestView: some View {
        IVEmptyState(
            icon: "photo.on.rectangle.angled",
            title: "Photos Access Required",
            message: "ImmichVault needs access to your Photos library to scan and upload media to Immich. Your photos never leave your Mac without your explicit action.",
            actionTitle: "Grant Access"
        ) {
            Task { await viewModel.requestPhotosAccess() }
        }
    }

    private var authorizationDeniedView: some View {
        IVEmptyState(
            icon: "lock.shield",
            title: "Photos Access Denied",
            message: "ImmichVault needs Photos access to function. Please open System Settings → Privacy & Security → Photos and enable access for ImmichVault.",
            actionTitle: "Open System Settings"
        ) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Authorized Content

    private var authorizedContent: some View {
        HSplitView {
            // Main content: toolbar + results
            VStack(spacing: 0) {
                scanToolbar
                Divider()

                if viewModel.scannedAssets.isEmpty && !viewModel.isScanning {
                    emptyState
                } else if viewModel.isScanning {
                    scanningProgressView
                } else {
                    assetTable
                }

                // Bottom status bar
                if let stats = viewModel.scanStats {
                    statusBar(stats: stats)
                }
            }
            .frame(minWidth: 500)

            // Inspector panel
            if showInspector, let asset = viewModel.selectedAsset {
                AssetInspectorPanel(
                    asset: asset,
                    onQueueUpload: { viewModel.queueForUpload(asset.localIdentifier) },
                    onMarkNever: { viewModel.markNeverReupload(asset.localIdentifier) },
                    onForceReupload: {
                        pendingForceReuploadID = asset.localIdentifier
                        showForceReuploadConfirmation = true
                    }
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }
        }
        .alert("Force Re-Upload", isPresented: $showForceReuploadConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingForceReuploadID = nil
            }
            Button("Force Re-Upload", role: .destructive) {
                if let id = pendingForceReuploadID {
                    viewModel.forceReupload(id)
                }
                pendingForceReuploadID = nil
            }
        } message: {
            Text("This overrides duplicate protection and may create duplicates in Immich. The action will be logged in the audit trail.")
        }
        .onAppear {
            viewModel.loadAlbums()
        }
    }

    // MARK: - Scan Toolbar

    private var scanToolbar: some View {
        VStack(spacing: IVSpacing.sm) {
            // Top row: title + actions
            HStack(spacing: IVSpacing.md) {
                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text("Photos Library")
                        .font(IVFont.displayMedium)
                        .foregroundColor(.ivTextPrimary)
                    if let stats = viewModel.scanStats {
                        Text("\(stats.totalInLibrary) assets in library")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextTertiary)
                    }
                }

                Spacer()

                // Upload controls
                if viewModel.isUploading {
                    // Stop upload button
                    Button {
                        viewModel.stopUploading()
                    } label: {
                        Label("Stop Upload", systemImage: "stop.circle")
                            .font(IVFont.bodyMedium)
                    }
                    .buttonStyle(.bordered)
                    .tint(.ivError)

                    // Upload progress indicator
                    if let progress = viewModel.uploadProgress {
                        HStack(spacing: IVSpacing.xs) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(progress.description)
                                .font(IVFont.captionMedium)
                                .foregroundColor(.ivTextSecondary)
                        }
                    }
                } else if let stats = viewModel.scanStats, stats.included > 0 {
                    // Queue & Upload button
                    Button {
                        viewModel.queueAllAndUpload()
                    } label: {
                        Label("Upload All (\(stats.included))", systemImage: "arrow.up.circle.fill")
                            .font(IVFont.bodyMedium)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    // Queue only (no auto-start)
                    Button {
                        viewModel.queueAllIncluded()
                    } label: {
                        Label("Queue Only", systemImage: "arrow.up.circle")
                            .font(IVFont.bodyMedium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                // Scan button
                Button {
                    Task { await viewModel.startScan() }
                } label: {
                    Label(viewModel.isScanning ? "Scanning..." : "Scan Library", systemImage: "magnifyingglass")
                        .font(IVFont.bodyMedium)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isUploading)
                .keyboardShortcut("r", modifiers: .command)

                // Inspector toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInspector.toggle()
                    }
                } label: {
                    Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.trailing")
                        .foregroundColor(showInspector ? .ivAccent : .ivTextSecondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle Inspector")
                .keyboardShortcut("i", modifiers: .command)
            }

            // Filter row
            HStack(spacing: IVSpacing.md) {
                // Search
                HStack(spacing: IVSpacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.ivTextTertiary)
                        .font(.system(size: 11))
                    TextField("Search by filename, type, or reason...", text: $viewModel.filterText)
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
                .frame(maxWidth: 280)

                // Status filter pills
                ForEach(PhotosViewModel.StatusFilterOption.allCases) { option in
                    filterPill(option)
                }

                Spacer()

                // Sort
                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(PhotosViewModel.SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .font(IVFont.caption)
            }

            // Error banner (scan errors)
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
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.md)
        .background(Color.ivBackground)
    }

    private func filterPill(_ option: PhotosViewModel.StatusFilterOption) -> some View {
        let isActive = viewModel.statusFilter == option
        let count: Int? = {
            guard viewModel.scanResult != nil else { return nil }
            switch option {
            case .all: return viewModel.scannedAssets.count
            case .included: return viewModel.scannedAssets.filter { $0.isIncluded }.count
            case .skipped: return viewModel.scannedAssets.filter { !$0.isIncluded }.count
            case .icloudPlaceholder: return viewModel.scannedAssets.filter { $0.isICloudPlaceholder }.count
            }
        }()

        return Button {
            viewModel.statusFilter = option
        } label: {
            HStack(spacing: IVSpacing.xxs) {
                Image(systemName: option.icon)
                    .font(.system(size: 10))
                Text(option.rawValue)
                    .font(IVFont.captionMedium)
                if let count {
                    Text("\(count)")
                        .font(IVFont.monoSmall)
                        .foregroundColor(isActive ? .ivAccent.opacity(0.7) : .ivTextTertiary)
                }
            }
            .padding(.horizontal, IVSpacing.sm)
            .padding(.vertical, IVSpacing.xxs)
            .background {
                Capsule()
                    .fill(isActive ? Color.ivAccent.opacity(0.12) : Color.ivSurface)
            }
            .foregroundColor(isActive ? .ivAccent : .ivTextSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        IVEmptyState(
            icon: "photo.on.rectangle.angled",
            title: "Ready to Scan",
            message: "Click \"Scan Library\" to enumerate your Photos library and apply your configured filters. Adjust filters in Settings before scanning.",
            actionTitle: "Scan Library"
        ) {
            Task { await viewModel.startScan() }
        }
    }

    // MARK: - Scanning Progress

    private var scanningProgressView: some View {
        VStack(spacing: IVSpacing.xl) {
            ProgressView()
                .scaleEffect(1.2)

            if let progress = viewModel.scanProgress {
                VStack(spacing: IVSpacing.sm) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)

                    Text("Scanning \(progress.current) of \(progress.total)...")
                        .font(IVFont.bodyMedium)
                        .foregroundColor(.ivTextPrimary)

                    HStack(spacing: IVSpacing.lg) {
                        Label("\(progress.included) included", systemImage: "checkmark.circle")
                            .font(IVFont.caption)
                            .foregroundColor(.ivSuccess)
                        Label("\(progress.skipped) skipped", systemImage: "minus.circle")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextTertiary)
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

    // MARK: - Asset Table

    private var assetTable: some View {
        VStack(spacing: 0) {
            // Table header
            tableHeader

            Divider()

            // Table content
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredAssets) { asset in
                        assetRow(asset)
                            .background(
                                viewModel.selectedAssetID == asset.localIdentifier
                                ? Color.ivAccent.opacity(0.12)
                                : Color.clear
                            )
                            .onTapGesture {
                                viewModel.selectedAssetID = asset.localIdentifier
                                if !showInspector {
                                    showInspector = true
                                }
                            }
                            .contextMenu {
                                assetContextMenu(asset)
                            }

                        Divider()
                            .padding(.leading, IVSpacing.lg)
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Type")
                .frame(width: 60, alignment: .leading)
            Text("Filename")
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text("Date")
                .frame(width: 100, alignment: .leading)
            Text("Resolution")
                .frame(width: 90, alignment: .trailing)
            Text("Size")
                .frame(width: 80, alignment: .trailing)
            Text("Status")
                .frame(width: 130, alignment: .center)
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextTertiary)
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background(Color.ivSurface.opacity(0.5))
    }

    private func assetRow(_ asset: ScannedAsset) -> some View {
        HStack(spacing: 0) {
            // Type icon
            HStack(spacing: IVSpacing.xs) {
                Image(systemName: asset.assetType.icon)
                    .font(.system(size: 13))
                    .foregroundColor(asset.isIncluded ? .ivAccent : .ivTextTertiary)
                    .frame(width: 18)

                if asset.isICloudPlaceholder {
                    Image(systemName: "icloud")
                        .font(.system(size: 9))
                        .foregroundColor(.ivInfo)
                }
            }
            .frame(width: 60, alignment: .leading)

            // Filename + subtypes
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(asset.metadata.originalFilename ?? "Unknown")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !asset.metadata.subtypeLabels.isEmpty {
                    HStack(spacing: IVSpacing.xxs) {
                        ForEach(asset.metadata.subtypeLabels, id: \.self) { label in
                            Text(label)
                                .font(IVFont.monoSmall)
                                .foregroundColor(.ivTextTertiary)
                                .padding(.horizontal, IVSpacing.xxs)
                                .padding(.vertical, 1)
                                .background {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.ivTextTertiary.opacity(0.08))
                                }
                        }
                    }
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            // Date
            Text(asset.metadata.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 100, alignment: .leading)

            // Resolution / Duration
            VStack(alignment: .trailing, spacing: 0) {
                Text(asset.metadata.resolutionString)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
                if let dur = asset.metadata.durationString {
                    Text(dur)
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextTertiary)
                }
            }
            .frame(width: 90, alignment: .trailing)

            // File size
            Text(asset.metadata.fileSizeString ?? "\u{2014}")
                .font(IVFont.monoSmall)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 80, alignment: .trailing)

            // Status badge — skip reasons take priority, then DB upload state
            Group {
                if !asset.skipReasons.isEmpty {
                    // Determine the most descriptive status from skip reasons
                    if asset.skipReasons.contains(where: { if case .alreadyUploaded = $0 { return true }; return false }) {
                        IVStatusBadge("Duplicate", status: .idle)
                    } else if asset.skipReasons.contains(where: { if case .neverReuploadFlagged = $0 { return true }; return false }) {
                        IVStatusBadge("Never Upload", status: .idle)
                    } else if asset.skipReasons.count == 1 {
                        IVStatusBadge("Excluded", status: .warning)
                    } else {
                        IVStatusBadge("Excluded (\(asset.skipReasons.count))", status: .warning)
                    }
                } else if let state = asset.uploadState, state != .idle {
                    IVStatusBadge(state.label, status: state.statusBadgeType)
                } else {
                    IVStatusBadge("Ready", status: .success)
                }
            }
            .frame(width: 130, alignment: .center)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(asset.assetType.label), \(asset.metadata.originalFilename ?? "Unknown"), \(asset.skipReasons.isEmpty ? (asset.uploadState?.label ?? "Ready") : "Excluded")")
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func assetContextMenu(_ asset: ScannedAsset) -> some View {
        if asset.isIncluded {
            Button {
                viewModel.uploadNow(asset.localIdentifier)
            } label: {
                Label("Upload Now", systemImage: "arrow.up.circle.fill")
            }
        }

        Button {
            viewModel.queueForUpload(asset.localIdentifier)
        } label: {
            Label("Queue for Upload", systemImage: "arrow.up.circle")
        }

        Divider()

        Button {
            viewModel.markNeverReupload(asset.localIdentifier)
        } label: {
            Label("Mark Never Upload", systemImage: "hand.raised")
        }

        Button {
            pendingForceReuploadID = asset.localIdentifier
            showForceReuploadConfirmation = true
        } label: {
            Label("Force Re-Upload...", systemImage: "exclamationmark.arrow.circlepath")
        }

        Divider()

        Button {
            viewModel.selectedAssetID = asset.localIdentifier
            showInspector = true
        } label: {
            Label("Inspect", systemImage: "info.circle")
        }
    }

    // MARK: - Status Bar

    private func statusBar(stats: PhotosViewModel.ScanStats) -> some View {
        VStack(spacing: 0) {
            // Upload progress bar
            if viewModel.isUploading, let progress = viewModel.uploadProgress {
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

            // Upload error banner
            if let uploadError = viewModel.uploadError {
                HStack(spacing: IVSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.ivWarning)
                    Text(uploadError)
                        .font(IVFont.caption)
                        .foregroundColor(.ivWarning)
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") { viewModel.uploadError = nil }
                        .font(IVFont.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, IVSpacing.lg)
                .padding(.vertical, IVSpacing.xs)
                .background(Color.ivWarning.opacity(0.06))
            }

            // Main status bar
            HStack(spacing: IVSpacing.lg) {
                HStack(spacing: IVSpacing.xs) {
                    Circle()
                        .fill(Color.ivSuccess)
                        .frame(width: 6, height: 6)
                    Text("\(stats.included) included")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }

                HStack(spacing: IVSpacing.xs) {
                    Circle()
                        .fill(Color.ivTextTertiary)
                        .frame(width: 6, height: 6)
                    Text("\(stats.skipped) skipped")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }

                if stats.icloudPlaceholders > 0 {
                    HStack(spacing: IVSpacing.xs) {
                        Image(systemName: "icloud")
                            .font(.system(size: 9))
                            .foregroundColor(.ivInfo)
                        Text("\(stats.icloudPlaceholders) in iCloud")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                    }
                }

                Spacer()

                if viewModel.isUploading {
                    HStack(spacing: IVSpacing.xs) {
                        Circle()
                            .fill(Color.ivAccent)
                            .frame(width: 6, height: 6)
                        Text("Uploading")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivAccent)
                    }
                }

                Text("Scanned in \(stats.durationString)")
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)

                Text("Showing \(viewModel.filteredAssets.count) of \(stats.totalScanned)")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }
            .padding(.horizontal, IVSpacing.lg)
            .padding(.vertical, IVSpacing.sm)
        }
        .background {
            Rectangle()
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 1, y: -1)
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return df
    }()

    private struct ColumnWidths {
        var type: CGFloat = 60
        var filename: CGFloat = 200
        var date: CGFloat = 100
        var resolution: CGFloat = 90
        var size: CGFloat = 80
        var status: CGFloat = 130
    }
}
