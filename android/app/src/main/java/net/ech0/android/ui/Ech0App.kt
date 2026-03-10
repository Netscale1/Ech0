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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
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
import net.ech0.android.model.AudioInputProfile
import net.ech0.android.model.SessionConfig
import net.ech0.android.protocol.PairingPayload
import net.ech0.android.service.RememberedReceiver
import net.ech0.android.service.SessionStore
import net.ech0.android.service.StreamingService
import net.ech0.android.service.TrustedReconnectStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Ech0App() {
    val context = LocalContext.current
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val rememberedReceiverFlow = remember(context.applicationContext) {
        TrustedReconnectStore.rememberedReceiver(context)
    }
    val rememberedReceiver by rememberedReceiverFlow.collectAsStateWithLifecycle()

    var host by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf("48484") }
    var token by rememberSaveable { mutableStateOf("") }
    var audioInputProfileName by rememberSaveable { mutableStateOf(AudioInputProfile.VoiceCommunication.name) }
    var enableVoiceProcessing by rememberSaveable { mutableStateOf(true) }
    var localError by rememberSaveable { mutableStateOf<String?>(null) }
    var showScanner by rememberSaveable { mutableStateOf(false) }
    val audioInputProfile = AudioInputProfile.valueOf(audioInputProfileName)

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
            onPrimary = Color.White,
            primaryContainer = Color(0xFFC5E3F1),
            onPrimaryContainer = Color(0xFF082536),
            secondary = Color(0xFFE78A2F),
            onSecondary = Color(0xFF2E1500),
            secondaryContainer = Color(0xFFF7D7B5),
            onSecondaryContainer = Color(0xFF432300),
            surface = Color(0xFFF8F3EA),
            background = Color(0xFFF4EEE3),
            surfaceVariant = Color(0xFFE7E0D3),
            onSurfaceVariant = Color(0xFF405463),
            outline = Color(0xFF5B7180),
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
                        rememberedReceiver?.let { receiver ->
                            Card(
                                colors = CardDefaults.cardColors(
                                    containerColor = Color(0xFFE9F1F6),
                                    contentColor = Color(0xFF17374D),
                                ),
                            ) {
                                Column(
                                    modifier = Modifier.padding(14.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    Text(
                                        text = "Remembered Mac",
                                        style = MaterialTheme.typography.labelLarge,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    Text(
                                        text = receiver.label,
                                        style = MaterialTheme.typography.bodyLarge,
                                    )
                                    Button(
                                        onClick = {
                                            host = receiver.host
                                            port = receiver.port.toString()
                                            localError = null
                                        },
                                        modifier = Modifier.fillMaxWidth(),
                                        enabled = !sessionState.serviceRunning,
                                        colors = ButtonDefaults.buttonColors(
                                            containerColor = MaterialTheme.colorScheme.primary,
                                            contentColor = MaterialTheme.colorScheme.onPrimary,
                                        ),
                                    ) {
                                        Text("Use remembered receiver")
                                    }
                                    OutlinedButton(
                                        onClick = {
                                            TrustedReconnectStore.forgetRememberedReceiver(context)
                                            localError = null
                                        },
                                        modifier = Modifier.fillMaxWidth(),
                                        enabled = !sessionState.serviceRunning,
                                        colors = ButtonDefaults.outlinedButtonColors(
                                            contentColor = MaterialTheme.colorScheme.primary,
                                        ),
                                    ) {
                                        Text("Forget remembered receiver")
                                    }
                                }
                            }
                        }
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
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = port,
                                onValueChange = {
                                    port = it.filter(Char::isDigit)
                                    localError = null
                                },
                                label = { Text("Port") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true,
                            )
                            OutlinedTextField(
                                value = token,
                                onValueChange = {
                                    token = it.filter(Char::isDigit).take(6)
                                    localError = null
                                },
                                label = { Text("Code") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true,
                            )
                        }
                        val tokenOptionalForRemembered = rememberedReceiver?.matches(
                            candidateHost = host,
                            candidatePort = port.toIntOrNull(),
                        ) == true
                        if (tokenOptionalForRemembered) {
                            Text(
                                text = "Code is optional when reconnecting to the remembered receiver.",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFF405463),
                            )
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Mic mode", style = MaterialTheme.typography.labelLarge)
                            AudioInputProfile.entries.forEach { profile ->
                                FilterChip(
                                    selected = audioInputProfile == profile,
                                    onClick = {
                                        audioInputProfileName = profile.name
                                        localError = null
                                    },
                                    enabled = !sessionState.serviceRunning,
                                    colors = FilterChipDefaults.filterChipColors(
                                        containerColor = Color.White,
                                        labelColor = MaterialTheme.colorScheme.onSurface,
                                        selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                    ),
                                    label = {
                                        Text(profile.label)
                                    },
                                )
                            }
                            Text(
                                text = audioInputProfile.description,
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFF405463),
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(
                                modifier = Modifier.fillMaxWidth(0.72f),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                Text("Voice cleanup", style = MaterialTheme.typography.labelLarge)
                                Text(
                                    text = if (enableVoiceProcessing) {
                                        "Noise suppression and voice tuning enabled."
                                    } else {
                                        "Extra voice processing disabled."
                                    },
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color(0xFF405463),
                                )
                            }
                            Switch(
                                checked = enableVoiceProcessing,
                                onCheckedChange = { enableVoiceProcessing = it },
                                enabled = !sessionState.serviceRunning,
                            )
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            FilledTonalButton(
                                onClick = {
                                    if (cameraGranted) {
                                        showScanner = true
                                    } else {
                                        cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.filledTonalButtonColors(
                                    containerColor = MaterialTheme.colorScheme.secondaryContainer,
                                    contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                                ),
                            ) {
                                Text("Scan QR")
                            }
                            Button(
                                onClick = {
                                    if (microphoneGranted) {
                                        startStreamingOrShowError(
                                            context = context,
                                            host = host,
                                            port = port,
                                            token = token,
                                            rememberedReceiver = rememberedReceiver,
                                            audioInputProfile = audioInputProfile,
                                            enableVoiceProcessing = enableVoiceProcessing,
                                            onInvalidInput = { localError = it },
                                        )
                                    } else {
                                        microphonePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                enabled = !sessionState.serviceRunning,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = MaterialTheme.colorScheme.primary,
                                    contentColor = MaterialTheme.colorScheme.onPrimary,
                                ),
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
                                    colors = FilterChipDefaults.filterChipColors(
                                        containerColor = Color.White,
                                        labelColor = MaterialTheme.colorScheme.onSurface,
                                        selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                    ),
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
                            progress = { sessionState.inputLevel.coerceIn(0f, 1f) },
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
    val containerColor = if (granted) Color(0xFFF3E7CC) else Color(0xFFFFD9CC)
    val textColor = if (granted) Color(0xFF102A3A) else Color(0xFF6B1F00)

    Card(
        shape = RoundedCornerShape(999.dp),
        colors = CardDefaults.cardColors(
            containerColor = containerColor,
            contentColor = textColor,
        ),
    )
    {
        Text(
            text = if (granted) "$label ready" else "$label needed",
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = textColor,
        )
    }
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
    rememberedReceiver: RememberedReceiver?,
    audioInputProfile: AudioInputProfile,
    enableVoiceProcessing: Boolean,
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
    val normalizedToken = token.filter(Char::isDigit).take(6)
    val tokenOptionalForRemembered = rememberedReceiver?.matches(host, parsedPort) == true
    if (normalizedToken.length < 6 && !tokenOptionalForRemembered) {
        onInvalidInput("Enter the 6-digit pairing code or use the remembered receiver.")
        return
    }
    val identity = TrustedReconnectStore.getOrCreateIdentity(context)

    val config = SessionConfig(
        host = host,
        port = parsedPort,
        token = normalizedToken,
        deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
        senderId = identity.senderId,
        trustedSecret = identity.trustedSecret,
        audioInputProfile = audioInputProfile,
        enableVoiceProcessing = enableVoiceProcessing,
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
