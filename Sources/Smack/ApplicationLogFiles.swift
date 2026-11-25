import Foundation

enum ApplicationLogFiles {
    static let byteLimit = 128 * 1024
    static let fileLimit = 500

    static func discover(_ paths: [AggregatedPath], now: Date = Date(),
                         metadata: (String) -> (Int64, Date)? = fileMetadata) -> [AggregatedPath] {
        paths.lazy.filter { $0.path.localizedCaseInsensitiveContains("log") }.prefix(fileLimit).filter { row in
            guard let (size, modified) = metadata(row.path) else { return false }
            return size > 0 && modified >= now.addingTimeInterval(-7 * 86_400)
        }
    }

    static func fileMetadata(_ path: String) -> (Int64, Date)? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (Int64(size), modified)
    }

    static func read(_ path: String, files: any TranscriptFileAccess = LocalLogFileAccess()) throws -> String {
        guard let data = files.last(byteLimit, of: path) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
