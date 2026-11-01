package com.futurpals.maaso

import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.NoCopySpan
import android.text.SpanWatcher
import android.text.Spannable
import android.text.Spanned
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Home-only genuine text buffer; images, app references and frost stay outside. */
object HomeTextEditorPlugin {
    fun register(flutterEngine: FlutterEngine) {
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "maaso/home_text_editor",
            HomeTextEditorFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
    }
}

private class HomeTextEditorFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        HomeTextEditorView(context, viewId, args as? Map<*, *> ?: emptyMap<Any, Any>(), messenger)
}

// These actual source predicates also run on the host JVM in the contract test.
internal object HomeTextEditorRules {
    data class AttachmentSnapshot(val token: Long, val ids: List<String>, val selectedId: String?, val enabled: Boolean) {
        fun clearingSelection(): AttachmentSnapshot = copy(selectedId = null)

        fun applying(command: AttachmentCommand): AttachmentSnapshot? {
            if (!enabled || command.before != this) return null
            return when {
                command.kind == "boundaryDelete" && selectedId == null && ids.lastOrNull() == command.targetId ->
                    copy(selectedId = command.targetId)
                command.kind == "deleteSelectedAttachment" && selectedId == command.targetId && ids.contains(command.targetId) ->
                    copy(ids = ids.filter { it != command.targetId }, selectedId = null)
                else -> null
            }
        }
    }

    data class AttachmentCommand(val kind: String, val before: AttachmentSnapshot, val targetId: String) {
        fun arguments(): Map<String, Any?> = mapOf(
            "snapshotToken" to before.token, "beforeIds" to before.ids,
            "beforeSelectedId" to before.selectedId, "targetId" to targetId
        )
    }

    fun attachmentSnapshot(raw: Any?): AttachmentSnapshot? {
        val values = raw as? Map<*, *> ?: return null
        val token = integer(values["token"]) ?: return null
        val rawIds = values["ids"] as? List<*> ?: return null
        if (token < 0 || rawIds.size > 4 || rawIds.any { it !is String || it.isEmpty() || it.length > 256 } ||
            !values.containsKey("selectedId")) return null
        val ids = rawIds.filterIsInstance<String>().toList()
        val enabled = values["enabled"] as? Boolean ?: return null
        val selected = values["selectedId"]
        if (ids.toSet().size != ids.size || (selected != null && (selected !is String || !ids.contains(selected)))) return null
        return AttachmentSnapshot(token, ids, selected as? String, enabled)
    }

    fun argb(raw: Any?): Int? {
        val value = integer(raw) ?: return null
        return if (value in 0..0xFFFFFFFFL) value.toInt() else null
    }

    fun fontSize(value: Any?): Float {
        val requested = (value as? Number)?.toFloat() ?: 17f
        return if (requested.isFinite()) requested.coerceIn(10f, 48f) else 17f
    }

    fun integer(value: Any?): Long? = when (value) {
        is Int -> value.toLong()
        is Long -> value
        is Short -> value.toLong()
        is Byte -> value.toLong()
        else -> null
    }

    fun utf16Offset(requested: Long, text: String): Int {
        val offset = requested.coerceIn(0, text.length.toLong()).toInt()
        return if (offset > 0 && offset < text.length &&
            Character.isHighSurrogate(text[offset - 1]) && Character.isLowSurrogate(text[offset])) {
            offset - 1
        } else offset
    }

    fun attachmentCommand(
        enabled: Boolean, attachments: AttachmentSnapshot?,
        selectionBase: Int, selectionExtent: Int, composingStart: Int, composingEnd: Int
    ): AttachmentCommand? {
        if (!enabled || attachments == null || !attachments.enabled || attachments.ids.isEmpty() ||
            selectionBase < 0 || selectionBase != selectionExtent ||
            (composingStart >= 0 && composingEnd >= composingStart)) return null
        if (attachments.selectedId != null) return AttachmentCommand("deleteSelectedAttachment", attachments, attachments.selectedId)
        return if (selectionBase == 0) AttachmentCommand("boundaryDelete", attachments, attachments.ids.last()) else null
    }
}

