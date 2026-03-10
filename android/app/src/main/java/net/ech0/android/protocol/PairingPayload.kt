package net.ech0.android.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class PairingPayload(
    val v: Int,
    val host: String,
    val port: Int,
    val token: String,
) {
    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
        }

        fun parse(raw: String): PairingPayload {
            val payload = json.decodeFromString(PairingPayload.serializer(), raw)
            require(payload.v == 1) { "Unsupported QR payload version ${payload.v}" }
            require(payload.host.isNotBlank()) { "Missing host" }
            require(payload.port in 1..65_535) { "Invalid port" }
            require(payload.token.isNotBlank()) { "Missing token" }
            return payload
        }
    }
}
