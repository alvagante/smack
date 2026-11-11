import SwiftUI

struct DocumentsSummaryTile: View {
    @ObservedObject var model: DocumentsModel
    var open: () -> Void
    var openDocument: (String) -> Void
    @Environment(\.summaryArranging) private var arranging

    @Environment(\.summaryTileSize) private var tileSize

    private var headline: String {
        if model.loading { return "Finding files…" }
        if model.listing.error != nil { return "Unavailable" }
        guard model.checkedAt != nil else { return "Explore documents" }
        let count = model.listing.entries.count
        return "\(count) \(count == 1 ? "file" : "files")"
    }

    private var caption: String {
        if model.listing.error != nil { return "Open Documents to retry discovery" }
        guard let checked = model.checkedAt else { return "Open Documents to find recently modified files" }
        return "Last inventory · checked " + Formatting.relative(checked)
    }

    var body: some View {
        let recent = Array(model.listing.entries.prefix(tileSize.rowLimit))
        SummaryTile(route: .documents, headline: headline, caption: caption,
                    interactiveVisual: !recent.isEmpty, open: open) {
            if !recent.isEmpty {
                VStack(spacing: 8) {
                    ForEach(recent) { file in
                        Button {
                            guard !arranging else { return }
                            openDocument(file.path)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: DocumentFileType.systemImage(path: file.path, contentType: file.contentType))
                                    .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                                Text(file.name).font(.caption.weight(.medium))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if tileSize != .square, let modified = file.modified {
                                    Text(Formatting.relative(modified)).font(.caption2).foregroundStyle(.secondary).fixedSize()
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(file.path)
                        .accessibilityLabel("Open document details for " + file.name)
                    }
                }
                if model.listing.warning != nil {
                    Text("Limited sample").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
