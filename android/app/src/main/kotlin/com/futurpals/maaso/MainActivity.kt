package com.futurpals.maaso

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.location.Address
import android.location.Geocoder
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Future
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val STREAMING_AUDIO_MIN_SAMPLE_RATE = 8_000
private const val STREAMING_AUDIO_MAX_SAMPLE_RATE = 192_000
private const val STREAMING_AUDIO_MAX_SESSION_SECONDS = 3_600L
private const val STREAMING_AUDIO_MAX_PENDING_BYTES = 2 * 1024 * 1024
private const val STREAMING_AUDIO_PUMP_CHUNK_BYTES = 64 * 1024
private const val STREAMING_AUDIO_PUMP_RETRY_MS = 4L
private const val STREAMING_AUDIO_WRITE_STALL_TIMEOUT_MS = 5_000L
private const val STREAMING_AUDIO_DRAIN_POLL_MS = 10L
private const val STREAMING_AUDIO_PLAYBACK_HEAD_MODULUS = 0x1_0000_0000L

private class StreamingAudioMethodResult(
    private val delegate: MethodChannel.Result,
    private val mainHandler: Handler
) {
    private val completed = AtomicBoolean(false)

    fun success(value: Any?) = complete { delegate.success(value) }

    fun error(code: String, message: String?, details: Any? = null) =
        complete { delegate.error(code, message, details) }

    private fun complete(callback: () -> Unit) {
        if (!completed.compareAndSet(false, true)) return
        if (Looper.myLooper() == mainHandler.looper) {
            callback()
        } else {
            mainHandler.post(callback)
        }
    }
}

private data class PendingStreamingAudioWrite(
    val generation: Long,
    val bytes: ByteArray,
    var offset: Int = 0,
    var lastProgressAtMs: Long = SystemClock.uptimeMillis()
)

