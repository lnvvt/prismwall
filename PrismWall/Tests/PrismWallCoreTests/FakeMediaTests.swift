import XCTest
@testable import PrismWallCore

final class FakeMediaTests: XCTestCase {
    func testTotalCountMatchesRequested() {
        let sections = FakeMedia.makeSections(count: 10_000)
        XCTAssertEqual(sections.reduce(0) { $0 + $1.items.count }, 10_000)
    }

    func testSectionsNewestFirstAndItemsSortedWithinSection() {
        let sections = FakeMedia.makeSections(count: 5_000)
        for (newer, older) in zip(sections, sections.dropFirst()) {
            XCTAssertGreaterThanOrEqual(newer.id, older.id)
        }
        for section in sections {
            let dates = section.items.map(\.date)
            XCTAssertEqual(dates, dates.sorted(by: >), "月内条目应按时间倒序：\(section.title)")
        }
    }

    func testSameSeedProducesSameSections() {
        let a = FakeMedia.makeSections(count: 1_000)
        let b = FakeMedia.makeSections(count: 1_000)
        XCTAssertEqual(a.map(\.title), b.map(\.title))
        XCTAssertEqual(
            a.map { $0.items.map(\.id) },
            b.map { $0.items.map(\.id) }
        )
    }
}
