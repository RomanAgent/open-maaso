import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/chat/presentation/media/chat_attachment_preview.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/application/home_native_text_editing_bridge.dart';
import 'home_app_invocation_sheet.dart';
import 'home_composer_footprint.dart';
import 'home_composer_morph.dart';
import 'home_native_text_editor.dart';

/// Home presentation of the shared ASR session, using one canonical typed draft.
class HomeChatComposer extends StatefulWidget {
  const HomeChatComposer({
    super.key,
    required this.controller,
    required this.hint,
    this.header,
    this.textInputBorder = false,
    this.floatingGlass = false,
  });
  final HomeController controller;
  final String hint;
  final Widget? header;
  final bool textInputBorder, floatingGlass;

  @override
  State<HomeChatComposer> createState() => _HomeChatComposerState();
}

class _HomeChatComposerState extends State<HomeChatComposer> {
  final _localFocus = FocusNode(debugLabel: 'home-composer-fallback');
  final _footprintOwner = Object();
  late Object _owner;
  late HomeNativeTextEditingBridge _bridge;
  HomeChatInteraction? _interaction;
  ChatInputPresentation? _presentation;
  List<PreparedChatMedia> _observedMedia = [];
  late int _observedRevision;
  int _attachmentToken = 0;
  String? _selectedImage;
  bool _expanded = false, _submitting = false, _applyingAttachment = false;
  bool _nativeFocused = false;
  double _headerHeight = 0;
  late TextEditingValue _lastTextValue;
  HomeController get c => widget.controller;
  bool get _current =>
      mounted && !c.isClosed && identical(_owner, c.composerOwnerToken);
  bool get _native =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  bool get _editable => _current && !c.busy && !c.preparingMedia.value;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  FocusNode get _focus => _interaction?.focusNode ?? _localFocus;

