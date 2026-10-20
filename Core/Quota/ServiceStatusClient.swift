import Foundation
import SwiftUI

// MARK: - ServiceStatus 模型与抓取
//
// 复用 Statuspage.io 公开接口(summary.json),只看和 CLI 相关的组件，避免无关产品的故障把圆点染黄:
// - OpenAI    https://status.openai.com/api/v2/summary.json   组件:Codex… / Responses / Login
// - Anthropic https://status.claude.com/api/v2/summary.json   组件:Claude Code / Claude API…
// 组件状态 operational / degraded_performance / partial_outage / major_outage / under_maintenance
// 映射为 none / minor / major / critical / maintenance,取最严重的一个;
// 页面上找不到这些组件时退回整页 status.indicator。解析失败统一归为 .unknown。
//
// xAI 不是 Statuspage.io:status.x.ai 页面和 JSON 接口被 Cloudflare 拦截，
// 只有 RSS(https://status.x.ai/feed.xml)可直接读取，见 `fetchXAI()`。
//
// Cursor(Grok Bot)是 Statuspage.io:https://status.cursor.com/api/v2/summary.json,组件「Grok Bot」。
//
// Google 没有 Statuspage.io,用两份公开的 incidents.json(同一格式):
// - Workspace https://www.google.com/appsstatus/dashboard/incidents.json   产品「Gemini」(Gemini app)
// - Cloud     https://status.cloud.google.com/incidents.json               产品「Vertex Gemini API」
// 只看受影响产品名含 "Gemini"、且没有结束时间(end 为空)的事件:SERVICE_OUTAGE → major,
// SERVICE_DISRUPTION → minor,其余(SERVICE_INFORMATION)→ none。见 `fetchGoogle()`。
//
// 见 docs/技术实现.md "服务状态" 一节。

enum ServiceStatusIndicator: String, Sendable, Codable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    /// 弹出窗口 / 悬浮窗使用的圆点颜色;`.unknown` 由 UI 自行决定是否显示。
    var dotColor: Color {
        switch self {
        case .none: return .green
        case .minor: return .yellow
        case .major: return .orange
        case .critical: return .red
        case .maintenance: return .blue
        case .unknown: return .gray
        }
    }

    /// 默认中英文标签,在 UI 没有 description 时用作 tooltip。
    var label: String {
        switch self {
        case .none: return tr("All systems normal", "服务正常")
        case .minor: return tr("Minor issue", "轻微故障")
        case .major: return tr("Major issue", "重大故障")
        case .critical: return tr("Critical outage", "严重故障")
        case .maintenance: return tr("Maintenance", "维护中")
        case .unknown: return tr("Status unknown", "状态未知")
        }
    }
}

struct ServiceStatus: Sendable, Equatable {
    var indicator: ServiceStatusIndicator
    var description: String?
    var updatedAt: Date?
    var fetchedAt: Date
}

enum ServiceStatusClient {
    static let openAIStatusURL = URL(string: "https://status.openai.com/api/v2/summary.json")!
    static let anthropicStatusURL = URL(string: "https://status.claude.com/api/v2/summary.json")!

    /// Codex CLI 依赖的 OpenAI 组件(名称前缀匹配,不区分大小写)。
    static let openAIComponents = ["Codex", "Responses", "Login"]
    /// Claude Code CLI 依赖的 Anthropic 组件。
    static let anthropicComponents = ["Claude Code", "Claude API"]

    static let xAIStatusFeedURL = URL(string: "https://status.x.ai/feed.xml")!

    static let cursorStatusURL = URL(string: "https://status.cursor.com/api/v2/summary.json")!
    /// Grok Bot 依赖的 Cursor 组件。
    static let cursorComponents = ["Grok Bot"]

    static let googleIncidentFeeds = [
        URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!,
        URL(string: "https://status.cloud.google.com/incidents.json")!
    ]

