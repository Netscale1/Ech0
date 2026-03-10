import AudioToolbox
import CoreAudio
import Foundation

final class AudioOutputEngine {
    private let jitterBuffer = JitterBuffer()
    private var audioUnit: AudioUnit?
    private(set) var outputDevice: AudioDeviceDescriptor?
    private(set) var isRunning = false

    func prepare(deviceNamed name: String = "BlackHole 2ch") throws {
        guard let device = SystemAudio.deviceNamed(name) else {
            throw ReceiverError.audioDeviceNotFound(name)
        }
        try configureAudioUnit(for: device)
        outputDevice = device
    }

    func start() throws {
        guard !isRunning else { return }
        guard let audioUnit else {
            throw ReceiverError.audioComponentUnavailable
        }

        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw ReceiverError.coreAudio(status)
        }
        isRunning = true
    }

    func stop() {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
        outputDevice = nil
        isRunning = false
        jitterBuffer.reset()
    }

    deinit {
        stop()
    }

    func enqueue(_ frame: AudioFrame) {
        jitterBuffer.push(frame)
    }

    func clear() {
        jitterBuffer.reset()
    }

    func snapshot() -> JitterBufferSnapshot {
        jitterBuffer.snapshot()
    }

    fileprivate func render(frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }

        let monoSamples = jitterBuffer.consumeMonoSamples(count: frameCount)
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

        if bufferList.count == 1 {
            guard let rawPointer = bufferList[0].mData else { return noErr }
            let stereoPointer = rawPointer.bindMemory(to: Int16.self, capacity: frameCount * 2)
            for index in 0..<frameCount {
                let sample = monoSamples[index]
                stereoPointer[index * 2] = sample
                stereoPointer[index * 2 + 1] = sample
            }
        } else {
            for buffer in bufferList {
                guard let rawPointer = buffer.mData else { continue }
                let monoPointer = rawPointer.bindMemory(to: Int16.self, capacity: frameCount)
                for index in 0..<frameCount {
                    monoPointer[index] = monoSamples[index]
                }
            }
        }

        return noErr
    }

    private func configureAudioUnit(for device: AudioDeviceDescriptor) throws {
        stop()

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw ReceiverError.audioComponentUnavailable
        }

        var maybeAudioUnit: AudioUnit?
        let instanceStatus = AudioComponentInstanceNew(component, &maybeAudioUnit)
        guard instanceStatus == noErr, let audioUnit = maybeAudioUnit else {
            throw ReceiverError.coreAudio(instanceStatus)
        }

        var enableOutput: UInt32 = 1
        var disableInput: UInt32 = 0
        var deviceID = device.id
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var renderCallback = AURenderCallbackStruct(
            inputProc: ech0RenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        var status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw ReceiverError.coreAudio(status) }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &disableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw ReceiverError.coreAudio(status) }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw ReceiverError.coreAudio(status) }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw ReceiverError.coreAudio(status) }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &renderCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { throw ReceiverError.coreAudio(status) }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else { throw ReceiverError.coreAudio(status) }

        self.audioUnit = audioUnit
    }
}

private let ech0RenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    guard let refCon else { return noErr }
    let engine = Unmanaged<AudioOutputEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.render(frameCount: Int(frameCount), ioData: ioData)
}

