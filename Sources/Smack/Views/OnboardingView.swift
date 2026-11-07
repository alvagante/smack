import AppKit
import SwiftUI

/// Shows Onboarding in its own centered window, so changing the Window style does not rebuild the window it lives in.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let defaults: UserDefaults
    private var onDone: (() -> Void)?

    /// - Parameter onDone: Runs once after Finish, Skip or closing the window, with the choices already saved.
    init(store: MonitorStore, defaults: UserDefaults = .standard, onDone: @escaping () -> Void) {
        self.defaults = defaults
        self.onDone = onDone
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        var finish: (OnboardingChoices?) -> Void = { _ in }
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            choices: OnboardingChoices(settings: store.settingsStore.settings),
            finish: { finish($0) }
        ))
        finish = { [weak self, weak store] choices in
            if let choices, let store {
                store.settingsStore.update { choices.apply(to: &$0) }
                store.settingsChanged()
            }
            self?.complete(closing: true)
        }
        window.title = "Welcome to Smack"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        complete(closing: false)
    }

    private func complete(closing: Bool) {
        guard let onDone else { return }
        self.onDone = nil
        Onboarding.markDone(defaults)
        if closing { window.close() }
        // After the button action or close notification has unwound, since `onDone` releases this controller.
        DispatchQueue.main.async { onDone() }
    }
}

struct OnboardingView: View {
    @State var choices: OnboardingChoices
    /// Nil skips, keeping every Setting as it was.
    let finish: (OnboardingChoices?) -> Void

    private static let environmentPages: [SummaryPage] = [.projects, .devServers, .agents, .docker, .homebrew, .devEnvironments, .installedApps, .userHome]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Welcome to Smack").font(.title2.weight(.semibold))
                Text("A few choices to start with. Everything here can be changed later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 36)
            .padding([.horizontal, .bottom])

            Form {
                Section {
                    Picker("Window style", selection: $choices.windowStyle) {
                        ForEach(WindowStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if choices.windowStyle == .panel {
                        Picker("Open the Panel on", selection: $choices.trigger) {
                            ForEach(PanelTrigger.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Launch at login", isOn: $choices.launchAtLogin)
                } header: {
                    Text("Window")
                } footer: {
                    SettingsFooter(choices.windowStyle == .panel
                        ? "The Panel drops down from the menu-bar icon and hides when you move away or click elsewhere."
                        : "Smack opens as an ordinary window with a Dock icon; the menu-bar icon still brings it forward.")
                }

                Section {
                    Picker("Performance Preset", selection: $choices.preset) {
                        if choices.startedCustom { Text("Custom (keep current)").tag(nil as PerformancePreset?) }
                        ForEach(PerformancePreset.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    SettingsFooter(choices.preset?.summary ?? "Your current sampling and history Settings are kept as they are.")
                }

                if !Capabilities.isSandboxed {
                    Section {
                        FolderListRows(folders: $choices.projectFolders, addTitle: "Add Project Folder…", empty: "No project folders")
                    } header: {
                        Text("Project Folders")
                    } footer: {
                        SettingsFooter("Folders holding your Git repositories, such as ~/Developer or ~/src. Only directory entries and .git files are read, while Projects is visible, to the project scan depth.")
                    }

                    Section {
                        ForEach(Self.environmentPages) { page in
                            Toggle(page.rawValue, isOn: Binding(
                                get: { choices.shownPages.contains(page) },
                                set: { show in
                                    if show { choices.shownPages.insert(page) } else { choices.shownPages.remove(page) }
                                }
                            ))
                        }
                    } header: {
                        Text("Show on Summary")
                    } footer: {
                        SettingsFooter("A page that is off drops its Summary tile and stops its discovery and background work.")
                    }
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)

            HStack {
                Button("Skip") { finish(nil) }
                    .help("Keep every Setting as it is")
                Spacer()
                Button("Start Smack") { finish(choices) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
    }
}
