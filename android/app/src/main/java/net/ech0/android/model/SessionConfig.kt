package net.ech0.android.model

data class SessionConfig(
    val host: String,
    val port: Int,
    val token: String,
    val deviceName: String,
    val senderId: String,
    val trustedSecret: String,
    val audioInputProfile: AudioInputProfile = AudioInputProfile.VoiceCommunication,
    val enableVoiceProcessing: Boolean = true,
    val sampleRate: Int = 48_000,
    val channels: Int = 1,
    val frameMs: Int = 20,
)