  @override
  void initState() {
    super.initState();
    _owner = c.composerOwnerToken;
    _observedRevision = c.composerDraftRevision;
    _observedMedia = List.of(c.pendingMedia);
    _lastTextValue = c.inputController.value;
    _bridge = HomeNativeTextEditingBridge(
      owner: 'home-${identityHashCode(_owner)}-${identityHashCode(this)}',
      controller: c.inputController,
      isCurrent: () => _current,
      attachmentSnapshot: _snapshot(),
      onAttachmentCommand: _nativeAttachment,
    )..addListener(_nativeChanged);
    c.inputController.addListener(_textChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final interaction = HomeChatInteractionScope.maybeOf(context);
    if (!identical(_interaction, interaction)) {
      _interaction?.releaseComposer(_footprintOwner);
      _interaction = interaction;
      _interaction?.claimComposer(_footprintOwner);
    }
  }

  bool _sameMedia() => listEquals(_observedMedia, c.pendingMedia);
  HomeNativeAttachmentSnapshot _snapshot() => HomeNativeAttachmentSnapshot(
    token: _attachmentToken,
    ids: c.pendingMedia.map((m) => m.attachment.id),
    selectedId: _selectedImage,
    enabled: _editable,
  );

  void _observeDraft({bool external = false}) {
    if (external) _attachmentToken++;
    if (!c.pendingMedia.any((m) => m.attachment.id == _selectedImage)) {
      _selectedImage = null;
    }
    _observedMedia = List.of(c.pendingMedia);
    _observedRevision = c.composerDraftRevision;
    _bridge.setAttachmentSnapshot(_snapshot());
  }

  void _reconcile() {
    if (!_current) {
      return;
    }
    if (!_sameMedia() || c.composerDraftRevision != _observedRevision) {
      _observeDraft(external: true);
    } else {
      _bridge.setAttachmentSnapshot(_snapshot());
    }
  }

  void _textChanged() {
    if (!_current || _applyingAttachment) {
      return;
    }
    final changed = c.inputController.value != _lastTextValue;
    final textChanged = c.inputController.text != _lastTextValue.text;
    _lastTextValue = c.inputController.value;
    if (changed) {
      _selectedImage = null;
      _observeDraft(
        external:
            !_bridge.applyingNativeValue ||
            !_sameMedia() ||
            c.composerDraftRevision > _observedRevision + 1,
      );
      if (_bridge.applyingNativeValue && _bridge.hasFocus) {
        _presentation?.reportInputActivity(
          textChanged
              ? PresenceInputActivityKind.typing
              : PresenceInputActivityKind.tap,
        );
      }
      setState(() {});
    }
  }

  void _nativeChanged() {
    if (!_current) {
      return;
    }
    final focused = _bridge.hasFocus;
    if (focused && !_nativeFocused) {
      _presentation?.reportInputActivity(PresenceInputActivityKind.focus);
    }
    _nativeFocused = focused;
    _interaction?.setNativeInputFocus(_footprintOwner, focused);
    setState(() {});
  }

  HomeNativeAttachmentSnapshot? _nativeAttachment(
    HomeNativeAttachmentCommand command,
  ) {
    if (!_editable ||
        c.inputController.value.composing != TextRange.empty ||
        c.composerDraftRevision != _observedRevision ||
        !_sameMedia() ||
        !_snapshot().admits(command)) {
      if (_current) {
        _observeDraft(external: true);
      }
      return null;
    }
    final expected = _snapshot().apply(command);
    _applyingAttachment = true;
    try {
      if (command.kind == HomeNativeEditingEventKind.boundaryDelete) {
        _selectedImage = command.targetId;
      } else {
        c.removeMedia(command.targetId);
        _selectedImage = null;
      }
      _observeDraft();
      if (!_snapshot().sameAs(expected)) {
        _observeDraft(external: true);
        return null;
      }
      setState(() {});
      return _snapshot();
    } finally {
      _applyingAttachment = false;
    }
  }

  Future<bool> _commitAndBlur() async {
    if (!_current) {
      return false;
    }
    if (_native) {
      if (!await _bridge.commitAndBlur()) {
        return false;
      }
    } else {
      _focus.unfocus();
      // Closing Flutter's input connection commits the current composing value.
      c.inputController.clearComposing();
    }
    return _current && c.inputController.value.composing == TextRange.empty;
  }

  Future<void> _submit(ChatInputPresentation presentation) async {
    if (_submitting || !_current) {
      return;
    }
    _submitting = true;
    try {
      if (await _commitAndBlur() && _current) {
        presentation.submit();
      }
    } finally {
      _submitting = false;
    }
  }

  Future<void> _selectImage(String id) async {
    if (!_editable) {
      return;
    }
    // Do not reinterpret a pending IME composition as an attachment selection.
    if (c.inputController.value.composing != TextRange.empty &&
        !await _commitAndBlur()) {
      return;
    }
    if (!_editable || !c.pendingMedia.any((m) => m.attachment.id == id)) {
      return;
    }
    // Flutter normalizes an invalid caret when its multiline editor gains
    // focus. Do that before selecting the image so the resulting text-value
    // notification cannot clear this explicit selection.
    if (!_native && !c.inputController.selection.isValid) {
      c.inputController.selection = TextSelection.collapsed(
        offset: c.inputController.text.length,
      );
    }
    setState(() {
      _selectedImage = id;
      _observeDraft(external: true);
    });
    if (_native) {
      await _bridge.requestFocus();
    } else {
      _focus.requestFocus();
    }
  }

  Future<void> _removeImage(String id) async {
    if (!_editable) {
      return;
    }
    if (c.inputController.value.composing != TextRange.empty &&
        !await _commitAndBlur()) {
      return;
    }
    if (!_editable) {
      return;
    }
    c.removeMedia(id);
    setState(() {
      _selectedImage = null;
      _observeDraft(external: true);
    });
  }

  Future<void> _imageMenu(String id) async {
    if (!_editable || !await _commitAndBlur() || !mounted) {
      return;
    }
    final remove = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(_zh ? '删除图片' : 'Delete image'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (remove == true && _current) await _removeImage(id);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (_native || event is! KeyDownEvent || !_current) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      if (c.inputController.value.composing == TextRange.empty &&
          _presentation != null) {
        unawaited(_submit(_presentation!));
      }
      return KeyEventResult.handled;
    }
    if (!_editable || c.inputController.value.composing != TextRange.empty) {
      return KeyEventResult.ignored;
    }
    final backspace = event.logicalKey == LogicalKeyboardKey.backspace;
    if (!backspace && event.logicalKey != LogicalKeyboardKey.delete) {
      return KeyEventResult.ignored;
    }
    if (_selectedImage case final id?) {
      unawaited(_removeImage(id));
      return KeyEventResult.handled;
    }
    final selection = c.inputController.selection;
    if (backspace &&
        selection.isCollapsed &&
        selection.extentOffset == 0 &&
        c.pendingMedia.isNotEmpty) {
      unawaited(_selectImage(c.pendingMedia.last.attachment.id));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _add() async {
    if (!_editable || !await _commitAndBlur() || !mounted) {
      return;
    }
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('home-add-image'),
              leading: const Icon(Icons.image_outlined),
              title: Text(_zh ? '添加图片' : 'Add image'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              key: const ValueKey('home-add-game'),
              leading: const Icon(Icons.sports_esports_outlined),
              title: Text(_zh ? '小游戏' : 'Mini game'),
              onTap: () => Navigator.pop(context, 'game'),
            ),
            ListTile(
              key: const ValueKey('home-add-applet'),
              leading: const Icon(Icons.apps_rounded),
              title: Text(_zh ? '小程序' : 'Mini app'),
              onTap: () => Navigator.pop(context, 'applet'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || !_current || kind == null) {
      return;
    }
    if (kind != 'image') {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => HomeAppInvocationSheet(
          controller: c,
          type: kind == 'game'
              ? AppletCatalogType.game
              : AppletCatalogType.applet,
        ),
      );
      return;
    }
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (!_current || file == null) {
        return;
      }
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException('image_size');
      }
      final bytes = await file.readAsBytes();
      if (_current) await c.addMedia(bytes, video: false);
    } on Object {
      if (_current) {
        appNavigation.showSnackBar(
          message: _zh
              ? '未能读取图片，请选择较小的图片后重试'
              : 'Could not read the image. Try a smaller image.',
        );
      }
    }
  }

  Widget _images() => SizedBox(
    height: 76,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: c.pendingMedia.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final media = c.pendingMedia[index];
        final id = media.attachment.id;
        final selected = id == _selectedImage;
        return Semantics(
          selected: selected,
          customSemanticsActions: {
            CustomSemanticsAction(label: _zh ? '删除图片' : 'Delete image'): () =>
                _removeImage(id),
          },
          child: GestureDetector(
            onLongPress: () => _imageMenu(id),
            child: Container(
              key: ValueKey('home-image-$id'),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: selected
                    ? MaasoGlassTheme.of(context).accentSoft
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(13),
              ),
              child: ChatAttachmentThumbnail(
                attachment: media.attachment,
                size: 70,
                onTap: () => _selectImage(id),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _editor(double maxHeight) {
    final glass = MaasoGlassTheme.of(context);
    if (_native) {
      final metrics = _bridge.metrics;
      final line =
          metrics?.lineHeight ?? MediaQuery.textScalerOf(context).scale(20);
      final height = _expanded
          ? maxHeight
          : math.min(
              maxHeight,
              math.max(
                32.0,
                math.min(metrics?.contentHeight ?? 32.0, line * 4),
              ),
            );
      return SizedBox(
        key: const ValueKey('home-composer-editor'),
        width: double.infinity,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: HomeNativeTextEditor(bridge: _bridge)),
            if (c.inputController.text.isEmpty)
              IgnorePointer(
                child: Text(
                  widget.hint,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.3,
                    color: glass.foregroundSecondary,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: 32, maxHeight: maxHeight),
      child: Focus(
        onKeyEvent: _key,
        child: TextField(
          key: const ValueKey('home-composer-editor'),
          controller: c.inputController,
          focusNode: _focus,
          onTapOutside: (_) => _focus.unfocus(),
          onTap: () =>
              _presentation?.reportInputActivity(PresenceInputActivityKind.tap),
          onChanged: (_) => _presentation?.reportInputActivity(
            PresenceInputActivityKind.typing,
          ),
          minLines: _expanded ? null : 1,
          maxLines: _expanded ? null : 4,
          expands: _expanded,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: TextStyle(
            fontSize: 16,
            height: 1.3,
            color: glass.foregroundPrimary,
          ),
          decoration: InputDecoration(
            hintText: widget.hint,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            hintStyle: TextStyle(color: glass.foregroundSecondary),
          ),
        ),
      ),
    );
  }

  Widget _content(ChatInputPresentation p) {
    final selection = c.selectedAppInvocation.value;
    final glass = MaasoGlassTheme.of(context);
    final media = MediaQuery.of(context);
    final available = math.max(
      32.0,
      media.size.height -
          media.viewInsets.bottom -
          media.padding.top -
          media.padding.bottom -
          220 -
          (widget.header == null ? 0 : _headerHeight) -
          (c.pendingMedia.isEmpty ? 0 : 84) -
          (selection == null ? 0 : 52),
    );
    final maxTextHeight = _expanded
        ? math.min(420.0, available)
        : math.min(160.0, available);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selection != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    key: const ValueKey('home-app-invocation-chip'),
                    decoration: BoxDecoration(
                      color: glass.accentSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Icon(
                            selection.entry.type == AppletCatalogType.game
                                ? Icons.sports_esports_outlined
                                : Icons.apps_rounded,
                            color: glass.accentText,
                            size: 20,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            selection.entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: glass.accentText,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _zh ? '移除调用引用' : 'Remove app reference',
                          onPressed: _editable ? c.clearAppInvocation : null,
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 48,
                          ),
                          icon: Icon(
                            Icons.close_rounded,
                            color: glass.accentText,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (c.pendingMedia.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _images(),
                ),
              _editor(maxTextHeight),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              _button(
                key: const ValueKey('home-attach-media'),
                label: _zh ? '添加' : 'Add',
                onPressed: _editable ? _add : null,
                icon: c.preparingMedia.value
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded, size: 25),
              ),
              const Spacer(),
              _button(
                key: const ValueKey('home-expand-composer'),
                label: _expanded
                    ? (_zh ? '收起输入框' : 'Collapse input')
                    : (_zh ? '展开输入框' : 'Expand input'),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.close_fullscreen : Icons.open_in_full,
                  size: 20,
                ),
              ),
              _button(
                key: const ValueKey('home-voice-entry'),
                label: _zh ? '语音输入' : 'Voice input',
                onPressed: p.canEnterVoice ? p.enterVoice : null,
                icon: const Icon(Icons.mic_none_rounded, size: 26),
              ),
              const SizedBox.square(dimension: 48),
            ],
          ),
        ),
      ],
    );
  }

  Widget _button({
    required Key key,
    required String label,
    required VoidCallback? onPressed,
    required Widget icon,
  }) => SizedBox.square(
    dimension: 48,
    child: IconButton(
      key: key,
      tooltip: label,
      onPressed: onPressed,
      icon: icon,
      padding: EdgeInsets.zero,
    ),
  );

  Widget _send(ChatInputPresentation p) {
    final hasDraft =
        c.inputController.text.trim().isNotEmpty || c.pendingMedia.isNotEmpty;
    final stop = p.isThinking && !hasDraft;
    final enabled = p.enabled && !c.preparingMedia.value && (hasDraft || stop);
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        key: const ValueKey('home-send'),
        tooltip: stop ? (_zh ? '停止' : 'Stop') : (_zh ? '发送' : 'Send'),
        padding: const EdgeInsets.all(4),
        onPressed: !enabled
            ? null
            : stop
            ? p.interrupt
            : () => _submit(p),
        icon: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: MaasoFrostTokens.composerAction.withValues(
              alpha: enabled ? 1 : .30,
            ),
          ),
          child: Icon(
            stop ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: 25,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    _reconcile();
    return HomeChatActivityRegion(
      child: ChatInputBar(
        controller: c.inputController,
        focusNode: _focus,
        homeComposerMode: true,
        inheritVoiceSession: true,
        floatingGlass: widget.floatingGlass,
        textInputBorder: widget.textInputBorder,
        onVoiceTextSend: c.sendVoiceText,
        beforeVoiceEntry: _commitAndBlur,
        onSend: c.send,
        onInterrupt: c.cancelCurrent,
        isThinking: c.busy,
        onInputActivity: (kind) {
          c.observeInputActivity(kind);
          // Native selection/IME snapshots also report a semantic tap. A late
          // blur commit must not undo the outside pointer's dismissal.
          if (kind == PresenceInputActivityKind.tap &&
              !_bridge.applyingNativeValue) {
            _interaction?.activity(kind);
          }
        },
        presentationBuilder: (context, p) {
          _presentation = p;
          final voice = p.voiceActive || p.enteringVoice;
          return TapRegion(
            enabled: _native && !voice && _bridge.hasFocus,
            onTapOutside: (_) => unawaited(_commitAndBlur()),
            child: HomeComposerFootprint(
              onHeight: (height) =>
                  _interaction?.setComposerExtent(_footprintOwner, height),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.header != null && !voice)
                    HomeComposerFootprint(
                      onHeight: (height) {
                        if (_current &&
                            widget.header != null &&
                            (_headerHeight - height).abs() >= .5) {
                          setState(() => _headerHeight = height);
                        }
                      },
                      child: widget.header!,
                    ),
                  HomeComposerMorph(
                    voiceMode: voice,
                    textInputBorder: widget.textInputBorder,
                    content: _content(p),
                    sendControl: _send(p),
                    voiceControlBuilder: p.voiceControlBuilder,
                    voiceLabel: p.enteringVoice
                        ? (_zh ? '正在连接语音…' : 'Connecting voice…')
                        : (_zh
                              ? '轻点语音球返回输入'
                              : 'Tap the orb to return to typing'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  });

  @override
  void dispose() {
    c.inputController.removeListener(_textChanged);
    _bridge.removeListener(_nativeChanged);
    _bridge.dispose();
    _interaction?.releaseComposer(_footprintOwner);
    _localFocus.dispose();
    super.dispose();
  }
}
