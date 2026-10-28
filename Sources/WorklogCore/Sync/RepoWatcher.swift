import CoreServices
import Foundation

/// Watches each repo's git dir with FSEvents and reports ref/HEAD changes, debounced.
public final class RepoWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "worklog.repo-watcher")
    private var streams: [Int64: (stream: FSEventStreamRef, gitDir: String)] = [:]
    private var pending: [Int64: DispatchWorkItem] = [:]
    private let debounce: TimeInterval
    private let onChange: @Sendable (Int64) -> Void

    public init(debounce: TimeInterval = 1.5, onChange: @escaping @Sendable (Int64) -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        for (_, entry) in streams { Self.stop(entry.stream) }
    }

    /// Replaces the watched set with `repos` (repoId → absolute git dir).
    public func update(_ repos: [Int64: String]) {
        queue.async { [self] in
            for (id, entry) in streams where repos[id] != entry.gitDir {
                Self.stop(entry.stream)
                streams[id] = nil
            }
            for (id, dir) in repos where streams[id] == nil {
                if let stream = makeStream(repoId: id, gitDir: dir) { streams[id] = (stream, dir) }
            }
        }
    }

    fileprivate func handle(repoId: Int64, paths: [String]) {
        guard paths.contains(where: Self.isRelevant) else { return }
        pending[repoId]?.cancel()
        let onChange = self.onChange
        let item = DispatchWorkItem { onChange(repoId) }
        pending[repoId] = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    static func isRelevant(_ path: String) -> Bool {
        if path.contains("/objects/") { return false }
        return path.hasSuffix("/HEAD") || path.hasSuffix("/packed-refs") || path.contains("/refs/") || path.contains("/logs/")
    }

    private func makeStream(repoId: Int64, gitDir: String) -> FSEventStreamRef? {
        let box = StreamBox(watcher: self, repoId: repoId)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<StreamBox>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let list = (0..<count).compactMap { array[$0] as? String }
            box.watcher?.handle(repoId: box.repoId, paths: list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [gitDir] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return stream
    }

    private static func stop(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

private final class StreamBox {
    weak var watcher: RepoWatcher?
    let repoId: Int64

    init(watcher: RepoWatcher, repoId: Int64) {
        self.watcher = watcher
        self.repoId = repoId
    }
}
