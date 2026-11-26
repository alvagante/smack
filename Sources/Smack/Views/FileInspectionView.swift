import AppKit
import SwiftUI

struct FileInspectionView<Actions: View>: View {
    let item: HomeEntry?
    let preview: HomePreview?
    let inspecting: Bool
    var quickLookURL: URL? = nil
    @ViewBuilder var actions: Actions
    @AppStorage(FileContentsScrollView<EmptyView>.wrapKey) private var wrap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item {
                Text(item.url.path).font(.headline.monospaced()).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    WrapToggle(wrap: $wrap)
                    actions
                }.controlSize(.small)
                FileContentsScrollView(wrap: wrap) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let info = preview?.info { HomeFileInfoView(info: info) }
                        Divider()
                        if let quickLookURL {
                            DocumentQuickLookView(url: quickLookURL).frame(height: 400)
                        } else if inspecting {
                            ProgressView(item.isDirectory ? "Listing folder…" : "Reading contents…")
                        } else if let preview {
                            if let message = preview.message {
                                Text(message).font(.callout).foregroundStyle(.secondary)
                            }
                            Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: !wrap, vertical: false)
                        }
                    }
                }
            } else {
                Text("Select a file or folder to show its details.").foregroundStyle(.secondary)
                Spacer()
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
