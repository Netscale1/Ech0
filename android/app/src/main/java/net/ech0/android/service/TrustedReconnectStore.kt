package net.ech0.android.service

import android.content.Context
import android.content.SharedPreferences
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class SenderIdentity(
    val senderId: String,
    val trustedSecret: String,
)

data class RememberedReceiver(
    val host: String,
    val port: Int,
) {
    val label: String
        get() = "$host:$port"

    fun matches(candidateHost: String, candidatePort: Int?): Boolean {
        return candidatePort == port && host.equals(candidateHost.trim(), ignoreCase = true)
    }
}

object TrustedReconnectStore {
    private const val PREFS_NAME = "ech0_trusted_reconnect"
    private const val KEY_SENDER_ID = "sender_id"
    private const val KEY_TRUSTED_SECRET = "trusted_secret"
    private const val KEY_REMEMBERED_HOST = "remembered_host"
    private const val KEY_REMEMBERED_PORT = "remembered_port"

    private val lock = Any()
    private val rememberedReceiver = MutableStateFlow<RememberedReceiver?>(null)
    private val secureRandom = SecureRandom()

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var initialized = false

    fun rememberedReceiver(context: Context): StateFlow<RememberedReceiver?> {
        ensureInitialized(context)
        return rememberedReceiver.asStateFlow()
    }

    fun getOrCreateIdentity(context: Context): SenderIdentity {
        ensureInitialized(context)
        synchronized(lock) {
            val prefs = prefs()
            val senderId = prefs.getString(KEY_SENDER_ID, null) ?: UUID.randomUUID().toString()
            val trustedSecret = prefs.getString(KEY_TRUSTED_SECRET, null) ?: generateTrustedSecret()

            if (prefs.getString(KEY_SENDER_ID, null) == null || prefs.getString(KEY_TRUSTED_SECRET, null) == null) {
                prefs.edit()
                    .putString(KEY_SENDER_ID, senderId)
                    .putString(KEY_TRUSTED_SECRET, trustedSecret)
                    .apply()
            }

            return SenderIdentity(
                senderId = senderId,
                trustedSecret = trustedSecret,
            )
        }
    }

    fun rememberReceiver(context: Context, host: String, port: Int) {
        ensureInitialized(context)
        val normalizedHost = host.trim()
        val next = RememberedReceiver(host = normalizedHost, port = port)
        synchronized(lock) {
            prefs().edit()
                .putString(KEY_REMEMBERED_HOST, normalizedHost)
                .putInt(KEY_REMEMBERED_PORT, port)
                .apply()
            rememberedReceiver.value = next
        }
    }

    fun forgetRememberedReceiver(context: Context) {
        ensureInitialized(context)
        synchronized(lock) {
            prefs().edit()
                .remove(KEY_REMEMBERED_HOST)
                .remove(KEY_REMEMBERED_PORT)
                .apply()
            rememberedReceiver.value = null
        }
    }

    private fun ensureInitialized(context: Context) {
        if (initialized) {
            return
        }
        synchronized(lock) {
            if (initialized) {
                return
            }
            appContext = context.applicationContext
            rememberedReceiver.value = loadRememberedReceiver()
            initialized = true
        }
    }

    private fun loadRememberedReceiver(): RememberedReceiver? {
        val prefs = prefs()
        val host = prefs.getString(KEY_REMEMBERED_HOST, null)?.trim().orEmpty()
        val port = prefs.getInt(KEY_REMEMBERED_PORT, -1)
        if (host.isBlank() || port !in 1..65_535) {
            return null
        }
        return RememberedReceiver(host = host, port = port)
    }

    private fun prefs(): SharedPreferences {
        val context = checkNotNull(appContext) { "TrustedReconnectStore not initialized" }
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun generateTrustedSecret(): String {
        val bytes = ByteArray(32)
        secureRandom.nextBytes(bytes)
        return Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(bytes)
    }
}
