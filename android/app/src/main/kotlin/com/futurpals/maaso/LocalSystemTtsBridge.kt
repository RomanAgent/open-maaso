package com.futurpals.maaso

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/** Installed non-network voices only; each synthesis result owns its UUID. */
internal class LocalSystemTtsBridge(context: Context, messenger: BinaryMessenger) {
    private data class Job(val id: String, var result: MethodChannel.Result?, var file: File? = null)
    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "maaso/system_tts")
    private var engine: TextToSpeech? = null
    private var ready = false
    private var initializing = false
    private var closed = false
    private var active: Job? = null
    private val waiters = mutableListOf<(Boolean) -> Unit>()

    init {
        channel.setMethodCallHandler { call, result ->
            if (closed) {
                result.error("system_tts_closed", "System speech is unavailable.", null)
            } else when (call.method) {
                "isAvailable" -> ensureReady { ok -> result.success(ok && localVoices().isNotEmpty()) }
                "synthesize" -> synthesize(call.arguments as? Map<*, *>, result)
                "cancel" -> {
                    val job = active
                    if (job != null && call.argument<String>("id") == job.id) {
                        fail(job, "system_tts_cancelled")
                        result.success(true)
                    } else result.success(false)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun localVoices() = engine?.voices.orEmpty().filter {
        !it.isNetworkConnectionRequired &&
            !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
    }

    private fun ensureReady(callback: (Boolean) -> Unit) {
        if (closed) { callback(false); return }
        if (ready) { callback(true); return }
        waiters.add(callback)
        if (initializing) return
        initializing = true
        engine = TextToSpeech(context) { status ->
            main.post {
                initializing = false
                ready = !closed && status == TextToSpeech.SUCCESS
                if (ready) {
                    engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(id: String?) {}
                        override fun onDone(id: String?) {
                            main.post {
                                val job = active
                                if (job == null || job.id != id) return@post
                                val file = job.file ?: return@post fail(job, "system_tts_audio_format")
                                Thread {
                                    val bytes = try {
                                        if (file.length() in 44..(20L * 1024 * 1024)) file.readBytes() else null
                                    } catch (_: Exception) { null }
                                    main.post {
                                        file.delete()
                                        if (active !== job) return@post
                                        if (bytes == null) { fail(job, "system_tts_audio_format"); return@post }
                                        val response = job.result
                                        job.result = null
                                        active = null
                                        response?.success(bytes)
                                    }
                                }.start()
                            }
                        }
                        @Deprecated("Platform callback")
                        override fun onError(id: String?) = error(id)
                        override fun onError(id: String?, code: Int) = error(id)
                        override fun onStop(id: String?, interrupted: Boolean) = error(id)
                        private fun error(id: String?) {
                            main.post { active?.takeIf { it.id == id }?.let { fail(it, "system_tts_failed") } }
                        }
                    })
                }
                val callbacks = waiters.toList()
                waiters.clear()
                callbacks.forEach { it(ready) }
            }
        }
    }

    private fun synthesize(args: Map<*, *>?, result: MethodChannel.Result) {
        val id = args?.get("id") as? String
        val text = args?.get("text") as? String
        if (id.isNullOrEmpty() || id.length > 128 || text.isNullOrBlank() || text.length > 8000) {
            result.error("system_tts_input", "Invalid system speech request.", null); return
        }
        if (active != null) { result.error("system_tts_busy", "System speech is busy.", null); return }
        val job = Job(id, result)
        active = job
        ensureReady { ok ->
            if (active !== job) return@ensureReady
            if (!ok) { fail(job, "system_tts_unavailable"); return@ensureReady }
            val language = (args?.get("language") as? String ?: "en").replace('_', '-')
            val requested = Locale.forLanguageTag(language)
            val voice = localVoices().filter { it.locale.language == requested.language }
                .sortedByDescending { if (it.locale.toLanguageTag().equals(language, true)) 2 else if (it.locale.country == Locale.getDefault().country) 1 else 0 }
                .firstOrNull()
            if (voice == null || engine?.setVoice(voice) != TextToSpeech.SUCCESS) {
                fail(job, "system_tts_voice_missing"); return@ensureReady
            }
            engine?.setSpeechRate(1.0f)
            engine?.setPitch(1.0f)
            val file = File.createTempFile("maaso-system-", ".wav", context.cacheDir)
            job.file = file
            if (engine?.synthesizeToFile(text, Bundle(), file, id) != TextToSpeech.SUCCESS) {
                fail(job, "system_tts_failed")
            }
        }
        main.postDelayed({ if (active === job) fail(job, "system_tts_timeout") }, 29000)
    }

    private fun fail(job: Job, code: String) {
        if (active !== job) return
        active = null
        val response = job.result
        job.result = null
        engine?.stop()
        job.file?.delete()
        response?.error(code, "Local system speech did not complete.", null)
    }

    fun close() {
        closed = true
        active?.let { fail(it, "system_tts_closed") }
        waiters.toList().also { waiters.clear() }.forEach { it(false) }
        engine?.shutdown()
        channel.setMethodCallHandler(null)
    }
}
