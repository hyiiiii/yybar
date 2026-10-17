import SwiftUI
import AppKit

// MARK: - AddAccountSheet
//
// 设置 · 服务 →「添加账号…」。三步:
// 1. 选服务商(Codex / Claude Code / Grok)
// 2. 选方式：在浏览器中登录(调用官方 CLI,独立目录，不影响本机已登录账号)/ 粘贴凭据
// 3. 浏览器登录进度，或粘贴表单
// Codex 的粘贴沿用 AddImportedCodexAccountSheet。

struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case provider
        case method
        case browser
        case paste

        /// 步骤先后，用于决定滑入方向。
        var order: Int {
            switch self {
            case .provider: return 0
            case .method: return 1
            case .browser, .paste: return 2
            }
        }
    }

    /// 步骤切换：内容按前进 / 后退方向滑入并淡入(弹簧动画)。
    private static let stepAnimation = Animation.spring(response: 0.4, dampingFraction: 0.88)
    @State private var movingForward = true

    private enum Method {
        case browser
        case paste
    }

    @State private var step: Step = .provider
    @State private var provider: AccountProvider = .codex
    @State private var method: Method = .browser

    // 浏览器登录
    @State private var session: CLILoginSession?
    @State private var authCode = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var addedName: String?

    // 粘贴(Claude / Grok)
    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var isSaving = false

    var body: some View {
        if step == .paste && provider == .codex {
            AddImportedCodexAccountSheet { appState.reloadImportedCodexAccounts() }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch step {
                        case .provider: providerStep
                        case .method: methodStep
                        case .browser: browserStep
                        case .paste: pasteStep
                        }
                    }
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: movingForward ? 28 : -28)),
                        removal: .opacity
                    ))
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
            .frame(width: 480, height: 440)
            .onChange(of: session?.phase) { _, phase in
                if phase == .exited(succeeded: true) { importFromSession() }
            }
            .onDisappear { if addedName == nil { session?.cancel() } }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            Text(tr("Add Account", "添加账号"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                stepLabel(tr("Service", "服务商"), active: step == .provider)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                stepLabel(tr("Method", "方式"), active: step == .method)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                stepLabel(tr("Sign in", "登录"), active: step == .browser || step == .paste)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func stepLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary)
    }

    private var footer: some View {
        HStack {
            if step == .method || (step == .paste && addedName == nil) || canGoBackFromBrowser {
                Button(tr("Back", "返回")) { goBack() }
            }
            Spacer()
            if addedName != nil {
                Button(tr("Done", "完成")) { dismiss() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            } else {
                Button(tr("Cancel", "取消")) {
                    session?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                primaryButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .provider:
            Button(tr("Continue", "继续")) { go(to: .method) }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        case .method:
            Button(tr("Continue", "继续")) {
                if method == .browser { startBrowserLogin() } else { go(to: .paste) }
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
        case .paste:
            Button(tr("Add", "添加")) { savePaste() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        case .browser:
            EmptyView()
        }
    }

    private var canGoBackFromBrowser: Bool {
        guard step == .browser, addedName == nil, !isImporting, let session else { return false }
        switch session.phase {
        case .failed, .exited(succeeded: false): return true
        default: return importError != nil
        }
    }

    private func go(to next: Step) {
        movingForward = next.order >= step.order
        withAnimation(Self.stepAnimation) { step = next }
    }

    private func goBack() {
        switch step {
        case .method: go(to: .provider)
        case .paste: go(to: .method)
        case .browser:
            session?.cancel()
            session = nil
            importError = nil
            authCode = ""
            go(to: .method)
        case .provider: break
        }
    }

    // MARK: Step 1 · Provider

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Which service is this account for?", "要添加哪个服务的账号？"))
                .font(.system(size: 12.5, weight: .medium))
            HStack(spacing: 10) {
                ForEach(AccountProvider.allCases) { item in
                    choiceCard(selected: provider == item) {
                        withAnimation(.easeOut(duration: 0.15)) { provider = item }
                    } content: {
                        // 图标在左，服务名 / 服务商在右，卡片矮一些。
                        HStack(spacing: 9) {
                            ServiceTile(logoName: item.logoName, fallback: String(item.title.prefix(1)),
                                        tint: tint(for: item), size: 28, logoSize: 16, cornerRadius: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text(item.vendor)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Step 2 · Method

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("How do you want to add the \(provider.title) account?", "怎样添加 \(provider.title) 账号？"))
                .font(.system(size: 12.5, weight: .medium))
            choiceCard(selected: method == .browser) {
                withAnimation(.easeOut(duration: 0.15)) { method = .browser }
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text(tr("Sign in in the browser", "在浏览器中登录"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(tr("Recommended", "推荐"))
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.12)))
                    }
                    Text(tr("Runs the official `\(provider.loginCommand)` in a separate folder. Your current sign-in on this Mac isn't touched.",
                            "调用官方 `\(provider.loginCommand)`,在独立目录登录，不影响本机已登录的账号。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            choiceCard(selected: method == .paste) {
                withAnimation(.easeOut(duration: 0.15)) { method = .paste }
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text(tr("Paste credentials", "粘贴凭据"))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    Text(tr("Paste \(provider.credentialsFile) from another Mac.",
                            "粘贴另一台机器上的 \(provider.credentialsFile)。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Step 3a · Browser login

    @ViewBuilder
    private var browserStep: some View {
        if let addedName {
            successView(name: addedName)
        } else if let session {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ServiceTile(logoName: provider.logoName, fallback: String(provider.title.prefix(1)),
                                tint: tint(for: provider), size: 28, logoSize: 16, cornerRadius: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.title).font(.system(size: 12.5, weight: .semibold))
                        Text(provider.loginCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                browserStatus(session)
                    // 登录进度(等待浏览器 → 输入授权码 → 正在添加 → 失败)之间淡入淡出。
                    .animation(.easeInOut(duration: 0.25), value: session.phase)
                    .animation(.easeInOut(duration: 0.25), value: isImporting)
                    .animation(.easeInOut(duration: 0.25), value: importError)
            }
        }
    }

    @ViewBuilder
    private func browserStatus(_ session: CLILoginSession) -> some View {
        if isImporting {
            progressRow(tr("Signed in. Adding the account…", "已登录，正在添加账号…"))
        } else if let importError {
            errorBlock(importError, detail: nil)
        } else {
            switch session.phase {
            case .starting:
                progressRow(tr("Starting sign-in…", "正在启动登录…"))
            case .waitingForBrowser:
                VStack(alignment: .leading, spacing: 8) {
                    progressRow(tr("Finish signing in in your browser. This window continues on its own.",
                                   "请在浏览器中完成登录，完成后这里会自动继续。"))
                    reopenButton(session)
                }
            case .needsCode:
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("After approving in the browser, Claude shows an authorization code. Paste it here:",
                            "在浏览器中授权后,Claude 会显示一个授权码，把它粘贴到这里："))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(tr("Authorization code", "授权码"), text: $authCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { session.submitCode(authCode) }
                        Button(tr("Submit", "提交")) { session.submitCode(authCode) }
                            .buttonStyle(.borderedProminent)
                            .disabled(authCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    reopenButton(session)
                }
            case .exited(succeeded: true):
                progressRow(tr("Signed in. Adding the account…", "已登录，正在添加账号…"))
            case .exited(succeeded: false):
                errorBlock(tr("Sign-in didn't finish.", "登录没有完成。"), detail: session.outputTail)
            case .failed(let message):
                errorBlock(message, detail: nil)
            }
        }
    }

    private func reopenButton(_ session: CLILoginSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if let url = session.loginURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label(tr("Open sign-in page again", "重新打开登录页"), systemImage: "arrow.up.right.square")
                }
                Button {
                    if let url = session.switchAccountURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label(tr("Sign in with another account", "用其他账号登录"), systemImage: "person.crop.circle.badge.plus")
                }
            }
            .controlSize(.small)
            .disabled(session.loginURL == nil)
            Text(tr("If the page shows the account already signed in on this Mac, use \u{201C}Sign in with another account\u{201D}, or sign out on that page first.",
                    "如果页面显示的是本机已登录的账号，点「用其他账号登录」,或先在页面上退出登录再换账号。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// CLI 退出码 0 后，从独立目录导入凭据。
    private func importFromSession() {
        guard let session, !isImporting, addedName == nil else { return }
        isImporting = true
        Task {
            do {
                addedName = try await appState.importLoggedIn(session: session)
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func startBrowserLogin() {
        importError = nil
        authCode = ""
        do {
            let newSession = try CLILoginSession(provider: provider)
            session = newSession
            go(to: .browser)
            newSession.start()
        } catch {
            importError = error.localizedDescription
            go(to: .browser)
        }
    }

    // MARK: Step 3b · Paste (Claude / Grok)

    @ViewBuilder
    private var pasteStep: some View {
        if let addedName {
            successView(name: addedName)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Paste the contents of \(provider.credentialsFile)", "粘贴 \(provider.credentialsFile) 的内容"))
                    .font(.system(size: 12.5, weight: .medium))
                Text(provider == .claude
                     ? tr("On the other Mac, Claude Code may keep it in the Keychain instead: run `security find-generic-password -s \"Claude Code-credentials\" -w` there and paste the output.",
                          "另一台 Mac 上 Claude Code 也可能把它存在钥匙串里：在那台机器运行 `security find-generic-password -s \"Claude Code-credentials\" -w`,粘贴输出即可。")
                     : tr("It's stored only on this Mac, in a private folder used just for this account.",
                          "凭据只保存在本机，放在这个账号专用的私有目录里。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $pasteText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 150)
                    .padding(6)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(pasteError != nil ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1))
                    .onChange(of: pasteText) { _, _ in pasteError = nil }
                if isSaving {
                    progressRow(tr("Checking the account…", "正在检查账号…"))
                }
                if let pasteError {
                    Text(pasteError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func savePaste() {
        isSaving = true
        pasteError = nil
        let text = pasteText
        Task {
            do {
                let name = provider == .claude
                    ? try await appState.addExtraClaude(pasted: text)
                    : try await appState.addExtraGrok(pasted: text)
                addedName = name
            } catch {
                pasteError = (error as? ExtraAccountPaste.PasteError)?.description ?? error.localizedDescription
            }
            isSaving = false
        }
    }

    // MARK: Shared pieces

    private func successView(name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Added \(name)", "已添加 \(name)"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("It appears in the list and the popover after its first refresh.",
                        "首次刷新后会显示在列表和弹出窗口里。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBlock(_ message: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            Text(tr("Go back to try again, or paste credentials instead.", "可以返回重试，或改用粘贴凭据。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func choiceCard<Content: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(selected ? 0.06 : 0.02)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tint(for provider: AccountProvider) -> Color {
        switch provider {
        case .codex: return .codexAccent
        case .claude: return .claudeAccent
        case .grok: return .grokAccent
        }
    }
}
