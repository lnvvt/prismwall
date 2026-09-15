import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrismWallCore

/// 测试夹具：生成小 JPEG 与临时数据库
enum TestFixtures {
    @MainActor
    static func makeJPEG(
        directory: URL, name: String, width: Int = 120, height: Int = 80,
        hue: CGFloat = 0.3
    ) throws -> URL {
        // 直接经 ImageIO 写 JPEG，避免 NSImage 在 Retina 下 backing store 被放大
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "fixtures", code: 1) }
        context.setFillColor(
            NSColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw NSError(domain: "fixtures", code: 2) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "fixtures", code: 3)
        }
        return url
    }

    static func makeRepository() throws -> (MediaRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismwall-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try Database(path: directory.appendingPathComponent("test.sqlite").path)
        let repository = MediaRepository(database: database)
        try repository.migrate()
        return (repository, directory)
    }
}

final class DatabaseTests: XCTestCase {
    func testRoundtripAndTransactionRollback() throws {
        let (repository, _) = try TestFixtures.makeRepository()
        let id = try repository.insertSource(path: "/tmp/demo", bookmark: nil)
        XCTAssertGreaterThan(id, 0)
        XCTAssertEqual(try repository.listSources().count, 1)

        // 事务回滚：upsertBatch 内部任一步失败不应留下半截数据
        let record = MediaRecord(
            sourceId: id, relPath: "a.jpg", filename: "a.jpg", ext: "jpg",
            kind: .photo, takenAt: nil, fsModifiedAt: Date(), fsSize: 1,
            durationMs: nil, width: 10, height: 10, camera: nil, lens: nil, envColor: 1
        )
        try repository.upsertBatch(adds: [record], updates: [], removeIds: [])
        XCTAssertEqual(try repository.mediaCount(), 1)
    }
}

final class ScannerTests: XCTestCase {
    @MainActor
    func testScanCreatesPhotoRecords() async throws {
        let (repository, directory) = try TestFixtures.makeRepository()
        for (index, hue) in [CGFloat(0.1), 0.5, 0.8].enumerated() {
            _ = try TestFixtures.makeJPEG(
                directory: directory, name: "photo\(index).jpg", hue: hue
            )
        }
        try "not media".write(
            to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8
        )

        let source = SourceRecord(
            id: try repository.insertSource(path: directory.path, bookmark: nil),
            path: directory.path, bookmark: nil, state: "online", createdAt: Date()
        )
        try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }

        let records = try repository.allMedia()
        XCTAssertEqual(records.count, 3, "txt 不应入库，3 张照片应入库")
        XCTAssertTrue(records.allSatisfy { $0.kind == .photo })
        XCTAssertTrue(records.allSatisfy { $0.width == 120 && $0.height == 80 })
        XCTAssertTrue(records.allSatisfy { $0.envColor != nil }, "环境主色应已计算")
    }

    /// 回归：/tmp 符号链接导致 relPath 切偏（l-media 事故）
    @MainActor
    func testScanThroughSymlinkedRootProducesCleanRelPaths() async throws {
        let (repository, realDirectory) = try TestFixtures.makeRepository()
        _ = try TestFixtures.makeJPEG(directory: realDirectory, name: "real.jpg")

        let linkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismwall-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: linkDirectory, withDestinationURL: realDirectory
        )
        defer { try? FileManager.default.removeItem(at: linkDirectory) }

        let source = SourceRecord(
            id: try repository.insertSource(path: linkDirectory.path, bookmark: nil),
            path: linkDirectory.path, bookmark: nil, state: "online", createdAt: Date()
        )
        try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }

        let records = try repository.allMedia()
        XCTAssertEqual(records.map(\.relPath), ["real.jpg"], "经符号链接根扫描的相对路径必须干净")
    }

    @MainActor
    func testIncrementalDiff() async throws {        let (repository, directory) = try TestFixtures.makeRepository()
        let urlA = try TestFixtures.makeJPEG(directory: directory, name: "a.jpg")
        _ = try TestFixtures.makeJPEG(directory: directory, name: "b.jpg")

        let source = SourceRecord(
            id: try repository.insertSource(path: directory.path, bookmark: nil),
            path: directory.path, bookmark: nil, state: "online", createdAt: Date()
        )
        try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }
        XCTAssertEqual(try repository.mediaCount(), 2)

        // 新增 c.jpg、修改 a.jpg 的 mtime、删除 b.jpg
        _ = try TestFixtures.makeJPEG(directory: directory, name: "c.jpg", hue: 0.9)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(50)], ofItemAtPath: urlA.path
        )
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.jpg"))

        try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }

        let records = try repository.allMedia()
        XCTAssertEqual(records.count, 2, "应为 a.jpg + c.jpg")
        XCTAssertEqual(Set(records.map(\.filename)), ["a.jpg", "c.jpg"])
    }
}