class MainActivity : FlutterActivity() {
    private var speechRecognizer: SpeechRecognizer? = null
    private var nativeAsrChannel: MethodChannel? = null
    private var appIconChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var gameSnapshotPlugin: GameSnapshotPlugin? = null
    private var locationBridge: MaasoCityGeocoderBridge? = null
    private var streamingAudioSinkChannel: MethodChannel? = null
    private val streamingAudioMainHandler = Handler(Looper.getMainLooper())
    private val streamingAudioThread = HandlerThread(
        "MaasoStreamingAudio",
        Process.THREAD_PRIORITY_AUDIO
    ).apply { start() }
    private val streamingAudioHandler = Handler(streamingAudioThread.looper)
    private var streamingAudioTrack: AudioTrack? = null
    private val streamingAudioPendingWrites = ArrayDeque<PendingStreamingAudioWrite>()
    private var streamingAudioPendingBytes = 0
    private var streamingAudioWritePumpRunnable: Runnable? = null
    private var streamingAudioDrainPollRunnable: Runnable? = null
    private var streamingAudioSampleRate = 24000
    private var streamingAudioChannels = 1
    private var streamingAudioAcceptedFrames = 0L
    private var streamingAudioWrittenFrames = 0L
    private var streamingAudioSessionFrameLimit = 0L
    private var streamingAudioGeneration: Long? = null
    private var streamingAudioIncarnation = 0L
    private var streamingAudioPlaybackHeadGeneration: Long? = null
    private var streamingAudioPlaybackHeadLastRaw = 0L
    private var streamingAudioPlaybackHeadWrapFrames = 0L
    private var streamingAudioDrainGeneration: Long? = null
    private var streamingAudioDrainResult: StreamingAudioMethodResult? = null
    private var streamingAudioPaused = false
    @Volatile
    private var streamingAudioThreadReleased = false
    private var unityAvatarBridge: UnityAvatarBridge? = null
    private var avatarPortalTextureBridge: AvatarPortalTextureBridge? = null
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingStartLocale: String? = null
    private var pendingStartRequestId: Long? = null
    private var activeNativeAsrRequestId: Long? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.navigationBarColor = android.graphics.Color.TRANSPARENT

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
    }

    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode = TransparencyMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        HomeTextEditorPlugin.register(flutterEngine)
        gameSnapshotPlugin?.dispose()
        gameSnapshotPlugin = GameSnapshotPlugin(this, flutterEngine)
        locationBridge?.dispose()
        locationBridge = MaasoCityGeocoderBridge(
            applicationContext,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maaso/location")
        )
        appIconChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "maaso/app_icon"
        )
        appIconChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setThemeIcon" -> {
                    val dark = call.argument<Boolean>("dark") ?: true
                    syncLauncherIcon(dark)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "maaso/share"
        )
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "share" -> shareMedia(
                    text = call.argument<String>("text").orEmpty(),
                    filePath = call.argument<String>("filePath"),
                    result = result
                )
                else -> result.notImplemented()
            }
        }
        nativeAsrChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "maaso/native_asr"
        )
        nativeAsrChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(SpeechRecognizer.isRecognitionAvailable(this))
                "start" -> {
                    val locale = call.argument<String>("locale")
                    val requestId = call.argument<Number>("requestId")?.toLong()
                    if (requestId == null) {
                        result.error("invalid_request", "requestId is required", null)
                    } else {
                        startNativeAsr(locale, requestId, result)
                    }
                }
                "stop" -> {
                    speechRecognizer?.stopListening()
                    result.success(null)
                }
                "cancel" -> {
                    // A start may still be waiting for RECORD_AUDIO. Resolve
                    // its Flutter result before the permission callback can
                    // create a recognizer after this cancellation.
                    pendingStartResult?.success(false)
                    pendingStartResult = null
                    pendingStartLocale = null
                    pendingStartRequestId = null
                    val requestId = activeNativeAsrRequestId
                    speechRecognizer?.cancel()
                    if (requestId != null) {
                        emitNativeAsrCallback("onListening", requestId, false)
                    }
                    activeNativeAsrRequestId = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        streamingAudioSinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "maaso/streaming_audio_sink"
        )
        streamingAudioSinkChannel?.setMethodCallHandler { call, result ->
            val reply = StreamingAudioMethodResult(result, streamingAudioMainHandler)
            when (call.method) {
                "start" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                    val channels = call.argument<Int>("channels") ?: 1
                    val generation = call.argument<Number>("generation")?.toLong()
                    if (generation == null || generation <= 0L) {
                        reply.error(
                            "invalid_generation",
                            "start expects a positive generation",
                            null
                        )
                    } else if (sampleRate !in
                        STREAMING_AUDIO_MIN_SAMPLE_RATE..STREAMING_AUDIO_MAX_SAMPLE_RATE ||
                        channels !in 1..2) {
                        reply.error(
                            "invalid_audio_format",
                            "start expects 8-192 kHz mono or stereo PCM",
                            null
                        )
                    } else {
                        postStreamingAudioTask(reply) {
                            runCatching {
                                startStreamingAudio(sampleRate, channels, generation)
                            }.onSuccess {
                                reply.success(streamingAudioReceipt(generation, "started"))
                            }.onFailure { error ->
                                retireStreamingAudio(completedDrain = false)
                                reply.error("audio_start_failed", error.message, null)
                            }
                        }
                    }
                }
                "write" -> {
                    val generation = call.argument<Number>("generation")?.toLong()
                    val bytes = call.argument<ByteArray>("pcm")
                    if (generation == null || generation <= 0L || bytes == null) {
                        reply.error("invalid_pcm", "write expects Uint8List PCM data", null)
                    } else if (bytes.isEmpty() ||
                        bytes.size > STREAMING_AUDIO_MAX_PENDING_BYTES) {
                        reply.error(
                            "invalid_pcm",
                            "PCM write must contain at most 2 MiB",
                            null
                        )
                    } else {
                        postStreamingAudioTask(reply) {
                            enqueueStreamingAudioWrite(bytes, generation, reply)
                        }
                    }
                }
                "pause" -> {
                    val generation = call.argument<Number>("generation")?.toLong()
                    if (generation == null || generation <= 0L) {
                        reply.error(
                            "invalid_generation",
                            "pause expects a positive generation",
                            null
                        )
                    } else {
                        postStreamingAudioTask(reply) {
                            pauseStreamingAudio(generation, reply)
                        }
                    }
                }
                "resume" -> {
                    val generation = call.argument<Number>("generation")?.toLong()
                    if (generation == null || generation <= 0L) {
                        reply.error(
                            "invalid_generation",
                            "resume expects a positive generation",
                            null
                        )
                    } else {
                        postStreamingAudioTask(reply) {
                            resumeStreamingAudio(generation, reply)
                        }
                    }
                }
                "position" -> {
                    val generation = call.argument<Number>("generation")?.toLong()
                    if (generation == null || generation <= 0L) {
                        reply.error(
                            "invalid_generation",
                            "position expects a positive generation",
                            null
                        )
                    } else {
                        postStreamingAudioTask(reply) {
                            positionStreamingAudio(generation, reply)
                        }
                    }
                }
                "stop" -> {
                    val drain = call.argument<Boolean>("drain") ?: true
                    val generation = call.argument<Number>("generation")?.toLong()
                    if (generation == null || generation <= 0L) {
                        reply.error(
                            "invalid_generation",
                            "stop expects a positive generation",
                            null
                        )
                    } else {
                        postStreamingAudioTask(reply) {
                            stopStreamingAudio(
                                generation = generation,
                                drain = drain,
                                result = reply
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        avatarPortalTextureBridge = AvatarPortalTextureBridge(flutterEngine)
        unityAvatarBridge = UnityAvatarBridge(this, flutterEngine)
    }

    // The bridge validates renderer receipts before they cross into Dart.
    fun emitUnityAvatarCommandResult(payload: String) {
        runOnUiThread {
            unityAvatarBridge?.emitCommandResult(payload)
        }
    }

    fun emitUnityAvatarReady() {
        runOnUiThread {
            unityAvatarBridge?.emitReady()
        }
    }

    private fun shareMedia(
        text: String,
        filePath: String?,
        result: MethodChannel.Result
    ) {
        if (text.isBlank()) {
            result.error("invalid_share", "Share text is required.", null)
            return
        }
        runCatching {
            val share = Intent(Intent.ACTION_SEND).apply {
                putExtra(Intent.EXTRA_TEXT, text)
                type = "text/plain"
                val file = filePath?.takeIf { it.isNotBlank() }?.let(::File)
                if (file != null && file.exists()) {
                    val sharedDirectory = File(cacheDir, "shared_media").apply {
                        mkdirs()
                    }
                    val sharedFile = file.copyTo(
                        File(sharedDirectory, file.name),
                        overwrite = true
                    )
                    val uri = FileProvider.getUriForFile(
                        this@MainActivity,
                        "$packageName.fileprovider",
                        sharedFile
                    )
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = android.content.ClipData.newRawUri("Maaso media", uri)
                    type = if (sharedFile.extension.lowercase() == "gif") {
                        "image/gif"
                    } else {
                        "image/jpeg"
                    }
                }
            }
            startActivity(Intent.createChooser(share, "分享"))
            result.success(true)
        }.onFailure { error ->
            result.error("share_unavailable", error.message, null)
        }
    }

    private fun syncLauncherIcon(dark: Boolean) {
        val darkAlias = ComponentName(this, "$packageName.MainActivityDark")
        val lightAlias = ComponentName(this, "$packageName.MainActivityLight")
        val activeAlias = if (dark) darkAlias else lightAlias
        val inactiveAlias = if (dark) lightAlias else darkAlias
        packageManager.setComponentEnabledSetting(
            activeAlias,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        packageManager.setComponentEnabledSetting(
            inactiveAlias,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
    }

    private fun postStreamingAudioTask(
        result: StreamingAudioMethodResult,
        task: () -> Unit
    ) {
        if (streamingAudioThreadReleased) {
            result.error("audio_sink_disposed", "streaming audio worker is unavailable")
            return
        }
        val posted = streamingAudioHandler.post {
            if (streamingAudioThreadReleased) {
                result.error("audio_sink_disposed", "streaming audio worker is unavailable")
                return@post
            }
            task()
        }
        if (!posted) {
            result.error("audio_sink_disposed", "streaming audio worker rejected the task")
        }
    }

    private fun startStreamingAudio(sampleRate: Int, channels: Int, generation: Long) {
        retireStreamingAudio(completedDrain = false)
        val channelConfig = if (channels == 2) {
            AudioFormat.CHANNEL_OUT_STEREO
        } else {
            AudioFormat.CHANNEL_OUT_MONO
        }
        val platformMinBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            channelConfig,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (platformMinBuffer <= 0) {
            throw IllegalStateException("AudioTrack reported an invalid minimum buffer")
        }
        val bytesPerFrame = channels * 2
        val preferredBuffer = sampleRate * bytesPerFrame / 5
        val bufferSize = maxOf(platformMinBuffer, preferredBuffer)
        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelConfig)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferSize)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_MUSIC,
                sampleRate,
                channelConfig,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
                AudioTrack.MODE_STREAM
            )
        }
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw IllegalStateException("AudioTrack failed to initialize")
        }
        try {
            track.play()
        } catch (error: Throwable) {
            track.release()
            throw error
        }
        streamingAudioTrack = track
        streamingAudioSampleRate = sampleRate
        streamingAudioChannels = channels
        streamingAudioAcceptedFrames = 0L
        streamingAudioWrittenFrames = 0L
        streamingAudioSessionFrameLimit =
            sampleRate.toLong() * STREAMING_AUDIO_MAX_SESSION_SECONDS
        streamingAudioGeneration = generation
        streamingAudioPlaybackHeadGeneration = generation
        streamingAudioPlaybackHeadLastRaw = 0L
        streamingAudioPlaybackHeadWrapFrames = 0L
        streamingAudioPaused = false
    }

    private fun enqueueStreamingAudioWrite(
        bytes: ByteArray,
        generation: Long,
        result: StreamingAudioMethodResult
    ) {
        if (streamingAudioGeneration != generation) {
            result.error(
                "stale_audio_generation",
                "write generation is no longer active"
            )
            return
        }
        if (streamingAudioDrainResult != null) {
            result.error("audio_draining", "streaming audio is already draining")
            return
        }
        if (streamingAudioTrack == null) {
            result.error("audio_write_failed", "streaming audio track is not active")
            return
        }
        val bytesPerFrame = (streamingAudioChannels * 2).coerceAtLeast(1)
        if (bytes.isEmpty() || bytes.size % bytesPerFrame != 0) {
            result.error("invalid_pcm", "PCM data must contain complete sample frames")
            return
        }
        if (streamingAudioPendingBytes > STREAMING_AUDIO_MAX_PENDING_BYTES - bytes.size) {
            result.error("audio_backpressure", "streaming audio pending queue is full")
            return
        }
        val frameCount = bytes.size / bytesPerFrame
        val projectedFrames = streamingAudioAcceptedFrames + frameCount
        if (projectedFrames > streamingAudioSessionFrameLimit) {
            result.error(
                "audio_session_limit",
                "streaming audio session exceeded its frame limit"
            )
            return
        }
        streamingAudioPendingWrites.addLast(
            PendingStreamingAudioWrite(
                generation = generation,
                bytes = bytes
            )
        )
        streamingAudioPendingBytes += bytes.size
        streamingAudioAcceptedFrames = projectedFrames
        // "accepted" means admission to this bounded, generation-local native
        // queue, matching iOS scheduleBuffer semantics. AudioTrack may consume
        // a large frame over several non-blocking pump iterations.
        result.success(streamingAudioReceipt(generation, "accepted"))
        scheduleStreamingAudioWritePump(generation, streamingAudioIncarnation)
    }

    private fun scheduleStreamingAudioWritePump(generation: Long, incarnation: Long) {
        if (streamingAudioPaused) return
        if (streamingAudioWritePumpRunnable != null) return
        lateinit var pump: Runnable
        pump = Runnable {
            if (streamingAudioWritePumpRunnable !== pump) return@Runnable
            streamingAudioWritePumpRunnable = null
            if (streamingAudioThreadReleased ||
                streamingAudioGeneration != generation ||
                streamingAudioIncarnation != incarnation) {
                return@Runnable
            }
            pumpStreamingAudioWrites(generation, incarnation)
        }
        streamingAudioWritePumpRunnable = pump
        if (!streamingAudioHandler.post(pump)) {
            streamingAudioWritePumpRunnable = null
            failStreamingAudio(
                "audio_write_failed",
                "streaming audio worker rejected the write pump"
            )
        }
    }

    private fun pumpStreamingAudioWrites(generation: Long, incarnation: Long) {
        val pending = streamingAudioPendingWrites.peekFirst()
        if (pending == null) {
            if (streamingAudioDrainGeneration == generation) {
                scheduleStreamingAudioDrainStop(generation)
            }
            return
        }
        if (pending.generation != generation) {
            failStreamingAudio(
                "stale_audio_generation",
                "queued PCM belongs to a retired generation"
            )
            return
        }
        val track = streamingAudioTrack
        if (track == null) {
            failStreamingAudio(
                "audio_write_failed",
                "streaming audio track is not active"
            )
            return
        }
        val bytesPerFrame = (streamingAudioChannels * 2).coerceAtLeast(1)
        val remaining = pending.bytes.size - pending.offset
        val requested = minOf(remaining, STREAMING_AUDIO_PUMP_CHUNK_BYTES)
        val alignedRequest = requested - requested % bytesPerFrame
        if (alignedRequest <= 0) {
            failStreamingAudio(
                "audio_write_failed",
                "queued PCM ended with an incomplete sample frame"
            )
            return
        }
        val written = try {
            track.write(
                pending.bytes,
                pending.offset,
                alignedRequest,
                AudioTrack.WRITE_NON_BLOCKING
            )
        } catch (error: Throwable) {
            failStreamingAudio(
                "audio_write_failed",
                error.message ?: error.javaClass.simpleName
            )
            return
        }
        if (written < 0 || written % bytesPerFrame != 0) {
            failStreamingAudio(
                "audio_write_failed",
                "AudioTrack write failed with status $written"
            )
            return
        }
        if (written == 0) {
            if (SystemClock.uptimeMillis() - pending.lastProgressAtMs >=
                STREAMING_AUDIO_WRITE_STALL_TIMEOUT_MS) {
                failStreamingAudio(
                    "audio_write_timeout",
                    "AudioTrack did not accept PCM before the write deadline"
                )
                return
            }
            scheduleStreamingAudioWritePumpAfterDelay(generation, incarnation)
            return
        }
        pending.offset += written
        pending.lastProgressAtMs = SystemClock.uptimeMillis()
        streamingAudioPendingBytes -= written
        streamingAudioWrittenFrames += written / bytesPerFrame
        if (pending.offset == pending.bytes.size) {
            streamingAudioPendingWrites.removeFirst()
        }
        scheduleStreamingAudioWritePumpAfterDelay(
            generation,
            incarnation,
            delayMs = if (streamingAudioPendingWrites.isEmpty()) {
                0L
            } else {
                STREAMING_AUDIO_PUMP_RETRY_MS
            }
        )
    }

    private fun scheduleStreamingAudioWritePumpAfterDelay(
        generation: Long,
        incarnation: Long,
        delayMs: Long = STREAMING_AUDIO_PUMP_RETRY_MS
    ) {
        if (streamingAudioPaused) return
        if (streamingAudioPendingWrites.isEmpty()) {
            if (streamingAudioDrainGeneration == generation) {
                scheduleStreamingAudioDrainStop(generation)
            }
            return
        }
        if (streamingAudioWritePumpRunnable != null) return
        lateinit var pump: Runnable
        pump = Runnable {
            if (streamingAudioWritePumpRunnable !== pump) return@Runnable
            streamingAudioWritePumpRunnable = null
            if (streamingAudioThreadReleased ||
                streamingAudioGeneration != generation ||
                streamingAudioIncarnation != incarnation) {
                return@Runnable
            }
            pumpStreamingAudioWrites(generation, incarnation)
        }
        streamingAudioWritePumpRunnable = pump
        val posted = if (delayMs <= 0L) {
            streamingAudioHandler.post(pump)
        } else {
            streamingAudioHandler.postDelayed(pump, delayMs)
        }
        if (!posted) {
            streamingAudioWritePumpRunnable = null
            failStreamingAudio(
                "audio_write_failed",
                "streaming audio worker rejected the write pump"
            )
        }
    }

    private fun retireStreamingAudio(
        completedDrain: Boolean,
        drainErrorCode: String? = null,
        drainErrorMessage: String? = null
    ) {
        val retiringGeneration = streamingAudioGeneration
        val pendingDrain = streamingAudioDrainResult
        val pendingDrainGeneration = streamingAudioDrainGeneration
        streamingAudioDrainResult = null
        streamingAudioDrainGeneration = null
        streamingAudioPaused = false
        streamingAudioWritePumpRunnable?.let { streamingAudioHandler.removeCallbacks(it) }
        streamingAudioWritePumpRunnable = null
        streamingAudioDrainPollRunnable?.let { streamingAudioHandler.removeCallbacks(it) }
        streamingAudioDrainPollRunnable = null
        streamingAudioGeneration = null
        streamingAudioIncarnation += 1L
        streamingAudioTrack?.let { track ->
            try {
                track.pause()
                track.flush()
                track.stop()
            } catch (_: IllegalStateException) {
                // Track may already be stopped or uninitialized.
            }
            track.release()
        }
        streamingAudioTrack = null
        streamingAudioPendingWrites.clear()
        streamingAudioPendingBytes = 0
        streamingAudioAcceptedFrames = 0L
        streamingAudioWrittenFrames = 0L
        streamingAudioSessionFrameLimit = 0L
        streamingAudioPlaybackHeadGeneration = null
        streamingAudioPlaybackHeadLastRaw = 0L
        streamingAudioPlaybackHeadWrapFrames = 0L
        if (pendingDrain != null && pendingDrainGeneration != null) {
            if (drainErrorCode != null) {
                pendingDrain.error(drainErrorCode, drainErrorMessage)
            } else {
                val terminal = if (completedDrain &&
                    retiringGeneration == pendingDrainGeneration) {
                    "completed"
                } else {
                    "cancelled"
                }
                pendingDrain.success(
                    streamingAudioReceipt(pendingDrainGeneration, terminal)
                )
            }
        }
    }

    private fun failStreamingAudio(code: String, message: String) {
        retireStreamingAudio(
            completedDrain = false,
            drainErrorCode = if (streamingAudioDrainResult == null) null else code,
            drainErrorMessage = message
        )
    }

    private fun stopStreamingAudio(
        generation: Long,
        drain: Boolean,
        result: StreamingAudioMethodResult
    ) {
        if (streamingAudioGeneration != generation) {
            result.success(streamingAudioReceipt(generation, "cancelled"))
            return
        }
        if (!drain) {
            retireStreamingAudio(completedDrain = false)
            result.success(streamingAudioReceipt(generation, "cancelled"))
            return
        }
        if (streamingAudioDrainResult != null) {
            result.error("audio_drain_pending", "a drain is already pending")
            return
        }
        streamingAudioDrainGeneration = generation
        streamingAudioDrainResult = result
        if (streamingAudioPendingWrites.isEmpty()) {
            scheduleStreamingAudioDrainStop(generation)
        } else {
            scheduleStreamingAudioWritePump(generation, streamingAudioIncarnation)
        }
    }

    private fun pauseStreamingAudio(
        generation: Long,
        result: StreamingAudioMethodResult
    ) {
        if (streamingAudioGeneration != generation) {
            result.error(
                "stale_audio_generation",
                "pause generation is no longer active"
            )
            return
        }
        val track = streamingAudioTrack
        if (track == null) {
            result.error("audio_pause_failed", "streaming audio track is not active")
            return
        }
        if (!streamingAudioPaused) {
            try {
                track.pause()
            } catch (error: IllegalStateException) {
                result.error("audio_pause_failed", error.message)
                return
            }
            streamingAudioPaused = true
            streamingAudioWritePumpRunnable?.let { streamingAudioHandler.removeCallbacks(it) }
            streamingAudioWritePumpRunnable = null
            streamingAudioDrainPollRunnable?.let { streamingAudioHandler.removeCallbacks(it) }
            streamingAudioDrainPollRunnable = null
        }
        result.success(streamingAudioReceipt(generation, "paused"))
    }

    private fun resumeStreamingAudio(
        generation: Long,
        result: StreamingAudioMethodResult
    ) {
        if (streamingAudioGeneration != generation) {
            result.error(
                "stale_audio_generation",
                "resume generation is no longer active"
            )
            return
        }
        val track = streamingAudioTrack
        if (track == null || !streamingAudioPaused) {
            result.error("audio_resume_failed", "streaming audio track is not paused")
            return
        }
        try {
            track.play()
        } catch (error: IllegalStateException) {
            result.error("audio_resume_failed", error.message)
            return
        }
        streamingAudioPaused = false
        val resumedAt = SystemClock.uptimeMillis()
        streamingAudioPendingWrites.forEach { it.lastProgressAtMs = resumedAt }
        if (streamingAudioPendingWrites.isNotEmpty()) {
            scheduleStreamingAudioWritePump(generation, streamingAudioIncarnation)
        } else if (streamingAudioDrainGeneration == generation) {
            scheduleStreamingAudioDrainStop(generation)
        }
        result.success(streamingAudioReceipt(generation, "resumed"))
    }

    private fun scheduleStreamingAudioDrainStop(generation: Long) {
        if (streamingAudioPaused) return
        if (streamingAudioDrainPollRunnable != null) return
        if (streamingAudioPendingWrites.isNotEmpty()) {
            scheduleStreamingAudioWritePump(generation, streamingAudioIncarnation)
            return
        }
        val track = streamingAudioTrack
        if (track == null || streamingAudioWrittenFrames == 0L) {
            retireStreamingAudio(completedDrain = true)
            return
        }
        val incarnation = streamingAudioIncarnation
        val targetFrames = streamingAudioWrittenFrames
        val initialPlayedFrames = streamingAudioPlayedFrames(track, generation)
        val remainingFrames = (targetFrames - initialPlayedFrames).coerceAtLeast(0L)
        val expectedRemainingMs =
            remainingFrames * 1000L / streamingAudioSampleRate.coerceAtLeast(1)
        val deadlineMs = SystemClock.uptimeMillis() +
            (expectedRemainingMs + 5000L).coerceIn(5000L, 600000L)

        lateinit var poll: Runnable
        poll = Runnable {
            if (streamingAudioGeneration != generation ||
                streamingAudioIncarnation != incarnation) {
                return@Runnable
            }
            val activeTrack = streamingAudioTrack
            if (activeTrack == null) {
                failStreamingAudio(
                    "audio_drain_failed",
                    "streaming audio track disappeared during drain"
                )
                return@Runnable
            }
            val playedFrames = streamingAudioPlayedFrames(activeTrack, generation)
            if (playedFrames >= targetFrames) {
                retireStreamingAudio(completedDrain = true)
                return@Runnable
            }
            if (SystemClock.uptimeMillis() >= deadlineMs) {
                retireStreamingAudio(
                    completedDrain = false,
                    drainErrorCode = "audio_drain_timeout",
                    drainErrorMessage =
                        "AudioTrack playback head did not reach the drain marker"
                )
                return@Runnable
            }
            if (!streamingAudioHandler.postDelayed(poll, STREAMING_AUDIO_DRAIN_POLL_MS)) {
                retireStreamingAudio(
                    completedDrain = false,
                    drainErrorCode = "audio_drain_failed",
                    drainErrorMessage = "streaming audio worker rejected the drain poll"
                )
            }
        }
        streamingAudioDrainPollRunnable = poll
        if (!streamingAudioHandler.post(poll)) {
            streamingAudioDrainPollRunnable = null
            retireStreamingAudio(
                completedDrain = false,
                drainErrorCode = "audio_drain_failed",
                drainErrorMessage = "streaming audio worker rejected the drain poll"
            )
        }
    }

    private fun positionStreamingAudio(
        generation: Long,
        result: StreamingAudioMethodResult
    ) {
        if (streamingAudioGeneration != generation) {
            result.error(
                "stale_audio_generation",
                "position generation is no longer active"
            )
            return
        }
        val track = streamingAudioTrack
        if (track == null) {
            result.error(
                "audio_position_failed",
                "streaming audio track is not active"
            )
            return
        }
        val acceptedFrames = streamingAudioAcceptedFrames.coerceAtLeast(0L)
        val playedFrames = streamingAudioPlayedFrames(track, generation)
            .coerceIn(0L, acceptedFrames)
        result.success(
            streamingAudioPositionReceipt(
                generation = generation,
                playedFrames = playedFrames,
                acceptedFrames = acceptedFrames
            )
        )
    }

    private fun streamingAudioPlayedFrames(track: AudioTrack, generation: Long): Long {
        if (streamingAudioPlaybackHeadGeneration != generation) {
            streamingAudioPlaybackHeadGeneration = generation
            streamingAudioPlaybackHeadLastRaw = 0L
            streamingAudioPlaybackHeadWrapFrames = 0L
        }
        val raw = track.playbackHeadPosition.toLong() and 0xffffffffL
        val previous = streamingAudioPlaybackHeadLastRaw
        if (raw < previous) {
            val crossedWrapBoundary = previous >= 0xc0000000L && raw <= 0x3fffffffL
            if (crossedWrapBoundary) {
                streamingAudioPlaybackHeadWrapFrames +=
                    STREAMING_AUDIO_PLAYBACK_HEAD_MODULUS
            } else {
                // Some devices briefly report a stale lower value. Keep the
                // counter monotonic rather than mistaking it for playback.
                return streamingAudioPlaybackHeadWrapFrames + previous
            }
        }
        streamingAudioPlaybackHeadLastRaw = raw
        return streamingAudioPlaybackHeadWrapFrames + raw
    }

    private fun streamingAudioReceipt(generation: Long, terminal: String): Map<String, Any> =
        mapOf("generation" to generation, "terminal" to terminal)

    private fun streamingAudioPositionReceipt(
        generation: Long,
        playedFrames: Long,
        acceptedFrames: Long
    ): Map<String, Any> = mapOf(
        "generation" to generation,
        "playedFrames" to playedFrames,
        "acceptedFrames" to acceptedFrames
    )

    private fun startNativeAsr(
        locale: String?,
        requestId: Long,
        result: MethodChannel.Result
    ) {
        val permissionRequestInFlight = pendingStartResult != null
        pendingStartResult?.success(false)
        pendingStartResult = null
        pendingStartLocale = null
        pendingStartRequestId = null

        val previousRequestId = activeNativeAsrRequestId
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        activeNativeAsrRequestId = null
        if (previousRequestId != null) {
            emitNativeAsrCallback("onListening", previousRequestId, false)
        }

        if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
            emitNativeAsrCallback(
                "onError",
                requestId,
                "on-device speech recognition unavailable"
            )
            result.success(false)
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pendingStartResult = result
            pendingStartLocale = locale
            pendingStartRequestId = requestId
            if (!permissionRequestInFlight) {
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 9012)
            }
            return
        }
        result.success(startRecognizer(locale, requestId))
    }

    private fun startRecognizer(locale: String?, requestId: Long): Boolean {
        if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
            emitNativeAsrCallback("onError", requestId, "on-device speech recognition unavailable")
            return false
        }
        speechRecognizer?.destroy()
        speechRecognizer = null
        activeNativeAsrRequestId = requestId
        try {
            speechRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this).also { recognizer ->
                recognizer.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        emitNativeAsrCallback("onListening", requestId, true)
                    }

                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {
                        emitNativeAsrCallback("onListening", requestId, false)
                    }

                    override fun onError(error: Int) {
                        emitNativeAsrCallback("onListening", requestId, false)
                        emitNativeAsrCallback("onError", requestId, "speech recognizer error $error")
                        if (activeNativeAsrRequestId == requestId) {
                            activeNativeAsrRequestId = null
                        }
                    }

                    override fun onResults(results: Bundle?) {
                        emitNativeAsrCallback("onListening", requestId, false)
                        val text = results
                            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            ?.firstOrNull()
                            .orEmpty()
                        emitNativeAsrCallback("onFinal", requestId, text)
                        if (activeNativeAsrRequestId == requestId) {
                            activeNativeAsrRequestId = null
                        }
                    }

                    override fun onPartialResults(partialResults: Bundle?) {
                        val text = partialResults
                            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            ?.firstOrNull()
                            .orEmpty()
                        emitNativeAsrCallback("onPartial", requestId, text)
                    }

                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })
            }

            val language = locale?.takeIf { it.isNotBlank() } ?: Locale.getDefault().toLanguageTag()
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                )
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            }
            speechRecognizer?.startListening(intent)
            return true
        } catch (_: RuntimeException) {
            speechRecognizer?.destroy()
            speechRecognizer = null
            if (activeNativeAsrRequestId == requestId) {
                activeNativeAsrRequestId = null
            }
            emitNativeAsrCallback("onError", requestId, "on-device speech recognition unavailable")
            return false
        }
    }

    private fun emitNativeAsrCallback(method: String, requestId: Long, value: Any) {
        val valueKey = when (method) {
            "onListening" -> "listening"
            "onError" -> "error"
            else -> "text"
        }
        nativeAsrChannel?.invokeMethod(
            method,
            mapOf("requestId" to requestId, valueKey to value)
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 9012) return
        val result = pendingStartResult
        val locale = pendingStartLocale
        val requestId = pendingStartRequestId
        pendingStartResult = null
        pendingStartLocale = null
        pendingStartRequestId = null
        if (
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED &&
            requestId != null
        ) {
            result?.success(startRecognizer(locale, requestId))
        } else {
            if (requestId != null) {
                emitNativeAsrCallback(
                    "onError",
                    requestId,
                    "microphone permission denied"
                )
            }
            result?.success(false)
        }
    }

    override fun onStart() {
        locationBridge?.setForeground(true)
        unityAvatarBridge?.onUnityStart()
        super.onStart()
    }

    override fun onStop() {
        locationBridge?.setForeground(false)
        unityAvatarBridge?.onUnityStop()
        super.onStop()
    }

    override fun onPause() {
        unityAvatarBridge?.onUnityPause()
        super.onPause()
    }

    override fun onResume() {
        unityAvatarBridge?.onUnityResume()
        super.onResume()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        unityAvatarBridge?.onUnityWindowFocusChanged(hasFocus)
        super.onWindowFocusChanged(hasFocus)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        unityAvatarBridge?.onUnityConfigurationChanged(newConfig)
        super.onConfigurationChanged(newConfig)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        unityAvatarBridge?.onUnityNewIntent(intent)
    }

    override fun onTrimMemory(level: Int) {
        avatarPortalTextureBridge?.onTrimMemory(level)
        super.onTrimMemory(level)
    }

    override fun onDestroy() {
        gameSnapshotPlugin?.dispose()
        gameSnapshotPlugin = null
        locationBridge?.dispose()
        locationBridge = null
        streamingAudioSinkChannel?.setMethodCallHandler(null)
        streamingAudioSinkChannel = null
        streamingAudioThreadReleased = true
        val releasePosted = streamingAudioHandler.post {
            retireStreamingAudio(completedDrain = false)
            streamingAudioThread.quitSafely()
        }
        if (!releasePosted) streamingAudioThread.quitSafely()
        avatarPortalTextureBridge?.dispose()
        avatarPortalTextureBridge = null
        unityAvatarBridge?.onUnityDestroy()
        speechRecognizer?.destroy()
        speechRecognizer = null
        activeNativeAsrRequestId = null
        super.onDestroy()
    }
}

