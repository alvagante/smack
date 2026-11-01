import Combine
import Foundation
import UserNotifications

enum AlertAuthorization: Sendable { case notDetermined, denied, authorized }

struct AlertNotification: Sendable {
    var title: String
    var body: String
    var ruleID: UUID?
}

protocol UserNotifying: Sendable {
    func authorizationStatus() async -> AlertAuthorization
    func requestAuthorization() async -> Bool
    func post(_ notification: AlertNotification) async throws
}

struct SystemUserNotifier: UserNotifying {
    func authorizationStatus() async -> AlertAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func post(_ notification: AlertNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = "SMACK_ALERT"
        if let id = notification.ruleID { content.userInfo["ruleID"] = id.uuidString }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@MainActor
final class AlertDispatcher: ObservableObject {
    var enabled = true {
        didSet {
            if !enabled {
                flushTask?.cancel(); flushTask = nil
                wakeAlerts.removeAll(); wakeUntil = nil
                overflow = 0; overflowDue = nil
            }
        }
    }
    @Published private(set) var authorization: AlertAuthorization = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published var pausedUntil: Date? {
        didSet { defaults?.set(pausedUntil, forKey: "smack.alerts.pausedUntil") }
    }
    @Published private(set) var lastFired: [UUID: Date] = [:]
    private let notifier: any UserNotifying
    private let defaults: UserDefaults?
    private(set) var deliverySnoozes: [UUID: Date] = [:]
    private var sent: [Date] = []
    @Published private(set) var cooldowns: [UUID: Date] = [:]
    private var overflow = 0
    private var overflowDue: Date?
    private var wakeUntil: Date?
    private var wakeAlerts: [UUID: FiredAlert] = [:]
    private var flushTask: Task<Void, Never>?
    var isTargetVisible: (AlertTarget?) -> Bool = { _ in false }
    var isRuleEnabled: (UUID) -> Bool = { _ in true }

    init(notifier: any UserNotifying, defaults: UserDefaults? = nil) {
        self.notifier = notifier
        self.defaults = defaults
        pausedUntil = defaults?.object(forKey: "smack.alerts.pausedUntil") as? Date
    }

    func prepare(rules: [AlertRule]) async {
        guard enabled else { return }
        await refreshAuthorization(request: rules.contains(where: \.enabled))
        let enabled = Set(rules.filter(\.enabled).map(\.id))
        wakeAlerts = wakeAlerts.filter { enabled.contains($0.key) }
        deliverySnoozes = deliverySnoozes.filter { id, until in rules.contains { $0.id == id } && until > Date() }
        for rule in rules where wakeAlerts[rule.id] != nil { wakeAlerts[rule.id]?.rule = rule }
    }

    private func refreshAuthorization(request: Bool) async {
        authorization = await notifier.authorizationStatus()
        if enabled, request, authorization == .notDetermined {
            _ = await notifier.requestAuthorization()
            authorization = await notifier.authorizationStatus()
        }
    }

    func snoozeDelivery(_ id: UUID, until: Date) { deliverySnoozes[id] = until }

    func noteWake(at: Date) { wakeUntil = at.addingTimeInterval(30) }

    private func suppression(_ alert: FiredAlert, now: Date) -> String? {
        if !enabled { return "disabled" }
        if let pausedUntil, pausedUntil > now { return "paused" }
        if let until = deliverySnoozes[alert.rule.id], until > now { return "snoozed" }
        if let until = alert.rule.snoozedUntil, until > now { return "snoozed" }
        if let last = cooldowns[alert.rule.id], now.timeIntervalSince(last) < alert.rule.cooldown { return "cooldown" }
        if isTargetVisible(alert.rule.target) { return "visible" }
        if authorization != .authorized { return "authorization" }
        return nil
    }

    func dispatch(_ alert: FiredAlert) async -> ActivityEvent {
        let now = alert.timestamp
        lastFired[alert.rule.id] = now
        var reason = suppression(alert, now: now)
        sent.removeAll { now.timeIntervalSince($0) >= 600 }
        if reason == nil, sent.count >= 10 {
            reason = "rateLimit"
            overflow += 1
            overflowDue = overflowDue ?? sent[0].addingTimeInterval(600)
            scheduleFlush()
        }
        if reason == nil, case .event = alert.rule.kind, let wakeUntil, now < wakeUntil {
            reason = "wakeCoalesced"
            if var queued = wakeAlerts[alert.rule.id] {
                queued.count += alert.count
                queued.subjects = Array((queued.subjects + alert.subjects).prefix(3))
                wakeAlerts[alert.rule.id] = queued
            } else { wakeAlerts[alert.rule.id] = alert }
            scheduleFlush()
        }
        if reason == nil {
            cooldowns[alert.rule.id] = now
            sent.append(now)
            do { try await notifier.post(.init(title: alert.rule.name, body: alert.body, ruleID: alert.rule.id)) }
            catch { reason = "deliveryFailed"; errorMessage = error.localizedDescription }
        }
        var details = alert.details
        details["ruleID"] = alert.rule.id.uuidString
        details["ruleName"] = alert.rule.name
        details["count"] = String(alert.count)
        if let reason { details["suppressed"] = reason }
        return .make(kind: .alertFired, timestamp: now, subject: alert.rule.name, severity: .warning,
                     details: details, dedupe: UUID().uuidString)
    }

    func flush(at now: Date) async {
        guard enabled else { return }
        sent.removeAll { now.timeIntervalSince($0) >= 600 }
        if let until = wakeUntil, now >= until {
            wakeUntil = nil
            let pending = Array(wakeAlerts.values)
            wakeAlerts.removeAll()
            for var alert in pending where isRuleEnabled(alert.rule.id) {
                alert.timestamp = now
                alert.rule.name = "Since wake: " + alert.rule.name
                _ = await dispatch(alert)
            }
        }
        if let due = overflowDue, now >= due {
            guard (pausedUntil ?? .distantPast) <= now, authorization == .authorized else { return }
            guard sent.count < 10 else {
                overflowDue = sent[0].addingTimeInterval(600)
                return
            }
            let count = overflow
            overflow = 0
            overflowDue = nil
            sent.append(now)
            do { try await notifier.post(.init(title: "\(count) more alerts", body: "Open the Timeline to review suppressed alerts.", ruleID: nil)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while let self, self.overflowDue != nil || !self.wakeAlerts.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self.flush(at: Date())
            }
            self?.flushTask = nil
        }
    }

    func test(_ rule: AlertRule) async {
        guard enabled else { return }
        await refreshAuthorization(request: true)
        guard enabled else { return }
        do { try await notifier.post(.init(title: rule.name, body: "Test alert from Smack", ruleID: rule.id)) }
        catch { errorMessage = error.localizedDescription }
    }
}
