package net.ech0.android.audio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.SystemClock
import java.io.IOException
import kotlin.math.sqrt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

class AudioCaptureEngine(
    private val sampleRate: Int = 48_000,
    private val frameMs: Int = 20,
    private val audioSource: Int = MediaRecorder.AudioSource.VOICE_COMMUNICATION,
) {
    suspend fun run(
        isMuted: () -> Boolean,
        onFrame: suspend (pcm: ByteArray, level: Float, timestampMs: Long, muted: Boolean) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val samplesPerFrame = sampleRate * frameMs / 1_000
        val minBufferSize = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        require(minBufferSize > 0) { "AudioRecord minimum buffer size unavailable" }

        val record = AudioRecord.Builder()
            .setAudioSource(audioSource)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBufferSize * 2, samplesPerFrame * 8))
            .build()

        val effects = createEffects(record.audioSessionId)
        val sampleBuffer = ShortArray(samplesPerFrame)

        try {
            record.startRecording()
            while (currentCoroutineContext().isActive) {
                var offset = 0
                while (offset < samplesPerFrame) {
                    val read = record.read(
                        sampleBuffer,
                        offset,
                        samplesPerFrame - offset,
                        AudioRecord.READ_BLOCKING,
                    )
                    if (read <= 0) {
                        throw IOException("AudioRecord read failed with code $read")
                    }
                    offset += read
                }

                val muted = isMuted()
                val pcm = ByteArray(samplesPerFrame * 2)
                var writeOffset = 0
                for (sample in sampleBuffer) {
                    val value = if (muted) 0 else sample.toInt()
                    pcm[writeOffset] = (value and 0xFF).toByte()
                    pcm[writeOffset + 1] = ((value ushr 8) and 0xFF).toByte()
                    writeOffset += 2
                }

                onFrame(
                    pcm,
                    calculateLevel(sampleBuffer),
                    SystemClock.elapsedRealtime(),
                    muted,
                )
            }
        } finally {
            runCatching {
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    record.stop()
                }
            }
            record.release()
            effects.forEach { runCatching { it.release() } }
        }
    }

    private fun calculateLevel(buffer: ShortArray): Float {
        var sum = 0.0
        for (sample in buffer) {
            val normalized = sample / 32768.0
            sum += normalized * normalized
        }
        val rms = sqrt(sum / buffer.size.toDouble()).toFloat()
        return (rms * 5f).coerceIn(0f, 1f)
    }

    private fun createEffects(audioSessionId: Int): List<AudioEffect> {
        val effects = mutableListOf<AudioEffect>()

        if (NoiseSuppressor.isAvailable()) {
            NoiseSuppressor.create(audioSessionId)?.also {
                it.enabled = true
                effects += it
            }
        }
        if (AutomaticGainControl.isAvailable()) {
            AutomaticGainControl.create(audioSessionId)?.also {
                it.enabled = true
                effects += it
            }
        }
        if (AcousticEchoCanceler.isAvailable()) {
            AcousticEchoCanceler.create(audioSessionId)?.also {
                it.enabled = true
                effects += it
            }
        }

        return effects
    }
}

