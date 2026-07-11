import Foundation

enum ReceiverError: LocalizedError {
    case audioComponentUnavailable
    case audioDeviceNotFound(String)
    case connectionClosed
    case coreAudio(OSStatus)
    case invalidAudioPayload
    case listenerAlreadyRunning
    case listenerPortUnavailable
    case packetTooLarge
    case truncatedAudioFrame
    case unsupportedAudioFormat
    case unsupportedControlMessage(String)

    var errorDescription: String? {
        switch self {
        case .audioComponentUnavailable:
            return "Core Audio output component unavailable."
        case .audioDeviceNotFound(let name):
            return "\(name) was not found on this Mac."
        case .connectionClosed:
            return "The TCP connection closed."
        case .coreAudio(let status):
            return "Core Audio error \(status)."
        case .invalidAudioPayload:
            return "The audio packet payload is invalid."
        case .listenerAlreadyRunning:
            return "The receiver is already listening."
        case .listenerPortUnavailable:
            return "Port 48484 is unavailable."
        case .packetTooLarge:
            return "The network packet exceeds the allowed size."
        case .truncatedAudioFrame:
            return "The audio frame header is truncated."
        case .unsupportedAudioFormat:
            return "The sender requested an unsupported audio format."
        case .unsupportedControlMessage(let kind):
            return "Unsupported control message: \(kind)."
        }
    }
}