/** City-level reverse geocoding only; geolocator owns permission and GPS. */
private class MaasoCityGeocoderBridge(
    private val context: Context,
    private val channel: MethodChannel
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val workerDelegate = lazy {
        ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
            { runnable -> Thread(runnable, "MaasoCityGeocoder").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy())
    }
    private val worker by workerDelegate
    private var foreground = false
    private var disposed = false
    private var sequence = 0L
    private var pendingRequest: Long? = null
    private var pendingResult: MethodChannel.Result? = null
    private var deadline: Runnable? = null
    private var job: Future<*>? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "reverseGeocode" -> reverseGeocode(call.arguments, result)
                "cancelReverseGeocode" -> {
                    cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun setForeground(value: Boolean) {
        foreground = value
        if (!value) cancel()
    }

    private fun reverseGeocode(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val latitude = coordinate(values?.get("latitude"), 90.0)
        val longitude = coordinate(values?.get("longitude"), 180.0)
        if (values?.keys != setOf("latitude", "longitude") || latitude == null || longitude == null) {
            result.success(unavailable("invalid_coordinates"))
            return
        }
        if (disposed || !foreground) {
            result.success(unavailable("cancelled"))
            return
        }
        if (pendingRequest != null) {
            result.success(unavailable("busy"))
            return
        }
        if (!Geocoder.isPresent()) {
            result.success(unavailable("geocoder_unavailable"))
            return
        }
        val request = ++sequence
        pendingRequest = request
        pendingResult = result
        val timeout = Runnable {
            finish(request, unavailable("timeout"))
        }
        deadline = timeout
        mainHandler.postDelayed(timeout, 10_000L)
        try {
            val geocoder = Geocoder(context, Locale.getDefault())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                geocoder.getFromLocation(latitude, longitude, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) {
                        deliver(request, cityPayload(addresses.firstOrNull()))
                    }
                    override fun onError(errorMessage: String?) {
                        deliver(request, unavailable("geocoder_failed"))
                    }
                })
            } else {
                job = worker.submit {
                    val payload = try {
                        @Suppress("DEPRECATION")
                        val addresses = geocoder.getFromLocation(latitude, longitude, 1)
                        cityPayload(addresses?.firstOrNull())
                    } catch (_: Exception) {
                        unavailable("geocoder_failed")
                    }
                    deliver(request, payload)
                }
            }
        } catch (_: Exception) {
            finish(request, unavailable("geocoder_failed"))
        }
    }

    private fun coordinate(raw: Any?, limit: Double): Double? {
        val value = (raw as? Number)?.toDouble() ?: return null
        return value.takeIf { it.isFinite() && kotlin.math.abs(it) <= limit }
    }

    private fun cityText(raw: String?): String? = raw?.trim()?.takeIf {
        it.isNotEmpty() && it.length <= 120 && it.none(Char::isISOControl)
    }

    private fun countryCode(raw: String?): String? = raw?.takeIf {
        it.length == 2 && it.all { letter -> letter in 'A'..'Z' }
    }

    private fun cityPayload(place: Address?): Map<String, Any> {
        val city = cityText(place?.locality) ?: return unavailable("city_unavailable")
        return mapOf("status" to "available", "city" to city,
            "region" to (cityText(place?.adminArea) ?: ""),
            "country" to (cityText(place?.countryName) ?: ""),
            "countryCode" to (countryCode(place?.countryCode) ?: ""))
    }

    private fun unavailable(code: String): Map<String, Any> =
        mapOf("status" to "unavailable", "code" to code)

    private fun deliver(request: Long, payload: Map<String, Any>) {
        mainHandler.post { finish(request, payload) }
    }

    private fun finish(request: Long, payload: Map<String, Any>) {
        if (pendingRequest != request) return
        val result = pendingResult
        pendingRequest = null
        pendingResult = null
        deadline?.let { mainHandler.removeCallbacks(it) }
        deadline = null
        job?.cancel(true)
        job = null
        result?.success(payload)
    }

    private fun cancel() {
        pendingRequest?.let { finish(it, unavailable("cancelled")) }
    }

    fun dispose() {
        disposed = true
        foreground = false
        cancel()
        channel.setMethodCallHandler(null)
        if (workerDelegate.isInitialized()) worker.shutdownNow()
    }
}

