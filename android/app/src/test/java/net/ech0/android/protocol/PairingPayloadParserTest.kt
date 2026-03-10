package net.ech0.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class PairingPayloadParserTest {
    @Test
    fun `parse accepts valid json payload`() {
        val payload = PairingPayload.parse(
            """
            {"v":1,"host":"192.168.1.50","port":48484,"token":"123456"}
            """.trimIndent(),
        )

        assertEquals("192.168.1.50", payload.host)
        assertEquals(48_484, payload.port)
        assertEquals("123456", payload.token)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `parse rejects unsupported version`() {
        PairingPayload.parse(
            """
            {"v":2,"host":"192.168.1.50","port":48484,"token":"123456"}
            """.trimIndent(),
        )
    }
}

