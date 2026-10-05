import Foundation
import Darwin
import DrawerCore

/// Keep any drag-provided access alive until the system finishes with the items.
/// A metadata/isReadableFile check alone doesn't request macOS Files & Folders
/// permission. Open the selected items before ShareKit's non-prompting preflight.
final class SharedFileAccess {
    let urls: [URL]
    private var scopedURLs: [URL] = []

    init(_ selectedURLs: [URL]) throws {
        var acquired: [URL] = []
        do {
            for url in selectedURLs where url.startAccessingSecurityScopedResource() {
                acquired.append(url)
            }
            let validated = try DropPayload.validate(selectedURLs)
            for url in validated {
                // FileHandle(forReadingFrom:) rejects directory URLs. Opening a
                // directory read-only checks access without listing its contents.
                let descriptor = url.withUnsafeFileSystemRepresentation { path in
                    path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
                }
                guard descriptor >= 0 else {
                    let code = errno
                    throw NSError(domain: NSCocoaErrorDomain,
                                  code: code == EACCES || code == EPERM ? NSFileReadNoPermissionError : NSFileReadUnknownError,
                                  userInfo: [NSFilePathErrorKey: url.path,
                                             NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
                }
                Darwin.close(descriptor)
            }
            urls = validated
            scopedURLs = acquired
        } catch {
            acquired.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func release() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    deinit { release() }
}
