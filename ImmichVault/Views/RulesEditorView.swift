import SwiftUI

// MARK: - Rules Editor View
// Premium macOS SwiftUI view for managing transcode rules.
// Supports viewing, creating, editing, deleting, toggling, duplicating,
// and reordering rules. Built-in rules are protected from deletion.

struct RulesEditorView: View {
    @StateObject private var viewModel = RulesEditorViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if viewModel.isLoading {
                loadingState
            } else if viewModel.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }

            // Error banner
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            statusBar
        }
        .onAppear {
            viewModel.loadRules()
        }
        .sheet(isPresented: $viewModel.isEditing) {
            if let rule = viewModel.editingRule {
                RuleEditorSheet(
                    rule: rule,
                    isBuiltIn: rule.isBuiltIn,
                    onSave: { updatedRule in
                        Task { await viewModel.saveRule(updatedRule) }
                        viewModel.isEditing = false
                        viewModel.editingRule = nil
                    },
                    onCancel: {
                        viewModel.isEditing = false
                        viewModel.editingRule = nil
                    }
                )
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: IVSpacing.md) {
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Transcode Rules")
                    .font(IVFont.displayMedium)
                    .foregroundColor(.ivTextPrimary)
                Text("Rules are evaluated in priority order. First matching rule wins.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }

            Spacer()

            Button {
                viewModel.startCreating()
            } label: {
                Label("Add Rule", systemImage: "plus")
                    .font(IVFont.bodyMedium)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.md)
        .background(Color.ivBackground)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: IVSpacing.lg) {
            ForEach(0..<4, id: \.self) { _ in
                IVSkeletonRow()
                    .padding(.horizontal, IVSpacing.lg)
            }
        }
        .padding(.vertical, IVSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        IVEmptyState(
            icon: "list.bullet.rectangle",
            title: "No Rules Defined",
            message: "Add a rule to automatically select transcode presets and providers based on video properties.",
            actionTitle: "Add Rule"
        ) {
            viewModel.startCreating()
        }
    }

    // MARK: - Rules List

    private var rulesList: some View {
        VStack(spacing: 0) {
            rulesTableHeader
            Divider()

            List {
                ForEach(viewModel.rules) { rule in
                    RuleRowView(
                        rule: rule,
                        onToggle: {
                            Task { await viewModel.toggleRule(rule.id) }
                        },
                        onEdit: {
                            viewModel.startEditing(rule)
                        },
                        onDuplicate: {
                            viewModel.duplicateRule(rule)
                        },
                        onDelete: {
                            Task { await viewModel.deleteRule(rule.id) }
                        }
                    )
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: 0,
                        bottom: 0,
                        trailing: 0
                    ))
                    .listRowSeparator(.visible)
                }
                .onMove { from, to in
                    viewModel.moveRules(from: from, to: to)
                }
            }
            .listStyle(.plain)
        }
    }

    private var rulesTableHeader: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 36, alignment: .center)
            Text("Rule")
                .frame(minWidth: 160, alignment: .leading)
            Spacer()
            Text("Preset")
                .frame(width: 120, alignment: .center)
            Text("Provider")
                .frame(width: 110, alignment: .center)
            Text("Enabled")
                .frame(width: 70, alignment: .center)
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextTertiary)
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background(Color.ivSurface.opacity(0.5))
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: IVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.ivError)
            Text(error)
                .font(IVFont.caption)
                .foregroundColor(.ivError)
            Spacer()
            Button("Dismiss") { viewModel.errorMessage = nil }
                .font(IVFont.caption)
                .buttonStyle(.borderless)
        }
        .padding(IVSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                .fill(Color.ivError.opacity(0.08))
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.xs)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: IVSpacing.lg) {
            HStack(spacing: IVSpacing.xs) {
                Circle()
                    .fill(Color.ivAccent)
                    .frame(width: 6, height: 6)
                Text("\(viewModel.rules.count) rules")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }

            HStack(spacing: IVSpacing.xs) {
                Circle()
                    .fill(Color.ivSuccess)
                    .frame(width: 6, height: 6)
                Text("\(viewModel.enabledCount) enabled")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }

            HStack(spacing: IVSpacing.xs) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.ivTextTertiary)
                Text("\(viewModel.builtInCount) built-in")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }

            Spacer()

            Text("Drag to reorder. Lower priority number wins.")
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background {
            Rectangle()
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 1, y: -1)
        }
    }
}

// MARK: - Rule Row View

private struct RuleRowView: View {
    let rule: TranscodeRule
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Priority badge
            ZStack {
                Circle()
                    .fill(rule.enabled ? Color.ivAccent.opacity(0.15) : Color.ivTextTertiary.opacity(0.1))
                    .frame(width: 26, height: 26)
                Text("\(rule.priority)")
                    .font(IVFont.captionMedium)
                    .foregroundColor(rule.enabled ? .ivAccent : .ivTextTertiary)
            }
            .frame(width: 36, alignment: .center)

