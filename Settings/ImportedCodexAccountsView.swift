import SwiftUI

// MARK: - OtherAccountRows
//
// 设置 · 服务里某个服务的「其他账号」行，紧跟在该服务本机账号(带绿点)那一行之后，
// 与本机账号共用 ServiceMatrixRow 布局：最左单选 = 把本机 CLI 切换到这个账号，启用 = 刷新额度，
// 菜单栏 / 悬浮窗 = 在那里显示这个账号的额度，最右列 = 删除。
// Codex 行可整行拖动排序(沿用 ImportedCodexAccount 顺序);Claude / Grok 按添加顺序。
// 添加入口是卡片底部的 AddAccountButton(选服务商 → 浏览器登录或粘贴凭据)。

struct OtherAccountRows: View {
    @Environment(AppState.self) private var appState
    let provider: AccountProvider
    /// 指定时改为列这个类型的其他账号(Google:Gemini · Antigravity,没有对应的 AccountProvider)。
    var extraProvider: ExtraProvider? = nil
    /// 本机账号行被删除时，第一行前不再画分隔线(上方已有服务之间的分隔线)。
    var leadingDivider: Bool = true

    @State private var deleteTarget: ImportedCodexAccount?
    @State private var extraDeleteTarget: ExtraAccount?
    @State private var draggingId: String?
    @State private var dropTargetId: String?

