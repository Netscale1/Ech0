package net.ech0.android.protocol

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

data class Packet(
    val type: Int,
    val payload: ByteArray,
)

data class AudioFramePayload(
    val sequence: Long,
    val captureTimestampMs: Long,
    val flags: Int,
    val pcm: ByteArray,
)

object PacketCodec {
    const val TYPE_CONTROL: Int = 0x01
    const val TYPE_AUDIO: Int = 0x02
    private const val AUDIO_HEADER_SIZE = 20

    fun writePacket(output: OutputStream, type: Int, payload: ByteArray) {
        val header = ByteBuffer.allocate(5)
            .order(ByteOrder.BIG_ENDIAN)
            .put(type.toByte())
            .putInt(payload.size)
            .array()
        output.write(header)
        output.write(payload)
        output.flush()
    }

    fun readPacket(input: InputStream): Packet? {
        val header = readFully(input, 5) ?: return null
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN)
        val type = buffer.get().toInt() and 0xFF
        val length = buffer.int
        val payload = readFully(input, length) ?: return null
        return Packet(type = type, payload = payload)
    }

    fun encodeAudioFrame(
        sequence: Long,
        captureTimestampMs: Long,
        flags: Int,
        pcm: ByteArray,
    ): ByteArray {
        val header = ByteBuffer.allocate(AUDIO_HEADER_SIZE)
            .order(ByteOrder.BIG_ENDIAN)
            .putLong(sequence)
            .putLong(captureTimestampMs)
            .putInt(flags)
            .array()
        return header + pcm
    }

    fun decodeAudioFrame(payload: ByteArray): AudioFramePayload {
        require(payload.size >= AUDIO_HEADER_SIZE) { "Audio payload too short" }
        val header = ByteBuffer.wrap(payload, 0, AUDIO_HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
        return AudioFramePayload(
            sequence = header.long,
            captureTimestampMs = header.long,
            flags = header.int,
            pcm = payload.copyOfRange(AUDIO_HEADER_SIZE, payload.size),
        )
    }

    private fun readFully(input: InputStream, length: Int): ByteArray? {
        val payload = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(payload, offset, length - offset)
            if (read == -1) {
                if (offset == 0) {
                    return null
                }
                throw EOFException("Stream closed mid-packet")
            }
            offset += read
        }
        return payload
    }
}

