import Testing
@testable import Smack

@Test func thermalSensorsCollapseDuplicatesKeepingHottest() {
    let collapsed = ThermalSensorReader.collapse([
        TemperatureSensor(name: "PMU tdie", celsius: 40),
        TemperatureSensor(name: "PMU tdie", celsius: 55),
        TemperatureSensor(name: "NAND", celsius: 30)
    ])
    #expect(collapsed == [TemperatureSensor(name: "NAND", celsius: 30), TemperatureSensor(name: "PMU tdie", celsius: 55)])
}

@Test func thermalSensorReadNeverCrashesAndStaysPlausible() {
    for sensor in ThermalSensorReader().read() { #expect((1.0...150.0).contains(sensor.celsius)) }
}
