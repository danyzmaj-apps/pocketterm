package com.danyzmaj.pocketterm.ui.setup

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.lifecycle.Observer
import kotlinx.coroutines.suspendCancellableCoroutine
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.danyzmaj.pocketterm.ActivityHost
import com.danyzmaj.pocketterm.core.Backend
import com.danyzmaj.pocketterm.core.debugPrint
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

/** What the camera is doing: asking for it, showing, or why it shows nothing. */
private sealed interface Camera {
    data object Starting : Camera

    data object Running : Camera

    /** Not allowed: Settings is the way to allow it. */
    data object Denied : Camera

    /** No camera at all (a tablet or phone without one, an emulator without one). */
    data object Unsupported : Camera

    /** It failed to start or stopped; [code] says how. */
    data class Failed(val code: String) : Camera
}

private const val box = 260

/** The amber a problem shows in, readable on the camera's black. */
private val warnOnBlack = Color(0xFFFFC53D)

/**
 * The camera, reading the code the computer shows (Settings → Add a phone…): a setup link with a
 * sign-in code in it or, when [signedIn] (a phone adding a computer's key), with that computer's
 * key. Answers with that link through [com.danyzmaj.pocketterm.ui.Nav.scanned], or null when
 * cancelled. E2E builds take a pasted link too, as if the camera had read it.
 */
@Composable
fun ScanScreen(signedIn: Boolean) {
    val graph = LocalGraph.current
    val nav = LocalNav.current
    val haptics = rememberHaptics()
    var done by remember { mutableStateOf(false) }
    var camera by remember { mutableStateOf<Camera>(Camera.Starting) }

    // Set when a QR was read that isn't a usable PocketTerm code (a Wi-Fi code, a website).
    var notOurs by remember { mutableStateOf<String?>(null) }

    // What the camera (or, in E2E builds, the paste field) read: the first usable PocketTerm link
    // closes the scanner with it; otherwise says why none was.
    fun read(codes: List<String?>) {
        if (done) return
        var problem: String? = null
        for (raw in codes) {
            val link = raw?.trim() ?: ""
            if (Backend.fromLink(link) == null) continue
            val usable = if (signedIn) Backend.computerKey(link) != null else Backend.pairingCode(link) != null
            if (usable) {
                done = true
                haptics.done()
                nav.scanned(link)
                return
            }
            problem = if (signedIn) {
                "That code has no key for a computer. Update PocketTerm on your computer, then scan its code in " +
                    "Settings \u2192 Phone \u2192 Add a phone\u2026"
            } else {
                "That code has no sign-in in it. Scan the one under Your phone in PocketTerm\u2019s setup checklist " +
                    "on your computer, or in its Settings \u2192 Phone \u2192 Add a phone\u2026"
            }
        }
        notOurs = problem ?: "That's not a PocketTerm code. Scan the one on your computer."
    }

    BackHandler { nav.scanned(null) }
    LightSystemBars()

    val context = LocalContext.current
    LaunchedEffect(Unit) {
        camera = when {
            !context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) -> Camera.Unsupported
            ActivityHost.request(Manifest.permission.CAMERA) -> Camera.Running
            else -> Camera.Denied
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (val c = camera) {
            Camera.Starting -> {}
            Camera.Running -> {
                CameraPreview(onCodes = ::read, onFailed = { camera = Camera.Failed(it) })
                Framing(notOurs)
            }
            else -> CameraProblem(c, onSettings = { graph.scope.launch { graph.native.openSettings() } })
        }

        // Emulators may have no camera: E2E builds take the link a code holds, as if the camera had
        // read it (maestro/e2e). Never in release builds (graph.e2e needs a debug build).
        if (graph.e2e) {
            PasteCode(
                // Why a code didn't work shows under the square, unless the camera's problem took the screen.
                problem = if (camera == Camera.Running) null else notOurs,
                onCode = { read(listOf(it)) },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .imePadding(),
            )
        }

        IconButton(
            onClick = { nav.scanned(null) },
            colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(4.dp)
                .tag("scan-cancel"),
        ) {
            Icon(Icons.Filled.Close, contentDescription = "Cancel")
        }
    }
}

/** Light status and navigation bar icons over the camera's black, for as long as the scanner shows. */
@Composable
private fun LightSystemBars() {
    val view = LocalView.current
    DisposableEffect(view) {
        val window = ActivityHost.activity?.window
        val bars = window?.let { WindowCompat.getInsetsController(it, view) }
        val status = bars?.isAppearanceLightStatusBars
        val navigation = bars?.isAppearanceLightNavigationBars
        bars?.isAppearanceLightStatusBars = false
        bars?.isAppearanceLightNavigationBars = false
        onDispose {
            if (status != null) bars.isAppearanceLightStatusBars = status
            if (navigation != null) bars.isAppearanceLightNavigationBars = navigation
        }
    }
}