private object UnityAvatarCommandPayload {
    fun encode(method: String, arguments: Any?): String {
        return JSONObject()
            .put("method", method)
            .put("json", encodeArguments(arguments))
            .toString()
    }

    private fun encodeArguments(arguments: Any?): String {
        return when (val normalized = normalize(arguments)) {
            is JSONObject -> normalized.toString()
            is JSONArray -> normalized.toString()
            else -> JSONObject().put("value", normalized).toString()
        }
    }

    private fun normalize(value: Any?): Any {
        return when (value) {
            null -> JSONObject()
            is Map<*, *> -> JSONObject().apply {
                value.forEach { entry ->
                    val key = entry.key ?: return@forEach
                    put(key.toString(), normalize(entry.value))
                }
            }
            is List<*> -> JSONArray().apply {
                value.forEach { item -> put(normalize(item)) }
            }
            is Boolean, is Number, is String -> value
            is ByteArray -> JSONObject().put("byteLength", value.size)
            else -> value.toString()
        }
    }
}

private object UnityAvatarAgentSpacePayload {
    val methods = setOf("enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint")
    private val identifiers = Regex("^[A-Za-z0-9._:-]{1,128}$")
    private val receiptKeys = setOf("method", "requestId", "sessionId", "ok", "code")

    fun isValidArguments(method: String, arguments: Any?): Boolean {
        val values = arguments as? Map<*, *> ?: return false
        val moving = method == "requestAgentSpaceMoveAtScreenPoint"
        val keys = if (moving) setOf("requestId", "sessionId", "x", "y")
            else setOf("requestId", "sessionId")
        val allowed = if (moving) keys else keys + setOf("animated", "viewportTop", "viewportBottom")
        if (method !in methods || !values.keys.containsAll(keys) || !allowed.containsAll(values.keys) ||
            !identifier(values["requestId"]) || !identifier(values["sessionId"])) return false
        if (moving) {
            for (key in listOf("x", "y")) {
                val value = (values[key] as? Number)?.toDouble() ?: return false
                if (!value.isFinite() || value < 0 || value > 1) return false
            }
            return true
        }
        if (values.containsKey("animated") && values["animated"] !is Boolean) return false
        if (values.containsKey("viewportTop") != values.containsKey("viewportBottom")) return false
        if (values.containsKey("viewportTop")) {
            for (key in listOf("viewportTop", "viewportBottom")) {
                val value = (values[key] as? Number)?.toDouble() ?: return false
                if (!value.isFinite() || value < 0 || value > 0.45) return false
            }
        }
        return true
    }

