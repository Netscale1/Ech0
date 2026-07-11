import Foundation

struct Packet {
    let type: UInt8
    let payload: Data
}

struct AudioFrame {
    let sequence: UInt64
    let captureTimestampMs: UInt64
    let flags: UInt32
    let samples: [Int16]

    var durationMs: Int {
        samples.count * 1_000 / 48_000
    }
}

enum PacketCodec {
    static let controlType: UInt8 = 0x01
    static let audioType: UInt8 = 0x02
    static let maximumControlPayloadSize = 16 * 1_024
    static let maximumPayloadSize = 64 * 1_024
    static let audioSamplesPerFrame = 960
    static let audioHeaderSize = 20
    static let audioPayloadSize = audioHeaderSize + audioSamplesPerFrame * 2

    static func encodePacket(type: UInt8, payload: Data) -> Data {
        var packet = Data([type])
        var bigEndianLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &bigEndianLength) { bytes in
            packet.append(contentsOf: bytes)
        }
        packet.append(payload)
        return packet
    }

    static func encodeAudioFrame(
        sequence: UInt64,
        captureTimestampMs: UInt64,
        flags: UInt32,
        samples: [Int16]
    ) -> Data {
        var payload = Data()
        var sequenceBE = sequence.bigEndian
        var timestampBE = captureTimestampMs.bigEndian
        var flagsBE = flags.bigEndian
        withUnsafeBytes(of: &sequenceBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestampBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &flagsBE) { payload.append(contentsOf: $0) }

        for sample in samples {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    static func decodeAudioFrame(_ payload: Data) throws -> AudioFrame {
        guard payload.count >= audioHeaderSize else {
            throw ReceiverError.truncatedAudioFrame
        }
        guard payload.count == audioPayloadSize else {
            throw ReceiverError.invalidAudioPayload
        }

        let sequence = payload.readUInt64BE(at: 0)
        let captureTimestampMs = payload.readUInt64BE(at: 8)
        let flags = payload.readUInt32BE(at: 16)

        let pcmData = payload.subdata(in: audioHeaderSize..<payload.count)
        guard pcmData.count.isMultiple(of: 2) else {
            throw ReceiverError.invalidAudioPayload
        }

        var samples: [Int16] = []
        samples.reserveCapacity(pcmData.count / 2)

        var index = pcmData.startIndex
        while index < pcmData.endIndex {
            let sample = pcmData.readInt16LE(at: index)
            samples.append(sample)
            index += 2
        }

        return AudioFrame(
            sequence: sequence,
            captureTimestampMs: captureTimestampMs,
            flags: flags,
            samples: samples,
        )
    }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        let slice = self[offset..<(offset + 4)]
        return slice.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        let slice = self[offset..<(offset + 8)]
        return slice.reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    func readInt16LE(at offset: Int) -> Int16 {
        let low = UInt16(self[offset])
        let high = UInt16(self[offset + 1]) << 8
        return Int16(bitPattern: high | low)
    }
}
