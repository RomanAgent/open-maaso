import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_scaffold.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_palette.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';

import '../application/identity_page_adapter.dart';
import '../../content_engagement/application/content_review_controller.dart';
import '../../content_engagement/application/content_review_page_actions.dart';
import '../application/identity_setup_controller.dart';
import '../domain/identity_profile.dart';
import '../domain/identity_local_state.dart';
import 'identity_badge.dart';
import '../application/companion_setup_controller.dart';
import 'companion_avatar.dart';
import 'companion_setup_fields.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/presentation/content_review_panel.dart';

class IdentitySetupPage extends StatefulWidget {
  const IdentitySetupPage({
    super.key,
    required this.controller,
    required this.onCompleted,
    required this.route,
    this.uiControl,
    this.autoComplete = false,
    this.onContinueLocally,
    this.onChangeAccount,
    this.companion,
  });

  final IdentitySetupController controller;
  final Future<void> Function(IdentitySetupResult result) onCompleted;
  final String route;
  final AgentUiControlService? uiControl;
  final bool autoComplete;
  final VoidCallback? onContinueLocally;
  final VoidCallback? onChangeAccount;
  final CompanionSetupController? companion;

  @override
  State<IdentitySetupPage> createState() => _IdentitySetupPageState();
}

class _IdentitySetupPageState extends State<IdentitySetupPage> {
  final _form = GlobalKey<FormState>();
  final _player = TextEditingController();
  final _agent = TextEditingController();
  final _playerFocus = FocusNode();
  final _agentFocus = FocusNode();
  Worker? _revisionWatcher;
  IdentityPageAdapter? _adapter;
  ContentReviewPageActions? _reviewActions;
  ContentReviewController? _reviewController;
  PageAgentAdapterRegistration<IdentityPageAdapter>? _registration;
  AgentUiControlService? _uiControl;
  bool _finishing = false;
  bool _completionFailed = false;
  int _step = 0;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _mount();
    _playerFocus.addListener(_focusChanged);
    _agentFocus.addListener(_focusChanged);
  }

  void _mount() {
    _step = 0;
    _player.text = widget.controller.playerName.value;
    _agent.text = widget.controller.agentName.value;
    _revisionWatcher = ever<int>(widget.controller.revision, (_) {
      _player.text = widget.controller.playerName.value;
      _agent.text = widget.controller.agentName.value;
    });
    _uiControl =
        widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    // The first-use guide shows one field at a time. Its names are entered by
    // the player; the two-field draft adapter belongs to the full edit form.
    if (_uiControl != null && !_guided) {
      _reviewActions = ContentReviewPageActions(
        coordinator: _uiControl!.coordinator,
        open: _openReviews,
        controller: () => _reviewController,
      );
      final adapter = IdentityPageAdapter(
        route: widget.route,
        controller: widget.controller,
        coordinator: _uiControl!.coordinator,
        reviews: _reviewActions,
      );
      _adapter = adapter;
      _registration = _uiControl!.adapters.register(adapter);
    }
    unawaited(_initialize());
  }

  bool _openReviews() {
    final client = appServices.maybeFind<ContentEngagementClient>();
    if (!mounted ||
        !widget.controller.service.completed ||
        client == null ||
        !client.reviewActive) {
      return false;
    }
    if (_reviewController?.active == true) return true;
    final controller = ContentReviewController(client);
    _reviewController = controller;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
            child: ContentReviewPanel(
              gateway: client,
              controller: controller,
              onUserActivity: () => _uiControl?.coordinator
                  .pauseForUserActivity(reason: 'review_panel_input'),
            ),
          ),
        ),
      ).whenComplete(() {
        if (identical(_reviewController, controller)) _reviewController = null;
        controller.dispose();
      }),
    );
    return true;
  }

  Future<void> _initialize() async {
    final admitted = widget.controller;
    final companion = widget.companion;
    await admitted.initialize();
    if (!mounted || !identical(admitted, widget.controller)) return;
    await companion?.initialize();
    if (!mounted ||
        !identical(admitted, widget.controller) ||
        !identical(companion, widget.companion)) {
      return;
    }
    if (_guided &&
        admitted.service.onboardingCompleted &&
        companion != null &&
        !companion.completed) {
      setState(() => _step = 2);
    }
    if (widget.autoComplete &&
        admitted.service.onboardingCompleted &&
        (companion == null || companion.completed)) {
      final result = admitted.service.setupResult;
      if (result != null) await _finish(result);
    }
  }

  void _unmount() {
    widget.controller.setUserControl(false);
    _revisionWatcher?.dispose();
    _reviewActions?.detach();
    _reviewActions = null;
    _reviewController = null;
    _adapter?.detach();
    _registration?.unregister();
  }

  @override
  void didUpdateWidget(covariant IdentitySetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.route != widget.route ||
        oldWidget.uiControl != widget.uiControl ||
        oldWidget.companion != widget.companion) {
      oldWidget.controller.setUserControl(false);
      _unmount();
      _mount();
    }
  }

  void _focusChanged() {
    final active = _playerFocus.hasFocus || _agentFocus.hasFocus;
    widget.controller.setUserControl(active);
    if (active) {
      _uiControl?.coordinator.pauseForUserActivity(
        reason: 'identity_form_input',
      );
    }
  }

  @override
  void dispose() {
    _unmount();
    _player.dispose();
    _agent.dispose();
    _playerFocus.dispose();
    _agentFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _finishing) return;
    _uiControl?.coordinator.pauseForUserActivity(reason: 'identity_form_save');
    FocusScope.of(context).unfocus();
    final admittedController = widget.controller;
    final companion = widget.companion;
    final result = _guided && admittedController.service.onboardingCompleted
        ? admittedController.service.setupResult
        : await admittedController.save();
    if (!mounted ||
        result == null ||
        !identical(admittedController, widget.controller)) {
      return;
    }
    if (companion != null && !await companion.save()) return;
    if (!mounted ||
        !identical(companion, widget.companion) ||
        !identical(admittedController, widget.controller)) {
      return;
    }
    await _finish(result);
  }

  Future<void> _finish(IdentitySetupResult result) async {
    if (_finishing) return;
    setState(() {
      _finishing = true;
      _completionFailed = false;
    });
    try {
      await widget.onCompleted(result);
    } catch (_) {
      if (mounted) setState(() => _completionFailed = true);
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  String? _validation(String? value) =>
      switch (IdentityNames.validate(value ?? '')) {
        null => null,
        IdentityNameError.empty => _text('Enter a name.', '请输入名字。'),
        IdentityNameError.tooLong => _text(
          'Use 40 characters or fewer.',
          '名字最多 40 个字符。',
        ),
        IdentityNameError.invalidCharacters => _text(
          'Remove line breaks or control characters.',
          '请移除换行或控制字符。',
        ),
      };

  String _error(IdentityFailure failure) => switch (failure) {
    IdentityFailure.conflict => _text(
      'Your names changed on another device. Review the latest names before saving.',
      '另一台设备修改了名字。请核对最新名字后再保存。',
    ),
    IdentityFailure.authenticationRequired ||
    IdentityFailure.contextChanged => _text(
      'Your account changed. Sign in again to continue.',
      '账号状态已变化，请重新登录后继续。',
    ),
    IdentityFailure.rejected => _text(
      'These names could not be saved. Review them and try again.',
      '名字未能保存，请检查后重试。',
    ),
    _ => _text(
      'Unable to reach your profile. Please retry.',
      '暂时无法读取或保存资料，请重试。',
    ),
  };

  bool get _guided => widget.autoComplete && widget.controller.onlyMissing;
  bool get _extended => _guided && widget.companion != null;
  int get _lastStep => _extended ? 5 : 2;
  bool get _companionReady => !_extended || widget.companion!.ready.value;
  bool get _stepReady {
    if (!_extended) return true;
    final draft = widget.companion!.draft.value;
    if (draft == null) return false;
    if (_step == 2) {
      return draft.avatarPreset.isNotEmpty || draft.avatarJpeg.isNotEmpty;
    }
    if (_step == 3) return draft.agentGender.isNotEmpty;
    return true;
  }

  void _back() {
    if (widget.controller.saving.value ||
        widget.companion?.busy.value == true ||
        _finishing) {
      return;
    }
    if (_guided && _step > 0) {
      FocusScope.of(context).unfocus();
      setState(() => _step--);
    } else if (widget.onChangeAccount != null && _guided) {
      widget.onChangeAccount!();
    } else {
      appNavigation.pop(
        fallbackRoute: _guided ? null : AppRouteCatalog.profile,
      );
    }
  }

  void _next() {
    if (!widget.controller.ready.value ||
        widget.controller.saving.value ||
        widget.companion?.busy.value == true ||
        !_companionReady ||
        !_stepReady ||
        _finishing ||
        !_form.currentState!.validate()) {
      return;
    }
    _uiControl?.coordinator.pauseForUserActivity(reason: 'identity_guide_next');
    FocusScope.of(context).unfocus();
    setState(() => _step++);
  }

  Widget _nameField({required bool player}) {
    final c = widget.controller;
    final locked = player ? c.playerLocked : c.agentLocked;
    return TextFormField(
      key: ValueKey(player ? 'identity-player-name' : 'identity-agent-name'),
      controller: player ? _player : _agent,
      focusNode: player ? _playerFocus : _agentFocus,
      enabled: c.ready.value && !c.saving.value && !_finishing && !locked,
      decoration: InputDecoration(
        labelText: player
            ? _text('1. Your name (Alien)', '1. 玩家名字（外星人）')
            : _text('2. Your Agent’s name (Native)', '2. Agent 名字（原住民）'),
        filled: true,
        fillColor: AppSecondaryPalette.of(context).surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        helperText: locked
            ? player
                  ? _text('Your existing name is preserved.', '保留你已经设置的名字。')
                  : _text(
                      'Your existing Agent name is preserved.',
                      '保留 Agent 已经设置的名字。',
                    )
            : _text('1–40 characters. Names can be shared.', '1–40 个字符，允许重名。'),
        helperMaxLines: 2,
      ),
      validator: _validation,
      onChanged: player ? c.setPlayerName : c.setAgentName,
      textInputAction: _guided || player
          ? TextInputAction.next
          : TextInputAction.done,
      onFieldSubmitted: (_) {
        if (_guided) {
          _next();
        } else if (player) {
          _agentFocus.requestFocus();
        }
      },
    );
  }

  Widget _preview() {
    final c = widget.controller;
    final palette = AppSecondaryPalette.of(context);
    return DecoratedBox(
      key: const ValueKey('identity-preview'),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text('Identity preview', '身份预览'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (widget.companion?.draft.value != null) ...[
              CompanionAvatar(profile: widget.companion!.draft.value, size: 64),
              const SizedBox(height: 16),
            ],
            IdentityBadge(
              name: c.playerName.value.trim().isEmpty
                  ? _text('Your name', '玩家名字')
                  : c.playerName.value.trim(),
              kind: IdentityActorKind.player,
            ),
            const SizedBox(height: 12),
            IdentityBadge(
              name: c.agentName.value.trim().isEmpty
                  ? _text('Agent name', 'Agent 名字')
                  : c.agentName.value.trim(),
              kind: IdentityActorKind.agent,
            ),
            if (widget.companion?.draft.value != null) ...[
              const SizedBox(height: 16),
              Text(
                '${widget.companion!.avatars.selected.name} · '
                '${companionGenderLabel(widget.companion!.draft.value!.agentGender, _zh)}',
              ),
              const SizedBox(height: 8),
              Text(
                widget.companion!.draft.value!.interests
                    .map((value) => companionInterestLabel(value, _zh))
                    .join(' · '),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final c = widget.controller;
    final colors = Theme.of(context).colorScheme;
    final busy =
        c.saving.value || widget.companion?.busy.value == true || _finishing;
    final heading = !_guided
        ? _text('Your names in Maaso', '你在 Maaso 的名字')
        : switch (_step) {
            0 => _text('What should we call you?', '怎么称呼你？'),
            1 => _text('Give your Agent a name', '给你的 Agent 起个名字'),
            2 when _extended => _text('Make yourself at home', '选一个属于你的头像'),
            3 when _extended => _text('Meet your Agent', '选择你的 Agent'),
            4 when _extended => _text('What do you enjoy?', '你喜欢什么？'),
            _ => _text('Ready to meet your Agent', '准备好和你的 Agent 见面了'),
          };
    final description = !_guided
        ? _text(
            'Your player and Agent names appear with their roles.',
            '玩家和 Agent 的名字会与身份标识一起显示。',
          )
        : switch (_step) {
            0 => _text(
              'When you comment or interact, this name appears with the Alien label.',
              '你参与评论和互动时，将使用这个名字，并标注「外星人」。',
            ),
            1 => _text(
              'Your Agent uses this name in Maaso, with the Native label.',
              'Agent 在 Maaso 中使用这个名字，并标注「原住民」。',
            ),
            2 when _extended => _text(
              'Choose an avatar, or add a photo.',
              '选择一个头像，也可以上传自己的照片。',
            ),
            3 when _extended => _text(
              'Choose a character and how your Agent identifies.',
              '选择人物形象和 Agent 的性别。',
            ),
            4 when _extended => _text(
              'These choices help your Agent get to know you.',
              '让 Agent 从你的兴趣开始了解你。',
            ),
            _ => _text(
              'Your setup follows your account. Chats and memories are stored locally and can sync while your devices are online.',
              '资料随账号同步；聊天和记忆保存在本机，设备在线时可以实时同步。',
            ),
          };
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: _guided
            ? _text('Welcome to Maaso', '欢迎来到 Maaso')
            : _text('Your Maaso identities', '你的 Maaso 身份'),
        onBack: _back,
      ),
      contentMaxWidth: 600,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_guided) ...[
                Text(
                  _text(
                    'Step ${_step + 1} of ${_lastStep + 1}',
                    '第 ${_step + 1} 步，共 ${_lastStep + 1} 步',
                  ),
                  key: const ValueKey('identity-guide-progress'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: (_step + 1) / (_lastStep + 1)),
                const SizedBox(height: 32),
              ],
              Text(heading, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(description, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 32),
              if (c.loading.value) ...[
                const LinearProgressIndicator(
                  key: ValueKey('identity-loading'),
                ),
                const SizedBox(height: 20),
              ],
              if (!_guided || _step == 0) _nameField(player: true),
              if (!_guided) const SizedBox(height: 24),
              if (!_guided || _step == 1) _nameField(player: false),
              if (_extended && _step >= 2 && _step < _lastStep)
                CompanionSetupFields(
                  controller: widget.companion!,
                  step: _step - 2,
                ),
              if (!_guided || _step == _lastStep) ...[
                if (!_guided) const SizedBox(height: 24),
                _preview(),
              ],
              if (_extended &&
                  widget.companion!.issue.value != null &&
                  (_step < 2 || _step == _lastStep))
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    companionIssueLabel(widget.companion!.issue.value!, _zh),
                    style: TextStyle(color: colors.error),
                  ),
                ),
              if (c.error.value != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _error(c.error.value!),
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                ),
              if (_completionFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _text(
                      'Your names were saved. Try opening Maaso again.',
                      '名字已保存，请重新进入 Maaso。',
                    ),
                    style: TextStyle(color: colors.error),
                  ),
                ),
              const SizedBox(height: 32),
              if (_guided && _step < _lastStep)
                FilledButton(
                  key: const ValueKey('identity-guide-next'),
                  onPressed:
                      c.ready.value && _companionReady && _stepReady && !busy
                      ? _next
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(_text('Next', '下一步')),
                  ),
                )
              else
                FilledButton(
                  key: const ValueKey('identity-save'),
                  onPressed:
                      c.canSave &&
                          !_finishing &&
                          !busy &&
                          (!_extended || widget.companion!.canSave)
                      ? _save
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      busy
                          ? _text('Saving…', '正在保存…')
                          : _guided
                          ? _text('Enter Maaso', '进入 Maaso')
                          : _text('Save and continue', '保存并继续'),
                    ),
                  ),
                ),
              if ((!c.ready.value || !_companionReady) &&
                  !c.loading.value &&
                  !busy)
                TextButton(
                  key: const ValueKey('identity-retry'),
                  onPressed: _initialize,
                  child: Text(_text('Retry', '重试')),
                ),
              if (!_guided &&
                  widget.onContinueLocally != null &&
                  c.service.canContinueLocally &&
                  !c.loading.value)
                TextButton(
                  key: const ValueKey('identity-continue-local'),
                  onPressed: widget.onContinueLocally,
                  child: Text(_text('Continue with local companion', '继续本地陪伴')),
                ),
              if (widget.onChangeAccount != null)
                TextButton(
                  key: const ValueKey('identity-change-account'),
                  onPressed: busy ? null : widget.onChangeAccount,
                  child: Text(_text('Use a different account', '使用其他账号')),
                ),
              if (!_guided &&
                  c.service.completed &&
                  appServices.maybeFind<ContentEngagementClient>() != null)
                TextButton.icon(
                  key: const ValueKey('identity-open-reviews'),
                  onPressed: () {
                    _uiControl?.coordinator.pauseForUserActivity(
                      reason: 'review_panel_open',
                    );
                    _openReviews();
                  },
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(_text('My reviews and appeals', '我的审核与申诉')),
                ),
            ],
          ),
        ),
      ),
    );
  });
}