    fun publicResult(raw: JSONObject): Map<String, Any>? {
        val method = raw.opt("method") as? String ?: return null
        if (raw.keys().asSequence().toSet() != receiptKeys ||
            method !in methods || !identifier(raw.opt("requestId")) ||
            !identifier(raw.opt("sessionId")) || raw.opt("ok") !is Boolean) return null
        val code = raw.opt("code") as? String ?: return null
        if (code.length > 128 || (code.isNotEmpty() && !identifiers.matches(code))) return null
        return receiptKeys.associateWith { raw.get(it) }
    }

    private fun identifier(value: Any?) = value is String && identifiers.matches(value)
}

private object UnityAvatarBackgroundTaskWorkPayload {
    const val commandMethod = "setBackgroundTaskWork"
    const val stateMethod = "backgroundTaskWorkState"
    private val commandKeys = setOf("requestId", "sessionId", "phase", "loadRequestId",
        "sequence", "issuedAtEpochMs", "deadlineEpochMs")
    private val resultKeys = setOf("method", "requestId", "sessionId", "phase", "loadRequestId",
        "sequence", "ok", "code")
    private val stateKeys = setOf("method", "requestId", "sessionId", "loadRequestId", "phase",
        "furnitureId", "sceneId", "sequence", "workSessionId")
    private val failureCodes = setOf("invalid_command", "deadline_expired", "model_stale", "stale_sequence",
        "session_ended", "session_mismatch", "authority_owned", "not_ready", "presentation_busy",
        "user_pose_owned", "work_unavailable", "mutation_failed")
    private val phases = setOf("approaching", "aligning", "seated", "working", "lying", "rising", "standing")
    private val furnitureIds = setOf("", "sofa", "chair", "desk", "bed")
    private val identifiers = Regex("^[A-Za-z0-9._:-]{1,128}$")
    private val sessions = Regex("^[a-f0-9]{64}$")

    fun isValidArguments(arguments: Any?): Boolean {
        val values = arguments as? Map<*, *> ?: return false
        if (values.keys != commandKeys || !identifier(values["requestId"]) ||
            !session(values["sessionId"]) || !identifier(values["loadRequestId"]) ||
            values["phase"] !in setOf("start", "end") || positiveSafeInteger(values["sequence"]) == null) return false
        val issued = positiveSafeInteger(values["issuedAtEpochMs"]) ?: return false
        val deadline = positiveSafeInteger(values["deadlineEpochMs"]) ?: return false
        return deadline > issued && deadline - issued <= 10000L
    }

