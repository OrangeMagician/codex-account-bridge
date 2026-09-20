import Foundation
import SwiftUI
import Testing
@testable import CABDesktop

@Suite("Token activity dates and rendering")
struct TokenActivityTests {
    private func report() -> TokenUsageReport {
        TokenUsageReport(fetchedAt: Date(), totalTokens: 140, maxDailyTokens: 100, activeDays: 2,
                         currentStreak: 1, longestStreak: 1, threadCount: 2,
                         daily: [.init(date: "2026-09-20", tokens: 100, threads: 1),
                                 .init(date: "2026-09-19", tokens: 40, threads: 1)])
    }

    @Test func latestDayIsVisibleInLastWeekAndFutureCellsAreEmpty() {
        let days = TokenActivityData.days(report(), now: TokenActivityData.date("2026-09-20")!)
        #expect(days.count == 371)
        #expect(days[364].id == "2026-09-20")
        #expect(days[364].tokens == 100)
        #expect(days[365...].allSatisfy { $0.isFuture && $0.tokens == 0 })
        #expect(TokenActivityData.calendar.component(.weekday, from: days[0].date) == 1)
    }

    @Test func duplicateRowsAndLeapDatesDoNotCrashOrShiftDays() {
        var usage = report()
        usage = TokenUsageReport(fetchedAt: usage.fetchedAt, totalTokens: 140, maxDailyTokens: 140,
                                activeDays: 1, currentStreak: 1, longestStreak: 1, threadCount: 2,
                                daily: [.init(date: "2024-02-29", tokens: 100, threads: 1),
                                        .init(date: "2024-02-29", tokens: 40, threads: 1)])
        let days = TokenActivityData.days(usage, now: TokenActivityData.date("2024-03-01")!)
        #expect(days.first { $0.id == "2024-02-29" }?.tokens == 140)
        #expect(TokenActivityData.date("2026-02-29") == nil)
        #expect(TokenActivityData.level(1, maximum: 9_000_000_000) > 0)
        #expect(TokenActivityData.level(0, maximum: 1) == 0)
    }

    // Opt-in export of the actual SwiftUI view, used for visual review when
    // native computer control is unavailable. This is not a mock HTML layout.
    @Test @MainActor func exportVisualReview() throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_TOKEN_RENDER_DIR"] else { return }
        var usage = report()
        if let input = ProcessInfo.processInfo.environment["CAB_TOKEN_RENDER_REPORT"] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return try #require(formatter.date(from: value))
            }
            usage = try decoder.decode(TokenUsageReport.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [360, 620, 900] {
            for dark in [false, true] {
                let view = TokenUsageDetails(report: usage).padding(16)
                    .frame(width: CGFloat(width)).background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                _ = NSApplication.shared
                let hosting = NSHostingView(rootView: view)
                let size = hosting.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tokens-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
