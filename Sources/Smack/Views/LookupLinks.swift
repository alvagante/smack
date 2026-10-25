import AppKit
import SwiftUI

/// Icons opening third-party pages about a public remote address. Always occupies the same width,
/// so addresses line up whether or not the row has lookups (local addresses have none).
struct IPLookupLinks: View {
    static let width: CGFloat = 130
    let host: String

    var body: some View {
        HStack(spacing: 8) {
            if let address = IPLookup.publicAddress(host) {
                ForEach(IPLookup.services(for: address)) { service in
                    if let url = service.url(for: address) {
                        Link(destination: url) {
                            Image(systemName: service.systemImage)
                        }
                        .hoverHint("\(service.id): \(service.summary)")
                        .accessibilityLabel("Look up \(address) on \(service.id)")
                    }
                }
            }
        }
        .font(.caption)
        .frame(width: Self.width, alignment: .leading)
    }
}

/// Reveal in Finder, a Google search for the file or its bundle, and a VirusTotal lookup by SHA-256 (only the hash leaves the Mac).
/// Open files skip the on-render check: a stat() on a stale network volume must not block the UI,
/// and hashing re-checks the type off the main thread anyway.
struct FileLookupLinks: View {
    static let width: CGFloat = 64
    let path: String
    var checksFileOnDisk = true

    var body: some View {
        HStack(spacing: 8) {
            if path.hasPrefix("/"), !checksFileOnDisk || FileLookup.isRegularFile(path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .hoverHint("Reveal in Finder")
                .accessibilityLabel("Reveal \(path) in Finder")
                if let url = FileLookup.googleURL(for: path) {
                    Link(destination: url) {
                        Image(systemName: "magnifyingglass")
                    }
                    .hoverHint("Google: search for \"\(FileLookup.searchTerm(for: path))\" macOS")
                    .accessibilityLabel("Search Google for \(FileLookup.searchTerm(for: path))")
                }
                Button(action: lookUpHash) {
                    Image(systemName: "shield.lefthalf.filled")
                }
                .hoverHint("VirusTotal: security vendor verdicts for this file's SHA-256 (the file is not uploaded)")
                .accessibilityLabel("Look up \(path) on VirusTotal")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .frame(width: Self.width, alignment: .leading)
    }

    private func lookUpHash() {
        let path = path
        Task {
            let digest = await Task.detached(priority: .userInitiated) { FileLookup.sha256(ofFileAt: path) }.value
            if let digest, let url = FileLookup.virusTotalURL(sha256: digest) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

@MainActor
private final class HoverHintState: ObservableObject {
    @Published var isPresented = false
    private var pending: Task<Void, Never>?

    func hover(_ inside: Bool) {
        pending?.cancel()
        guard inside else {
            isPresented = false
            return
        }
        // A short delay keeps popovers from flashing while the pointer sweeps across a row of icons.
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isPresented = true
        }
    }
}

/// Smack's panel never becomes key, and AppKit only shows `.help` tooltips for the active app,
/// so hints are drawn as a popover instead.
private struct HoverHint: ViewModifier {
    let text: String
    @StateObject private var state = HoverHintState()

    func body(content: Content) -> some View {
        content
            .onHover { state.hover($0) }
            .popover(isPresented: $state.isPresented, arrowEdge: .top) {
                Text(text)
                    .font(.caption)
                    .fixedSize()
                    .padding(8)
            }
    }
}

extension View {
    func hoverHint(_ text: String) -> some View {
        modifier(HoverHint(text: text))
    }
}