    fun publicResult(raw: JSONObject): Map<String, Any?>? {
        val method = raw.opt("method") as? String ?: return null
        if (!identifier(raw.opt("requestId")) || !session(raw.opt("sessionId")) ||
            !identifier(raw.opt("loadRequestId"))) return null
        val sequence = positiveSafeInteger(raw.opt("sequence")) ?: return null
        if (method == commandMethod) {
            if (raw.keys().asSequence().toSet() != resultKeys || raw.opt("phase") !in setOf("start", "end")) return null
            val ok = raw.opt("ok") as? Boolean ?: return null
            val code = raw.opt("code") as? String ?: return null
            if (code.length > 64 || (if (ok) code.isNotEmpty() else code !in failureCodes)) return null
            return mapOf("method" to method, "requestId" to raw.opt("requestId"), "sessionId" to raw.opt("sessionId"),
                "phase" to raw.opt("phase"), "loadRequestId" to raw.opt("loadRequestId"),
                "sequence" to sequence, "ok" to ok, "code" to code)
        }
        if (method != stateMethod || raw.keys().asSequence().toSet() != stateKeys) return null
        val phase = raw.opt("phase") as? String ?: return null
        val furniture = raw.opt("furnitureId") as? String ?: return null
        val scene = raw.opt("sceneId") as? String ?: return null
        if (phase !in phases || furniture !in furnitureIds || (phase != "standing" && furniture.isEmpty()) ||
            scene.isEmpty() || scene.length > 128 || !validFurnitureWorkSession(raw)) return null
        val work = raw.opt("workSessionId")
        if (work != null && work !== JSONObject.NULL && work != "" && work != raw.opt("sessionId")) return null
        return mapOf("method" to method, "requestId" to raw.opt("requestId"), "sessionId" to raw.opt("sessionId"),
            "loadRequestId" to raw.opt("loadRequestId"), "phase" to phase, "furnitureId" to furniture,
            "sceneId" to scene, "sequence" to sequence,
            "workSessionId" to if (work === JSONObject.NULL) null else work)
    }

    fun validFurnitureWorkSession(raw: JSONObject): Boolean {
        val value = raw.opt("workSessionId")
        if (value == null || value === JSONObject.NULL || value == "") return true
        return session(value) && raw.opt("furnitureId") == "desk" &&
            raw.opt("phase") in setOf("approaching", "aligning", "working")
    }

    fun boundedWorkVersion(raw: Any?) = integer(raw, 0L, 2147483647L)

    private fun positiveSafeInteger(raw: Any?) = integer(raw, 1L, 9007199254740991L)

    private fun integer(raw: Any?, minimum: Long, maximum: Long): Long? {
        val number = raw as? Number ?: return null
        val value = number.toDouble()
        if (!value.isFinite() || value < minimum.toDouble() || value > maximum.toDouble() ||
            value != number.toLong().toDouble()) return null
        return number.toLong()
    }

    private fun identifier(raw: Any?) = raw is String && identifiers.matches(raw)
    private fun session(raw: Any?) = raw is String && sessions.matches(raw)
}

private object UnityAvatarArbiterPayload {
    private const val maximumExactInteger = 9007199254740991L
    private const val maximumPayloadBytes = 256 * 1024
    private val channels = setOf("mouth", "expression", "gaze", "bodyGesture", "framing")
    private val commandFailureCodes = setOf(
        "deadline_expired",
        "owner_mismatch",
        "stale_ticket",
        "invalid_command",
        "mutation_failed",
    )
    private val resetFailureCodes = setOf(
        "deadline_expired",
        "mutation_failed",
        "reset_rejected",
    )
    private val commandKeys = setOf(
        "protocolVersion", "requestId", "ticket", "rendererId", "ownerToken",
        "commitToken", "accountGeneration", "rendererGeneration", "channel",
        "fingerprint", "payloadJson", "payloadSha256", "deadlineEpochMs",
        "clearsChannel",
    )
    private val resetKeys = setOf(
        "protocolVersion", "requestId", "requirementId", "rendererId",
        "targetOwnerToken", "commitToken", "retiredAccountGeneration",
        "retiredRendererGeneration", "targetAccountGeneration",
        "targetRendererGeneration", "payloadJson", "payloadSha256",
        "deadlineEpochMs",
    )

    fun isValidArguments(method: String, raw: Any?): Boolean {
        val values = raw as? Map<*, *> ?: return false
        val keys = values.keys.mapNotNull { it as? String }.toSet()
        val expectedKeys = if (method == "avatarArbiterCommand") commandKeys else resetKeys
        if (keys.size != values.size || keys != expectedKeys) return false
        if (exactLong(values["protocolVersion"]) != 1L ||
            !identifier(values["requestId"], 96) ||
            !identifier(values["rendererId"], 96) ||
            !token(values["commitToken"]) ||
            !sha256(values["payloadSha256"]) ||
            !positiveExact(values["deadlineEpochMs"]) ||
            !boundedPayload(values["payloadJson"])) return false
        if (method == "avatarArbiterCommand") {
            val clears = values["clearsChannel"] as? Boolean ?: return false
            val fingerprint = values["fingerprint"] as? String ?: return false
            val channel = values["channel"] as? String ?: return false
            return positiveExact(values["ticket"]) &&
                token(values["ownerToken"]) &&
                nonNegativeExact(values["accountGeneration"]) &&
                nonNegativeExact(values["rendererGeneration"]) &&
                channel in channels &&
                (if (clears) fingerprint.isEmpty() else fingerprint.matches(Regex("^[a-f0-9]{16}$")))
        }
        val retiredRenderer = exactLong(values["retiredRendererGeneration"]) ?: return false
        val targetRenderer = exactLong(values["targetRendererGeneration"]) ?: return false
        return positiveExact(values["requirementId"]) &&
            token(values["targetOwnerToken"]) &&
            nonNegativeExact(values["retiredAccountGeneration"]) &&
            retiredRenderer in 0..maximumExactInteger &&
            nonNegativeExact(values["targetAccountGeneration"]) &&
            targetRenderer in 1..maximumExactInteger &&
            targetRenderer > retiredRenderer &&
            values["payloadJson"] == "{\"reset\":true}"
    }

    fun publicResult(raw: JSONObject): HashMap<String, Any>? {
        val method = raw.opt("method") as? String ?: return null
        val command = method == "avatarArbiterCommand"
        if (!command && method != "avatarArbiterReset") return null
        val expectedKeys = if (command) {
            commandKeys - "payloadJson" + setOf("method", "ok", "code")
        } else {
            resetKeys - "payloadJson" + setOf("method", "ok", "code")
        }
        val keys = buildSet {
            val iterator = raw.keys()
            while (iterator.hasNext()) add(iterator.next())
        }
        if (keys != expectedKeys) return null
        val source = hashMapOf<String, Any>()
        for (key in expectedKeys) {
            val value = raw.opt(key)
            if (value == null || value === JSONObject.NULL) return null
            source[key] = value
        }
        // Receipt payload JSON is intentionally not forwarded. Validate every
        // remaining field explicitly below rather than trusting Unity output.
        if (exactLong(source["protocolVersion"]) != 1L ||
            !identifier(source["requestId"], 96) ||
            !identifier(source["rendererId"], 96) ||
            !token(source["commitToken"]) ||
            !sha256(source["payloadSha256"]) ||
            !positiveExact(source["deadlineEpochMs"]) ||
            source["ok"] !is Boolean || source["code"] !is String) return null
        val ok = source["ok"] as Boolean
        val code = source["code"] as String
        val failureCodes = if (command) commandFailureCodes else resetFailureCodes
        if ((ok && code.isNotEmpty()) || (!ok && code !in failureCodes)) return null
        if (command) {
            val clears = source["clearsChannel"] as? Boolean ?: return null
            val fingerprint = source["fingerprint"] as? String ?: return null
            val channel = source["channel"] as? String ?: return null
            if (!positiveExact(source["ticket"]) ||
                !token(source["ownerToken"]) ||
                !nonNegativeExact(source["accountGeneration"]) ||
                !nonNegativeExact(source["rendererGeneration"]) ||
                channel !in channels ||
                !(if (clears) fingerprint.isEmpty() else fingerprint.matches(Regex("^[a-f0-9]{16}$")))) return null
        } else {
            val retiredRenderer = exactLong(source["retiredRendererGeneration"]) ?: return null
            val targetRenderer = exactLong(source["targetRendererGeneration"]) ?: return null
            if (!positiveExact(source["requirementId"]) ||
                !token(source["targetOwnerToken"]) ||
                !nonNegativeExact(source["retiredAccountGeneration"]) ||
                retiredRenderer !in 0..maximumExactInteger ||
                !nonNegativeExact(source["targetAccountGeneration"]) ||
                targetRenderer !in 1..maximumExactInteger ||
                targetRenderer <= retiredRenderer) return null
        }
        return source
    }

    private fun exactLong(raw: Any?): Long? {
        val number = raw as? Number ?: return null
        if (number !is Byte && number !is Short &&
            number !is Int && number !is Long) return null
        val value = number.toLong()
        return value.takeIf {
            value.toDouble() == number.toDouble() &&
                value in -maximumExactInteger..maximumExactInteger
        }
    }

    private fun positiveExact(raw: Any?) = exactLong(raw)?.let { it > 0 } == true
    private fun nonNegativeExact(raw: Any?) = exactLong(raw)?.let { it >= 0 } == true
    private fun identifier(raw: Any?, maximum: Int): Boolean {
        val value = raw as? String ?: return false
        return value.isNotEmpty() && value.length <= maximum &&
            value.matches(Regex("^[A-Za-z0-9][A-Za-z0-9_.:-]*$"))
    }
    private fun token(raw: Any?) =
        (raw as? String)?.matches(Regex("^[A-Za-z0-9_-]{43}$")) == true
    private fun sha256(raw: Any?) =
        (raw as? String)?.matches(Regex("^[a-f0-9]{64}$")) == true
    private fun boundedPayload(raw: Any?): Boolean {
        val value = raw as? String ?: return false
        return value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= maximumPayloadBytes
    }
}

