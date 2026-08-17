import CoreAudio
import Foundation

final class AudioInputDemandMonitor: @unchecked Sendable {
    struct Consumer: Equatable {
        let objectID: AudioObjectID
        let label: String
    }

    var onConsumersChanged: (([String]) -> Void)?
    var onUnavailable: (() -> Void)?

    private struct ProcessRegistration {
        let runningAddress: AudioObjectPropertyAddress
        let runningBlock: AudioObjectPropertyListenerBlock
        let devicesAddress: AudioObjectPropertyAddress
        let devicesBlock: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "net.ech0.receiver.audio-demand")
    private let queueKey = DispatchSpecificKey<Void>()
    private let ignoredBundleIdentifiers: Set<String>
    private let stopDelay: TimeInterval
    private var systemRegistration: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private var processRegistrations: [AudioObjectID: ProcessRegistration] = [:]
    private var targetDeviceID: AudioDeviceID?
    private var currentConsumers: [Consumer] = []
    private var pendingStop: DispatchWorkItem?
    private var isStarted = false

    init(
        stopDelay: TimeInterval = 2,
        ignoredBundleIdentifiers: Set<String> = ["net.ech0.mac"]
    ) {
        self.stopDelay = stopDelay
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        queue.setSpecific(key: queueKey, value: ())
    }

    @discardableResult
    func start(deviceNamed name: String = "BlackHole 2ch") -> Bool {
        syncOnQueue {
            guard !isStarted else { return targetDeviceID != nil }
            guard let device = SystemAudio.deviceNamed(name) else {
                return failStartOnQueue()
            }
            return startOnQueue(device: device)
        }
    }

    @discardableResult
    func start(device: AudioDeviceDescriptor) -> Bool {
        syncOnQueue {
            startOnQueue(device: device)
        }
    }

    private func startOnQueue(device: AudioDeviceDescriptor) -> Bool {
        guard !isStarted else { return targetDeviceID != nil }
        isStarted = true
        targetDeviceID = device.id

        let system = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(system, &address) else {
            return failStartOnQueue()
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshProcessesAndDemand()
        }
        guard AudioObjectAddPropertyListenerBlock(system, &address, queue, block) == noErr else {
            return failStartOnQueue()
        }
        systemRegistration = (address, block)
        refreshProcessesAndDemand()
        return true
    }

    func stop() {
        syncOnQueue {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard isStarted else { return }
        isStarted = false
        pendingStop?.cancel()
        pendingStop = nil

        let system = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        if var registration = systemRegistration {
            AudioObjectRemovePropertyListenerBlock(system, &registration.0, queue, registration.1)
        }
        systemRegistration = nil

        for (objectID, registration) in processRegistrations {
            var runningAddress = registration.runningAddress
            var devicesAddress = registration.devicesAddress
            AudioObjectRemovePropertyListenerBlock(objectID, &runningAddress, queue, registration.runningBlock)
            AudioObjectRemovePropertyListenerBlock(objectID, &devicesAddress, queue, registration.devicesBlock)
        }
        processRegistrations.removeAll()
        currentConsumers.removeAll()
        targetDeviceID = nil
    }

    deinit {
        stop()
    }

    static func usesTargetInput(
        isRunningInput: Bool,
        inputDeviceIDs: [AudioDeviceID],
        targetDeviceID: AudioDeviceID
    ) -> Bool {
        isRunningInput && inputDeviceIDs.contains(targetDeviceID)
    }

    private func refreshProcessesAndDemand() {
        guard isStarted, let targetDeviceID else { return }
        let processIDs = Self.audioObjectIDs(
            objectID: AudioObjectID(bitPattern: kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )

        let removedIDs = Set(processRegistrations.keys).subtracting(processIDs)
        for objectID in removedIDs {
            removeListeners(for: objectID)
        }
        for objectID in processIDs where processRegistrations[objectID] == nil {
            addListeners(for: objectID)
        }

        let consumers = processIDs.compactMap { objectID -> Consumer? in
            let bundleID = Self.string(objectID: objectID, selector: kAudioProcessPropertyBundleID)
            if let bundleID, ignoredBundleIdentifiers.contains(bundleID) {
                return nil
            }
            let isRunning = Self.uint32(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningInput,
                scope: kAudioObjectPropertyScopeGlobal
            ) == 1
            let devices = Self.audioObjectIDs(
                objectID: objectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            )
            guard Self.usesTargetInput(
                isRunningInput: isRunning,
                inputDeviceIDs: devices,
                targetDeviceID: targetDeviceID
            ) else {
                return nil
            }
            let label = bundleID ?? "Audio process \(objectID)"
            return Consumer(objectID: objectID, label: label)
        }
        apply(consumers: consumers)
    }

    private func apply(consumers: [Consumer]) {
        let normalizedConsumers = consumers.sorted {
            if $0.objectID != $1.objectID { return $0.objectID < $1.objectID }
            return $0.label < $1.label
        }
        if !normalizedConsumers.isEmpty {
            pendingStop?.cancel()
            pendingStop = nil
            guard normalizedConsumers != currentConsumers else { return }
            currentConsumers = normalizedConsumers
            publish(normalizedConsumers)
            return
        }

        guard !currentConsumers.isEmpty, pendingStop == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStop = nil
            self.currentConsumers = []
            self.publish([])
        }
        pendingStop = workItem
        queue.asyncAfter(deadline: .now() + stopDelay, execute: workItem)
    }

    private func publish(_ consumers: [Consumer]) {
        let labels = consumers.map(\.label).sorted()
        DispatchQueue.main.async { [weak self] in
            self?.onConsumersChanged?(labels)
        }
    }

    private func addListeners(for objectID: AudioObjectID) {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let runningBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshProcessesAndDemand()
        }
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshProcessesAndDemand()
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &runningAddress, queue, runningBlock) == noErr else {
            return
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &devicesAddress, queue, devicesBlock) == noErr else {
            AudioObjectRemovePropertyListenerBlock(objectID, &runningAddress, queue, runningBlock)
            return
        }
        processRegistrations[objectID] = ProcessRegistration(
            runningAddress: runningAddress,
            runningBlock: runningBlock,
            devicesAddress: devicesAddress,
            devicesBlock: devicesBlock
        )
    }

    private func removeListeners(for objectID: AudioObjectID) {
        guard let registration = processRegistrations.removeValue(forKey: objectID) else { return }
        var runningAddress = registration.runningAddress
        var devicesAddress = registration.devicesAddress
        AudioObjectRemovePropertyListenerBlock(objectID, &runningAddress, queue, registration.runningBlock)
        AudioObjectRemovePropertyListenerBlock(objectID, &devicesAddress, queue, registration.devicesBlock)
    }

    private static func audioObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }

    private static func uint32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
            let value
        else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private func failStartOnQueue() -> Bool {
        isStarted = false
        targetDeviceID = nil
        onUnavailable?()
        return false
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }
}
