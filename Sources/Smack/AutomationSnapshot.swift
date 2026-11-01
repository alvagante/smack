import Foundation
import SmackIPC

/// The transport owns cancellation, including when it stops consuming after a socket error.
struct ControlSubscription: Sendable {
    let responses: AsyncThrowingStream<ControlResponse, Error>
    let cancel: @Sendable () -> Void

    init(_ build: (AsyncThrowingStream<ControlResponse, Error>.Continuation) -> Void) {
        let (stream, continuation) = AsyncThrowingStream<ControlResponse, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        responses = stream
        cancel = { continuation.finish() }
        build(continuation)
    }
}

/// Projects only already collected values. Never invokes collectors or process inspection.
@MainActor
enum AutomationSnapshot {
    static var startedAt = Date()
    static weak var store: MonitorStore?
    static var openURL: ((URL) -> Void)?

    static func response(_ request: ControlRequest) -> ControlResponse {
        guard request.version == ControlProtocol.version else {
            return ControlResponse(error: .unsupportedVersion, requestedVersion: request.version)
        }
        guard (try? request.validate()) != nil else { return ControlResponse(error: .invalidRequest) }
        guard let store else { return ControlResponse(error: .unavailable) }
        var records: [ControlRecord]
        switch request.op {
        case "status":
            guard let s = store.system else { return ControlResponse(error: .unavailable) }
            records = [ControlRecord(id: "system", title: "System Status", fields: [
                "timestamp": s.timestamp.ISO8601Format(), "flavor": Capabilities.flavor.rawValue,
                "cpuPercent": s.cpu.hasUsage ? String(s.cpu.totalUsage) : "unavailable", "memoryUsedBytes": String(s.memory.usedBytes),
                "memoryTotalBytes": String(s.memory.totalBytes), "pressure": s.memory.pressure.rawValue,
                "swapUsedBytes": String(s.memory.swapUsedBytes), "thermal": s.thermalCondition.rawValue,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appUptimeSeconds": String(Date().timeIntervalSince(startedAt)),
                "systemUptimeSeconds": String(ProcessInfo.processInfo.systemUptime),
                "batteryPercent": s.battery?.chargePercent.map(String.init(describing:)) ?? "unavailable",
                "onBattery": s.battery?.isOnBattery.map(String.init(describing:)) ?? "unavailable",
                "startupDiskFreeBytes": s.volumes.first { $0.mountPath == "/" }.map { String($0.availableBytes) } ?? "unavailable",
                "helper": store.privilegedSampling.map { String(describing: $0.state) } ?? "unavailable",
                "alertsPausedUntil": store.alertDispatcher?.pausedUntil?.ISO8601Format() ?? "",
                "notificationAuthorization": store.alertDispatcher.map { String(describing: $0.authorization) } ?? "unavailable"]) ]
        case "ps":
            guard let snapshot = store.processes else { return ControlResponse(error: .unavailable) }
            let processes = snapshot.applications.filter {
                request.app == nil || $0.bundleIdentifier == request.app || $0.name == request.app
            }.flatMap(\.processes) + (request.app == nil ? snapshot.backgroundProcesses : [])
            records = processes.sorted {
                request.sort == "memory" ? $0.memoryBytes > $1.memoryBytes : $0.cpuUsage > $1.cpuUsage
            }.prefix(request.limit).map {
                ControlRecord(id: $0.id, title: $0.name, fields: ["pid": String($0.identity.pid),
                    "cpuPercent": String($0.cpuUsage), "memoryBytes": String($0.memoryBytes),
                    "timestamp": snapshot.timestamp.ISO8601Format(),
                    "startTime": $0.identity.startTime.ISO8601Format(), "user": $0.userName ?? "unknown",
                    "bundleIdentifier": $0.bundleIdentifier ?? "", "diskReadRate": String($0.diskReadRate),
                    "diskWriteRate": String($0.diskWriteRate), "wakeupsPerSecond": String($0.wakeupsPerSecond)])
            }
        case "apps":
            guard let snapshot = store.processes else { return ControlResponse(error: .unavailable) }
            records = snapshot.applications.prefix(request.limit).map {
                ControlRecord(id: $0.id, title: $0.name, fields: ["cpuPercent": String($0.cpuUsage),
                    "memoryBytes": String($0.memoryBytes), "bundleIdentifier": $0.bundleIdentifier ?? ""])
            }
        case "ports":
            guard Capabilities.supportsNetworkPortInspection, let snapshot = store.networkPorts else {
                return ControlResponse(error: .unavailable)
            }
            records = snapshot.ports.filter { request.port == nil || Int($0.port) == request.port }.prefix(request.limit).map {
                ControlRecord(id: $0.id, title: $0.processName, fields: ["port": String($0.port),
                    "pid": String($0.pid), "address": $0.localAddress, "scope": $0.scope.rawValue,
                    "clientCount": String($0.clients.count),
                    "clients": String(decoding: (try? JSONEncoder().encode($0.clients.map {
                        ["remoteHost": $0.remoteHost, "remotePort": String($0.remotePort), "state": $0.state]
                    })) ?? Data("[]".utf8), as: UTF8.self), "protocol": $0.protocolName, "timestamp": snapshot.timestamp.ISO8601Format()])
            }
        case "events":
            records = store.recentEvents.prefix(request.limit).map {
                ControlRecord(id: $0.id, title: $0.subject, fields: ["kind": $0.kind.rawValue,
                    "timestamp": $0.timestamp.ISO8601Format(), "severity": $0.severity.rawValue])
            }
        case "alerts":
            guard request.action == nil else { return ControlResponse(error: .invalidRequest) }
            records = store.alertRules.rules.prefix(request.limit).map {
                ControlRecord(id: $0.id.uuidString, title: $0.name, fields: ["enabled": String($0.enabled)])
            }
        case "open":
            guard store.settingsStore.settings.urlNavigationEnabled else { return ControlResponse(error: .unavailable) }
            guard let text = request.url, let url = URL(string: text), url.scheme == "smack",
                  let openURL else { return ControlResponse(error: .invalidRequest) }
            openURL(url); records = []
        case "startup":
            guard let inventory = store.startupItemsModel.inventory else { return ControlResponse(error: .unavailable) }
            return startupResponse(inventory, limit: request.limit)
        case "posture":
            guard let snapshot = store.posture else { return ControlResponse(error: .unavailable) }
            var response = ControlResponse(records: snapshot.checks.prefix(request.limit).map {
                ControlRecord(id: $0.id, title: $0.summary, fields: ["status": $0.status.rawValue,
                    "area": $0.area.rawValue, "reason": $0.reason ?? "", "timestamp": snapshot.timestamp.ISO8601Format()])
            })
            response.metadata = ["timestamp": snapshot.timestamp.ISO8601Format()]
            return response
        case "history": return ControlResponse(error: .unavailable)
        default: return ControlResponse(error: .unsupportedOperation)
        }
        return ControlResponse(records: records)
    }
    static func startupResponse(_ inventory: StartupInventory, limit: Int) -> ControlResponse {
        let coverage = ["timestamp": inventory.timestamp.ISO8601Format(),
            "includedCategories": inventory.includedCategories.map(\.rawValue).sorted().joined(separator: ","),
            "includesBackgroundTasks": String(inventory.includesBackgroundTasks)]
        var response = ControlResponse(records: inventory.items.prefix(limit).map {
            ControlRecord(id: $0.id, title: $0.name, fields: coverage.merging([
                "category": $0.category.rawValue, "enabled": String($0.isEnabled),
                "path": $0.path ?? "", "program": $0.program ?? ""]) { _, new in new })
        })
        response.metadata = coverage
        return response
    }