private interface UnityAvatarCommandSink {
    fun attach(container: FrameLayout, onReady: () -> Unit): Boolean
    fun detach()
    fun send(method: String, arguments: Any?)
    fun sendTicketed(method: String, arguments: Any?): Boolean
    fun onStart()
    fun onStop()
    fun onPause()
    fun onResume()
    fun onDestroy()
    fun onWindowFocusChanged(hasFocus: Boolean)
    fun onConfigurationChanged(newConfig: Configuration)
    fun onNewIntent(intent: Intent)
}

private class PlaceholderUnityAvatarCommandSink : UnityAvatarCommandSink {
    override fun attach(container: FrameLayout, onReady: () -> Unit): Boolean = false
    override fun detach() {}
    override fun send(method: String, arguments: Any?) {}
    override fun sendTicketed(method: String, arguments: Any?): Boolean = false
    override fun onStart() {}
    override fun onStop() {}
    override fun onPause() {}
    override fun onResume() {}
    override fun onDestroy() {}
    override fun onWindowFocusChanged(hasFocus: Boolean) {}
    override fun onConfigurationChanged(newConfig: Configuration) {}
    override fun onNewIntent(intent: Intent) {}
}

private object UnityAvatarCommandSinkFactory {
    fun create(context: Context): UnityAvatarCommandSink {
        val runtimeSink = RuntimeUnityAvatarCommandSink(context)
        return if (runtimeSink.isAvailable) {
            runtimeSink
        } else {
            PlaceholderUnityAvatarCommandSink()
        }
    }
}

private class RuntimeUnityAvatarCommandSink(
    private val context: Context
) : UnityAvatarCommandSink {
    private val unityPlayerForActivityOrServiceClass: Class<*>? = runCatching {
        Class.forName("com.unity3d.player.UnityPlayerForActivityOrService")
    }.getOrNull()
    private val unityPlayerClass: Class<*>? = runCatching {
        Class.forName("com.unity3d.player.UnityPlayer")
    }.getOrNull()
    private val unityPlayerConstructor = unityPlayerForActivityOrServiceClass?.let { unityClass ->
        runCatching {
            unityClass.getConstructor(Context::class.java)
        }.getOrNull()
    }
    private val getUnityViewMethod = unityPlayerForActivityOrServiceClass?.let { unityClass ->
        runCatching {
            unityClass.getMethod("getView")
        }.getOrNull()
    }
    private val isNativeInitialized = unityPlayerClass?.let { unityClass ->
        runCatching {
            unityClass.getDeclaredMethod("isNativeInitialized").apply {
                isAccessible = true
            }
        }.getOrNull()
    }
    private val unitySendMessage = unityPlayerClass?.let { unityClass ->
        runCatching {
            unityClass.getMethod(
                "UnitySendMessage",
                String::class.java,
                String::class.java,
                String::class.java
            )
        }.getOrNull()
    }
    private var unityPlayer: Any? = null
    private var unityView: View? = null
    private var flushHost: View? = null
    private var readyCallback: (() -> Unit)? = null
    private var flushScheduled = false
    private var didNotifyReady = false
    private var destroyed = false
    private val pendingCommands = ArrayDeque<String>()

    val isAvailable: Boolean
        get() = unityPlayerForActivityOrServiceClass != null &&
            unityPlayerConstructor != null &&
            unityPlayerClass != null &&
            unitySendMessage != null

    override fun attach(container: FrameLayout, onReady: () -> Unit): Boolean {
        flushHost = container
        readyCallback = onReady
        val view = resolveUnityView() ?: return false
        (view.parent as? ViewGroup)?.removeView(view)
        view.isClickable = false
        view.isFocusable = false
        view.isFocusableInTouchMode = false
        container.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        flushPendingCommands()
        return true
    }

    override fun detach() {
        (unityView?.parent as? ViewGroup)?.removeView(unityView)
        flushHost = null
        readyCallback = null
    }

    override fun send(method: String, arguments: Any?) {
        val payload = arguments as? String ?: return
        pendingCommands.add(payload)
        flushPendingCommands()
    }

    override fun sendTicketed(method: String, arguments: Any?): Boolean {
        if (destroyed) return false
        val payload = arguments as? String ?: return false
        val player = unityPlayer ?: run {
            resolveUnityView()
            unityPlayer
        } ?: return false
        if (!isUnityNativeReady(player)) return false
        return runCatching {
            val sendMessage = unitySendMessage ?: return false
            sendMessage.invoke(
                null,
                "Main Camera",
                "OnFlutterCommand",
                payload,
            )
            true
        }.getOrDefault(false)
    }

    override fun onStart() {
        callUnityPlayer("onStart")
    }

    override fun onStop() {
        callUnityPlayer("onStop")
    }

    override fun onPause() {
        callUnityPlayer("onPause")
    }

    override fun onResume() {
        callUnityPlayer("onResume")
        flushPendingCommands()
    }

    override fun onDestroy() {
        destroyed = true
        pendingCommands.clear()
        callUnityPlayer("destroy")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        callUnityPlayer("windowFocusChanged", Boolean::class.javaPrimitiveType, hasFocus)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        callUnityPlayer("configurationChanged", Configuration::class.java, newConfig)
    }

    override fun onNewIntent(intent: Intent) {
        callUnityPlayer("newIntent", Intent::class.java, intent)
    }

    private fun resolveUnityView(): View? {
        unityView?.let { return it }
        val player = unityPlayer ?: createUnityPlayer().also {
            unityPlayer = it
        } ?: return null
        val view = runCatching {
            getUnityViewMethod?.invoke(player) as? View
        }.getOrNull()
        unityView = view
        return view
    }

    private fun createUnityPlayer(): Any? {
        return runCatching {
            unityPlayerConstructor?.newInstance(context)
        }.onFailure { error ->
            Log.w("UnityAvatar", "UnityPlayerForActivityOrService init failed", error)
        }.getOrNull()
    }

    private fun flushPendingCommands() {
        if (destroyed) return
        val player = unityPlayer ?: run {
            resolveUnityView()
            unityPlayer
        } ?: return

        if (!isUnityNativeReady(player)) {
            scheduleFlush()
            return
        }

        notifyReady()
        while (pendingCommands.isNotEmpty()) {
            val payload = pendingCommands.removeFirst()
            runCatching {
                unitySendMessage?.invoke(
                    null,
                    "Main Camera",
                    "OnFlutterCommand",
                    payload
                )
            }.onFailure { error ->
                Log.w("UnityAvatar", "UnitySendMessage failed", error)
            }
        }
    }

    private fun scheduleFlush() {
        val host = flushHost ?: return
        if (flushScheduled || destroyed) return
        flushScheduled = true
        host.postDelayed({
            flushScheduled = false
            flushPendingCommands()
        }, 100L)
    }

    private fun isUnityNativeReady(player: Any): Boolean {
        return runCatching {
            isNativeInitialized?.invoke(player) as? Boolean
        }.getOrNull() == true
    }

    private fun notifyReady() {
        if (didNotifyReady) return
        didNotifyReady = true
        readyCallback?.invoke()
    }

    private fun callUnityPlayer(methodName: String) {
        val player = unityPlayer ?: return
        runCatching {
            player.javaClass.getMethod(methodName).invoke(player)
        }
    }

    private fun callUnityPlayer(methodName: String, parameterType: Class<*>?, argument: Any) {
        val player = unityPlayer ?: return
        val type = parameterType ?: return
        runCatching {
            player.javaClass.getMethod(methodName, type).invoke(player, argument)
        }
    }
}

