import Foundation

struct PublicResetRecord: Codable, Equatable, Identifiable {
    struct Scope: Codable, Equatable { let plans: [String]; let windows: [String] }
    struct Source: Codable, Equatable { let url: String? }
    let id: String
    let kind: String
    let resetType: String
    let announcedAt: String?
    let effectiveAt: String?
    let completedAt: String?
    let confidence: Double?
    let scope: Scope?
    let source: Source

    var date: Date? {
        [effectiveAt, completedAt, announcedAt].compactMap { $0 }.compactMap(publicResetDate).first
    }
    var isCompleted: Bool {
        !id.isEmpty && kind == "reset_completed" && ["global", "banked", "global_and_banked"].contains(resetType)
    }
    var title: String {
        switch resetType {
        case "banked": return cabLocalized("检测到 Codex 重置卡发放公告")
        case "global_and_banked": return cabLocalized("检测到 Codex 全局重置与重置卡公告")
        default: return cabLocalized("检测到 Codex 全局重置公告")
        }
    }
    var plans: String {
        guard let plans = scope?.plans, !plans.isEmpty, !plans.contains("unknown") else { return cabLocalized("适用套餐未明确") }
        return plans.contains("all") ? cabLocalized("全部套餐") : plans.joined(separator: " · ")
    }
    var sourceURL: URL? {
        guard let raw = source.url, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              ["x.com", "twitter.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }
}

func publicResetOccurredToday(_ record: PublicResetRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard let date = record.date else { return false }
    return calendar.isDate(date, inSameDayAs: now)
}

func publicResetDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

struct PublicResetSnapshot: Equatable {
    let records: [PublicResetRecord]
    let generatedAt: Date

    func isFresh(at now: Date) -> Bool {
        (-300...3600).contains(now.timeIntervalSince(generatedAt))
    }
}

struct PublicResetCheckpoint: Codable, Equatable {
    var initializedAt: Date?
    var seenIDs: [String] = []

    func alerts(in snapshot: PublicResetSnapshot, now: Date) -> [PublicResetRecord] {
        guard initializedAt != nil, snapshot.isFresh(at: now) else { return [] }
        var seen = Set(seenIDs)
        return snapshot.records.filter { record in
            guard record.isCompleted, let date = record.date, date <= now,
                  date >= now.addingTimeInterval(-86400) else { return false }
            return seen.insert(record.id).inserted
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    mutating func markSeen(_ records: [PublicResetRecord], now: Date) {
        if initializedAt == nil { initializedAt = now }
        for record in records where !seenIDs.contains(record.id) { seenIDs.append(record.id) }
        seenIDs = Array(seenIDs.suffix(512))
    }
}

enum PublicResetFeedError: LocalizedError {
    case invalidResponse
    case http(Int)
    case rateLimited(TimeInterval)
    case stale

    var errorDescription: String? {
        switch self {
        case .rateLimited: return cabLocalized("重置信号服务限流，稍后自动重试。")
        case .stale: return cabLocalized("重置信号数据较旧，等待来源更新。")
        default: return cabLocalized("暂时无法更新重置信号，保留上次状态。")
        }
    }
}

struct PublicResetFeedClient {
    static let endpoint = URL(string: "https://didcodexreset.com/openapi/v1/records?kind=reset_completed&page=1&pageSize=10")!
    // An ephemeral, cookie-free session never attaches local Codex credentials.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func fetch() async throws -> PublicResetSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PublicResetFeedError.invalidResponse }
        return try Self.decode(data, response: response)
    }

    static func decode(_ data: Data, response: HTTPURLResponse, now: Date = Date()) throws -> PublicResetSnapshot {
        if response.statusCode == 429 {
            let body = try? JSONDecoder().decode(RateLimitResponse.self, from: data)
            let header = response.value(forHTTPHeaderField: "Retry-After")
            let seconds = header.flatMap(Double.init) ?? header.flatMap { value -> Double? in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                return formatter.date(from: value)?.timeIntervalSince(now)
            }
            let candidates = [seconds, body?.retryAfter].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
            throw PublicResetFeedError.rateLimited(max(300, candidates.max() ?? 300))
        }
        guard response.statusCode == 200 else { throw PublicResetFeedError.http(response.statusCode) }
        guard data.count <= 2_000_000 else { throw PublicResetFeedError.invalidResponse }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw PublicResetFeedError.invalidResponse }
        guard envelope.ok, let generated = publicResetDate(envelope.meta.generatedAt), envelope.data.items.count <= 10 else {
            throw PublicResetFeedError.invalidResponse
        }
        return PublicResetSnapshot(records: envelope.data.items.filter(\.isCompleted), generatedAt: generated)
    }

    private struct Envelope: Decodable {
        struct Page: Decodable { let items: [PublicResetRecord] }
        struct Meta: Decodable { let generatedAt: String }
        let ok: Bool
        let data: Page
        let meta: Meta
    }
    private struct RateLimitResponse: Decodable { let retryAfter: Double? }
}
