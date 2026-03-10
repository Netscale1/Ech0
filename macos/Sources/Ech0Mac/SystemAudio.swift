import CoreAudio
import Foundation

struct AudioDeviceDescriptor: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

enum SystemAudio {
    static func allDevices() -> [AudioDeviceDescriptor] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        let dataStatus = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids)
        guard dataStatus == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard let name = deviceName(for: id) else { return nil }
            return AudioDeviceDescriptor(id: id, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func deviceNamed(_ name: String) -> AudioDeviceDescriptor? {
        allDevices().first { $0.name == name }
    }

    static func setDefaultInputDevice(named name: String) throws {
        guard let device = deviceNamed(name) else {
            throw ReceiverError.audioDeviceNotFound(name)
        }
        try setDefaultInputDevice(id: device.id)
    }

    static func nominalSampleRate(named name: String) throws -> Double {
        guard let device = deviceNamed(name) else {
            throw ReceiverError.audioDeviceNotFound(name)
        }
        return try nominalSampleRate(id: device.id)
    }

    static func setNominalSampleRate(named name: String, sampleRate: Double) throws {
        guard let device = deviceNamed(name) else {
            throw ReceiverError.audioDeviceNotFound(name)
        }
        try setNominalSampleRate(id: device.id, sampleRate: sampleRate)
    }

    static func setDefaultInputDevice(id: AudioDeviceID) throws {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw ReceiverError.coreAudio(status)
        }
    }

    private static func nominalSampleRate(id: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64.zero
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &sampleRate)
        guard status == noErr else {
            throw ReceiverError.coreAudio(status)
        }
        return sampleRate
    }

    private static func setNominalSampleRate(id: AudioDeviceID, sampleRate: Double) throws {
        let current = try nominalSampleRate(id: id)
        if abs(current - sampleRate) < 1 {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = sampleRate
        let status = AudioObjectSetPropertyData(
            id,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &value
        )
        guard status == noErr else {
            throw ReceiverError.coreAudio(status)
        }
    }

    private static func deviceName(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr else {
            return nil
        }
        return name as String
    }
}
