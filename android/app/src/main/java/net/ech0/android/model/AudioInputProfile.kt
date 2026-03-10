package net.ech0.android.model

import android.media.MediaRecorder

enum class AudioInputProfile(
    val label: String,
    val description: String,
    val audioSource: Int,
) {
    VoiceCommunication(
        label = "Voice optimized",
        description = "Call-style processing with device voice tuning.",
        audioSource = MediaRecorder.AudioSource.VOICE_COMMUNICATION,
    ),
    RawMic(
        label = "Raw mic",
        description = "Direct microphone capture with less voice-call shaping.",
        audioSource = MediaRecorder.AudioSource.MIC,
    ),
}
