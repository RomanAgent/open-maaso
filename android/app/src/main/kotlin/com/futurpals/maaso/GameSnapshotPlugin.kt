package com.futurpals.maaso

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A bounded snapshot of one existing game WebView, never a Window/screen capture. */
class GameSnapshotPlugin(activity: Activity, private val engine: FlutterEngine) {
    private val owner = WeakReference(activity)
    private val main = Handler(Looper.getMainLooper())
    private val encoder = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(1)
    )
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "maaso/game_snapshot")
    private var active: Capture? = null
    private var disposed = false

    private class Capture(val result: MethodChannel.Result, val startedAt: Long) {
        var replied = false
        var deadline: Runnable? = null
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "captureOpenedPlayer") {
                result.notImplemented()
            } else {
                capture(call.arguments, result)
            }
        }
    }

    @Suppress("DEPRECATION") // Pinned WebView plugin exposes this engine-bound external API.
    private fun capture(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *>
        val raw = args?.get("webViewIdentifier")
        val identifier = when (raw) {
            is Int -> raw.toLong()
            is Long -> raw
            else -> null
        }
        if (disposed || active != null || args?.keys != setOf("webViewIdentifier") || identifier == null || identifier < 0) {
            result.success(null)
            return
        }
        val view = WebViewFlutterAndroidExternalApi.getWebView(engine, identifier)
        if (view == null || !visible(view)) {
            result.success(null)
            return
        }
        val capture = Capture(result, SystemClock.uptimeMillis())
        active = capture
        val weakView = WeakReference(view)
        capture.deadline = Runnable { reply(capture, null) }
        main.postDelayed(capture.deadline!!, 2500L)
        main.post {
            val target = weakView.get()
            if (active !== capture || capture.replied || target == null || !visible(target) || SystemClock.uptimeMillis() - capture.startedAt >= 2500L) {
                finishPhysical(capture, null)
                return@post
            }
            var bitmap: Bitmap? = null
            try {
                val factor = min(1.0, 640.0 / max(target.width, target.height))
                val width = max(1, (target.width * factor).roundToInt())
                val height = max(1, (target.height * factor).roundToInt())
                val snapshot = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap = snapshot
                val canvas = Canvas(snapshot)
                canvas.scale(width.toFloat() / target.width, height.toFloat() / target.height)
                // View.draw renders this WebView only. No PixelCopy(Window),
                // camera, MediaProjection, JS navigation or other app pixels.
                target.draw(canvas)
                encoder.execute {
                    val bytes = try {
                        ByteArrayOutputStream().use { output ->
                            if (!snapshot.compress(Bitmap.CompressFormat.JPEG, 78, output)) null
                            else output.toByteArray().takeIf { it.size <= 256 * 1024 }
                        }
                    } catch (_: Exception) {
                        null
                    } catch (_: OutOfMemoryError) {
                        null
                    } finally {
                        snapshot.recycle()
                    }
                    main.post {
                        val current = weakView.get()
                        finishPhysical(capture, if (current != null && visible(current)) bytes else null)
                    }
                }
                bitmap = null // The encoding job now owns the bounded pixels.
            } catch (_: Exception) {
                bitmap?.recycle()
                finishPhysical(capture, null)
            } catch (_: OutOfMemoryError) {
                bitmap?.recycle()
                finishPhysical(capture, null)
            }
        }
    }

    private fun visible(view: WebView): Boolean {
        val activity = owner.get() ?: return false
        val decor = activity.window?.decorView ?: return false
        return !disposed && !activity.isFinishing && !activity.isDestroyed &&
            activity.hasWindowFocus() && decor.isShown && view.isAttachedToWindow &&
            view.isShown && view.windowVisibility == View.VISIBLE && view.alpha > 0f &&
            view.width > 0 && view.height > 0 && view.windowToken == decor.windowToken &&
            view.getGlobalVisibleRect(Rect())
    }

    private fun reply(capture: Capture, bytes: ByteArray?) {
        if (capture.replied) return
        capture.replied = true
        capture.result.success(bytes)
    }

    private fun finishPhysical(capture: Capture, bytes: ByteArray?) {
        if (active !== capture) return
        capture.deadline?.let(main::removeCallbacks)
        active = null
        reply(capture, if (disposed) null else bytes)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        active?.let { capture ->
            capture.deadline?.let(main::removeCallbacks)
            reply(capture, null)
        }
        // Let an existing encode drain and recycle its bitmap. A deadline or
        // disposal never makes its physical slot reusable by another request.
        encoder.shutdown()
    }
}
