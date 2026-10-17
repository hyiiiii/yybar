import SwiftUI

// MARK: - ModelPriceRows
//
// 设置 · 通用 ·「模型价格」卡片内容。模型列表取自本地用量(即统计 · 模型明细里出现过的模型),
// 按归一化模型名合并;Grok 的费用直接取自 Grok CLI 日志，不在此列。
// 每格是美元 / 百万 Token,预填当前生效价格(自定义 > 内置);改完按回车或离开输入框即保存，
// 和内置价格相同则视为恢复默认。保存后由 AppState.setCustomPrice 防抖重算全部历史费用。

struct ModelPriceRows: View {
    @Environment(AppState.self) private var appState

    /// 价格表里的一个模型。
    struct Model: Identifiable {
        /// 归一化模型名(价格表的键)。
        let id: String
        let app: UsageApp
        /// 日志里的原始名称(展示用)。
        let name: String
        let builtIn: ModelPrice?
    }

    /// Codex 在前、Claude 在后，各自按名称排序。
    private var models: [Model] {
        var byKey: [String: Model] = [:]
        for bucket in appState.usageService.aggregator.snapshot() where bucket.app != .grok {
            let raw = bucket.model
            guard !raw.isEmpty, !raw.hasPrefix("<"), raw != "unknown" else { continue }
            let key = Pricing.normalize(model: raw)
            if byKey[key] == nil {
                byKey[key] = Model(id: key, app: bucket.app, name: raw, builtIn: Pricing.table[key])
            }
        }
        return byKey.values.sorted {
            if $0.app != $1.app { return $0.app == .codex }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        let models = models
        VStack(spacing: 0) {
            ModelPriceHeader()
            if models.isEmpty {
                Divider()
                Text(tr("No models in the local usage yet", "本地用量里还没有模型"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            ForEach(models) { model in
                Divider()
                ModelPriceRow(model: model)
            }
        }
    }
}

enum ModelPriceColumn {
    static let field: CGFloat = 64
    static let reset: CGFloat = 22
    static let spacing: CGFloat = 8
}

private struct ModelPriceHeader: View {
    var body: some View {
        HStack(spacing: ModelPriceColumn.spacing) {
            Text(tr("Model", "模型"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("Input", "输入")).frame(width: ModelPriceColumn.field, alignment: .trailing)
            Text(tr("Output", "输出")).frame(width: ModelPriceColumn.field, alignment: .trailing)
            Text(tr("Cache read", "缓存读取")).frame(width: ModelPriceColumn.field, alignment: .trailing)
            Text(tr("Cache write", "缓存写入")).frame(width: ModelPriceColumn.field, alignment: .trailing)
            Color.clear.frame(width: ModelPriceColumn.reset, height: 1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct ModelPriceRow: View {
    @Environment(AppState.self) private var appState
    let model: ModelPriceRows.Model

    /// 输入 / 输出 / 缓存读取 / 缓存写入 四格的文字。
    @State private var fields = ["", "", "", ""]
    @FocusState private var focused: Int?

    private var custom: ModelPrice? {
        _ = appState.customPricesVersion
        return CustomModelPrices.shared.price(forKey: model.id)
    }

    var body: some View {
        HStack(spacing: ModelPriceColumn.spacing) {
            HStack(spacing: 7) {
                ServiceLogoImage(logoName: model.app.rawValue,
                                 tint: model.app == .codex ? .codexAccent : .claudeAccent, size: 13)
                Text(model.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                tag
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(0..<4, id: \.self) { index in
                TextField("", text: $fields[index], prompt: Text("—"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11.5).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($focused, equals: index)
                    .onSubmit { commit() }
                    .frame(width: ModelPriceColumn.field)
            }

            Group {
                if custom != nil {
                    Button {
                        appState.setCustomPrice(nil, forKey: model.id)
                        load()
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.builtIn == nil ? tr("Clear", "清除") : tr("Restore built-in price", "恢复内置价格"))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: ModelPriceColumn.reset)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .onAppear { load() }
        // 离开某个输入框(切到别的格或点到别处)就保存。
        .onChange(of: focused) { old, _ in
            if old != nil { commit() }
        }
        .animation(.easeInOut(duration: 0.2), value: custom != nil)
    }

    @ViewBuilder
    private var tag: some View {
        if custom != nil {
            Text(tr("Custom", "自定义"))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .transition(.opacity)
        } else if model.builtIn == nil {
            Text(tr("No price", "未定价"))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .transition(.opacity)
        }
    }

    /// 填入当前生效的价格(自定义 > 内置;都没有时留空)。
    private func load() {
        guard let price = custom ?? model.builtIn else {
            fields = ["", "", "", ""]
            return
        }
        fields = [price.input, price.output, price.cacheRead, price.cacheCreation].map { "\($0)" }
    }

    /// 解析四格：全空 = 清除自定义;和内置价格相同 = 恢复默认;否则保存为自定义(空格按 0)。
    /// 有格子不是数字时整行恢复原值。
    private func commit() {
        let parsed = fields.map { text -> Decimal?? in
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            if trimmed.isEmpty { return .some(nil) }
            guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
            return .some(value)
        }
        guard parsed.allSatisfy({ $0 != nil }) else {
            load()
            return
        }
        let values = parsed.map { $0! }
        let next: ModelPrice?
        if values.allSatisfy({ $0 == nil }) {
            next = nil
        } else {
            let price = ModelPrice(input: values[0] ?? 0, output: values[1] ?? 0,
                                   cacheRead: values[2] ?? 0, cacheCreation: values[3] ?? 0)
            next = price == model.builtIn ? nil : price
        }
        if next != custom {
            appState.setCustomPrice(next, forKey: model.id)
        }
        load()
    }
}
