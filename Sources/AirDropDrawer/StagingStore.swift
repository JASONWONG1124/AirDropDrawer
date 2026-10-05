import AppKit
import DrawerCore
import Darwin

/// Session-only references. Neither entries nor file contents are persisted.
@MainActor final class StagingStore {
    struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        static func read(_ url: URL) throws -> Identity {
            var value = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &value) } ?? -1
            }
            guard result == 0 else { throw DropPayload.ValidationError.missingFile }
            return Identity(device: value.st_dev, inode: value.st_ino)
        }
    }

    final class Entry {
        let id = UUID()
        var url: URL
        let identity: Identity
        let bookmark: Data?
        let access: SharedFileAccess
        var failure: String?
        init(url: URL, access: SharedFileAccess) throws {
            self.url = url
            self.access = access
            identity = try Identity.read(url)
            bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        func resolve() throws -> URL {
            do {
                var stale = false
                // No UI and no automatic mounting. Never substitute a different file at the old path.
                if let bookmark,
                   let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                           relativeTo: nil, bookmarkDataIsStale: &stale),
                   (try? Identity.read(resolved)) == identity {
                    url = (resolved as NSURL).filePathURL ?? resolved
                }
                guard try Identity.read(url) == identity else { throw DropPayload.ValidationError.missingFile }
                _ = try DropPayload.validate([url])
                failure = nil
                return url
            } catch {
                failure = "文件不可用，请重新拖入"
                throw error
            }
        }
    }

    private(set) var entries: [Entry] = []
    private var cleared: [Entry] = []
    private var undoTimer: Timer?
    var onChange: (() -> Void)?
    var canUndo: Bool { !cleared.isEmpty }

    @discardableResult func add(_ urls: [URL]) throws -> Int {
        // Acquire and validate the entire batch before committing anything.
        let batchAccess = try SharedFileAccess(urls)
        let candidates = try batchAccess.urls.map { url in
            try Entry(url: url, access: SharedFileAccess([url]))
        }
        var identities = entries.map(\.identity)
        var additions: [Entry] = []
        for candidate in candidates where !identities.contains(candidate.identity) {
            additions.append(candidate)
            identities.append(candidate.identity)
        }
        entries.append(contentsOf: additions)
        onChange?()
        return additions.count
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        onChange?()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        undoTimer?.invalidate()
        cleared = entries
        entries = []
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cleared = []
                self?.onChange?()
            }
        }
        onChange?()
    }

    func undoClear() {
        undoTimer?.invalidate()
        let ids = entries.map(\.identity)
        entries = cleared.filter { !ids.contains($0.identity) } + entries
        cleared = []
        onChange?()
    }

    func reset() {
        undoTimer?.invalidate()
        undoTimer = nil
        cleared = []
        entries = []
        onChange?()
    }
}