    var body: some View {
        VStack(spacing: 0) {
            if extraProvider == nil && provider == .codex {
                ForEach(Array(appState.otherCodexAccounts.enumerated()), id: \.element.id) { idx, account in
                    if idx > 0 || leadingDivider { Divider().padding(.leading, ServiceMatrixColumn.textInset) }
                    codexRow(account)
                        .opacity(draggingId == account.id ? 0.4 : 1)
                        .overlay(alignment: .top) {
                            if dropTargetId == account.id, draggingId != account.id {
                                Rectangle().fill(Color.accentColor).frame(height: 2)
                            }
                        }
                        .draggable(account.id) {
                            Text(rowTitle(account))
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.background.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .onAppear { draggingId = account.id }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            defer {
                                draggingId = nil
                                dropTargetId = nil
                            }
                            guard let sourceId = items.first, sourceId != account.id else { return false }
                            return performReorder(sourceId: sourceId, targetId: account.id)
                        } isTargeted: { isTargeted in
                            dropTargetId = isTargeted ? account.id : (dropTargetId == account.id ? nil : dropTargetId)
                        }
                }
            } else {
                ForEach(Array(appState.extraAccounts(for: extraProvider ?? (provider == .claude ? .claude : .grok)).enumerated()), id: \.element.id) { idx, account in
                    if idx > 0 || leadingDivider { Divider().padding(.leading, ServiceMatrixColumn.textInset) }
                    extraRow(account)
                }
            }
        }
        .confirmationDialog(
            tr("Remove account?", "删除此账号？"),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                Button(tr("Remove", "删除"), role: .destructive) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                        appState.removeImportedCodexAccount(id: target.id)
                    }
                    deleteTarget = nil
                }
                Button(tr("Cancel", "取消"), role: .cancel) { deleteTarget = nil }
            }
        } message: {
            if let target = deleteTarget {
                Text(tr("\u{201C}\(rowTitle(target))\u{201D} will be removed from yybar. The account itself is not affected.",
                        "\u{201C}\(rowTitle(target))\u{201D} 将从 yybar 中移除，账号本身不受影响。"))
            }
        }
        .confirmationDialog(
            tr("Remove account?", "删除此账号？"),
            isPresented: Binding(get: { extraDeleteTarget != nil }, set: { if !$0 { extraDeleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = extraDeleteTarget {
                Button(tr("Remove", "删除"), role: .destructive) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                        appState.removeExtraAccount(id: target.id)
                    }
                    extraDeleteTarget = nil
                }
                Button(tr("Cancel", "取消"), role: .cancel) { extraDeleteTarget = nil }
            }
        } message: {
            if let target = extraDeleteTarget {
                Text(tr("\u{201C}\(target.displayName)\u{201D} will be removed from yybar and its saved credentials deleted. The account itself is not affected.",
                        "\u{201C}\(target.displayName)\u{201D} 将从 yybar 中移除，并删除保存的凭据，账号本身不受影响。"))
            }
        }
    }

    // MARK: Rows

    /// 和本机账号同一布局(ServiceMatrixRow):单选(点击切换本机 CLI)+ 服务名 + 订阅标签 + 邮箱 + 全部开关。
    private func codexRow(_ account: ImportedCodexAccount) -> some View {
        ServiceMatrixRow(
            title: account.alias.isEmpty ? "Codex" : "Codex · \(account.alias)",
            logoName: "codex", fallback: "C", tint: .codexAccent,
            email: account.email ?? account.id,
            plan: account.planType,
            renewal: .codex(activeUntil: account.subscriptionActiveUntil),
            switchState: switchState(id: account.id) { await appState.switchCLI(toCodex: account) },
            enabled: Binding(
                get: { account.visibleInPopover },
                set: { newValue in
                    appState.updateImportedCodexMetadata(id: account.id) { $0.visibleInPopover = newValue }
                    FloatingPanelController.shared.sync()
                }
            ),
            menuBar: Binding(
                get: { account.showInMenuBar ?? false },
                set: { newValue in appState.updateImportedCodexMetadata(id: account.id) { $0.showInMenuBar = newValue } }
            ),
            floating: Binding(
                get: { account.showInFloating ?? false },
                set: { newValue in
                    appState.updateImportedCodexMetadata(id: account.id) { $0.showInFloating = newValue }
                    FloatingPanelController.shared.sync()
                }
            ),
            floatingAvailable: SettingsStore.shared.floatingEnabled,
            quotaCard: AnyView(OtherAccountQuotaCard(account: .codex(account)).environment(appState)),
            onDelete: { deleteTarget = account }
        )
        .help(tr("Drag to reorder", "拖动以排序"))
    }

    private func extraRow(_ account: ExtraAccount) -> some View {
        let isClaude = account.provider == .claude
        let isGoogle = account.provider == .google
        return ServiceMatrixRow(
            title: (isClaude ? "Claude Code" : (isGoogle ? "Gemini · Antigravity" : "Grok")) + (account.alias.isEmpty ? "" : " · \(account.alias)"),
            logoName: isGoogle ? "gemini" : account.provider.rawValue,
            fallback: isClaude ? "K" : "G",
            tint: isClaude ? .claudeAccent : (isGoogle ? .googleAccent : .grokAccent),
            email: account.email ?? account.displayName,
            plan: account.plan,
            renewal: isClaude ? .monthly(from: account.subscriptionStartedAt) : nil,
            // Google 账号不能切换本机 agy 的登录(agy 的登录在钥匙串里),没有单选。
            switchState: isGoogle ? .none : switchState(id: account.id) { await appState.switchCLI(toExtra: account) },
            enabled: Binding(
                get: { account.visibleInPopover },
                set: { newValue in
                    appState.updateExtraAccount(id: account.id) { $0.visibleInPopover = newValue }
                    FloatingPanelController.shared.sync()
                }
            ),
            menuBar: Binding(
                get: { account.showInMenuBar ?? false },
                set: { newValue in appState.updateExtraAccount(id: account.id) { $0.showInMenuBar = newValue } }
            ),
            floating: Binding(
                get: { account.showInFloating ?? false },
                set: { newValue in
                    appState.updateExtraAccount(id: account.id) { $0.showInFloating = newValue }
                    FloatingPanelController.shared.sync()
                }
            ),
            floatingAvailable: SettingsStore.shared.floatingEnabled,
            quotaCard: AnyView(OtherAccountQuotaCard(account: .extra(account)).environment(appState)),
            onDelete: { extraDeleteTarget = account }
        )
    }

    /// 其他账号的单选：点击后切换本机 CLI(切换中显示转圈，期间其他行不可点)。
    private func switchState(id: String, perform: @escaping () async -> Void) -> AccountSwitchIndicator {
        .switchable(
            busy: appState.switchingAccountId == id,
            disabled: appState.switchingAccountId != nil,
            action: { Task { await perform() } }
        )
    }

    private func rowTitle(_ account: ImportedCodexAccount) -> String {
        if !account.alias.isEmpty { return account.alias }
        if let email = account.email, !email.isEmpty {
            return email.components(separatedBy: "@").first ?? email
        }
        return account.id
    }

    private func performReorder(sourceId: String, targetId: String) -> Bool {
        var ids = appState.importedCodexAccounts.map(\.id)
        guard let from = ids.firstIndex(of: sourceId),
              let to = ids.firstIndex(of: targetId),
              from != to else { return false }
        let moved = ids.remove(at: from)
        let insertAt = ids.firstIndex(of: targetId) ?? to
        ids.insert(moved, at: insertAt)
        appState.reorderImportedCodexAccounts(orderedIds: ids)
        return true
    }
}

