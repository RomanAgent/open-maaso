import CoreFoundation
import Flutter
import UIKit

/// The Home editor owns genuine text only. Attachments and decorative frost
/// remain outside this view, so native copy/cut cannot expose an internal token.
final class MaasoHomeTextEditorFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    MaasoHomeTextEditorView(
      frame: frame, viewId: viewId, values: args as? [String: Any] ?? [:],
      messenger: messenger
    )
  }
}

// Kept independent of UIKit so the actual boundary predicate can be executed
// by the native contract test, in addition to typechecking this complete file.
enum MaasoHomeTextEditorRules {
  struct AttachmentSnapshot: Equatable {
    let token: Int
    let ids: [String]
    let selectedId: String?
    let enabled: Bool

    func clearingSelection() -> AttachmentSnapshot {
      AttachmentSnapshot(token: token, ids: ids, selectedId: nil, enabled: enabled)
    }

    func applying(_ command: AttachmentCommand) -> AttachmentSnapshot? {
      guard enabled, command.before == self else { return nil }
      if command.kind == "boundaryDelete", selectedId == nil, ids.last == command.targetId {
        return AttachmentSnapshot(token: token, ids: ids, selectedId: command.targetId, enabled: enabled)
      }
      if command.kind == "deleteSelectedAttachment", selectedId == command.targetId,
        ids.contains(command.targetId) {
        return AttachmentSnapshot(
          token: token, ids: ids.filter { $0 != command.targetId }, selectedId: nil, enabled: enabled
        )
      }
      return nil
    }
  }

  struct AttachmentCommand {
    let kind: String
    let before: AttachmentSnapshot
    let targetId: String

    var arguments: [String: Any] {
      [
        "snapshotToken": before.token, "beforeIds": before.ids,
        "beforeSelectedId": before.selectedId as Any? ?? NSNull(), "targetId": targetId,
      ]
    }
  }

  static func attachmentSnapshot(_ raw: Any?) -> AttachmentSnapshot? {
    guard let values = raw as? [String: Any],
      let tokenNumber = values["token"] as? NSNumber,
      CFGetTypeID(tokenNumber) != CFBooleanGetTypeID(),
      !["d", "f"].contains(String(cString: tokenNumber.objCType)),
      let token = Int(tokenNumber.stringValue), token >= 0,
      let ids = values["ids"] as? [String], ids.count <= 4,
      ids.allSatisfy({ !$0.isEmpty && ($0 as NSString).length <= 256 }),
      Set(ids).count == ids.count, values.keys.contains("selectedId"),
      let enabledNumber = values["enabled"] as? NSNumber,
      CFGetTypeID(enabledNumber) == CFBooleanGetTypeID()
    else { return nil }
    let selectedId: String?
    if values["selectedId"] is NSNull { selectedId = nil }
    else if let selected = values["selectedId"] as? String, ids.contains(selected) { selectedId = selected }
    else { return nil }
    return AttachmentSnapshot(token: token, ids: ids, selectedId: selectedId, enabled: enabledNumber.boolValue)
  }

  static func argb(_ raw: Any?) -> UInt32? {
    guard let value = integer(raw), value >= 0, value <= 0xFFFFFFFF,
      let number = raw as? NSNumber, !["d", "f"].contains(String(cString: number.objCType))
    else { return nil }
    return UInt32(value)
  }

  static func fontSize(_ value: Any?) -> Double {
    let requested = (value as? NSNumber)?.doubleValue ?? 17
    return requested.isFinite ? max(10, min(requested, 48)) : 17
  }

