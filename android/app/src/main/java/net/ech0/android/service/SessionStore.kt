package net.ech0.android.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import net.ech0.android.model.SessionState

object SessionStore {
    private val mutableState = MutableStateFlow(SessionState())
    val state: StateFlow<SessionState> = mutableState.asStateFlow()

    fun update(transform: (SessionState) -> SessionState) {
        mutableState.update(transform)
    }

    fun replace(next: SessionState) {
        mutableState.value = next
    }
}