private class UnityAvatarBridge(
    private val activity: MainActivity,
    flutterEngine: FlutterEngine,
    private val commandSink: UnityAvatarCommandSink = UnityAvatarCommandSinkFactory.create(activity)
) {
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "maaso/unity_avatar"
    )
    private var unityUnderlayContainer: PassthroughUnityAvatarContainer? = null
    private var activityStarted = false
    private var activityResumed = false
    private var activityWindowFocused = false
    private var didReplayLifecycleForAttachment = false
    private var didEmitReady = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareView" -> {
                    if (attachToFlutterUnderlay()) {
                        completeCommand(call, result)
                    } else {
                        result.error(
                            "unity_view_unavailable",
                            "Unity avatar underlay unavailable",
                            null
                        )
                    }
                }
                "loadAvatar" -> completeCommand(call, result)
                "setBackgroundTaskWork" -> completeBackgroundTaskWorkCommand(call, result)
                "avatarArbiterCommand", "avatarArbiterReset" ->
                    completeArbiterCommand(call, result)
                "setExpression" -> completeCommand(call, result)
                "setLocalAvatarVisible" -> completeCommand(call, result)
                "enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint" ->
                    completeAgentSpaceCommand(call, result)
                "setMouthOpen" -> completeCommand(call, result)
                "setGaze" -> completeCommand(call, result)
                "clearGaze" -> completeCommand(call, result)
                "startLipSync" -> completeCommand(call, result)
                "syncSpeechPlaybackClock", "setConversationPhase" -> completeCommand(call, result)
                "startVisemeTimeline" -> completeCommand(call, result)
                "stopLipSync" -> completeCommand(call, result)
                "playPrimitive" -> completeCommand(call, result)
                "playAnimationClip" -> completeCommand(call, result)
                "reactToScreenTap" -> completeCommand(call, result)
                "setHandIkTarget" -> completeCommand(call, result)
                "setBodyPose" -> completeCommand(call, result)
                "transitionPresence", "transitionLoginDoorway", "setPhoneInteraction" -> completeCommand(call, result)
                "playMotion" -> completeCommand(call, result)
                "playMotionSequence" -> completeCommand(call, result)
                "setFraming" -> completeCommand(call, result)
                "setViewportSafeArea" -> completeCommand(call, result)
                "setWorldTimeOfDay" -> completeCommand(call, result)
                "setWorldCamera" -> completeCommand(call, result)
                "pause" -> {
                    commandSink.onPause()
                    result.success(null)
                }
                "resume" -> {
                    commandSink.onResume()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun attachToFlutterUnderlay(): Boolean {
        val content = activity.findViewById<FrameLayout>(android.R.id.content) ?: return false
        val container = unityUnderlayContainer ?: PassthroughUnityAvatarContainer(activity).apply {
            setBackgroundColor(Color.TRANSPARENT)
            isClickable = false
            isFocusable = false
            isFocusableInTouchMode = false
        }.also { container ->
            unityUnderlayContainer = container
            content.addView(
                container,
                0,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
        }

        val attached = if (commandSink.attach(container) {
                emitReady()
            }) {
            true
        } else {
            false
        }
        if (attached) {
            replayUnityLifecycleAfterAttach()
            for (index in 0 until content.childCount) {
                val child = content.getChildAt(index)
                if (child !== container) {
                    child.bringToFront()
                }
            }
        }
        return attached
    }

    fun emitReady() {
        if (didEmitReady) return
        didEmitReady = true
        channel.invokeMethod("ready", null)
    }

    private fun replayUnityLifecycleAfterAttach() {
        if (didReplayLifecycleForAttachment) return
        didReplayLifecycleForAttachment = true
        if (activityStarted) {
            commandSink.onStart()
        }
        if (activityResumed) {
            commandSink.onResume()
        }
        commandSink.onWindowFocusChanged(activityWindowFocused)
    }

    private fun completeCommand(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val payload = UnityAvatarCommandPayload.encode(call.method, call.arguments)
        commandSink.send(call.method, payload)
        result.success(null)
    }

    private fun completeArbiterCommand(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (!UnityAvatarArbiterPayload.isValidArguments(call.method, call.arguments)) {
            result.error(
                "invalid_unity_avatar_arbiter_command",
                "Unity Avatar arbiter command is invalid.",
                null,
            )
            return
        }
        val payload = UnityAvatarCommandPayload.encode(call.method, call.arguments)
        if (!commandSink.sendTicketed(call.method, payload)) {
            result.error("not_ready", "Unity Avatar renderer is not ready.", null)
            return
        }
        result.success(null)
    }

    private fun completeAgentSpaceCommand(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (!UnityAvatarAgentSpacePayload.isValidArguments(call.method, call.arguments)) {
            result.error("invalid_agent_space_command", "Personal-room command is invalid.", null)
            return
        }
        val payload = UnityAvatarCommandPayload.encode(call.method, call.arguments)
        if (!commandSink.sendTicketed(call.method, payload)) {
            result.error("not_ready", "Unity Avatar renderer is not ready.", null)
            return
        }
        result.success(null)
    }

    private fun completeBackgroundTaskWorkCommand(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (!UnityAvatarBackgroundTaskWorkPayload.isValidArguments(call.arguments)) {
            result.error("invalid_background_task_work_command", "Task work command is invalid.", null)
            return
        }
        val payload = UnityAvatarCommandPayload.encode(call.method, call.arguments)
        if (!commandSink.sendTicketed(call.method, payload)) {
            result.error("not_ready", "Unity Avatar renderer is not ready.", null)
            return
        }
        result.success(null)
    }

    fun emitCommandResult(payload: String) {
        val raw = runCatching { JSONObject(payload) }.getOrNull() ?: return
        val method = raw.optString("method")
        if (method == UnityAvatarBackgroundTaskWorkPayload.commandMethod ||
            method == UnityAvatarBackgroundTaskWorkPayload.stateMethod) {
            val result = UnityAvatarBackgroundTaskWorkPayload.publicResult(raw) ?: return
            channel.invokeMethod("commandResult", result)
            return
        }
        if (method in UnityAvatarAgentSpacePayload.methods) {
            val receipt = UnityAvatarAgentSpacePayload.publicResult(raw) ?: return
            channel.invokeMethod("commandResult", receipt)
            return
        }
        if (method == "avatarArbiterCommand" || method == "avatarArbiterReset") {
            val result = UnityAvatarArbiterPayload.publicResult(raw) ?: return
            channel.invokeMethod("commandResult", result)
            return
        }
        if (method == "furnitureState") {
            if (!UnityAvatarBackgroundTaskWorkPayload.validFurnitureWorkSession(raw)) return
            val owner = raw.opt("ownerToken") as? String ?: return
            val phase = raw.opt("phase") as? String ?: return
            val furniture = raw.opt("furnitureId") as? String ?: return
            val scene = raw.opt("sceneId") as? String ?: return
            if (owner.isEmpty() || owner.length > 256 || scene.isEmpty() || scene.length > 128 ||
                phase !in setOf("approaching", "aligning", "seated", "working", "lying", "rising", "standing") ||
                furniture !in setOf("", "sofa", "chair", "desk", "bed")) return
            val result = hashMapOf<String, Any>("method" to method, "ownerToken" to owner,
                "phase" to phase, "furnitureId" to furniture, "sceneId" to scene)
            for (key in listOf("accountGeneration", "rendererGeneration", "sequence")) {
                val value = raw.opt(key) as? Number ?: return
                val number = value.toDouble()
                if (!number.isFinite() || number < (if (key == "sequence") 1 else 0) || number > 9007199254740991.0 || number != value.toLong().toDouble()) return
                result[key] = value.toLong()
            }
            (raw.opt("workSessionId") as? String)?.let { result["workSessionId"] = it }
            channel.invokeMethod("commandResult", result)
            return
        }
        if (method !in setOf(
                "loadAvatar",
                "transitionPresence", "transitionLoginDoorway", "setPhoneInteraction",
            )
        ) return
        val requestId = raw.optString("requestId").trim()
        if (requestId.isEmpty() || !raw.has("ok")) return
        val ok = raw.optBoolean("ok")
        val result = hashMapOf<String, Any>(
            "requestId" to requestId,
            "method" to method,
            "ok" to ok,
        )
        if (method == "setPhoneInteraction") {
            val interactionId = raw.opt("interactionId") as? String ?: return
            val phase = raw.opt("phase") as? String ?: return
            result["interactionId"] = interactionId
            result["phase"] = phase
            result["code"] = raw.optString("code")
            channel.invokeMethod("commandResult", result)
            return
        }
        if (method == "transitionPresence" || method == "transitionLoginDoorway") {
            val transitionId = raw.opt("transitionId") as? String ?: return
            val phase = raw.opt("phase") as? String ?: return
            result["transitionId"] = transitionId
            result["phase"] = phase
            result["code"] = raw.optString("code")
            channel.invokeMethod("commandResult", result)
            return
        }
        if (method == "loadAvatar") {
            raw.optString("code").trim().takeIf { it.isNotEmpty() }?.let {
                result["code"] = it
            }
            raw.optString("message").trim().takeIf { it.isNotEmpty() }?.let {
                result["message"] = it
            }
            if (raw.has("cacheHit")) {
                result["cacheHit"] = raw.optBoolean("cacheHit")
            }
            raw.optString("assetSha256").trim()
                .takeIf { it.matches(Regex("^[a-f0-9]{64}$")) }
                ?.let { result["assetSha256"] = it }
            if (raw.has("backgroundTaskWorkVersion")) {
                val version = UnityAvatarBackgroundTaskWorkPayload.boundedWorkVersion(raw.opt("backgroundTaskWorkVersion"))
                if (version == null) {
                    result["ok"] = false
                    result["code"] = "invalid_background_task_work_version"
                    result["message"] = "Unity avatar work presentation version is invalid."
                } else {
                    result["backgroundTaskWorkVersion"] = version
                }
            }
            channel.invokeMethod("commandResult", result)
            return
        }

    }

    fun onUnityStart() {
        activityStarted = true
        commandSink.onStart()
    }

    fun onUnityStop() {
        activityStarted = false
        commandSink.onStop()
    }

    fun onUnityPause() {
        activityResumed = false
        commandSink.onPause()
    }

    fun onUnityResume() {
        activityResumed = true
        commandSink.onResume()
    }

    fun onUnityDestroy() = commandSink.onDestroy()

    fun onUnityWindowFocusChanged(hasFocus: Boolean) {
        activityWindowFocused = hasFocus
        commandSink.onWindowFocusChanged(hasFocus)
    }

    fun onUnityConfigurationChanged(newConfig: Configuration) =
        commandSink.onConfigurationChanged(newConfig)

    fun onUnityNewIntent(intent: Intent) = commandSink.onNewIntent(intent)
}

private class PassthroughUnityAvatarContainer(context: Context) : FrameLayout(context) {
    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = false

    override fun dispatchTouchEvent(event: MotionEvent): Boolean = false
}
