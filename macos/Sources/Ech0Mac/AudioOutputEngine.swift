import AudioToolbox
import CoreAudio
import Foundation

final class AudioOutputEngine: @unchecked Sendable {
    static let fallbackDeviceName = "BlackHole 2ch"
    static let sampleRate = 48_000.0

    private let jitterBuffer = JitterBuffer()
    private let lifecycleLock = NSLock()
    private var audioUnit: AudioUnit?
    private var virtualMicrophoneWriter: VirtualMicrophoneWriter?
    private var storedOutputDevice: AudioDeviceDescriptor?
    private var running = false

    var outputDevice: AudioDeviceDescriptor? {
        withLifecycleLock { storedOutputDevice }
    }

    var isRunning: Bool {
        withLifecycleLock { running }
    }

    func prepare(fallbackDeviceNamed name: String = fallbackDeviceName) throws {
        if let writer = VirtualMicrophoneWriter.connect() {
            withLifecycleLock {
                stopUnlocked()
                virtualMicrophoneWriter = writer
                storedOutputDevice = writer.device
            }
            return
        }

        guard let device = SystemAudio.deviceNamed(name) else {
            throw ReceiverError.audioEndpointUnavailable(fallbackName: name)
        }
        try SystemAudio.setNominalSampleRate(named: name, sampleRate: Self.sampleRate)
        try withLifecycleLock {
            try configureAudioUnitUnlocked(for: device)
            storedOutputDevice = device
        }
    }

    func start() throws {
        try withLifecycleLock {
            guard !running else { return }
            if virtualMicrophoneWriter != nil {
                running = true
                return
            }
            guard let audioUnit else {
                throw ReceiverError.audioComponentUnavailable
            }

            let status = AudioOutputUnitStart(audioUnit)
            guard status == noErr else {
                throw ReceiverError.coreAudio(status)
            }
            running = true
        }
    }

    func stop() {
        withLifecycleLock {
            stopUnlocked()
        }
    }

    private func stopUnlocked() {
        virtualMicrophoneWriter?.clear()
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
        virtualMicrophoneWriter = nil
        storedOutputDevice = nil
        running = false
        jitterBuffer.reset()
    }

    deinit {
        stop()
    }

    func enqueue(_ frame: AudioFrame) {
        if let writer = withLifecycleLock({ virtualMicrophoneWriter }) {
            writer.write(frame)
            return
        }
        jitterBuffer.push(frame)
    }

    func clear() {
        if let writer = withLifecycleLock({ virtualMicrophoneWriter }) {
            writer.clear()
            return
        }
        jitterBuffer.reset()
    }

    func snapshot() -> JitterBufferSnapshot {
        jitterBuffer.snapshot()
    }

    fileprivate func render(frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }

        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

        if bufferList.count == 1 {
            guard let rawPointer = bufferList[0].mData,
                  Int(bufferList[0].mDataByteSize) >= frameCount * MemoryLayout<Int16>.size * 2 else {
                return kAudio_ParamError
            }
            let stereoPointer = rawPointer.bindMemory(to: Int16.self, capacity: frameCount * 2)
            jitterBuffer.consumeMonoSamples(
                into: UnsafeMutableBufferPointer(start: stereoPointer, count: frameCount)
            )
            guard frameCount > 0 else { return noErr }
            for index in stride(from: frameCount - 1, through: 0, by: -1) {
                let sample = stereoPointer[index]
                stereoPointer[index * 2] = sample
                stereoPointer[index * 2 + 1] = sample
            }
        } else {
            guard let firstRawPointer = bufferList.first?.mData,
                  Int(bufferList.first?.mDataByteSize ?? 0) >= frameCount * MemoryLayout<Int16>.size else {
                return kAudio_ParamError
            }
            let firstPointer = firstRawPointer.bindMemory(to: Int16.self, capacity: frameCount)
            jitterBuffer.consumeMonoSamples(
                into: UnsafeMutableBufferPointer(start: firstPointer, count: frameCount)
            )
            for buffer in bufferList.dropFirst() {
                guard let rawPointer = buffer.mData,
                      Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Int16>.size else {
                    return kAudio_ParamError
                }
                rawPointer.copyMemory(
                    from: firstRawPointer,
                    byteCount: frameCount * MemoryLayout<Int16>.size
                )
            }
        }

        return noErr
    }

    private func configureAudioUnitUnlocked(for device: AudioDeviceDescriptor) throws {
        stopUnlocked()

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
        var shouldDisposeAudioUnit = true
        defer {
            if shouldDisposeAudioUnit {
                AudioComponentInstanceDispose(audioUnit)
            }
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
        shouldDisposeAudioUnit = false
    }

    private func withLifecycleLock<T>(_ body: () throws -> T) rethrows -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try body()
    }
}

private let ech0RenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let engine = Unmanaged<AudioOutputEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.render(frameCount: Int(frameCount), ioData: ioData)
}
