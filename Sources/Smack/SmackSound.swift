import AppKit

@MainActor
final class SmackSound {
    private let sound: NSSound?

    init() {
        sound = NSSound(data: Self.wavData())
        sound?.volume = 0.55
    }

    func play() {
        sound?.stop()
        sound?.play()
    }

    private static func wavData() -> Data {
        let sampleRate = 44_100
        let duration = 0.22
        let sampleCount = Int(Double(sampleRate) * duration)
        let dataSize = UInt32(sampleCount * 2)
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        appendLittleEndian(36 + dataSize, to: &data)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20])
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        appendLittleEndian(dataSize, to: &data)

        var randomState: UInt32 = 0x53_4D_41_43
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: randomState)) / Double(Int32.max)
            let attack = min(time / 0.002, 1)
            let slap = noise * exp(-time * 48) * 0.82
            let thump = sin(2 * Double.pi * (145 * time - 90 * time * time)) * exp(-time * 20) * 0.42
            let sample = Int16(max(-1, min(1, (slap + thump) * attack)) * Double(Int16.max))
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