    static func query(_ request: ControlRequest) async -> ControlResponse {
        guard request.version == ControlProtocol.version else {
            return ControlResponse(error: .unsupportedVersion, requestedVersion: request.version)
        }
        do { try request.validate() } catch { return ControlResponse(error: .invalidRequest) }
        guard let store else { return ControlResponse(error: .unavailable) }
        if request.op == "events" || request.op == "history" {
            let end = request.until.map(Date.init(timeIntervalSince1970:)) ?? Date()
            let start = request.since.map(Date.init(timeIntervalSince1970:)) ?? end.addingTimeInterval(-3600)
            guard end.timeIntervalSince(start) <= 31 * 86400 else { return ControlResponse(error: .invalidRequest) }
            do {
                if request.op == "events" {
                    let kinds = try eventKinds(request)
                    let events = try await store.loadEvents(from: start, to: end, kinds: kinds,
                                                           search: request.search ?? "", limit: request.limit)
                    return ControlResponse(records: events.map(eventRecord))
                }
                guard let name = request.metric, let metric = SystemMetric(rawValue: name) else {
                    return ControlResponse(error: .invalidRequest)
                }
                let points = try await store.history.controlSeries(metric, from: start, to: end,
                    resolution: request.resolution ?? 60, limit: request.limit)
                return ControlResponse(records: points.map {
                    ControlRecord(id: $0.timestamp.ISO8601Format(), title: name, fields: [
                        "timestamp": $0.timestamp.ISO8601Format(), "average": String($0.average),
                        "peak": String($0.peak), "resolutionSeconds": String(request.resolution ?? 60)])
                })
            } catch let error as ControlError { return ControlResponse(error: error) }
            catch { return ControlResponse(error: .unavailable) }
        }
        if request.op == "alerts" {
            guard let dispatcher = store.alertDispatcher else { return ControlResponse(error: .unavailable) }
            switch request.action {
            case "pause": dispatcher.pausedUntil = request.duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
            case "resume": dispatcher.pausedUntil = nil
            case "snooze":
                guard let id = request.ruleID.flatMap(UUID.init(uuidString:)),
                      store.alertRules.rules.contains(where: { $0.id == id }), let duration = request.duration else {
                    return ControlResponse(error: .invalidRequest)
                }
                dispatcher.snoozeDelivery(id, until: Date().addingTimeInterval(duration))
            case nil: break
            default: return ControlResponse(error: .invalidRequest)
            }
            let runtime = await store.alertRuntime()
            return ControlResponse(records: store.alertRules.rules.prefix(request.limit).map {
                ControlRecord(id: $0.id.uuidString, title: $0.name, fields: [
                    "enabled": String($0.enabled), "evaluationEnabled": String(store.settingsStore.settings.alertsEnabled),
                    "state": !store.settingsStore.settings.alertsEnabled ? "Disabled" : runtime[$0.id]?.state ?? ($0.enabled ? "Armed" : "Disabled"),
                    "lastFired": dispatcher.lastFired[$0.id]?.ISO8601Format() ?? "",
                    "deliverySnoozedUntil": (dispatcher.deliverySnoozes[$0.id] ?? $0.snoozedUntil)?.ISO8601Format() ?? "",
                    "pausedUntil": dispatcher.pausedUntil?.ISO8601Format() ?? ""])
            })
        }
        return response(request)
    }

