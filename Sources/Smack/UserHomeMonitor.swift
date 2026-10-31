import Foundation
import Darwin

enum HomeCategory: String, CaseIterable, Identifiable, Sendable {
    case dotfiles = "Dotfiles and home files"
    case config = "XDG configuration"
    case preferences = "Preferences"
    case applicationSupport = "Application support"
    case launchAgents = "Launch agents"
    case containers = "App containers"
    case groupContainers = "Group containers"
    case library = "User Library"
    var id: String { rawValue }

    func directory(home: URL, environment: [String: String]) -> URL {
        switch self {
        case .dotfiles: home
        case .config:
            if let path = environment["XDG_CONFIG_HOME"], path.hasPrefix("/") {
                URL(fileURLWithPath: path, isDirectory: true)
            } else { home.appendingPathComponent(".config", isDirectory: true) }
        case .preferences: home.appendingPathComponent("Library/Preferences", isDirectory: true)
        case .applicationSupport: home.appendingPathComponent("Library/Application Support", isDirectory: true)
        case .launchAgents: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        case .containers: home.appendingPathComponent("Library/Containers", isDirectory: true)
        case .groupContainers: home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        case .library: home.appendingPathComponent("Library", isDirectory: true)
        }
    }
}

struct HomeEntry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let bytes: Int64?
    let modified: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct HomeListing: Sendable {
    var entries: [HomeEntry] = []
    var error: String?
    var warning: String?
}

struct HomePreview: Sendable {
    var text = ""
    var message: String?
    var info: HomeFileInfo?
}

/// The fields `stat(1)` reports for a path, read with lstat so links describe themselves.
struct HomeFileInfo: Sendable {
    var path: String
    var type: String
    var mode: String
    var octal: String
    var owner: String
    var group: String
    var links: UInt64
    var bytes: Int64
    var blocks: Int64
    var blockSize: Int32
    var inode: UInt64
    var device: String
    var flags: String
    var accessed: Date
    var modified: Date
    var changed: Date
    var created: Date
    var linkTarget: String?
}

enum HomeDirectory {
    static func names(_ url: URL, limit: Int = 5_000) throws -> (names: [String], truncated: Bool) {
        guard let stream = opendir(url.path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(stream) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= deadline { return (names, true) }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return (names, false)
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < limit else { return (names, true) }
            names.append(name)
        }
    }
}

enum HomeStat {
    static func info(_ url: URL) throws -> HomeFileInfo {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let target = (st.st_mode & S_IFMT) == S_IFLNK
            ? try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
        let flags = st.st_flags == 0 ? "-" : (fflagstostr(UInt(st.st_flags)).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? String(st.st_flags, radix: 16))
        return HomeFileInfo(
            path: url.path, type: typeName(st.st_mode), mode: modeString(st.st_mode),
            octal: String(format: "%04o", st.st_mode & 0o7777),
            owner: "\(userName(st.st_uid)) (\(st.st_uid))", group: "\(groupName(st.st_gid)) (\(st.st_gid))",
            links: UInt64(st.st_nlink), bytes: st.st_size, blocks: st.st_blocks, blockSize: st.st_blksize,
            inode: st.st_ino, device: "\(major(st.st_dev)),\(minor(st.st_dev))", flags: flags,
            accessed: date(st.st_atimespec), modified: date(st.st_mtimespec),
            changed: date(st.st_ctimespec), created: date(st.st_birthtimespec), linkTarget: target)
    }