  static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite,
      number.doubleValue.rounded(.towardZero) == number.doubleValue,
      number.doubleValue >= Double(Int.min),
      number.doubleValue < Double(Int.max)
    else { return nil }
    return number.intValue
  }

  static func utf16Offset(_ requested: Int, in text: String) -> Int {
    let value = text as NSString
    let offset = max(0, min(requested, value.length))
    if offset > 0 && offset < value.length {
      let left = value.character(at: offset - 1)
      let right = value.character(at: offset)
      if (0xD800...0xDBFF).contains(left) && (0xDC00...0xDFFF).contains(right) {
        return offset - 1
      }
    }
    return offset
  }

  /// Preserves exact user-selected code units, including literal U+FFFC.
  /// Invalid selections never become clipboard writes.
  static func exactSelectedText(in text: String, range: NSRange) -> String? {
    let source = text as NSString
    guard range.location != NSNotFound, range.location >= 0, range.length > 0,
      range.location <= source.length,
      range.length <= source.length - range.location
    else { return nil }
    let end = range.location + range.length
    guard utf16Offset(range.location, in: text) == range.location,
      utf16Offset(end, in: text) == end
    else { return nil }
    return source.substring(with: range)
  }

  static func attachmentCommand(
    enabled: Bool, attachments: AttachmentSnapshot?,
    selectionBase: Int, selectionExtent: Int,
    composingStart: Int, composingEnd: Int
  ) -> AttachmentCommand? {
    guard enabled, let attachments, attachments.enabled, !attachments.ids.isEmpty, selectionBase >= 0,
      selectionBase == selectionExtent,
      !(composingStart >= 0 && composingEnd >= composingStart)
    else { return nil }
    if let selected = attachments.selectedId {
      return AttachmentCommand(kind: "deleteSelectedAttachment", before: attachments, targetId: selected)
    }
    guard selectionBase == 0, let target = attachments.ids.last else { return nil }
    return AttachmentCommand(kind: "boundaryDelete", before: attachments, targetId: target)
  }
}

private struct MaasoHomeEditingSnapshot: Equatable {
  let text: String
  let selectionBase: Int
  let selectionExtent: Int
  let composingStart: Int
  let composingEnd: Int

  func arguments(owner: String, sequence: Int, kind: String) -> [String: Any] {
    [
      "owner": owner, "sequence": sequence, "kind": kind, "text": text,
      "selectionBase": selectionBase, "selectionExtent": selectionExtent,
      "composingStart": composingStart, "composingEnd": composingEnd,
    ]
  }
}

private struct MaasoHomeLayoutMetrics: Equatable {
  let width: CGFloat
  let contentHeight: CGFloat
  let lineHeight: CGFloat
}

private final class MaasoHomeTextEditorView: NSObject, FlutterPlatformView, UITextViewDelegate {
  private let editor: MaasoHomeTextView
  private let channel: FlutterMethodChannel
  private let owner: String
  private var sequence = 0
  private var retired = false
  private var suppressEvents = false
  private var enabled: Bool
  private var attachments: MaasoHomeTextEditorRules.AttachmentSnapshot?
  private var lastSnapshot: MaasoHomeEditingSnapshot?
  private var appliedFontSize: CGFloat?
  private var appliedDark: Bool?
  private var appliedTextColor: UInt32?
  private var appliedCursorColor: UInt32?
  private var metricsRevision = 0
  private var metricsScheduled = false
  private var lastMetrics: MaasoHomeLayoutMetrics?
  private var hasAcceptedSync = false