            // Rule name + conditions summary
            HStack(spacing: IVSpacing.sm) {
                if rule.isBuiltIn {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.ivTextTertiary)
                        .help("Built-in rule (cannot be deleted)")
                }

                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text(rule.name)
                        .font(IVFont.bodyMedium)
                        .foregroundColor(rule.enabled ? .ivTextPrimary : .ivTextTertiary)
                        .lineLimit(1)

                    Text(rule.conditionsSummary)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 160, alignment: .leading)

            Spacer()

            // Preset pill
            Text(rule.presetName)
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextSecondary)
                .padding(.horizontal, IVSpacing.sm)
                .padding(.vertical, IVSpacing.xxs)
                .background {
                    Capsule()
                        .fill(Color.ivAccent.opacity(0.1))
                }
                .frame(width: 120, alignment: .center)

            // Provider
            Text(rule.resolvedProviderType.label)
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 110, alignment: .center)

            // Enabled toggle
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 70, alignment: .center)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button {
                onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(rule.isBuiltIn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.name), priority \(rule.priority), \(rule.enabled ? "enabled" : "disabled")")
        .accessibilityHint(rule.isBuiltIn ? "Built-in rule" : "Custom rule. Use context menu to edit or delete.")
    }
}

// MARK: - Rule Editor Sheet

private struct RuleEditorSheet: View {
    @State private var editableRule: TranscodeRule
    @State private var editableConditions: [EditableCondition]
    @State private var selectedPresetName: String
    @State private var selectedProviderType: TranscodeProviderType

    let isBuiltIn: Bool
    let onSave: (TranscodeRule) -> Void
    let onCancel: () -> Void

    init(
        rule: TranscodeRule,
        isBuiltIn: Bool,
        onSave: @escaping (TranscodeRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _editableRule = State(initialValue: rule)
        _editableConditions = State(initialValue: rule.conditions.map { EditableCondition(condition: $0) })
        _selectedPresetName = State(initialValue: rule.presetName)
        _selectedProviderType = State(initialValue: rule.resolvedProviderType)
        self.isBuiltIn = isBuiltIn
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: IVSpacing.xl) {
                    nameSection
                    conditionsSection
                    presetSection
                    providerSection

                    if isBuiltIn {
                        builtInNotice
                    }
                }
                .padding(IVSpacing.xl)
            }

