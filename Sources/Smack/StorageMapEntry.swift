import Foundation
import SmackIPC

struct StorageMapEntry: Identifiable {
    var id: String
    var name: String
    var path: String?
    var bytes: UInt64
    var files: UInt64
    var colorIndex: Int

    static func entries(directory: StorageDirectory, children: [StorageDirectory]) -> [Self] {
        var entries = children.prefix(12).enumerated().map { index, child in
            Self(id: child.path, name: child.name, path: child.path, bytes: child.bytes, files: child.files, colorIndex: index)
        }
        let remaining = children.dropFirst(12)
        if !remaining.isEmpty {
            entries.append(Self(id: "other", name: "Other folders", bytes: remaining.reduce(0) { $0 + $1.bytes },
                                files: remaining.reduce(0) { $0 + $1.files }, colorIndex: 6))
        }
        if directory.directFiles > 0 {
            entries.append(Self(id: "files", name: "Files here", bytes: directory.directBytes, files: directory.directFiles, colorIndex: 7))
        }
        return entries.filter { $0.bytes > 0 }
    }

    struct Tile: Identifiable {
        var id: String { entry.id }
        var entry: StorageMapEntry
        var rect: CGRect
    }

    /// Balanced binary partition keeps areas proportional while avoiding long, thin strips.
    static func layout(_ entries: [Self], in rect: CGRect) -> [Tile] {
        guard !entries.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        if entries.count == 1 { return [Tile(entry: entries[0], rect: rect)] }
        let total = entries.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return [] }
        var split = 1
        var left = Double(entries[0].bytes)
        while split < entries.count - 1, left + Double(entries[split].bytes) / 2 < total / 2 {
            left += Double(entries[split].bytes)
            split += 1
        }
        let fraction = left / total
        let first: CGRect
        let second: CGRect
        if rect.width >= rect.height {
            let width = rect.width * fraction
            first = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            second = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            let height = rect.height * fraction
            first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            second = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }
        return layout(Array(entries.prefix(split)), in: first) + layout(Array(entries.dropFirst(split)), in: second)
    }
}