    private static func eventKinds(_ request: ControlRequest) throws -> Set<ActivityEventKind>? {
        guard let names = request.kinds else { return nil }
        let kinds = names.compactMap(ActivityEventKind.init(rawValue:))
        guard kinds.count == names.count else { throw ControlError.invalidRequest }
        return Set(kinds)
    }
    static func eventRecord(_ event: ActivityEvent) -> ControlRecord {
        ControlRecord(id: event.id, title: String(event.subject.prefix(4096)), fields: [
            "kind": event.kind.rawValue, "timestamp": event.timestamp.ISO8601Format(),
            "severity": event.severity.rawValue])
    }

    private static var followers: [UUID: (ControlRequest, AsyncThrowingStream<ControlResponse, Error>.Continuation)] = [:]

    static var followerCount: Int { followers.count }

    /// Follow starts at subscription time. Historical queries are separate, so no hidden replay gaps.
    static func follow(_ request: ControlRequest) -> ControlSubscription {
        ControlSubscription { continuation in
            do { try request.validate(); _ = try eventKinds(request) }
            catch { continuation.finish(throwing: ControlError.invalidRequest); return }
            guard store != nil, request.op == "events", request.follow == true,
                  request.since == nil, request.until == nil else {
                continuation.finish(throwing: ControlError.invalidRequest); return
            }
            let id = UUID()
            followers[id] = (request, continuation)
            // Only subscribed clients get heartbeats, to detect disconnects without permanent polling.
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    var response = ControlResponse(); response.end = false
                    if case .dropped = continuation.yield(response) {
                        continuation.finish(throwing: ControlError.slowConsumer); return
                    }
                }
            }
            continuation.onTermination = { _ in
                heartbeat.cancel()
                Task { @MainActor in followers[id] = nil }
            }
        }
    }

    static func publish(_ events: [ActivityEvent], from source: MonitorStore) {
        guard store === source else { return }
        for (_, (request, continuation)) in followers {
            for event in events where (request.kinds?.contains(event.kind.rawValue) ?? true)
                && event.matches(search: request.search ?? "") {
                var response = ControlResponse(records: [eventRecord(event)]); response.end = false
                if case .dropped = continuation.yield(response) {
                    continuation.finish(throwing: ControlError.slowConsumer); break
                }
            }
        }
    }

}
