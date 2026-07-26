import CoreAudio
import Foundation

struct VirtualMicrophoneWriter: Sendable {
    static let deviceUID = "net.ech0.virtual-mic.device"
    static let pcmWriteSelector = fourCC("e0wr")

    let device: AudioDeviceDescriptor

    static func connect() -> VirtualMicrophoneWriter? {
        guard let device = SystemAudio.deviceWithUID(deviceUID) else {
            return nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: pcmWriteSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device.id, &address) else {
            return nil
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device.id, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return nil
        }

        return VirtualMicrophoneWriter(device: device)
    }

    @discardableResult
    func write(_ frame: AudioFrame) -> OSStatus {
        let data = frame.samples.withUnsafeBytes { Data($0) } as CFData
        return write(data)
    }

    @discardableResult
    func clear() -> OSStatus {
        write(Data() as CFData)
    }

    private func write(_ data: CFData) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: Self.pcmWriteSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var property: CFData? = data
        return withUnsafePointer(to: &property) { pointer in
            AudioObjectSetPropertyData(
                device.id,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFData?>.size),
                pointer
            )
        }
    }

    private static func fourCC(_ value: StaticString) -> AudioObjectPropertySelector {
        precondition(value.utf8CodeUnitCount == 4)
        return value.withUTF8Buffer { bytes in
            bytes.reduce(AudioObjectPropertySelector(0)) {
                ($0 << 8) | AudioObjectPropertySelector($1)
            }
        }
    }
}
