import SwiftUI

struct AlertsSettingsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var rules: AlertRuleStore
    @State private var runtime: [UUID: AlertRuntime] = [:]
    @State private var editing: AlertRule?

    var body: some View {
        Group {
            if let dispatcher = store.alertDispatcher { AlertDeliverySettings(dispatcher: dispatcher) }
            if let notice = rules.recoveryNotice {
                Section { Text(notice); Button("Dismiss") { rules.dismissRecoveryNotice() } }
            }
            if let error = rules.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            if rules.rules.contains(where: { $0.enabled && $0.backgroundWarning(store.settingsStore.settings) != nil }) {
                Section {
                    Text("Some alerts pause while the panel is hidden. Alerts require their collection loop to run.")
                    Button("Enable background collection") {
                        store.settingsStore.update {
                            $0.sampling.backgroundSystemInterval = $0.sampling.backgroundSystemInterval ?? 5
                            $0.sampling.backgroundProcessInterval = $0.sampling.backgroundProcessInterval ?? 5
                            $0.sampling.backgroundNetworkInterval = $0.sampling.backgroundNetworkInterval ?? 15
                        }
                        store.settingsChanged()
                    }
                }
            }
            Section {
                ForEach(rules.rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { enabled in
                                rules.update { items in
                                    if let i = items.firstIndex(where: { $0.id == rule.id }) { items[i].enabled = enabled }
                                }
                            })).disabled(rule.isUnknown)
                            Button("Edit") { editing = rule }.disabled(rule.isUnknown)
                            Button("Test") { Task { await store.alertDispatcher?.test(rule) } }.disabled(rule.isUnknown)
                        }
                        Text(status(rule)).font(.caption).foregroundStyle(.secondary)
                        if let last = store.alertDispatcher?.lastFired[rule.id] ?? runtime[rule.id]?.lastFired {
                            Text("Last fired: \(last.formatted())").font(.caption)
                        }
                    }
                }
                Menu("Add from template") {
                    ForEach(AlertRule.templates) { template in
                        Button(template.name) { rules.update { $0.append(template) } }
                    }
                }
            } footer: {
                Text("Event alerts evaluate before Timeline recording filters. Security templates require background posture checks or persistence monitoring.")
            }
        }
        .sheet(item: $editing) { rule in
            AlertRuleEditor(rule: rule, interval: rule.expectedInterval(store.settingsStore.settings)) { updated in
                rules.update { items in
                    if let i = items.firstIndex(where: { $0.id == updated.id }) { items[i] = updated }
                }
            }
        }
        .task(id: store.settingsStore.settings.automation.alertsEnabled) {
            guard store.settingsStore.settings.automation.alertsEnabled else { return }
            await store.alertDispatcher?.prepare(rules: rules.rules)
            while !Task.isCancelled {
                runtime = await store.alertRuntime()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func status(_ rule: AlertRule) -> String {
        if rule.isUnknown { return "Metric unavailable" }
        if !rule.enabled { return "Disabled" }
        if let until = store.alertDispatcher?.pausedUntil, until > Date() { return "Paused" }
        if let until = rule.snoozedUntil, until > Date() { return "Snoozed until " + until.formatted() }
        if let warning = rule.backgroundWarning(store.settingsStore.settings) { return warning }
        if let last = store.alertDispatcher?.cooldowns[rule.id], Date().timeIntervalSince(last) < rule.cooldown { return "Cooldown" }
        return runtime[rule.id]?.state ?? "Armed"
    }
}

private struct AlertDeliverySettings: View {
    @ObservedObject var dispatcher: AlertDispatcher
    var body: some View {
        Section {
            if let until = dispatcher.pausedUntil, until > Date() {
                Text(until == .distantFuture ? "Alerts paused indefinitely" : "Alerts paused until " + until.formatted())
                Button("Resume alerts") { dispatcher.pausedUntil = nil }
            } else {
                Menu("Pause alerts") {
                    Button("1 hour") { dispatcher.pausedUntil = Date().addingTimeInterval(3600) }
                    Button("Until tomorrow") { dispatcher.pausedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) }
                    Button("Indefinitely") { dispatcher.pausedUntil = .distantFuture }
                }
            }
            if dispatcher.authorization == .denied {
                Text("Notifications are off for Smack")
                Link("Open Notification Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
            if let error = dispatcher.errorMessage { Text(error).foregroundStyle(.red) }
        } header: { Text("Alert delivery") }
    }
}

private struct AlertRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: AlertRule
    let interval: TimeInterval
    var save: (AlertRule) -> Void

    var body: some View {
        VStack {
            Form {
                TextField("Name", text: $rule.name)
                TextField("Cooldown (seconds)", value: $rule.cooldown, format: .number)
                switch rule.kind {
                case let .systemThreshold(metric, comparison, value, sustain, clear):
                    Picker("Metric", selection: Binding(get: { metric }, set: { rule.kind = .systemThreshold(metric: $0, comparison: comparison, value: value, sustain: sustain, clear: clear) })) {
                        ForEach(SystemAlertMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    thresholdFields(comparison, value, sustain, clear) { c, v, s, cl in
                        rule.kind = .systemThreshold(metric: metric, comparison: c, value: v, sustain: s, clear: cl)
                    }
                case let .processThreshold(metric, matcher, comparison, value, sustain, clear):
                    Picker("Metric", selection: Binding(get: { metric }, set: { rule.kind = .processThreshold(metric: $0, matcher: matcher, comparison: comparison, value: value, sustain: sustain, clear: clear) })) {
                        ForEach(ProcessAlertMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Agent session roots only", isOn: Binding(get: { matcher.agentSessionRoot == true }, set: { enabled in
                        var updated = matcher; updated.agentSessionRoot = enabled ? true : nil
                        rule.kind = .processThreshold(metric: metric, matcher: updated, comparison: comparison, value: value, sustain: sustain, clear: clear)
                    }))
                    if metric == .uptime { Text("Uptime threshold is in seconds.") }
                    Toggle("Any process", isOn: matcherBinding(matcher, metric, comparison, value, sustain, clear, \.anyProcess))
                    TextField("Exact process name", text: matcherText(matcher, metric, comparison, value, sustain, clear, \.name))
                    TextField("Bundle identifier", text: matcherText(matcher, metric, comparison, value, sustain, clear, \.bundleIdentifier))
                    TextField("Executable path prefix", text: matcherText(matcher, metric, comparison, value, sustain, clear, \.executablePathPrefix))
                    if metric == .networkSendRate { Text("Visible only: requires process network sampling.") }
                    thresholdFields(comparison, value, sustain, clear) { c, v, s, cl in
                        rule.kind = .processThreshold(metric: metric, matcher: matcher, comparison: c, value: v, sustain: s, clear: cl)
                    }
                case let .event(kinds, severity, predicates):
                    ForEach(ActivityEventKind.allCases.filter { $0 != .alertFired }, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { kinds.contains(kind) }, set: { enabled in
                            var updated = kinds
                            if enabled { updated.insert(kind) } else { updated.remove(kind) }
                            rule.kind = .event(kinds: updated, minimumSeverity: severity, predicates: predicates)
                        }))
                    }
                    Picker("Minimum severity", selection: Binding(get: { severity }, set: { rule.kind = .event(kinds: kinds, minimumSeverity: $0, predicates: predicates) })) {
                        ForEach([ActivityEventSeverity.info, .notice, .warning], id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    ForEach(predicates.indices, id: \.self) { i in
                        TextField("Field", text: predicateBinding(i, \.field))
                        Picker("Operator", selection: predicateBinding(i, \.op)) {
                            ForEach(EventPredicate.Op.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Value", text: predicateBinding(i, \.value))
                    }
                    Button("Add predicate") {
                        rule.kind = .event(kinds: kinds, minimumSeverity: severity, predicates: predicates + [.init(field: "subject", op: .contains, value: "")])
                    }
                    Text("All predicates must match. Events evaluate even when their Timeline group is not recorded.")
                case .unknown: Text("Metric unavailable")
                }
                Text("Ratios: 0...1. CPU, battery and GPU: percent. Sizes: bytes. Rates: bytes/s. Pressure: 0...2. Thermal: 0...3.").font(.caption)
            }.formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Save") { rule.validate(); save(rule); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 580, height: 640)
    }

    private func predicateBinding<T>(_ i: Int, _ path: WritableKeyPath<EventPredicate, T>) -> Binding<T> {
        Binding(get: {
            guard case let .event(_, _, predicates) = rule.kind else { preconditionFailure() }
            return predicates[i][keyPath: path]
        }, set: { value in
            guard case let .event(kinds, severity, predicates) = rule.kind else { return }
            var updated = predicates
            updated[i][keyPath: path] = value
            rule.kind = .event(kinds: kinds, minimumSeverity: severity, predicates: updated)
        })
    }
    private func matcherBinding<T>(_ matcher: ProcessMatcher, _ metric: ProcessAlertMetric, _ c: Comparison, _ v: Double, _ s: Double, _ cl: Double?, _ path: WritableKeyPath<ProcessMatcher, T>) -> Binding<T> {
        Binding(get: { matcher[keyPath: path] }, set: { value in
            var updated = matcher; updated[keyPath: path] = value
            rule.kind = .processThreshold(metric: metric, matcher: updated, comparison: c, value: v, sustain: s, clear: cl)
        })
    }
    private func matcherText(_ matcher: ProcessMatcher, _ metric: ProcessAlertMetric, _ c: Comparison, _ v: Double, _ s: Double, _ cl: Double?, _ path: WritableKeyPath<ProcessMatcher, String?>) -> Binding<String> {
        let binding = matcherBinding(matcher, metric, c, v, s, cl, path)
        return Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
    @ViewBuilder private func thresholdFields(_ c: Comparison, _ v: Double, _ s: Double, _ cl: Double?, update: @escaping (Comparison, Double, Double, Double?) -> Void) -> some View {
        Picker("Comparison", selection: Binding(get: { c }, set: { update($0, v, s, cl) })) {
            ForEach(Comparison.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        TextField("Threshold", value: Binding(get: { v }, set: { update(c, $0, s, cl) }), format: .number)
        TextField("Sustain (seconds)", value: Binding(get: { s }, set: { update(c, v, $0, cl) }), format: .number)
        TextField("Clear duration (seconds)", value: Binding(get: { cl ?? s }, set: { update(c, v, s, $0) }), format: .number)
        Text("Effective minimum: two samples (at least \(Int(interval)) s at the configured cadence). Power-saving cadence can increase this.").font(.caption)
    }
}

extension AlertRule {
    var isUnknown: Bool { if case .unknown = kind { true } else { false } }
    func expectedInterval(_ settings: CollectionSettings) -> TimeInterval {
        switch kind {
        case .processThreshold: settings.sampling.backgroundProcessInterval ?? settings.sampling.liveRefreshSeconds
        default: settings.sampling.backgroundSystemInterval ?? settings.sampling.liveRefreshSeconds
        }
    }
    func backgroundWarning(_ settings: CollectionSettings) -> String? {
        switch kind {
        case .systemThreshold where settings.sampling.backgroundSystemInterval == nil: return "Paused while the panel is hidden"
        case .processThreshold where settings.sampling.backgroundProcessInterval == nil: return "Paused while the panel is hidden"
        case .event(let kinds, _, _) where kinds.contains(.listenerOpened) && settings.sampling.backgroundNetworkInterval == nil: return "Paused while the panel is hidden"
        default: return nil
        }
    }
}
