import Foundation

/// 假媒体条目：S1 Spike 用，后续由 LibraryKit 的真实索引数据替换
public struct MediaItem: Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public let hue: Double
    public let isVideo: Bool
}

/// 按月分区的墙数据（新月份在前）
public struct MonthSection: Identifiable, Sendable {
    /// year*12+month，数值越大越新
    public let id: Int
    public let title: String
    public let items: [MediaItem]
}

public enum FakeMedia {
    /// 生成跨约 5 年的确定性假数据，按月分桶、月内按时间倒序
    public static func makeSections(count: Int, seed: UInt64 = 42) -> [MonthSection] {
        var rng = LCG(seed: seed)
        let now = Date().timeIntervalSince1970
        let span: Double = 60 * 366 * 24 * 3600
        let calendar = Calendar(identifier: .gregorian)

        var buckets: [Int: [MediaItem]] = [:]
        var monthTitles: [Int: String] = [:]
        var nextID = 0

        for _ in 0..<count {
            let date = Date(timeIntervalSince1970: now - Double.random(in: 0..<span, using: &rng))
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let year = comps.year, let month = comps.month else { continue }
            let key = year * 12 + month
            let item = MediaItem(
                id: nextID,
                date: date,
                hue: Double.random(in: 0..<1, using: &rng),
                isVideo: Double.random(in: 0..<1, using: &rng) < 0.15
            )
            nextID += 1
            buckets[key, default: []].append(item)
            if monthTitles[key] == nil {
                monthTitles[key] = "\(year)年\(month)月"
            }
        }

        return buckets
            .map { key, items in
                MonthSection(
                    id: key,
                    title: monthTitles[key] ?? "",
                    items: items.sorted { $0.date > $1.date }
                )
            }
            .sorted { $0.id > $1.id }
    }
}

/// 可复现的线性同余发生器，保证测试与演示数据稳定
private struct LCG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