// MARK: - AddAccountButton

/// 账号卡片底部的「添加账号…」,打开 AddAccountSheet。
struct AddAccountButton: View {
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text(tr("Add account…", "添加账号…"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            AddAccountSheet()
        }
    }
}

// MARK: - AddImportedCodexAccountSheet

struct AddImportedCodexAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onSuccess: () -> Void

    @State private var jsonText = ""
    @State private var visibleInPopover = true

    @State private var parseResult: Result<[ImportedCodexPaste.Parsed], ImportedCodexPaste.Failure>?
    @State private var saveError: String?
    @State private var isSaving = false

    private var parsedBatch: [ImportedCodexPaste.Parsed]? {
        if case .success(let list) = parseResult { return list }
        return nil
    }
    private var parsed: ImportedCodexPaste.Parsed? { parsedBatch?.first }
    private var isBatch: Bool { (parsedBatch?.count ?? 0) > 1 }
    private var parseError: String? {
        if case .failure(let f) = parseResult { return f.description }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text(tr("Add Codex Account", "添加 Codex 账号"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // JSON 粘贴区
                    jsonSection
                    // 预览
                    if isBatch, let batch = parsedBatch {
                        batchPreviewSection(batch)
                    } else if let p = parsed {
                        previewSection(p)
                    }
                    // 表单(显示开关,单账号 / 批量通用)
                    if parsedBatch != nil { formSection }
                    // 错误
                    if let err = parseError ?? saveError {
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // 按钮栏
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Button(isBatch ? tr("Import All", "批量导入") : tr("Save", "保存")) { save() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(parsedBatch == nil || isSaving)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 460)
        .onChange(of: jsonText) { _, _ in reParse() }
    }

    // MARK: JSON 粘贴区

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Paste auth.json content", "粘贴 auth.json 内容"))
                .font(.system(size: 12, weight: .semibold))
            Text(tr(
                "Supports a single auth.json or a JSON array of multiple accounts (e.g. cc-switch export). The display name is taken from the email prefix automatically.",
                "支持单个 auth.json,也支持多账号的 JSON 数组(如 cc-switch 导出)。显示名自动取邮箱 @ 前的部分。"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $jsonText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 120)
                .padding(6)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            parseError != nil ? Color.red.opacity(0.6) :
                            (parsed != nil ? Color.green.opacity(0.5) : Color.secondary.opacity(0.25)),
                            lineWidth: 1
                        )
                )
        }
    }

    // MARK: 解析预览

    private func previewSection(_ p: ImportedCodexPaste.Parsed) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let email = p.email {
                        Text(email)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    if let plan = p.planType {
                        Text(plan.capitalized)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("ID: \(p.chatgptAccountId)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(10)
        .background(.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 批量预览

    private func batchPreviewSection(_ batch: [ImportedCodexPaste.Parsed]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))
                Text(tr("Found \(batch.count) accounts", "找到 \(batch.count) 个账号"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(batch.enumerated()), id: \.element.id) { idx, p in
                    HStack(spacing: 8) {
                        if let email = p.email {
                            Text(email)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                        }
                        if let plan = p.planType {
                            Text(plan.capitalized)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(p.chatgptAccountId)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)

                    if idx < batch.count - 1 {
                        Divider().padding(.leading, 10)
                    }
                }
            }
            .background(.green.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: 表单

    private var formSection: some View {
        // 显示开关(单账号 / 批量通用,默认开启)
        Toggle(isOn: $visibleInPopover) {
            Text(tr("Show in popover", "在弹出面板中显示"))
                .font(.system(size: 12.5))
        }
        .toggleStyle(.switch)
        .tint(.green)
    }

    // MARK: 操作

    private func reParse() {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parseResult = nil
            saveError = nil
            return
        }
        parseResult = ImportedCodexPaste.parseAny(trimmed)
        saveError = nil
    }

    private func save() {
        guard let batch = parsedBatch, !batch.isEmpty else { return }
        isSaving = true
        var firstError: String?
        // 别名一律留空,显示名由 email @ 前部分自动派生;
        // visibleInPopover 单账号 / 批量都遵循当前开关。
        for p in batch {
            do {
                try appState.upsertImportedCodexAccount(
                    from: p,
                    alias: "",
                    visibleInPopover: visibleInPopover
                )
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        isSaving = false
        if let err = firstError {
            saveError = err
        } else {
            onSuccess()
            dismiss()
        }
    }
}
