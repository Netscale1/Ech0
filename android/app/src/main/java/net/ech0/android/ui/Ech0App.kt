package net.ech0.android.ui

import android.Manifest
import android.content.Context
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.ech0.android.model.SessionConfig
import net.ech0.android.protocol.PairingPayload
import net.ech0.android.service.SessionStore
import net.ech0.android.service.StreamingService

@Composable
fun Ech0App() {
    val context = LocalContext.current
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()

    var host by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf("48484") }
    var token by rememberSaveable { mutableStateOf("") }
    var localError by rememberSaveable { mutableStateOf<String?>(null) }
    var showScanner by rememberSaveable { mutableStateOf(false) }

    var microphoneGranted by rememberSaveable {
        mutableStateOf(context.hasPermission(Manifest.permission.RECORD_AUDIO))
    }
    var cameraGranted by rememberSaveable {
        mutableStateOf(context.hasPermission(Manifest.permission.CAMERA))
    }

    val microphonePermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        microphoneGranted = granted
        if (!granted) {
            localError = "Microphone permission is required to stream audio."
        }
    }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        cameraGranted = granted
        if (granted) {
            showScanner = true
            localError = null
        } else {
            localError = "Camera permission is required to scan the pairing QR."
        }
    }

    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Color(0xFF0D4A6B),
            secondary = Color(0xFFE78A2F),
            surface = Color(0xFFF8F3EA),
            background = Color(0xFFF4EEE3),
        ),
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Text("Ech0 Sender", fontWeight = FontWeight.SemiBold)
                    },
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            listOf(Color(0xFFF4EEE3), Color(0xFFE3EEF2)),
                        ),
                    )
                    .padding(padding)
                    .padding(horizontal = 20.dp, vertical = 16.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Card(
                    shape = RoundedCornerShape(24.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = Color(0xFF17374D),
                        contentColor = Color.White,
                    ),
                ) {
                    Column(
                        modifier = Modifier.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            text = "Android phone as your Mac microphone",
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            text = "Scan the Mac QR or enter host and code manually. The stream stays alive in a foreground service while the screen is off.",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            PermissionChip("Mic", microphoneGranted)
                            PermissionChip("Camera", cameraGranted)
                            PermissionChip("Wi-Fi", true)
                        }
                    }
                }

                Card(shape = RoundedCornerShape(20.dp)) {
                    Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Pairing", style = MaterialTheme.typography.titleLarge)
                        OutlinedTextField(
                            value = host,
                            onValueChange = {
                                host = it.trim()
                                localError = null
                            },
                            label = { Text("Mac host or IP") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = port,
                                onValueChange = {
                                    port = it.filter(Char::isDigit)
                                    localError = null
                                },
                                label = { Text("Port") },
                                modifier = Modifier.weight(1f),
                                singleLine = true,
                            )
                            OutlinedTextField(
                                value = token,
                                onValueChange = {
                                    token = it.filter(Char::isDigit).take(6)
                                    localError = null
                                },
                                label = { Text("Code") },
                                modifier = Modifier.weight(1f),
                                singleLine = true,
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Button(
                                onClick = {
                                    if (cameraGranted) {
                                        showScanner = true
                                    } else {
                                        cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                                    }
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Scan QR")
                            }
                            OutlinedButton(
                                onClick = {
                                    if (microphoneGranted) {
                                        startStreamingOrShowError(
                                            context = context,
                                            host = host,
                                            port = port,
                                            token = token,
                                            onInvalidInput = { localError = it },
                                        )
                                    } else {
                                        microphonePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                    }
                                },
                                modifier = Modifier.weight(1f),
                                enabled = !sessionState.serviceRunning,
                            ) {
                                Text("Start")
                            }
                        }
                        if (sessionState.serviceRunning) {
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                FilterChip(
                                    selected = sessionState.isMuted,
                                    onClick = {
                                        context.startService(
                                            StreamingService.mutedIntent(
                                                context,
                                                !sessionState.isMuted,
                                            ),
                                        )
                                    },
                                    label = {
                                        Text(if (sessionState.isMuted) "Muted" else "Mute")
                                    },
                                )
                                OutlinedButton(
                                    onClick = {
                                        context.startService(StreamingService.stopIntent(context))
                                    },
                                ) {
                                    Text("Stop")
                                }
                            }
                        }
                    }
                }

                Card(
                    shape = RoundedCornerShape(20.dp),
                    colors = CardDefaults.cardColors(containerColor = Color.White.copy(alpha = 0.9f)),
                ) {
                    Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Session status", style = MaterialTheme.typography.titleLarge)
                        StatusLine("State", sessionState.phase.label)
                        StatusLine("Latency", sessionState.latencyMs?.let { "$it ms" } ?: "n/a")
                        StatusLine("Reconnect", sessionState.reconnectAttempt.takeIf { it > 0 }?.toString() ?: "0")
                        StatusLine("Target buffer", "${sessionState.targetBufferMs} ms")
                        Text("Input level", style = MaterialTheme.typography.labelLarge)
                        LinearProgressIndicator(
                            progress = sessionState.inputLevel.coerceIn(0f, 1f),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        val resolvedError = localError ?: sessionState.errorMessage
                        if (resolvedError != null) {
                            Text(
                                text = resolvedError,
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        } else {
                            Text(
                                text = "Best results: keep phone and Mac on the same 5 GHz Wi-Fi and place the phone away from laptop speakers.",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }
        }

        if (showScanner) {
            QrScannerDialog(
                onDismiss = { showScanner = false },
                onPayloadScanned = { rawValue ->
                    runCatching { PairingPayload.parse(rawValue) }
                        .onSuccess { payload ->
                            host = payload.host
                            port = payload.port.toString()
                            token = payload.token
                            showScanner = false
                            localError = null
                        }
                        .onFailure {
                            localError = "Unsupported QR payload."
                        }
                },
            )
        }
    }
}

@Composable
private fun PermissionChip(label: String, granted: Boolean) {
    AssistChip(
        onClick = {},
        enabled = false,
        label = {
            Text(if (granted) "$label ready" else "$label needed")
        },
    )
}

@Composable
private fun StatusLine(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.labelLarge)
        Text(value, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
    }
}

private fun startStreamingOrShowError(
    context: Context,
    host: String,
    port: String,
    token: String,
    onInvalidInput: (String) -> Unit,
) {
    val parsedPort = port.toIntOrNull()
    if (host.isBlank()) {
        onInvalidInput("Enter the Mac host or IP address.")
        return
    }
    if (parsedPort == null || parsedPort !in 1..65_535) {
        onInvalidInput("Enter a valid TCP port.")
        return
    }
    if (token.length < 6) {
        onInvalidInput("Enter the 6-digit pairing code.")
        return
    }

    val config = SessionConfig(
        host = host,
        port = parsedPort,
        token = token,
        deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
    )

    ContextCompat.startForegroundService(
        context,
        StreamingService.startIntent(context, config),
    )
}

private fun Context.hasPermission(permission: String): Boolean {
    return ContextCompat.checkSelfPermission(
        this,
        permission,
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
}
