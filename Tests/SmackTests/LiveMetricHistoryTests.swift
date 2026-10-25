import Foundation
import Testing
@testable import Smack

@Test func liveMetricHistoryKeepsNewestPointsWithinCapacity() {
    var history = LiveMetricHistory(capacity: 3)
    for index in 0..<5 {
        history.append(LiveMetricPoint(
            timestamp: Date(timeIntervalSince1970: Double(index)),
            cpuUsage: Double(index),
            memoryUsage: Double(index + 10),
            receiveRate: Double(index + 20),
            sendRate: Double(index + 30),
            diskReadRate: Double(index + 40),
            diskWriteRate: Double(index + 50)
        ))
    }

    #expect(history.points.map(\.cpuUsage) == [2, 3, 4])
    #expect(history.points.first?.memoryUsage == 12)
    #expect(history.points.last?.diskWriteRate == 54)
}

@Test func liveMetricHistoryHasPositiveCapacity() {
    var history = LiveMetricHistory(capacity: 0)
    history.append(LiveMetricPoint(
        timestamp: Date(),
        cpuUsage: 1,
        memoryUsage: 2,
        receiveRate: 3,
        sendRate: 4,
        diskReadRate: 5,
        diskWriteRate: 6
    ))

    #expect(history.capacity == 1)
    #expect(history.points.count == 1)
}