    /// 拉取 Google 两份 incidents.json,取 Gemini 相关的未结束事件里最严重的。两份都失败才抛错。
    static func fetchGoogle() async throws -> ServiceStatus {
        var feeds: [Data] = []
        var lastError: Error?
        for url in googleIncidentFeeds {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                feeds.append(data)
            } catch {
                lastError = error
            }
        }
        if feeds.isEmpty { throw lastError ?? URLError(.cannotParseResponse) }
        return try parseGoogleIncidents(feeds)
    }

    static func parseGoogleIncidents(_ feeds: [Data], now: Date = Date()) throws -> ServiceStatus {
        let rank: [ServiceStatusIndicator: Int] = [.none: 0, .maintenance: 1, .minor: 2, .major: 3, .critical: 4]
        var worst: ServiceStatusIndicator = .none
        var title: String?
        var parsed = 0
        for data in feeds {
            guard let incidents = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            parsed += 1
            for incident in incidents {
                let products = (incident["affected_products"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
                guard products.contains(where: { $0.localizedCaseInsensitiveContains("Gemini") }) else { continue }
                if let end = incident["end"] as? String, !end.isEmpty { continue }
                let indicator: ServiceStatusIndicator
                switch incident["status_impact"] as? String {
                case "SERVICE_OUTAGE": indicator = .major
                case "SERVICE_DISRUPTION": indicator = .minor
                default: indicator = .none
                }
                if (rank[indicator] ?? 0) > (rank[worst] ?? 0) {
                    worst = indicator
                    title = incident["external_desc"] as? String
                }
            }
        }
        if parsed == 0 { throw URLError(.cannotParseResponse) }
        return ServiceStatus(indicator: worst, description: title ?? tr("All systems normal", "服务正常"),
                             updatedAt: nil, fetchedAt: now)
    }

    /// 只看 Grok CLI 依赖的组件;grok.com 网页、语音等故障不影响 CLI。
    private static let xAIRelevantComponents = ["Grok (Build)", "Global (api.x.ai)"]

    /// 拉取 xAI 状态 RSS:相关组件下未结束的事件决定圆点颜色。
    /// outage → major,disruption → minor,maintenance → maintenance;没有未结束事件 → none。
    static func fetchXAI() async throws -> ServiceStatus {
        var request = URLRequest(url: xAIStatusFeedURL)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let xml = String(data: data, encoding: .utf8), xml.contains("<channel>") else {
            throw URLError(.cannotParseResponse)
        }
        return parseXAIFeed(xml)
    }

    /// RSS 的 description 里有 HTML 实体,XMLParser 会因未定义实体失败，这里按标签直接截取。
    static func parseXAIFeed(_ xml: String, now: Date = Date()) -> ServiceStatus {
        func tag(_ name: String, in text: String) -> [String] {
            var values: [String] = []
            var rest = text[...]
            while let open = rest.range(of: "<\(name)>"), let close = rest.range(of: "</\(name)>", range: open.upperBound..<rest.endIndex) {
                values.append(String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                rest = rest[close.upperBound...]
            }
            return values
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let rank: [ServiceStatusIndicator: Int] = [.none: 0, .maintenance: 1, .minor: 2, .major: 3, .critical: 4]
        var worst: ServiceStatusIndicator = .none
        var worstTitle: String?
        var latest: Date?

        for item in tag("item", in: xml) {
            guard let title = tag("title", in: item).first,
                  xAIRelevantComponents.contains(where: { title.hasPrefix("[\($0)]") }) else { continue }
            if let date = tag("pubDate", in: item).first.flatMap(dateFormatter.date(from:)) {
                latest = max(latest ?? date, date)
            }
            let categories = Set(tag("category", in: item).map { $0.lowercased() })
            // 已结束的事件不影响当前状态。
            guard categories.isDisjoint(with: ["resolved", "completed", "postmortem"]) else { continue }
            let indicator: ServiceStatusIndicator
            if categories.contains("maintenance") || categories.contains("scheduled") {
                indicator = .maintenance
            } else if categories.contains("outage") {
                indicator = .major
            } else {
                indicator = .minor
            }
            if (rank[indicator] ?? 0) > (rank[worst] ?? 0) {
                worst = indicator
                worstTitle = title
            }
        }

        return ServiceStatus(
            indicator: worst,
            description: worstTitle ?? tr("All systems normal", "服务正常"),
            updatedAt: latest,
            fetchedAt: now
        )
    }

    /// 拉取 Statuspage.io status.json 并解析为 ServiceStatus;
    /// 任何网络 / 解码错误都抛出,调用方负责保留旧快照。
    static func fetch(from url: URL, components relevant: [String] = []) async throws -> ServiceStatus {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }
            struct Component: Decodable {
                let name: String
                let status: String
            }
            struct Page: Decodable {
                let updatedAt: Date?
                private enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
            }
            let page: Page?
            let status: Status
            let components: [Component]?
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }

        let payload = try decoder.decode(Response.self, from: data)
        let matched = (payload.components ?? []).filter { component in
            relevant.contains { component.name.lowercased().hasPrefix($0.lowercased()) }
        }
        guard !matched.isEmpty else {
            let indicator = ServiceStatusIndicator(rawValue: payload.status.indicator) ?? .unknown
            return ServiceStatus(indicator: indicator, description: payload.status.description,
                                 updatedAt: payload.page?.updatedAt, fetchedAt: Date())
        }
        let rank: [ServiceStatusIndicator: Int] = [.none: 0, .maintenance: 1, .minor: 2, .major: 3, .critical: 4]
        var worst: ServiceStatusIndicator = .none
        var affected: [String] = []
        for component in matched {
            let indicator: ServiceStatusIndicator
            switch component.status {
            case "operational": indicator = .none
            case "degraded_performance": indicator = .minor
            case "partial_outage": indicator = .major
            case "major_outage": indicator = .critical
            case "under_maintenance": indicator = .maintenance
            default: indicator = .unknown
            }
            if indicator != .none { affected.append(component.name) }
            if (rank[indicator] ?? 0) > (rank[worst] ?? 0) { worst = indicator }
        }
        return ServiceStatus(
            indicator: worst,
            description: affected.isEmpty ? worst.label : "\(worst.label): \(affected.joined(separator: ", "))",
            updatedAt: payload.page?.updatedAt,
            fetchedAt: Date()
        )
    }
}
