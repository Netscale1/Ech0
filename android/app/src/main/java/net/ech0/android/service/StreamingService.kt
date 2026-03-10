package net.ech0.android.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import net.ech0.android.MainActivity
import net.ech0.android.R
import net.ech0.android.audio.AudioCaptureEngine
import net.ech0.android.model.SessionConfig
import net.ech0.android.model.SessionPhase
import net.ech0.android.model.SessionState
import net.ech0.android.network.StreamingClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class StreamingService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var sessionJob: Job? = null
    @Volatile
    private var shouldRun = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onDestroy() {
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startSession(extractConfig(intent))
            ACTION_STOP -> stopSession()
            ACTION_SET_MUTED -> {
                val muted = intent.getBooleanExtra(EXTRA_MUTED, false)
                SessionStore.update { it.copy(isMuted = muted) }
                updateNotification(if (muted) "Muted" else "Streaming")
            }
        }
        return START_NOT_STICKY
    }

    private fun startSession(config: SessionConfig) {
        shouldRun = true
        sessionJob?.cancel()
        SessionStore.replace(
            SessionState(
                config = config,
                phase = SessionPhase.Connecting,
                serviceRunning = true,
            ),
        )
        startForeground(NOTIFICATION_ID, buildNotification("Connecting to ${config.host}:${config.port}"))
        sessionJob = serviceScope.launch {
            runSession(config)
        }
    }

    private fun stopSession() {
        shouldRun = false
        sessionJob?.cancel()
        SessionStore.replace(SessionState())
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private suspend fun runSession(config: SessionConfig) {
        var reconnectAttempt = 0
        var backoffMs = 1_000L

        while (shouldRun && serviceScope.isActive) {
            val client = StreamingClient(config)
            val ended = CompletableDeferred<DisconnectEvent>()

            SessionStore.update {
                it.copy(
                    config = config,
                    phase = if (reconnectAttempt == 0) SessionPhase.Connecting else SessionPhase.Reconnecting,
                    serviceRunning = true,
                    reconnectAttempt = reconnectAttempt,
                    errorMessage = null,
                    inputLevel = 0f,
                )
            }
            updateNotification(
                if (reconnectAttempt == 0) {
                    "Connecting to ${config.host}:${config.port}"
                } else {
                    "Reconnecting to ${config.host}:${config.port}"
                },
            )

            try {
                val hello = client.connect()
                if (!hello.accepted) {
                    SessionStore.update {
                        it.copy(
                            phase = SessionPhase.Error,
                            errorMessage = hello.reason ?: "Server rejected this session",
                            serviceRunning = false,
                        )
                    }
                    client.close()
                    break
                }

                SessionStore.update {
                    it.copy(
                        phase = SessionPhase.Streaming,
                        targetBufferMs = hello.targetBufferMs,
                        reconnectAttempt = 0,
                        errorMessage = null,
                    )
                }
                updateNotification("Streaming to ${config.host}")

                val readerJob = client.startReaderLoop(
                    scope = serviceScope,
                    onPong = { echoedAt ->
                        val latency = (SystemClock.elapsedRealtime() - echoedAt)
                            .coerceAtLeast(0)
                            .toInt()
                        SessionStore.update { current -> current.copy(latencyMs = latency) }
                    },
                    onStop = { reason ->
                        if (!ended.isCompleted) {
                            ended.complete(DisconnectEvent.Stop(reason))
                        }
                    },
                    onClosed = { cause ->
                        if (!ended.isCompleted) {
                            ended.complete(DisconnectEvent.Closed(cause))
                        }
                    },
                )

                val captureEngine = AudioCaptureEngine(
                    sampleRate = config.sampleRate,
                    frameMs = config.frameMs,
                )

                var sequence = 0L
                val captureJob = serviceScope.launch(Dispatchers.IO) {
                    try {
                        captureEngine.run(
                            isMuted = { SessionStore.state.value.isMuted },
                        ) { pcm, level, timestampMs, muted ->
                            SessionStore.update { current -> current.copy(inputLevel = level) }
                            client.sendAudioFrame(
                                sequence = sequence++,
                                captureTimestampMs = timestampMs,
                                flags = if (muted) FLAG_MUTED else 0,
                                pcm = pcm,
                            )
                        }
                    } catch (t: Throwable) {
                        if (!ended.isCompleted) {
                            ended.complete(DisconnectEvent.Closed(t))
                        }
                    }
                }

                val pingJob = serviceScope.launch {
                    try {
                        while (isActive) {
                            client.sendPing(SystemClock.elapsedRealtime())
                            delay(1_000)
                        }
                    } catch (t: Throwable) {
                        if (!ended.isCompleted) {
                            ended.complete(DisconnectEvent.Closed(t))
                        }
                    }
                }

                when (val event = ended.await()) {
                    is DisconnectEvent.Stop -> {
                        captureJob.cancelAndJoin()
                        pingJob.cancelAndJoin()
                        readerJob.cancelAndJoin()
                        client.close()
                        shouldRun = false
                        SessionStore.update {
                            it.copy(
                                phase = SessionPhase.Error,
                                serviceRunning = false,
                                errorMessage = "Server stopped the session: ${event.reason}",
                                inputLevel = 0f,
                            )
                        }
                    }

                    is DisconnectEvent.Closed -> {
                        captureJob.cancelAndJoin()
                        pingJob.cancelAndJoin()
                        readerJob.cancelAndJoin()
                        client.close()
                        if (shouldRun) {
                            reconnectAttempt += 1
                            SessionStore.update {
                                it.copy(
                                    phase = SessionPhase.Reconnecting,
                                    reconnectAttempt = reconnectAttempt,
                                    errorMessage = event.cause?.message ?: "Connection lost",
                                    inputLevel = 0f,
                                )
                            }
                            updateNotification("Reconnecting")
                            delay(backoffMs)
                            backoffMs = (backoffMs * 2).coerceAtMost(8_000)
                        }
                    }
                }
            } catch (t: Throwable) {
                client.close()
                if (!shouldRun) {
                    break
                }
                reconnectAttempt += 1
                SessionStore.update {
                    it.copy(
                        phase = SessionPhase.Reconnecting,
                        reconnectAttempt = reconnectAttempt,
                        errorMessage = t.message ?: "Network error",
                        inputLevel = 0f,
                    )
                }
                updateNotification("Reconnecting")
                delay(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(8_000)
            }
        }

        if (SessionStore.state.value.phase != SessionPhase.Error) {
            SessionStore.replace(SessionState())
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun extractConfig(intent: Intent): SessionConfig {
        return SessionConfig(
            host = requireNotNull(intent.getStringExtra(EXTRA_HOST)),
            port = intent.getIntExtra(EXTRA_PORT, DEFAULT_PORT),
            token = requireNotNull(intent.getStringExtra(EXTRA_TOKEN)),
            deviceName = requireNotNull(intent.getStringExtra(EXTRA_DEVICE_NAME)),
        )
    }

    private fun updateNotification(contentText: String) {
        NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, buildNotification(contentText))
    }

    private fun buildNotification(contentText: String) =
        NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_call_record)
            .setContentTitle("Ech0 sender")
            .setContentText(contentText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(mainPendingIntent())
            .build()

    private fun mainPendingIntent(): PendingIntent {
        val launchIntent = Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.notification_channel_description)
        }
        manager.createNotificationChannel(channel)
    }

    sealed interface DisconnectEvent {
        data class Stop(val reason: String) : DisconnectEvent
        data class Closed(val cause: Throwable?) : DisconnectEvent
    }

    companion object {
        private const val ACTION_START = "net.ech0.android.action.START"
        private const val ACTION_STOP = "net.ech0.android.action.STOP"
        private const val ACTION_SET_MUTED = "net.ech0.android.action.SET_MUTED"
        private const val EXTRA_DEVICE_NAME = "extra_device_name"
        private const val EXTRA_HOST = "extra_host"
        private const val EXTRA_MUTED = "extra_muted"
        private const val EXTRA_PORT = "extra_port"
        private const val EXTRA_TOKEN = "extra_token"
        private const val FLAG_MUTED = 1
        private const val DEFAULT_PORT = 48_484
        private const val NOTIFICATION_CHANNEL_ID = "ech0-streaming"
        private const val NOTIFICATION_ID = 4001

        fun startIntent(context: Context, config: SessionConfig): Intent {
            return Intent(context, StreamingService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_HOST, config.host)
                putExtra(EXTRA_PORT, config.port)
                putExtra(EXTRA_TOKEN, config.token)
                putExtra(EXTRA_DEVICE_NAME, config.deviceName)
            }
        }

        fun stopIntent(context: Context): Intent {
            return Intent(context, StreamingService::class.java).apply {
                action = ACTION_STOP
            }
        }

        fun mutedIntent(context: Context, muted: Boolean): Intent {
            return Intent(context, StreamingService::class.java).apply {
                action = ACTION_SET_MUTED
                putExtra(EXTRA_MUTED, muted)
            }
        }
    }
}
