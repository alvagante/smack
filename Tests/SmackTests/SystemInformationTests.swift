import Testing
@testable import Smack

@MainActor
@Test func systemInformationContainsCoreSectionsAndValues() {
    let sections = SystemInformation.sections(gpuName: "Test GPU", gpuCoreCount: 40)
    let titles = sections.map(\.title)

    #expect(Array(titles.prefix(4)) == ["Mac", "Processor and Memory", "Graphics and Displays", "Software"])
    #expect(titles.contains("Identity and User"))
    let rows = sections.flatMap(\.rows)
    #expect(rows.contains { $0.key == "Model Identifier" && !$0.value.isEmpty })
    #expect(rows.contains { $0.key == "macOS" && !$0.value.isEmpty })
    #expect(rows.contains { $0.key == "GPU" && $0.value == "Test GPU" })
    #expect(rows.contains { $0.key == "GPU Cores" && $0.value == "40" })
    #expect(rows.allSatisfy { !$0.value.isEmpty })
    for section in sections {
        #expect(Set(section.rows.map(\.id)).count == section.rows.count, "\(section.title) has duplicate row keys")
    }
}

@MainActor
@Test func systemInformationLeavesOutFiguresShownOnOtherPages() {
    let keys = SystemInformation.sections(gpuName: "", gpuCoreCount: nil).flatMap(\.rows).map(\.key)

    #expect(!keys.contains("GPU Utilization"))
    #expect(!keys.contains("Memory Pressure"))
    #expect(!keys.contains("Thermal State"))
    #expect(!keys.contains { $0.hasSuffix("Mount Path") })
    #expect(keys.contains("GPU") && !keys.contains("GPU Cores"))
}

@MainActor
@Test func systemInformationHidesHardwareIdentifiersWhenAsked() {
    let keys = SystemInformation.sections(gpuName: "", gpuCoreCount: nil, includeIdentifiers: false).flatMap(\.rows).map(\.key)

    #expect(!keys.contains("Serial Number"))
    #expect(!keys.contains("Hardware UUID"))
}

@MainActor
@Test func hardwareIdentifiersAreMarkedSensitive() {
    let rows = SystemInformation.sections(gpuName: "", gpuCoreCount: nil, includeIdentifiers: true).flatMap(\.rows)

    let identifiers: Set<String> = ["Serial Number", "Hardware UUID"]
    let sensitiveKeys = Set(rows.filter { $0.isSensitive }.map { $0.key })
    let identifierKeys = Set(rows.filter { identifiers.contains($0.key) }.map { $0.key })
    #expect(sensitiveKeys == identifierKeys)
}