private data class HomeEditingSnapshot(
    val text: String, val selectionBase: Int, val selectionExtent: Int,
    val composingStart: Int, val composingEnd: Int
) {
    fun arguments(owner: String, sequence: Long, kind: String): Map<String, Any> = mapOf(
        "owner" to owner, "sequence" to sequence, "kind" to kind, "text" to text,
        "selectionBase" to selectionBase, "selectionExtent" to selectionExtent,
        "composingStart" to composingStart, "composingEnd" to composingEnd
    )
}

private data class HomeLayoutMetrics(val width: Double, val contentHeight: Double, val lineHeight: Double)

private class HomeTextEditorView(
    context: Context, viewId: Int, values: Map<*, *>, messenger: BinaryMessenger
) : PlatformView {
    private val owner = values["owner"] as? String ?: ""
    private val editor = HomeBoundaryEditText(context)
    private val channel = MethodChannel(messenger, "maaso/home_text_editor/$viewId")
    private val main = Handler(Looper.getMainLooper())
    private var sequence = 0L
    private var retired = false
    private var suppressEvents = false
    private var enabled = owner.isNotBlank() && (values["enabled"] as? Boolean ?: true)
    private var attachments = HomeTextEditorRules.attachmentSnapshot(values["attachments"])
    private var lastSnapshot: HomeEditingSnapshot? = null
    private var appliedFontSize: Float? = null
    private var appliedDark: Boolean? = null
    private var appliedTextColor: Int? = null
    private var appliedCursorColor: Int? = null
    private var appliedSelectionColor: Int? = null
    private val emitPending = Runnable { emit("edit") }
    private val metricsPending = Runnable { emitMetrics() }
    private var metricsRevision = 0L
    private var lastMetrics: HomeLayoutMetrics? = null
    private var hasAcceptedSync = false

    // This observer has no text content and is explicitly excluded from copied
    // spans. It catches composition-only changes, including newer IME overloads.
    private val composingWatcher = object : SpanWatcher, NoCopySpan {
        override fun onSpanAdded(text: Spannable, what: Any, start: Int, end: Int) {
            if (what !== this) scheduleEdit()
        }
        override fun onSpanRemoved(text: Spannable, what: Any, start: Int, end: Int) {
            if (what !== this) scheduleEdit()
        }
        override fun onSpanChanged(text: Spannable, what: Any, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) {
            if (what !== this) scheduleEdit()
        }
    }
    private val textWatcher = object : TextWatcher {
        override fun beforeTextChanged(text: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(text: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(text: Editable?) {
            observeComposing(text)
            scheduleEdit()
        }
    }

    init {
        editor.setBackgroundColor(Color.TRANSPARENT)
        editor.setPadding(0, 0, 0, 0)
        editor.gravity = Gravity.TOP or Gravity.START
        editor.setSingleLine(false)
        editor.setHorizontallyScrolling(false)
        editor.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        editor.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        editor.isVerticalScrollBarEnabled = false
        editor.contentDescription = "Message"
        applyStyle(values)
        editor.setText(values["text"] as? String ?: "")
        setSelection(values, editor.text.toString())
        // Never restore composition from a previous keyboard connection.
        editor.isEnabled = enabled
        editor.onNativeEdit = { scheduleEdit() }
        editor.onNativeLayout = { scheduleMetrics() }
        editor.onAttachmentDelete = { forward -> deleteAttachment(forward) }
        editor.addTextChangedListener(textWatcher)
        observeComposing(editor.text)
        editor.onFocusChangeListener = View.OnFocusChangeListener { _, focused ->
            if (!focused) BaseInputConnection.removeComposingSpans(editor.text)
            flushEdit()
            emit(if (focused) "focus" else "blur")
        }
        lastSnapshot = snapshot()
        channel.setMethodCallHandler { call, result ->
            if (Looper.myLooper() == Looper.getMainLooper()) handle(call, result)
            else main.post { handle(call, result) }
        }
        scheduleMetrics()
    }

    override fun getView(): View = editor

    private fun applyStyle(values: Map<*, *>) {
        if (appliedFontSize == null || values.containsKey("fontSize")) {
            val size = HomeTextEditorRules.fontSize(values["fontSize"])
            if (appliedFontSize != size) {
                // Flutter already applied MediaQuery's text scaler. Use logical
                // pixels here so Android does not apply fontScale a second time.
                editor.setTextSize(TypedValue.COMPLEX_UNIT_DIP, size)
                appliedFontSize = size
                scheduleMetrics()
            }
        }
        if (appliedDark == null || values.containsKey("dark")) {
            val dark = values["dark"] as? Boolean ?: false
            appliedDark = dark
        }
        val textColor = HomeTextEditorRules.argb(values["textColorArgb"])
            ?: if (appliedDark == true) Color.rgb(231, 233, 237) else Color.rgb(36, 39, 43)
        val cursorColor = HomeTextEditorRules.argb(values["cursorColorArgb"]) ?: Color.rgb(42, 105, 211)
        val selectionColor = HomeTextEditorRules.argb(values["selectionColorArgb"]) ?: Color.argb(50, 42, 105, 211)
        if (appliedTextColor != textColor) {
            editor.setTextColor(textColor)
            appliedTextColor = textColor
        }
        if (appliedCursorColor != cursorColor) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                editor.textCursorDrawable?.mutate()?.setTint(cursorColor)
                editor.textSelectHandleLeft?.mutate()?.setTint(cursorColor)
                editor.textSelectHandleRight?.mutate()?.setTint(cursorColor)
                editor.textSelectHandle?.mutate()?.setTint(cursorColor)
            }
            appliedCursorColor = cursorColor
        }
        if (appliedSelectionColor != selectionColor) {
            editor.highlightColor = selectionColor
            appliedSelectionColor = selectionColor
        }
    }

    private fun scheduleMetrics() {
        if (retired || owner.isBlank()) return
        main.removeCallbacks(metricsPending)
        main.post(metricsPending)
    }

    private fun emitMetrics() {
        if (retired || owner.isBlank() || editor.width <= 0) return
        val layout = editor.layout ?: return
        val density = editor.resources.displayMetrics.density.toDouble()
        if (!density.isFinite() || density <= 0) return
        val metrics = HomeLayoutMetrics(
            editor.width / density,
            (layout.height.toDouble() + editor.compoundPaddingTop + editor.compoundPaddingBottom) / density,
            editor.lineHeight / density
        )
        if (!metrics.width.isFinite() || metrics.width <= 0 || !metrics.contentHeight.isFinite() ||
            metrics.contentHeight <= 0 || !metrics.lineHeight.isFinite() || metrics.lineHeight <= 0 ||
            metrics == lastMetrics) return
        lastMetrics = metrics
        metricsRevision += 1
        channel.invokeMethod("layoutMetrics", mapOf(
            "owner" to owner, "metricsRevision" to metricsRevision, "width" to metrics.width,
            "contentHeight" to metrics.contentHeight, "lineHeight" to metrics.lineHeight
        ))
    }

    private fun observeComposing(text: Editable?) {
        if (text != null && text.getSpanStart(composingWatcher) < 0) {
            text.setSpan(composingWatcher, 0, text.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
    }

    private fun snapshot(): HomeEditingSnapshot {
        val text = editor.text
        return HomeEditingSnapshot(
            text.toString(), editor.selectionStart, editor.selectionEnd,
            BaseInputConnection.getComposingSpanStart(text), BaseInputConnection.getComposingSpanEnd(text)
        )
    }

    private fun requestedSelection(values: Map<*, *>, text: String): Pair<Int, Int> {
        val base = HomeTextEditorRules.utf16Offset(HomeTextEditorRules.integer(values["selectionBase"]) ?: text.length.toLong(), text)
        val extent = HomeTextEditorRules.utf16Offset(HomeTextEditorRules.integer(values["selectionExtent"]) ?: base.toLong(), text)
        return base to extent
    }

    private fun setSelection(values: Map<*, *>, text: String) {
        val (base, extent) = requestedSelection(values, text)
        if (editor.selectionStart != base || editor.selectionEnd != extent) editor.setSelection(base, extent)
    }

    private fun scheduleEdit() {
        if (retired || suppressEvents) return
        main.removeCallbacks(emitPending)
        main.post(emitPending)
    }

    private fun flushEdit() {
        main.removeCallbacks(emitPending)
        emit("edit")
    }

    private fun emit(kind: String, attachment: HomeTextEditorRules.AttachmentCommand? = null) {
        if (retired || suppressEvents || owner.isBlank()) return
        val value = snapshot()
        if (kind == "edit" && value == lastSnapshot) return
        if (value != lastSnapshot) {
            attachments = attachments?.clearingSelection()
            scheduleMetrics()
        }
        lastSnapshot = value
        sequence += 1
        val arguments = value.arguments(owner, sequence, kind).toMutableMap()
        if (attachment != null) arguments["attachment"] = attachment.arguments()
        channel.invokeMethod("editingEvent", arguments)
    }

    private fun deleteAttachment(forward: Boolean): Boolean {
        flushEdit()
        val value = snapshot()
        val command = HomeTextEditorRules.attachmentCommand(
            enabled && !retired, attachments,
            value.selectionBase, value.selectionExtent, value.composingStart, value.composingEnd
        ) ?: return false
        if (forward && command.kind != "deleteSelectedAttachment") return false
        val next = attachments?.applying(command) ?: return false
        attachments = next
        emit(command.kind, command)
        return true
    }

    private fun reply(result: MethodChannel.Result, accepted: Boolean) {
        result.success(mapOf("accepted" to accepted, "sequence" to sequence))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val values = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        if (retired || owner.isBlank() || values["owner"] != owner) { reply(result, false); return }
        if (call.method == "dispose") {
            dispose()
            reply(result, true)
            return
        }
        if (call.method !in listOf("sync", "focus", "blur")) { result.notImplemented(); return }
        flushEdit()
        if (HomeTextEditorRules.integer(values["expectedSequence"]) != sequence) { reply(result, false); return }
        when (call.method) {
            "sync" -> {
                val text = values["text"] as? String
                if (text == null || HomeTextEditorRules.integer(values["selectionBase"]) == null ||
                    HomeTextEditorRules.integer(values["selectionExtent"]) == null ||
                    listOf("textColorArgb", "cursorColorArgb", "selectionColorArgb").any {
                        values.containsKey(it) && HomeTextEditorRules.argb(values[it]) == null
                    }) { reply(result, false); return }
                val (base, extent) = requestedSelection(values, text)
                val current = snapshot()
                val changingValue = current.text != text || current.selectionBase != base || current.selectionExtent != extent
                val nextEnabled = values["enabled"] as? Boolean ?: enabled
                if (current.composingStart >= 0 && current.composingEnd >= current.composingStart &&
                    (changingValue || !nextEnabled)) { reply(result, false); return }
                suppressEvents = true
                try {
                    if (editor.text.toString() != text) editor.setText(text)
                    setSelection(values, text)
                    // Attribute changes preserve the same view/input connection,
                    // including when a style-only sync arrives during composition.
                    applyStyle(values)
                    attachments = HomeTextEditorRules.attachmentSnapshot(values["attachments"])
                    enabled = nextEnabled
                    if (editor.isEnabled != enabled) editor.isEnabled = enabled
                    if (!enabled) {
                        editor.clearFocus()
                        hideKeyboard()
                    }
                    lastSnapshot = snapshot()
                } finally { suppressEvents = false }
                if (!hasAcceptedSync) { lastMetrics = null; hasAcceptedSync = true }
                scheduleMetrics()
                result.success(mapOf(
                    "accepted" to true, "sequence" to sequence,
                    "value" to snapshot().arguments(owner, sequence, "edit"),
                    "focused" to editor.hasFocus()
                ))
            }
            "focus" -> {
                val accepted = enabled && (editor.hasFocus() || editor.requestFocus())
                if (accepted) {
                    (editor.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
                        ?.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
                }
                reply(result, accepted)
            }
            "blur" -> {
                editor.finishNativeComposition()
                flushEdit()
                editor.clearFocus()
                hideKeyboard()
                flushEdit()
                reply(result, true)
            }
        }
    }

    private fun hideKeyboard() {
        (editor.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
            ?.hideSoftInputFromWindow(editor.windowToken, 0)
    }

    override fun dispose() {
        if (retired) return
        retired = true
        main.removeCallbacks(emitPending)
        main.removeCallbacks(metricsPending)
        editor.onFocusChangeListener = null
        editor.onNativeEdit = null
        editor.onNativeLayout = null
        editor.onAttachmentDelete = null
        editor.removeTextChangedListener(textWatcher)
        editor.text.removeSpan(composingWatcher)
        editor.finishNativeComposition()
        editor.clearFocus()
        hideKeyboard()
        editor.isEnabled = false
        channel.setMethodCallHandler(null)
    }
}

private class HomeBoundaryEditText(context: Context) : EditText(context) {
    // Nullable callbacks are safe when superclass construction changes selection.
    var onNativeEdit: (() -> Unit)? = null
    var onNativeLayout: (() -> Unit)? = null
    var onAttachmentDelete: ((Boolean) -> Boolean)? = null
    private var nativeConnection: InputConnection? = null
    private var lastConsumedDown: String? = null
    private var consumedKey: Pair<Int, Long>? = null

    override fun onSelectionChanged(start: Int, end: Int) {
        super.onSelectionChanged(start, end)
        onNativeEdit?.invoke()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        onNativeLayout?.invoke()
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        onNativeLayout?.invoke()
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val target = super.onCreateInputConnection(outAttrs) ?: return null
        nativeConnection = target
        return HomeEditorInputConnection(target, this)
    }

    fun finishNativeComposition() {
        nativeConnection?.finishComposingText()
        BaseInputConnection.removeComposingSpans(text)
        onNativeEdit?.invoke()
    }

    fun attachmentKey(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_DEL && event.keyCode != KeyEvent.KEYCODE_FORWARD_DEL) return false
        val key = event.keyCode to event.downTime
        if (event.action == KeyEvent.ACTION_UP && consumedKey == key) {
            consumedKey = null
            return true
        }
        if (event.action != KeyEvent.ACTION_DOWN) return false
        val identity = "${event.keyCode}:${event.downTime}:${event.eventTime}:${event.repeatCount}"
        if (lastConsumedDown == identity) return true
        if (onAttachmentDelete?.invoke(event.keyCode == KeyEvent.KEYCODE_FORWARD_DEL) != true) return false
        lastConsumedDown = identity
        consumedKey = key
        return true
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        attachmentKey(event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        attachmentKey(event) || super.onKeyUp(keyCode, event)
}

private class HomeEditorInputConnection(target: InputConnection, private val editor: HomeBoundaryEditText) :
    InputConnectionWrapper(target, false) {
    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
        if (beforeLength > 0 && afterLength == 0 && editor.onAttachmentDelete?.invoke(false) == true) return true
        return super.deleteSurroundingText(beforeLength, afterLength).also { editor.onNativeEdit?.invoke() }
    }

    override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean {
        if (beforeLength > 0 && afterLength == 0 && editor.onAttachmentDelete?.invoke(false) == true) return true
        return super.deleteSurroundingTextInCodePoints(beforeLength, afterLength).also { editor.onNativeEdit?.invoke() }
    }

    override fun sendKeyEvent(event: KeyEvent): Boolean {
        if (editor.attachmentKey(event)) return true
        return super.sendKeyEvent(event).also { editor.onNativeEdit?.invoke() }
    }

    override fun finishComposingText(): Boolean =
        super.finishComposingText().also { editor.onNativeEdit?.invoke() }

    override fun closeConnection() {
        super.closeConnection()
        editor.onNativeEdit?.invoke()
    }
}