/** The back camera's picture, its frames read for QR codes (ML Kit); [onCodes] gets what each frame with codes held. */
@OptIn(ExperimentalGetImage::class)
@Composable
private fun CameraPreview(onCodes: (List<String?>) -> Unit, onFailed: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val codes by rememberUpdatedState(onCodes)
    val failed by rememberUpdatedState(onFailed)
    val preview = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val scope = rememberCoroutineScope()

    AndroidView({ preview }, Modifier.fillMaxSize())

    DisposableEffect(lifecycleOwner) {
        val scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
        )
        val analysisThread = Executors.newSingleThreadExecutor()
        val main = ContextCompat.getMainExecutor(context)
        var provider: ProcessCameraProvider? = null
        val job = scope.launch {
            try {
                val p = ProcessCameraProvider.getInstance(context).let { future ->
                    suspendCancellableCoroutine { cont ->
                        future.addListener({ cont.resumeWith(runCatching { future.get() }) }, main)
                    }
                }
                provider = p
                if (!p.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) && !p.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)) {
                    failed("noCamera")
                    return@launch
                }
                val selector = if (p.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) {
                    CameraSelector.DEFAULT_BACK_CAMERA
                } else {
                    CameraSelector.DEFAULT_FRONT_CAMERA
                }
                val picture = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(analysisThread) { frame ->
                    val image = frame.image
                    if (image == null) {
                        frame.close()
                        return@setAnalyzer
                    }
                    scanner.process(InputImage.fromMediaImage(image, frame.imageInfo.rotationDegrees))
                        .addOnSuccessListener(main) { found -> if (found.isNotEmpty()) codes(found.map { it.rawValue }) }
                        .addOnCompleteListener { frame.close() }
                }
                p.unbindAll()
                val bound = p.bindToLifecycle(lifecycleOwner, selector, picture, analysis)
                // A camera that stops for good (taken by another app, disabled by policy) says so.
                bound.cameraInfo.cameraState.observe(lifecycleOwner, Observer<CameraState> { state ->
                    val error = state.error ?: return@Observer
                    if (error.type == CameraState.ErrorType.CRITICAL) failed(cameraErrorName(error.code))
                })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                debugPrint("PocketTerm: camera: $e")
                failed(e::class.simpleName ?: "error")
            }
        }
        onDispose {
            job.cancel()
            provider?.unbindAll()
            scanner.close()
            analysisThread.shutdown()
        }
    }
}

private fun cameraErrorName(code: Int): String = when (code) {
    CameraState.ERROR_CAMERA_IN_USE -> "inUse"
    CameraState.ERROR_MAX_CAMERAS_IN_USE -> "maxCamerasInUse"
    CameraState.ERROR_CAMERA_DISABLED -> "disabled"
    CameraState.ERROR_CAMERA_FATAL_ERROR -> "fatalError"
    CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED -> "doNotDisturb"
    CameraState.ERROR_OTHER_RECOVERABLE_ERROR -> "recoverableError"
    CameraState.ERROR_STREAM_CONFIG -> "streamConfig"
    else -> "error$code"
}

/** Dims everything outside the square the code goes in; the hint (or why a code didn't work) under it. */
@Composable
private fun BoxScope.Framing(problem: String?) {
    Box(
        Modifier
            .fillMaxSize()
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .drawWithContent {
                val side = box.dp.toPx()
                val corner = CornerRadius(24.dp.toPx())
                val topLeft = Offset((size.width - side) / 2, (size.height - side) / 2)
                drawRect(Color(0x99000000))
                drawRoundRect(Color.Black, topLeft, Size(side, side), corner, blendMode = BlendMode.Clear)
            },
    )
    Box(
        Modifier
            .align(Alignment.Center)
            .size(box.dp)
            .border(3.dp, Color.White, RoundedCornerShape(24.dp)),
    )
    // Under the square.
    Box(
        Modifier
            .fillMaxSize()
            .padding(start = 32.dp, end = 32.dp, top = (box + 80).dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            problem ?: ("On your computer: Your phone in PocketTerm\u2019s setup checklist, " +
                "or Settings \u2192 Phone \u2192 Add a phone\u2026\nPoint this camera at the code."),
            color = if (problem == null) Color.White else warnOnBlack,
            textAlign = TextAlign.Center,
            modifier = Modifier.tag("scan-hint"),
        )
    }
}

/** Why the camera shows nothing: not allowed (with the way to Settings), no camera at all, or it failed to start. */
@Composable
private fun CameraProblem(camera: Camera, onSettings: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                when (camera) {
                    Camera.Denied ->
                        "PocketTerm needs the camera to read the code. Allow it in Settings \u2192 Apps \u2192 PocketTerm " +
                            "\u2192 Permissions."
                    Camera.Unsupported ->
                        "This device has no camera PocketTerm can use, so it can't read the code. Connect with a phone " +
                            "that has one, or close this and try the demo."
                    is Camera.Failed -> "The camera didn't start (${camera.code}). Close this and try again."
                    else -> ""
                },
                color = Color.White,
                textAlign = TextAlign.Center,
                modifier = Modifier.tag("camera-problem"),
            )
            if (camera == Camera.Denied) {
                Spacer(Modifier.height(16.dp))
                Button(onClick = onSettings, modifier = Modifier.tag("camera-settings")) { Text("Open Settings") }
            }
        }
    }
}

/** E2E builds only: a code's link, pasted instead of scanned. */
@Composable
private fun PasteCode(problem: String?, onCode: (String) -> Unit, modifier: Modifier = Modifier) {
    var text by remember { mutableStateOf("") }
    Column(modifier.fillMaxWidth().padding(16.dp)) {
        if (problem != null) {
            Text(problem, color = warnOnBlack, modifier = Modifier.padding(bottom = 8.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text("Paste a code (debug)") },
                singleLine = true,
                // A link: some keyboards "correct" url= to URL= and d= to do=.
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { onCode(text) }),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    focusedPlaceholderColor = Color.White.copy(alpha = 0.6f),
                    unfocusedPlaceholderColor = Color.White.copy(alpha = 0.6f),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.6f),
                    focusedBorderColor = Color.White,
                ),
                modifier = Modifier.weight(1f).tag("paste-code"),
            )
            TextButton(onClick = { onCode(text) }, modifier = Modifier.tag("paste-code-use")) {
                Text("Use", color = Color.White)
            }
        }
    }
}