    /// Mirrors `ls -la`: dot entries, a total in 512-byte blocks, and aligned long-format rows.
    static func longListing(_ directory: URL, limit: Int = 5_000) -> HomePreview {
        let scan: (names: [String], truncated: Bool)
        do { scan = try HomeDirectory.names(directory) }
        catch { return HomePreview(message: error.localizedDescription) }
        let all = [".", ".."] + scan.names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let shown = all.prefix(limit)
        var total: Int64 = 0
        var rows: [[String]] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var users: [uid_t: String] = [:]
        var groups: [gid_t: String] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var timedOut = false
        for name in shown {
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
            guard !Task.isCancelled else { return HomePreview(message: "Listing cancelled.") }
            let path = directory.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0 else { rows.append(["?---------", "?", "?", "?", "?", "", name]); continue }
            total += st.st_blocks
            var mode = modeString(st.st_mode)
            if listxattr(path, nil, 0, XATTR_NOFOLLOW) > 0 { mode += "@" }
            else if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); mode += "+" }
            var label = name
            if (st.st_mode & S_IFMT) == S_IFLNK, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                label += " -> " + target
            }
            let kind = st.st_mode & S_IFMT
            let size = kind == S_IFCHR || kind == S_IFBLK
                ? String(format: "%#x", UInt32(bitPattern: st.st_rdev)) : String(st.st_size)
            if users[st.st_uid] == nil { users[st.st_uid] = userName(st.st_uid) }
            if groups[st.st_gid] == nil { groups[st.st_gid] = groupName(st.st_gid) }
            rows.append([mode, String(st.st_nlink), users[st.st_uid]!, groups[st.st_gid]!, size,
                         lsDate(date(st.st_mtimespec), formatter: formatter), label])
        }
        let widths = (0..<6).map { column in rows.map { $0[column].count }.max() ?? 0 }
        let lines = rows.map { row in
            // ls always reserves the eleventh mode column for the @ and + markers.
            [row[0].padding(toLength: max(11, widths[0]), withPad: " ", startingAt: 0),
             String(repeating: " ", count: widths[1] - row[1].count) + row[1],
             row[2].padding(toLength: widths[2], withPad: " ", startingAt: 0) + " ",
             row[3].padding(toLength: widths[3], withPad: " ", startingAt: 0) + " ",
             String(repeating: " ", count: widths[4] - row[4].count) + row[4],
             row[5], row[6]].joined(separator: " ")
        }
        let message = scan.truncated || timedOut ? "Directory scan limited to 5,000 entries or one second; listing is incomplete." : all.count > limit ? "Showing the first \(limit) of \(all.count) entries." : nil
        return HomePreview(text: (["total \(total)"] + lines).joined(separator: "\n"), message: message)
    }

    static func modeString(_ mode: mode_t) -> String {
        let type: Character = switch mode & S_IFMT {
        case S_IFDIR: "d"
        case S_IFLNK: "l"
        case S_IFCHR: "c"
        case S_IFBLK: "b"
        case S_IFIFO: "p"
        case S_IFSOCK: "s"
        default: "-"
        }
        func triplet(_ shift: mode_t, special: mode_t, set: Character, unset: Character) -> String {
            let bits = (mode >> shift) & 7
            let execute: Character = mode & special != 0
                ? (bits & 1 != 0 ? set : unset) : (bits & 1 != 0 ? "x" : "-")
            return String([bits & 4 != 0 ? "r" : "-", bits & 2 != 0 ? "w" : "-", execute])
        }
        return String(type) + triplet(6, special: S_ISUID, set: "s", unset: "S")
            + triplet(3, special: S_ISGID, set: "s", unset: "S") + triplet(0, special: S_ISVTX, set: "t", unset: "T")
    }

    private static func typeName(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: "Directory"
        case S_IFLNK: "Symbolic link"
        case S_IFCHR: "Character special file"
        case S_IFBLK: "Block special file"
        case S_IFIFO: "Fifo file"
        case S_IFSOCK: "Socket"
        default: "Regular file"
        }
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    private static func lsDate(_ date: Date, formatter: DateFormatter) -> String {
        formatter.dateFormat = "MMM"
        let month = formatter.string(from: date)
        let dayNumber = String(Calendar.current.component(.day, from: date))
        let day = String(repeating: " ", count: 2 - dayNumber.count) + dayNumber
        // ls shows the time within six months ((365 / 2) * 86400 integer seconds), otherwise the year.
        formatter.dateFormat = abs(date.timeIntervalSinceNow) < 15_724_800 ? "HH:mm" : " yyyy"
        return "\(month) \(day) \(formatter.string(from: date))"
    }

    private static func userName(_ uid: uid_t) -> String {
        var entry = passwd(), result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil else { return String(uid) }
        return String(cString: entry.pw_name)
    }

    private static func groupName(_ gid: gid_t) -> String {
        var entry = group(), result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getgrgid_r(gid, &entry, &buffer, buffer.count, &result) == 0, result != nil else { return String(gid) }
        return String(cString: entry.gr_name)
    }

    private static func major(_ device: dev_t) -> Int32 { (device >> 24) & 0xff }
    private static func minor(_ device: dev_t) -> Int32 { device & 0xffffff }
}

