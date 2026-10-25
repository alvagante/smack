import Testing
@testable import Smack

@Test func advancedSystemInformationContainsCoreSectionsAndValues() {
    let sections = SystemInformation.advancedSections(gpuName: "Test GPU", volumes: [])

    #expect(sections.map(\.title) == ["Hardware", "Software", "Graphics and Displays"])
    #expect(sections.flatMap(\.rows).contains { $0.key == "Mac Model" && !$0.value.isEmpty })
    #expect(sections.flatMap(\.rows).contains { $0.key == "macOS" && !$0.value.isEmpty })
    #expect(sections.flatMap(\.rows).contains { $0.key == "GPU" && $0.value == "Test GPU" })
    #expect(sections.flatMap(\.rows).allSatisfy { !$0.value.isEmpty })
}

@Test func advancedSystemInformationIncludesVolumeCapacityAndMountPath() {
    let volume = VolumeSample(
        name: "Macintosh HD",
        mountPath: "/",
        totalBytes: 1_000,
        availableBytes: 250
    )
    let sections = SystemInformation.advancedSections(gpuName: "", volumes: [volume])
    let storage = sections.first { $0.title == "Storage" }

    #expect(storage?.rows.count == 2)
    #expect(storage?.rows[0].key == "Macintosh HD")
    #expect(storage?.rows[1].value == "/")
}
