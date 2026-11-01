package com.futurpals.maaso

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.lang.ref.WeakReference
import org.json.JSONObject

internal class AvatarPortalTextureBridge(
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )
    private val textureRegistry = flutterEngine.renderer
    private val mainHandler = Handler(Looper.getMainLooper())
    private val unitySendMessage = runCatching {
        Class.forName("com.unity3d.player.UnityPlayer").getMethod(
            "UnitySendMessage",
            String::class.java,
            String::class.java,
            String::class.java,
        )
    }.getOrNull()

    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var portalSurface: Surface? = null
    private var generation = 0
    private var width = 0
    private var height = 0
    private var firstFrameGeneration = 0

    init {
        System.loadLibrary("maaso_live_rtc")
        active = WeakReference(this)
        nativeInitialize()
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> acquire(call, result)
            "suspend", "resume" -> {
                val requestedGeneration = call.argument<Int>("generation") ?: 0
                if (requestedGeneration == generation && generation > 0) {
                    sendUnityCommand(call.method, generation)
                }
                result.success(null)
            }
            "release" -> {
                val requestedGeneration = call.argument<Int>("generation") ?: 0
                if (requestedGeneration <= 0 || requestedGeneration == generation) {
                    release(notifyUnity = true)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onTrimMemory(level: Int) {
        // ComponentCallbacks2 memory constants are deprecated at API 35, but
        // Activity still delivers the same numeric levels for compatibility.
        if (level >= RUNNING_CRITICAL_MEMORY_LEVEL) {
            val releasedGeneration = generation
            release(notifyUnity = true)
            channel.invokeMethod(
                "event",
                mapOf(
                    "type" to "released",
                    "reason" to "memoryPressure",
                    "generation" to releasedGeneration,
                ),
            )
        }
    }

    fun dispose() {
        release(notifyUnity = true)
        channel.setMethodCallHandler(null)
        if (active?.get() === this) {
            active = null
        }
    }

    private fun acquire(call: MethodCall, result: MethodChannel.Result) {
        val requestedGeneration = call.argument<Int>("generation") ?: 0
        if (requestedGeneration <= 0) {
            result.error(
                "invalid_avatar_portal_generation",
                "Avatar portal generation must be positive.",
                null,
            )
            return
        }
        val profile = call.argument<String>("profile") ?: "compactHigh"
        val dimensions = dimensionsFor(profile)
        release(notifyUnity = true)
        generation = requestedGeneration
        width = dimensions.first
        height = dimensions.second
        firstFrameGeneration = 0

        val producer = textureRegistry.createSurfaceProducer(
            TextureRegistry.SurfaceLifecycle.manual,
        )
        producer.setSize(width, height)
        producer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceCleanup() {
                    if (generation == requestedGeneration) {
                        nativeClearSurface(requestedGeneration)
                    }
                }
            },
        )
        val surface = producer.forcedNewSurface
        surfaceProducer = producer
        portalSurface = surface
        if (!nativeSetSurface(surface, width, height, requestedGeneration)) {
            release(notifyUnity = false)
            result.error(
                "avatar_portal_surface_unavailable",
                "Android could not attach the Avatar portal Surface.",
                null,
            )
            return
        }
        if (!sendUnityCommand("acquire", requestedGeneration, profile)) {
            release(notifyUnity = false)
            result.error(
                "avatar_portal_unity_unavailable",
                "The existing Unity Avatar runtime is unavailable.",
                null,
            )
            return
        }
        result.success(
            mapOf(
                "textureId" to producer.id(),
                "width" to width,
                "height" to height,
                "generation" to requestedGeneration,
            ),
        )
    }

    private fun release(notifyUnity: Boolean) {
        val releasedGeneration = generation
        generation = 0
        firstFrameGeneration = 0
        if (notifyUnity && releasedGeneration > 0) {
            sendUnityCommand("release", releasedGeneration)
        }
        nativeClearSurface(releasedGeneration)
        portalSurface?.release()
        portalSurface = null
        surfaceProducer?.release()
        surfaceProducer = null
        width = 0
        height = 0
    }

    private fun sendUnityCommand(
        method: String,
        activeGeneration: Int,
        profile: String? = null,
    ): Boolean {
        val sender = unitySendMessage ?: return false
        val payload = JSONObject()
            .put("method", method)
            .put("generation", activeGeneration)
        if (!profile.isNullOrBlank()) {
            payload.put("profile", profile)
        }
        return runCatching {
            sender.invoke(
                null,
                UNITY_OBJECT_NAME,
                UNITY_METHOD_NAME,
                payload.toString(),
            )
        }.onFailure { error ->
            Log.w(TAG, "Unity Avatar portal command failed: $method", error)
        }.isSuccess
    }

    private fun handleFrameAvailable(frameGeneration: Int) {
        mainHandler.post {
            val producer = surfaceProducer
            if (frameGeneration != generation || producer == null) {
                return@post
            }
            producer.scheduleFrame()
            if (firstFrameGeneration != frameGeneration) {
                firstFrameGeneration = frameGeneration
                channel.invokeMethod(
                    "event",
                    mapOf(
                        "type" to "firstFrame",
                        "generation" to frameGeneration,
                        "textureId" to producer.id(),
                        "width" to width,
                        "height" to height,
                    ),
                )
            }
        }
    }

    private fun dimensionsFor(profile: String): Pair<Int, Int> {
        return when (profile) {
            "compactLow" -> 240 to 416
            "compactBalanced" -> 288 to 496
            else -> 320 to 560
        }
    }

    private external fun nativeInitialize()
    private external fun nativeSetSurface(
        surface: Surface,
        width: Int,
        height: Int,
        generation: Int,
    ): Boolean
    private external fun nativeClearSurface(generation: Int)

    companion object {
        private const val CHANNEL_NAME = "maaso/avatar_portal"
        private const val UNITY_OBJECT_NAME = "Maaso Avatar Portal"
        private const val UNITY_METHOD_NAME = "OnAvatarPortalCommand"
        private const val TAG = "AvatarPortal"
        private const val RUNNING_CRITICAL_MEMORY_LEVEL = 15

        @Volatile
        private var active: WeakReference<AvatarPortalTextureBridge>? = null

        @JvmStatic
        fun frameAvailableNative(generation: Int) {
            active?.get()?.handleFrameAvailable(generation)
        }
    }
}
