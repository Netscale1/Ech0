package net.ech0.android.protocol

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

sealed interface ControlMessage {
    val kind: String
}

@Serializable
data class ClientHello(
    override val kind: String = "clientHello",
    val protocolVersion: Int,
    val token: String,
    val deviceName: String,
    val senderId: String? = null,
    val trustedSecret: String? = null,
    val sampleRate: Int,
    val channels: Int,
    val frameMs: Int,
) : ControlMessage

@Serializable
data class ServerHello(
    override val kind: String = "serverHello",
    val accepted: Boolean,
    val reason: String? = null,
    val targetBufferMs: Int = 60,
) : ControlMessage

@Serializable
data class Ping(
    override val kind: String = "ping",
    val monotonicMs: Long,
) : ControlMessage

@Serializable
data class Pong(
    override val kind: String = "pong",
    val monotonicMs: Long,
) : ControlMessage

@Serializable
data class Stop(
    override val kind: String = "stop",
    val reason: String,
) : ControlMessage

@OptIn(ExperimentalSerializationApi::class)
object ControlMessageJson {
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    fun encode(message: ControlMessage): ByteArray {
        val serialized = when (message) {
            is ClientHello -> json.encodeToString(ClientHello.serializer(), message)
            is ServerHello -> json.encodeToString(ServerHello.serializer(), message)
            is Ping -> json.encodeToString(Ping.serializer(), message)
            is Pong -> json.encodeToString(Pong.serializer(), message)
            is Stop -> json.encodeToString(Stop.serializer(), message)
        }
        return serialized.toByteArray()
    }

    fun decode(payload: ByteArray): ControlMessage {
        val document = json.decodeFromString(JsonObject.serializer(), payload.toString(Charsets.UTF_8))
        return when (document["kind"]?.jsonPrimitive?.content) {
            "clientHello" -> json.decodeFromJsonElement(ClientHello.serializer(), document)
            "serverHello" -> json.decodeFromJsonElement(ServerHello.serializer(), document)
            "ping" -> json.decodeFromJsonElement(Ping.serializer(), document)
            "pong" -> json.decodeFromJsonElement(Pong.serializer(), document)
            "stop" -> json.decodeFromJsonElement(Stop.serializer(), document)
            else -> error("Unsupported control message kind")
        }
    }
}
