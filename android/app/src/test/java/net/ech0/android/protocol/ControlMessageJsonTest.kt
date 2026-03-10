package net.ech0.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ControlMessageJsonTest {
    @Test
    fun `client hello round trips trusted reconnect fields`() {
        val message = ClientHello(
            protocolVersion = 1,
            token = "123456",
            deviceName = "Pixel 9",
            senderId = "sender-1",
            trustedSecret = "secret-1",
            sampleRate = 48_000,
            channels = 1,
            frameMs = 20,
        )

        val decoded = ControlMessageJson.decode(ControlMessageJson.encode(message))

        assertTrue(decoded is ClientHello)
        decoded as ClientHello
        assertEquals("sender-1", decoded.senderId)
        assertEquals("secret-1", decoded.trustedSecret)
        assertEquals("clientHello", decoded.kind)
    }
}
