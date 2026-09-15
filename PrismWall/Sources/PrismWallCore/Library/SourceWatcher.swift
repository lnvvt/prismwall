import Foundation

/// 来源文件监听：vnode（DispatchSource）监听来源根目录 fd，事件防抖 1s 后回调
/// 所有状态只在自身串行队列上触碰（S4 实测：沙盒内 vnode 延迟 5-10ms，FSEvents 不可用）
final class SourceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.prismwall.watcher", qos: .utility)
    private var sources: [Int64: DispatchSourceFileSystemObject] = [:]
    private var debounce: [Int64: DispatchWorkItem] = [:]

    func watch(sourceId: Int64, path: String, onChange: @escaping @MainActor (Int64) -> Void) {
        queue.async { [weak self] in
            guard let self, self.sources[sourceId] == nil else { return }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            let stream = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: self.queue
            )
            stream.setEventHandler { [weak self] in
                guard let self else { return }
                self.debounce[sourceId]?.cancel()
                let item = DispatchWorkItem {
                    Task { @MainActor in onChange(sourceId) }
                }
                self.debounce[sourceId] = item
                self.queue.asyncAfter(deadline: .now() + 1.0, execute: item)
            }
            stream.setCancelHandler { close(fd) }
            stream.resume()
            self.sources[sourceId] = stream
        }
    }

    func unwatch(sourceId: Int64) {
        queue.async { [weak self] in
            self?.sources[sourceId]?.cancel()
            self?.sources[sourceId] = nil
            self?.debounce[sourceId]?.cancel()
            self?.debounce[sourceId] = nil
        }
    }

    func unwatchAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, stream) in self.sources {
                stream.cancel()
            }
            self.sources.removeAll()
            for (_, item) in self.debounce {
                item.cancel()
            }
            self.debounce.removeAll()
        }
    }
}
