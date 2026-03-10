package net.ech0.android.network

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import net.ech0.android.model.SessionConfig
import net.ech0.android.protocol.ClientHello
import net.ech0.android.protocol.ControlMessage
import net.ech0.android.protocol.ControlMessageJson
import net.ech0.android.protocol.PacketCodec
import net.ech0.android.protocol.Ping
import net.ech0.android.protocol.Pong
import net.ech0.android.protocol.ServerHello
import net.ech0.android.protocol.Stop

class StreamingClient(
    private val config: SessionConfig,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val writeMutex = Mutex()
    private var socket: Socket? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null

    suspend fun connect(): ServerHello = withContext(ioDispatcher) {
        val newSocket = Socket().apply {
            tcpNoDelay = true
            keepAlive = true
            connect(InetSocketAddress(config.host, config.port), 5_000)
        }
        socket = newSocket
        input = BufferedInputStream(newSocket.getInputStream())
        output = BufferedOutputStream(newSocket.getOutputStream())

        sendControlLocked(
            ClientHello(
                protocolVersion = 1,
                token = config.token,
                deviceName = config.deviceName,
                senderId = config.senderId,
                trustedSecret = config.trustedSecret,
                sampleRate = config.sampleRate,
                channels = config.channels,
                frameMs = config.frameMs,
            ),
        )

        val packet = PacketCodec.readPacket(requireNotNull(input)) ?: throw EOFException("Server closed during handshake")
        require(packet.type == PacketCodec.TYPE_CONTROL) { "Expected control packet during handshake" }
        val response = ControlMessageJson.decode(packet.payload)
        require(response is ServerHello) { "Expected server hello response" }
        response
    }

    fun startReaderLoop(
        scope: CoroutineScope,
        onPong: (Long) -> Unit,
        onStop: (String) -> Unit,
        onClosed: (Throwable?) -> Unit,
    ): Job {
        return scope.launch(ioDispatcher) {
            var failure: Throwable? = null
            try {
                while (isActive) {
                    val packet = PacketCodec.readPacket(requireNotNull(input)) ?: break
                    if (packet.type != PacketCodec.TYPE_CONTROL) {
                        continue
                    }
                    when (val message = ControlMessageJson.decode(packet.payload)) {
                        is Pong -> onPong(message.monotonicMs)
                        is Stop -> {
                            onStop(message.reason)
                            break
                        }
                        else -> Unit
                    }
                }
            } catch (t: Throwable) {
                failure = t
            } finally {
                onClosed(failure)
            }
        }
    }

    suspend fun sendAudioFrame(
        sequence: Long,
        captureTimestampMs: Long,
        flags: Int,
        pcm: ByteArray,
    ) = withContext(ioDispatcher) {
        val payload = PacketCodec.encodeAudioFrame(
            sequence = sequence,
            captureTimestampMs = captureTimestampMs,
            flags = flags,
            pcm = pcm,
        )
        writeMutex.withLock {
            PacketCodec.writePacket(requireNotNull(output), PacketCodec.TYPE_AUDIO, payload)
        }
    }

    suspend fun sendPing(monotonicMs: Long) {
        sendControl(Ping(monotonicMs = monotonicMs))
    }

    suspend fun sendStop(reason: String) {
        runCatching { sendControl(Stop(reason = reason)) }
    }

    private suspend fun sendControl(message: ControlMessage) = withContext(ioDispatcher) {
        writeMutex.withLock {
            sendControlLocked(message)
        }
    }

    private fun sendControlLocked(message: ControlMessage) {
        PacketCodec.writePacket(
            requireNotNull(output),
            PacketCodec.TYPE_CONTROL,
            ControlMessageJson.encode(message),
        )
    }

    fun close() {
        runCatching { socket?.close() }
        socket = null
        input = null
        output = null
    }
}

