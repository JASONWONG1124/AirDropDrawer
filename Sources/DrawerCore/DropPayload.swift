import Foundation

public enum DropPayload {
    public enum ValidationError: Error, LocalizedError, Equatable {
        case empty
        case remoteURL
        case missingFile
        case unreadableFile
        case notDownloaded

        public var errorDescription: String? {
            switch self {
            case .empty: return "没有可发送的文件"
            case .remoteURL: return "只支持本地文件"
            case .missingFile: return "文件不存在"
            case .unreadableFile: return "文件不可读取"
            case .notDownloaded: return "文件尚未下载完成"
            }
        }
    }

    public static func validate(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { throw ValidationError.empty }

        var result: [URL] = []
        var seen = Set<URL>()
        for url in urls {
            guard url.isFileURL,
                  url.host == nil || url.host?.isEmpty == true || url.host == "localhost"
            else { throw ValidationError.remoteURL }
            let fileURL = url.standardizedFileURL
            let validationURL = fileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: validationURL.path) else {
                throw ValidationError.missingFile
            }

            guard let values = try? validationURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ]) else { throw ValidationError.unreadableFile }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw ValidationError.unreadableFile
            }
            guard FileManager.default.isReadableFile(atPath: validationURL.path) else {
                throw ValidationError.unreadableFile
            }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus == .notDownloaded {
                throw ValidationError.notDownloaded
            }

            if seen.insert(fileURL).inserted {
                // Validate through the standardized path, but hand the caller the
                // original URL so AppKit receives the user's selected item.
                result.append(url)
            }
        }
        return result
    }
}
