package net.ech0.android.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PacketCodecTest {
    @Test
    fun `audio packet round trips`() {
        val frame = PacketCodec.encodeAudioFrame(
            sequence = 42L,
            captureTimestampMs = 99L,
            flags = 1,
            pcm = byteArrayOf(1, 2, 3, 4),
        )

        val decoded = PacketCodec.decodeAudioFrame(frame)
        assertEquals(42L, decoded.sequence)
        assertEquals(99L, decoded.captureTimestampMs)
        assertEquals(1, decoded.flags)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), decoded.pcm)
    }
}
