import Foundation
import Darwin

/// 来源扫描：枚举 → diff → 元数据提取 → 批量入库（边扫边上墙）
enum SourceScanner {
    enum ScanError: LocalizedError {
        /// 枚举器创建失败：目录不存在/无读取权限（沙盒书签失效、外置盘掉线等）。
        /// 绝不能当成"空目录"做删除对账，否则会清空该来源全部索引
        case rootUnreadable(path: String)
        /// 对账保险丝：磁盘一个受支持文件都读不到，但库里有存量索引。
        /// 宁可跳过清理也不能把收藏/播放进度陪葬
        case sourceOffline(existing: Int)
        /// 批量入库失败（磁盘满/库损坏），N 个批次未能落库
        case writeFailures(Int)

        var errorDescription: String? {
            switch self {
            case .rootUnreadable(let path):
                return "来源目录不可读（\(path)）。若为外接盘请重新挂载，沙盒授权失效请在应用内重新添加"
            case .sourceOffline(let existing):
                return "来源当前读不到任何媒体文件，已保留库中 \(existing) 条索引（未做删除对账）"
            case .writeFailures(let count):
                return "\(count) 个批次写入数据库失败"
            }
        }
    }

    /// 解析符号链接（/tmp → /private/tmp 等）。
    /// URL/NSString 的 resolvingSymlinksInPath 对 /tmp 实测不解析（macOS 26），
    /// 而 FileManager 枚举返回的是解析后的路径，两端必须一致否则 relPath 切偏
    static func resolvedRoot(_ path: String) -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        if realpath(path, &buffer) != nil {
            return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    struct Candidate {
        let url: URL
        let relPath: String
        let filename: String
        let ext: String
        let modifiedAt: Date
        let size: Int64
    }

    struct Batch {
        var adds: [MediaRecord] = []
        var updates: [MediaRecord] = []
        var removeIds: [Int64] = []
    }

    static func candidates(under root: URL) throws -> [String: Candidate] {
        var result: [String: Candidate] = [:]
        // 前置体检：目录必须存在、是目录、且可读。缺失时 Foundation 的
        // enumerator 也会返回非 nil（静默空迭代），单靠 nil 判断根本拦不住——
        // 这条不抛错，增量对账就会把库中该来源的索引全部判为"已消失"而清空
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path)
        else {
            throw ScanError.rootUnreadable(path: root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.rootUnreadable(path: root.path)
        }

        var visited = 0
        for case let fileURL as URL in enumerator {
            // 大目录枚举耗时，提供取消检查点
            if visited & 0x3FF == 0 { try Task.checkCancellation() }
            visited += 1
            let ext = fileURL.pathExtension.lowercased()
            guard MetadataReader.kind(forExtension: ext) != .unsupported else { continue }
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
            ])
            guard values?.isRegularFile == true else { continue }
            let relPath = String(fileURL.path.dropFirst(root.path.count + 1))
            result[relPath] = Candidate(
                url: fileURL,
                relPath: relPath,
                filename: fileURL.lastPathComponent,
                ext: ext,
                modifiedAt: values?.contentModificationDate ?? Date(),
                size: Int64(values?.fileSize ?? 0)
            )
        }
        return result
    }

    /// 增量扫描：与 DB 对账后只处理新增/变更，删除已消失文件；每批回调入库并上墙。
    /// force = true 时强制重提全部文件元数据（重新索引用），缓存按 mtime 自动失效
    static func scan(
        source: SourceRecord,
        repository: MediaRepository,
        force: Bool = false,
        batchSize: Int = 200,
        progress: @escaping @MainActor (Int, Int) -> Void,
        onBatch: @escaping @MainActor (Batch) -> Void
    ) async throws {
        try Task.checkCancellation()
        let root = Self.resolvedRoot(source.path)
        // FileManager 枚举返回的是解析符号链接后的路径（如 /private/tmp），
        // 相对路径必须基于同样解析过的根计算，否则切偏（/tmp 符号链接事故）
        let current = try candidates(under: root)
        let existing = try repository.mediaIndex(sourceId: source.id)

        var toAdd: [Candidate] = []
        var toUpdate: [Candidate] = []
        for (relPath, candidate) in current.sorted(by: { $0.key < $1.key }) {
            if let old = existing[relPath] {
                if force || old.mtime != candidate.modifiedAt || old.size != candidate.size {
                    toUpdate.append(candidate)
                }
            } else {
                toAdd.append(candidate)
            }
        }
        // 对账保险丝：磁盘上一个受支持文件都找不到，但库里有存量索引 →
        // 判定来源离线，跳过删除对账（收藏/播放进度不能陪葬）。
        // 真要清空该来源：移除来源或重置媒体库
        if current.isEmpty && !existing.isEmpty {
            throw ScanError.sourceOffline(existing: existing.count)
        }
        let removedIds = existing.compactMap { relPath, old -> Int64? in
            current[relPath] == nil ? old.id : nil
        }

        let total = toAdd.count + toUpdate.count + removedIds.count
        await progress(0, max(total, 1))

        var batch = Batch()
        batch.removeIds = removedIds
        var processed = 0
        var writeFailures = 0

        func flush() async {
            guard !batch.adds.isEmpty || !batch.updates.isEmpty || !batch.removeIds.isEmpty else { return }
            let snapshot = batch
            batch = Batch()
            do {
                try repository.upsertBatch(
                    adds: snapshot.adds, updates: snapshot.updates, removeIds: snapshot.removeIds
                )
            } catch {
                // S-1：写库失败不再静默——计数并在扫描结束时上报（磁盘满/库损坏征兆）
                writeFailures += 1
                PWLog.scan.error("批量入库失败（累计 \(writeFailures) 批）：\(error.localizedDescription, privacy: .public)")
            }
            await onBatch(snapshot)
        }

        // 照片：ImageIO 同步提取（本函数整体运行在后台任务中）
        let photoCandidates = toAdd.filter { MetadataReader.kind(forExtension: $0.ext) == .photo }
        for candidate in photoCandidates {
            try Task.checkCancellation() // S-2：取消检查点
            let info = MetadataReader.photoInfo(at: candidate.url)
            let color = await MetadataReader.dominantColor(at: candidate.url, kind: .photo)
            batch.adds.append(makePhotoRecord(
                from: candidate, info: info, color: color, sourceId: source.id
            ))
            processed += 1
            if processed % batchSize == 0 {
                await progress(processed, max(total, 1))
                await flush()
            }
        }

        // 视频：AVFoundation 异步提取，限制并发 4
        let videoCandidates = toAdd.filter { MetadataReader.kind(forExtension: $0.ext) == .video }
        for chunk in videoCandidates.chunked(into: 4) {
            try Task.checkCancellation() // S-2：取消检查点
            let results = await withTaskGroup(
                of: (Candidate, MetadataReader.VideoInfo, Int64?).self
            ) { group -> [(Candidate, MetadataReader.VideoInfo, Int64?)] in
                for candidate in chunk {
                    group.addTask {
                        let info = await MetadataReader.videoInfo(at: candidate.url)
                        // Nit2：一次 480px 解码同时取主色与缩略图并落盘，浏览时零解码
                        let derived = await MetadataReader.videoFrameWithColor(url: candidate.url)
                        if let frame = derived.frame {
                            await ThumbnailService.shared.storeDiskThumbnail(
                                frame, fileURL: candidate.url,
                                fsModifiedAt: candidate.modifiedAt
                            )
                        }
                        return (candidate, info, derived.color)
                    }
                }
                var out: [(Candidate, MetadataReader.VideoInfo, Int64?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (candidate, info, color) in results {
                batch.adds.append(MediaRecord(
                    sourceId: source.id,
                    relPath: candidate.relPath,
                    filename: candidate.filename,
                    ext: candidate.ext,
                    kind: .video,
                    takenAt: info.takenAt ?? candidate.modifiedAt,
                    fsModifiedAt: candidate.modifiedAt,
                    fsSize: candidate.size,
                    durationMs: info.durationMs,
                    width: info.width,
                    height: info.height,
                    camera: nil,
                    lens: nil,
                    envColor: color
                ))
                processed += 1
            }
            await progress(processed, max(total, 1))
            await flush()
        }

        // 变更文件：mtime/size 变了就重提元数据
        for candidate in toUpdate {
            try Task.checkCancellation() // S-2：取消检查点
            let kind = MetadataReader.kind(forExtension: candidate.ext)
            let oldId = existing[candidate.relPath]?.id ?? 0
            let record: MediaRecord
            switch kind {
            case .photo:
                let info = MetadataReader.photoInfo(at: candidate.url)
                let color = await MetadataReader.dominantColor(at: candidate.url, kind: .photo)
                record = makePhotoRecord(
                    from: candidate, info: info, color: color, sourceId: source.id, id: oldId
                )
            case .video:
                let info = await MetadataReader.videoInfo(at: candidate.url)
                let derived = await MetadataReader.videoFrameWithColor(url: candidate.url)
                let color = derived.color
                if let frame = derived.frame {
                    await ThumbnailService.shared.storeDiskThumbnail(
                        frame, fileURL: candidate.url,
                        fsModifiedAt: candidate.modifiedAt
                    )
                }
                record = MediaRecord(
                    id: oldId, sourceId: source.id, relPath: candidate.relPath,
                    filename: candidate.filename, ext: candidate.ext, kind: kind,
                    takenAt: info.takenAt ?? candidate.modifiedAt,
                    fsModifiedAt: candidate.modifiedAt, fsSize: candidate.size,
                    durationMs: info.durationMs, width: info.width, height: info.height,
                    camera: nil, lens: nil, envColor: color
                )
            case .unsupported:
                continue
            }
            batch.updates.append(record)
            processed += 1
            if processed % batchSize == 0 {
                await progress(processed, max(total, 1))
                await flush()
            }
        }

        await progress(processed, max(total, 1))
        await flush()
        // S-1：有批次写库失败则上抛，由调用方在界面上给出可感知的失败提示
        if writeFailures > 0 {
            throw ScanError.writeFailures(writeFailures)
        }
    }

    private static func makePhotoRecord(
        from candidate: Candidate, info: MetadataReader.PhotoInfo, color: Int64?,
        sourceId: Int64, id: Int64 = 0
    ) -> MediaRecord {
        MediaRecord(
            id: id, sourceId: sourceId, relPath: candidate.relPath,
            filename: candidate.filename, ext: candidate.ext, kind: .photo,
            takenAt: info.takenAt, fsModifiedAt: candidate.modifiedAt, fsSize: candidate.size,
            durationMs: nil, width: info.width, height: info.height,
            camera: info.camera, lens: info.lens, envColor: color
        )
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