            Divider()
            sheetFooter
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 560)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(isBuiltIn ? "View Built-in Rule" : (editableRule.id.contains("builtin") ? "Edit Rule" : "Edit Rule"))
                    .font(IVFont.headline)
                    .foregroundColor(.ivTextPrimary)
                Text(isBuiltIn
                     ? "Built-in rules can be toggled but not modified or deleted."
                     : "Define conditions and select a preset for this rule.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, IVSpacing.xl)
        .padding(.vertical, IVSpacing.md)
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("GENERAL")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                    Text("Name")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)
                    TextField("Rule name", text: $editableRule.name)
                        .textFieldStyle(.roundedBorder)
                        .font(IVFont.body)
                        .disabled(isBuiltIn)
                }

                VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                    Text("Description (optional)")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)
                    TextField("Describe what this rule does", text: Binding(
                        get: { editableRule.description ?? "" },
                        set: { editableRule.description = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(IVFont.body)
                    .disabled(isBuiltIn)
                }
            }
        }
    }

    // MARK: - Conditions Section

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack {
                Text("CONDITIONS")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextTertiary)
                    .tracking(0.5)

                Spacer()

                if editableConditions.isEmpty {
                    Text("Matches all videos")
                        .font(IVFont.caption)
                        .foregroundColor(.ivWarning)
                }
            }

            VStack(spacing: IVSpacing.sm) {
                ForEach(Array(editableConditions.enumerated()), id: \.element.id) { index, condition in
                    conditionRow(index: index, condition: condition)
                }
            }

            if !isBuiltIn {
                Button {
                    let newCondition = EditableCondition(
                        condition: RuleCondition(
                            conditionType: .fileSize,
                            comparisonOperator: .greaterThan,
                            value: "",
                            unit: RuleCondition.ConditionType.fileSize.defaultUnit
                        )
                    )
                    editableConditions.append(newCondition)
                } label: {
                    Label("Add Condition", systemImage: "plus.circle")
                        .font(IVFont.bodyMedium)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.ivAccent)
            }

            if editableConditions.count > 1 {
                Text("All conditions must match (AND logic).")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }
        }
    }

    private func conditionRow(index: Int, condition: EditableCondition) -> some View {
        HStack(spacing: IVSpacing.sm) {
            // Condition type picker
            Picker("Type", selection: conditionTypeBinding(for: index)) {
                ForEach(RuleCondition.ConditionType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .font(IVFont.body)
            .disabled(isBuiltIn)
            .labelsHidden()

            // Comparison operator picker (filtered by condition type)
            Picker("Operator", selection: conditionOperatorBinding(for: index)) {
                ForEach(editableConditions[safe: index]?.conditionType.applicableOperators ?? [], id: \.self) { op in
                    Text(op.label).tag(op)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .font(IVFont.body)
            .disabled(isBuiltIn)
            .labelsHidden()

            // Value text field
            TextField(
                editableConditions[safe: index]?.conditionType.valuePlaceholder ?? "Value",
                text: conditionValueBinding(for: index)
            )
            .textFieldStyle(.roundedBorder)
            .font(IVFont.body)
            .frame(minWidth: 80)
            .disabled(isBuiltIn)

            // Unit label (if applicable)
            if let unit = editableConditions[safe: index]?.unit, !unit.isEmpty {
                Text(unit)
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextTertiary)
                    .frame(width: 50, alignment: .leading)
            }

            // Delete button
            if !isBuiltIn {
                Button {
                    if editableConditions.indices.contains(index) {
                        editableConditions.remove(at: index)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.ivError.opacity(0.7))
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Remove condition")
            }
        }
        .padding(IVSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
    }

    // MARK: - Condition Bindings

    private func conditionTypeBinding(for index: Int) -> Binding<RuleCondition.ConditionType> {
        Binding(
            get: {
                editableConditions[safe: index]?.conditionType ?? .fileSize
            },
            set: { newType in
                guard editableConditions.indices.contains(index) else { return }
                editableConditions[index].conditionType = newType
                // Reset operator to first applicable
                editableConditions[index].comparisonOperator = newType.applicableOperators.first ?? .greaterThan
                // Reset unit
                editableConditions[index].unit = newType.defaultUnit
                // Clear value
                editableConditions[index].value = ""
            }
        )
    }

    private func conditionOperatorBinding(for index: Int) -> Binding<RuleCondition.ComparisonOperator> {
        Binding(
            get: {
                editableConditions[safe: index]?.comparisonOperator ?? .greaterThan
            },
            set: { newOp in
                guard editableConditions.indices.contains(index) else { return }
                editableConditions[index].comparisonOperator = newOp
            }
        )
    }

    private func conditionValueBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                editableConditions[safe: index]?.value ?? ""
            },
            set: { newValue in
                guard editableConditions.indices.contains(index) else { return }
                editableConditions[index].value = newValue
            }
        )
    }

    // MARK: - Preset Section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("TRANSCODE PRESET")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                Picker("Preset", selection: $selectedPresetName) {
                    ForEach(TranscodePreset.allPresets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)
                .disabled(isBuiltIn)

                if let preset = TranscodePreset.allPresets.first(where: { $0.name == selectedPresetName }) {
                    HStack(spacing: IVSpacing.lg) {
                        presetDetailLabel("Codec", value: preset.videoCodec.label)
                        presetDetailLabel("CRF", value: "\(preset.crf)")
                        presetDetailLabel("Audio", value: "\(preset.audioCodec.label) \(preset.audioBitrate)")
                        presetDetailLabel("Container", value: preset.container.uppercased())
                    }

                    Text(preset.description)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
            }
        }
    }

    private func presetDetailLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
            Text(label)
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
            Text(value)
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextSecondary)
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("PROVIDER")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            Picker("Provider", selection: $selectedProviderType) {
                ForEach(TranscodeProviderType.allCases, id: \.self) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300)
            .disabled(isBuiltIn)

            if selectedProviderType != .local {
                HStack(spacing: IVSpacing.xs) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.ivWarning)
                    Text("Cloud providers incur costs. Make sure the API key is configured in Settings.")
                        .font(IVFont.caption)
                        .foregroundColor(.ivWarning)
                }
            }
        }
    }

    // MARK: - Built-in Notice

    private var builtInNotice: some View {
        HStack(spacing: IVSpacing.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundColor(.ivTextTertiary)
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Built-in Rule")
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
                Text("This rule is shipped with ImmichVault. You can enable or disable it, but it cannot be edited or deleted. Use \"Duplicate\" to create a custom version.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            if isBuiltIn {
                Text("Read-only")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            if !isBuiltIn {
                Button("Save") {
                    var ruleToSave = editableRule
                    ruleToSave.conditions = editableConditions.map(\.toRuleCondition)
                    ruleToSave.presetName = selectedPresetName
                    ruleToSave.providerType = selectedProviderType.rawValue
                    onSave(ruleToSave)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(editableRule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, IVSpacing.xl)
        .padding(.vertical, IVSpacing.md)
    }
}

// MARK: - Editable Condition (Mutable Wrapper)

/// Mutable wrapper around RuleCondition for editing in the sheet.
/// RuleCondition uses `let` properties, so we need a mutable intermediate.
private struct EditableCondition: Identifiable {
    let id = UUID()
    var conditionType: RuleCondition.ConditionType
    var comparisonOperator: RuleCondition.ComparisonOperator
    var value: String
    var unit: String?

    init(condition: RuleCondition) {
        self.conditionType = condition.conditionType
        self.comparisonOperator = condition.comparisonOperator
        self.value = condition.value
        self.unit = condition.unit
    }

    var toRuleCondition: RuleCondition {
        RuleCondition(
            conditionType: conditionType,
            comparisonOperator: comparisonOperator,
            value: value,
            unit: unit
        )
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