final class WallSectionTests: XCTestCase {
    func testBuildSectionsGroupsByMonthNewestFirst() {
        let calendar = Calendar.current
        func record(_ filename: String, date: Date) -> MediaRecord {
            MediaRecord(
                id: Int64(filename.hashValue.magnitude % 1000), sourceId: 1,
                relPath: filename, filename: filename, ext: "jpg", kind: .photo,
                takenAt: date, fsModifiedAt: date, fsSize: 1, durationMs: nil,
                width: 10, height: 10, camera: nil, lens: nil, envColor: nil
            )
        }
        let older = calendar.date(from: DateComponents(year: 2025, month: 3, day: 10))!
        let newer1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let newer2 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20))!
        let records = [
            record("old.jpg", date: older),
            record("n1.jpg", date: newer1),
            record("n2.jpg", date: newer2),
        ]
        let sections = LibraryStore.buildSections(
            from: records, sourcePaths: [1: "/tmp/src"]
        )
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.first?.title, "2026年9月")
        XCTAssertEqual(sections.first?.items.count, 2)
        XCTAssertEqual(sections.last?.title, "2025年3月")
        // 月内按时间倒序
        XCTAssertEqual(sections.first?.items.map(\.filename), ["n2.jpg", "n1.jpg"])
    }
}

final class ScanSafetyTests: XCTestCase {
    /// B-1：来源根目录不可读时必须抛错，绝不能当空目录清空索引
    @MainActor
    func testScanThrowsWhenRootUnreadable() async throws {
        let (repository, directory) = try TestFixtures.makeRepository()
        let missing = directory.appendingPathComponent("does-not-exist")
        let source = SourceRecord(
            id: try repository.insertSource(path: missing.path, bookmark: nil),
            path: missing.path, bookmark: nil, state: "online", createdAt: Date()
        )
        do {
            try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }
            XCTFail("不可读来源应抛 rootUnreadable")
        } catch let error as SourceScanner.ScanError {
            guard case .rootUnreadable = error else {
                return XCTFail("应为 rootUnreadable，实际：\(error)")
            }
        }
        XCTAssertTrue(try repository.allMedia().isEmpty)
    }

    /// B-1 保险丝：磁盘文件全没了但库里有存量 → 抛 sourceOffline 且索引原样保留
    @MainActor
    func testOfflineFusePreservesIndexWhenFolderEmptied() async throws {
        let (repository, directory) = try TestFixtures.makeRepository()
        for index in 0..<2 {
            _ = try TestFixtures.makeJPEG(directory: directory, name: "p\(index).jpg")
        }
        let source = SourceRecord(
            id: try repository.insertSource(path: directory.path, bookmark: nil),
            path: directory.path, bookmark: nil, state: "online", createdAt: Date()
        )
        try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }
        XCTAssertEqual(try repository.mediaCount(), 2)

        // 模拟盘掉线/权限丢失：目录变空
        for index in 0..<2 {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("p\(index).jpg"))
        }

        do {
            try await SourceScanner.scan(source: source, repository: repository) { _, _ in } onBatch: { _ in }
            XCTFail("空目录+有存量应抛 sourceOffline")
        } catch let error as SourceScanner.ScanError {
            guard case .sourceOffline = error else {
                return XCTFail("应为 sourceOffline，实际：\(error)")
            }
        }
        XCTAssertEqual(try repository.mediaCount(), 2, "保险丝必须保住存量索引")
    }
}