  init(frame: CGRect, viewId: Int64, values: [String: Any], messenger: FlutterBinaryMessenger) {
    owner = values["owner"] as? String ?? ""
    enabled = !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (values["enabled"] as? Bool ?? true)
    attachments = MaasoHomeTextEditorRules.attachmentSnapshot(values["attachments"])
    editor = MaasoHomeTextView(frame: frame, textContainer: nil)
    channel = FlutterMethodChannel(
      name: "maaso/home_text_editor/\(viewId)", binaryMessenger: messenger
    )
    super.init()
    editor.backgroundColor = .clear
    editor.isOpaque = false
    editor.textContainerInset = .zero
    editor.textContainer.lineFragmentPadding = 0
    editor.autocapitalizationType = .sentences
    editor.returnKeyType = .default
    editor.enablesReturnKeyAutomatically = false
    // UIKit's implicit paste policy then accepts plain strings, not image or
    // attributed attachment items outside the Flutter attachment model.
    editor.allowsEditingTextAttributes = false
    editor.showsVerticalScrollIndicator = false
    editor.accessibilityLabel = "Message"
    applyStyle(values)
    editor.text = values["text"] as? String ?? ""
    setSelection(values, text: editor.text)
    // Creation never revives a marked range from a retired keyboard connection.
    // Subsequent composing ranges come exclusively from the native IME.
    editor.isEditable = enabled
    editor.isSelectable = enabled
    editor.delegate = self
    editor.onAttachmentDelete = { [weak self] in self?.deleteAttachment() ?? false }
    editor.hasAttachmentDelete = { [weak self] in self?.attachmentCommand() != nil }
    editor.onNativeEdit = { [weak self] in self?.emit("edit") }
    editor.onNativeLayout = { [weak self] in self?.scheduleMetrics() }
    editor.clipboardActionsAllowed = { [weak self] in
      guard let self else { return false }
      return self.enabled && !self.retired
    }
    lastSnapshot = snapshot()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(["accepted": false, "sequence": 0]); return }
      if Thread.isMainThread {
        self.handle(call, result: result)
      } else {
        DispatchQueue.main.async { [weak self] in
          guard let self else { result(["accepted": false, "sequence": 0]); return }
          self.handle(call, result: result)
        }
      }
    }
    scheduleMetrics()
  }

  func view() -> UIView { editor }

  private func applyStyle(_ values: [String: Any]) {
    if appliedFontSize == nil || values.keys.contains("fontSize") {
      let size = CGFloat(MaasoHomeTextEditorRules.fontSize(values["fontSize"]))
      if appliedFontSize != size {
        editor.font = .systemFont(ofSize: size)
        appliedFontSize = size
        scheduleMetrics()
      }
    }
    if appliedDark == nil || values.keys.contains("dark") {
      let dark = values["dark"] as? Bool ?? false
      appliedDark = dark
    }
    let textColor = MaasoHomeTextEditorRules.argb(values["textColorArgb"])
      ?? (appliedDark == true ? 0xFFE7E9ED : 0xFF24272B)
    let cursorColor = MaasoHomeTextEditorRules.argb(values["cursorColorArgb"]) ?? 0xFF2A69D3
    if appliedTextColor != textColor {
      editor.textColor = color(textColor)
      appliedTextColor = textColor
    }
    if appliedCursorColor != cursorColor {
      editor.tintColor = color(cursorColor)
      appliedCursorColor = cursorColor
    }
    // UIKit exposes cursor/handle tint, but no public independent UITextView
    // selection-background color. Accept the semantic selection token while
    // preserving the system highlight; do not use private APIs or text overlays.
  }

  private func color(_ argb: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }

  private func scheduleMetrics() {
    guard !retired, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !metricsScheduled else { return }
    metricsScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      defer { self.metricsScheduled = false }
      self.emitMetrics()
    }
  }

  private func emitMetrics() {
    guard !retired, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let width = editor.bounds.width
    let lineHeight = editor.font?.lineHeight ?? 17
    guard width.isFinite, width > 0, lineHeight.isFinite, lineHeight > 0 else { return }
    let fitted = editor.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    let height = max(lineHeight + editor.textContainerInset.top + editor.textContainerInset.bottom, fitted.height)
    guard height.isFinite, height > 0 else { return }
    let metrics = MaasoHomeLayoutMetrics(width: width, contentHeight: height, lineHeight: lineHeight)
    guard metrics != lastMetrics else { return }
    lastMetrics = metrics
    metricsRevision += 1
    channel.invokeMethod("layoutMetrics", arguments: [
      "owner": owner, "metricsRevision": metricsRevision, "width": Double(width),
      "contentHeight": Double(height), "lineHeight": Double(lineHeight),
    ])
  }

  private func snapshot() -> MaasoHomeEditingSnapshot {
    let text = editor.text ?? ""
    let range = editor.selectedRange
    let base = range.location == NSNotFound ? 0 : min(range.location, (text as NSString).length)
    let extent = min((text as NSString).length, base + min(range.length, (text as NSString).length - base))
    let marked = editor.markedTextRange
    return MaasoHomeEditingSnapshot(
      text: text, selectionBase: base, selectionExtent: extent,
      composingStart: marked.map { editor.offset(from: editor.beginningOfDocument, to: $0.start) } ?? -1,
      composingEnd: marked.map { editor.offset(from: editor.beginningOfDocument, to: $0.end) } ?? -1
    )
  }

  private func selection(_ values: [String: Any], text: String) -> NSRange {
    let fallback = (text as NSString).length
    let base = MaasoHomeTextEditorRules.utf16Offset(
      MaasoHomeTextEditorRules.integer(values["selectionBase"]) ?? fallback, in: text
    )
    let extent = MaasoHomeTextEditorRules.utf16Offset(
      MaasoHomeTextEditorRules.integer(values["selectionExtent"]) ?? base, in: text
    )
    return NSRange(location: min(base, extent), length: abs(extent - base))
  }

  private func setSelection(_ values: [String: Any], text: String) {
    let range = selection(values, text: text)
    if editor.selectedRange != range { editor.selectedRange = range }
  }

  private func attachmentCommand() -> MaasoHomeTextEditorRules.AttachmentCommand? {
    let value = snapshot()
    return MaasoHomeTextEditorRules.attachmentCommand(
      enabled: enabled && !retired, attachments: attachments,
      selectionBase: value.selectionBase, selectionExtent: value.selectionExtent,
      composingStart: value.composingStart, composingEnd: value.composingEnd
    )
  }

  private func deleteAttachment() -> Bool {
    emit("edit")
    guard let command = attachmentCommand(), let next = attachments?.applying(command) else { return false }
    attachments = next
    emit(command.kind, attachment: command)
    return true
  }

  private func emit(_ kind: String, attachment: MaasoHomeTextEditorRules.AttachmentCommand? = nil) {
    guard !retired, !suppressEvents,
      !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    let value = snapshot()
    if kind == "edit" && value == lastSnapshot { return }
    if value != lastSnapshot {
      attachments = attachments?.clearingSelection()
      scheduleMetrics()
    }
    lastSnapshot = value
    sequence += 1
    var arguments = value.arguments(owner: owner, sequence: sequence, kind: kind)
    if let attachment { arguments["attachment"] = attachment.arguments }
    channel.invokeMethod("editingEvent", arguments: arguments)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let values = call.arguments as? [String: Any] ?? [:]
    guard !retired, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      values["owner"] as? String == owner
    else { result(["accepted": false, "sequence": sequence]); return }
    if call.method == "dispose" {
      retire()
      result(["accepted": true, "sequence": sequence])
      return
    }
    guard ["sync", "focus", "blur"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    emit("edit")
    guard MaasoHomeTextEditorRules.integer(values["expectedSequence"]) == sequence else {
      result(["accepted": false, "sequence": sequence])
      return
    }
    switch call.method {
    case "sync":
      guard let text = values["text"] as? String,
        MaasoHomeTextEditorRules.integer(values["selectionBase"]) != nil,
        MaasoHomeTextEditorRules.integer(values["selectionExtent"]) != nil,
        ["textColorArgb", "cursorColorArgb", "selectionColorArgb"].allSatisfy({
          !values.keys.contains($0) || MaasoHomeTextEditorRules.argb(values[$0]) != nil
        })
      else { result(["accepted": false, "sequence": sequence]); return }
      let range = selection(values, text: text)
      let changingValue = editor.text != text || editor.selectedRange != range
      let nextEnabled = values["enabled"] as? Bool ?? enabled
      if editor.markedTextRange != nil && (changingValue || !nextEnabled) {
        result(["accepted": false, "sequence": sequence])
        return
      }
      suppressEvents = true
      if editor.text != text { editor.text = text }
      setSelection(values, text: text)
      // Style-only updates are safe while the native IME owns a marked range:
      // mutate the existing view's attributes, never its text/input connection.
      applyStyle(values)
      attachments = MaasoHomeTextEditorRules.attachmentSnapshot(values["attachments"])
      enabled = nextEnabled
      if editor.isEditable != enabled { editor.isEditable = enabled }
      if editor.isSelectable != enabled { editor.isSelectable = enabled }
      if !enabled { editor.resignFirstResponder() }
      lastSnapshot = snapshot()
      suppressEvents = false
      if !hasAcceptedSync { lastMetrics = nil; hasAcceptedSync = true }
      scheduleMetrics()
      result([
        "accepted": true, "sequence": sequence,
        "value": snapshot().arguments(owner: owner, sequence: sequence, kind: "edit"),
        "focused": editor.isFirstResponder,
      ])
    case "focus":
      let accepted = enabled && (editor.isFirstResponder || editor.becomeFirstResponder())
      result(["accepted": accepted, "sequence": sequence])
    case "blur":
      editor.unmarkText()
      emit("edit")
      editor.resignFirstResponder()
      emit("edit")
      result(["accepted": true, "sequence": sequence])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func retire() {
    retired = true
    editor.delegate = nil
    editor.onAttachmentDelete = nil
    editor.hasAttachmentDelete = nil
    editor.onNativeEdit = nil
    editor.onNativeLayout = nil
    editor.clipboardActionsAllowed = nil
    editor.unmarkText()
    editor.resignFirstResponder()
    editor.isEditable = false
    channel.setMethodCallHandler(nil)
  }

  func textViewDidChange(_ textView: UITextView) { emit("edit") }
  func textViewDidChangeSelection(_ textView: UITextView) { emit("edit") }
  func textViewDidBeginEditing(_ textView: UITextView) { emit("focus") }
  func textViewDidEndEditing(_ textView: UITextView) {
    editor.unmarkText()
    emit("edit")
    emit("blur")
  }

  func textView(
    _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
  ) -> Bool { enabled && !retired }

  deinit {
    channel.setMethodCallHandler(nil)
    editor.delegate = nil
    editor.onAttachmentDelete = nil
    editor.hasAttachmentDelete = nil
    editor.onNativeEdit = nil
    editor.onNativeLayout = nil
    editor.clipboardActionsAllowed = nil
  }
}

private final class MaasoHomeTextView: UITextView {
  var onAttachmentDelete: (() -> Bool)?
  var hasAttachmentDelete: (() -> Bool)?
  var onNativeEdit: (() -> Void)?
  var onNativeLayout: (() -> Void)?
  var clipboardActionsAllowed: (() -> Bool)?
  private var performingCut = false

  override var hasText: Bool { super.hasText || (hasAttachmentDelete?() ?? false) }

  override func layoutSubviews() {
    super.layoutSubviews()
    onNativeLayout?()
  }

  override func copy(_ sender: Any?) {
    guard clipboardActionsAllowed?() == true, isEditable, isSelectable,
      let selected = MaasoHomeTextEditorRules.exactSelectedText(
        in: text ?? "", range: selectedRange
      ),
      super.canPerformAction(#selector(copy(_:)), withSender: sender)
    else { return }
    super.copy(sender)
    // UIKit's rich-text export omits literal U+FFFC even without an attachment.
    // Keep native selection/menu behavior and correct only the plain string.
    // A cut performs its exact export only after its native deletion succeeds.
    if !performingCut && clipboardActionsAllowed?() == true {
      UIPasteboard.general.string = selected
    }
  }

  override func cut(_ sender: Any?) {
    guard !performingCut, clipboardActionsAllowed?() == true,
      isEditable, isSelectable,
      let selected = MaasoHomeTextEditorRules.exactSelectedText(
        in: text ?? "", range: selectedRange
      ),
      super.canPerformAction(#selector(cut(_:)), withSender: sender)
    else { return }
    let previousText = text ?? ""
    performingCut = true
    super.cut(sender)
    performingCut = false
    let resultingText = text ?? ""
    // Keep UIKit's deletion, smart whitespace, caret and undo transaction.
    // A rejected/no-op cut must not receive our clipboard rewrite.
    guard clipboardActionsAllowed?() == true,
      resultingText != previousText, selectedRange.length == 0,
      selectedRange.location != NSNotFound,
      selectedRange.location >= 0,
      selectedRange.location <= (resultingText as NSString).length
    else { return }
    UIPasteboard.general.string = selected
  }

  override func deleteBackward() {
    if onAttachmentDelete?() == true { return }
    super.deleteBackward()
    onNativeEdit?()
  }

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    super.setMarkedText(markedText, selectedRange: selectedRange)
    onNativeEdit?()
  }

  override func unmarkText() {
    super.unmarkText()
    onNativeEdit?()
  }
}