struct UserHomeCollector: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var environment = ProcessInfo.processInfo.environment
    static let previewLimit = 1_048_576

    /// Stat details plus contents: a long listing for directories (links followed), file text otherwise.
    func details(_ url: URL) -> HomePreview {
        var isDirectory: ObjCBool = false
        var value = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? HomeStat.longListing(url) : preview(url)
        do { value.info = try HomeStat.info(url) }
        catch { value.message = value.message ?? error.localizedDescription }
        return value
    }

    func list(category: HomeCategory, directory: URL) -> HomeListing {
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let scan = try HomeDirectory.names(directory)
            let urls = scan.names.map { directory.appendingPathComponent($0) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            var timedOut = false
            let entries = try urls.compactMap { url -> HomeEntry? in
                guard ProcessInfo.processInfo.systemUptime < deadline else { timedOut = true; return nil }
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                // Resolve directory links for navigation, but retain their original paths and identities.
                let directory = values.isSymbolicLink == true
                    ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    : values.isDirectory == true
                return HomeEntry(url: url, isDirectory: directory, isSymbolicLink: values.isSymbolicLink == true,
                                 bytes: values.fileSize.map(Int64.init), modified: values.contentModificationDate)
            }.filter {
                category != .dotfiles || directory.standardizedFileURL != home.standardizedFileURL ||
                    $0.name.hasPrefix(".") || !$0.isDirectory
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return HomeListing(entries: entries, warning: scan.truncated || timedOut ? "Directory scan limited to 5,000 entries or one second; listing is incomplete." : nil)
        } catch { return HomeListing(error: error.localizedDescription) }
    }

    func preview(_ url: URL) -> HomePreview {
        // Nonblocking open plus fstat prevents a FIFO or device from hanging a preview.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return HomePreview(message: String(cString: strerror(errno))) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return HomePreview(message: String(cString: strerror(errno))) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return HomePreview(message: "Only regular files can be previewed.")
        }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.read(upToCount: Self.previewLimit + 1) ?? Data()
            guard data.count <= Self.previewLimit else {
                return HomePreview(message: "Preview unavailable: file exceeds the 1 MiB limit.")
            }
            // Binary object graphs can expand far beyond their encoded size during conversion.
            if data.starts(with: Data("bplist".utf8)) {
                return HomePreview(message: "Binary property list preview is unavailable. Reveal the file to open it with another app.")
            }
            if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
                return HomePreview(text: text, message: text.isEmpty ? "Empty file." : nil)
            }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
               let text = String(data: data, encoding: .utf16), !text.contains("\0") {
                return HomePreview(text: text)
            }
            return HomePreview(message: "Binary or unsupported text encoding. Reveal the file to open it with another app.")
        } catch { return HomePreview(message: error.localizedDescription) }
    }
}

@MainActor
final class UserHomeMonitor: ObservableObject {
    @Published private(set) var listing = HomeListing()
    @Published private(set) var preview: HomePreview?
    @Published private(set) var loading = false
    @Published private(set) var inspecting = false
    private var listingGeneration = 0
    private var previewGeneration = 0
    let collector: UserHomeCollector

    init(collector: UserHomeCollector = UserHomeCollector()) { self.collector = collector }

    func directory(for category: HomeCategory) -> URL {
        category.directory(home: collector.home, environment: collector.environment)
    }

    func load(category: HomeCategory, directory: URL) async {
        listingGeneration += 1
        let generation = listingGeneration
        loading = true
        listing = HomeListing()
        clearPreview()
        let collector = collector
        let worker = Task.detached(priority: .utility) { collector.list(category: category, directory: directory) }
        let value = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard generation == listingGeneration else { return }
        loading = false
        guard !Task.isCancelled else { return }
        listing = value
    }

    func clearPreview() {
        previewGeneration += 1
        preview = nil
        inspecting = false
    }

    func inspect(_ url: URL) async {
        clearPreview()
        let generation = previewGeneration
        inspecting = true
        let collector = collector
        let worker = Task.detached(priority: .utility) { collector.details(url) }
        let value = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard generation == previewGeneration else { return }
        inspecting = false
        guard !Task.isCancelled else { return }
        preview = value
    }
}
