package net.ech0.android.model

enum class SessionPhase(val label: String) {
    Idle("Idle"),
    Connecting("Connecting"),
    Streaming("Streaming"),
    Reconnecting("Reconnecting"),
    Error("Error"),
}

data class SessionState(
    val config: SessionConfig? = null,
    val phase: SessionPhase = SessionPhase.Idle,
    val serviceRunning: Boolean = false,
    val isMuted: Boolean = false,
    val inputLevel: Float = 0f,
    val latencyMs: Int? = null,
    val reconnectAttempt: Int = 0,
    val targetBufferMs: Int = 60,
    val errorMessage: String? = null,
)

