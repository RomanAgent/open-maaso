import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import '../../economy/application/store_purchase_service.dart';
import '../application/profile_controller.dart';
import '../application/profile_page_adapter.dart';
import '../domain/companion_profile.dart';
import 'companion_avatar.dart';
import 'companion_setup_fields.dart';
import 'daily_token_usage_card.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.controller,
    required this.route,
    required this.membershipRoute,
    this.membership,
    this.uiControl,
    this.tokenUsage,
    this.localEdition = false,
  });
  final ProfileController controller;
  final String route, membershipRoute;
  final StorePurchaseService? membership;
  final AgentUiControlService? uiControl;
  final DailyTokenUsageService? tokenUsage;
  final bool localEdition;
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  AgentUiControlService? _control;
  ProfilePageAdapter? _adapter;
  PageAgentAdapterRegistration<ProfilePageAdapter>? _registration;
  Worker? _editingWatcher;
  bool _dialogOpen = false;
  DailyTokenUsageService? _tokenUsage;
  bool get zh => Localizations.localeOf(context).languageCode == 'zh';
  String tr(String en, String cn) => zh ? cn : en;
  @override
  void initState() {
    super.initState();
    _mount();
  }

  void _mount() {
    _tokenUsage =
        widget.tokenUsage ?? appServices.maybeFind<DailyTokenUsageService>();
    if (_tokenUsage case final service?) unawaited(service.refresh());
    _control =
        widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    if (_control case final control?) {
      _adapter = ProfilePageAdapter(
        route: widget.route,
        controller: widget.controller,
        coordinator: control.coordinator,
      );
      _registration = control.adapters.register(_adapter!);
    }
    _editingWatcher = ever<ProfileEditField?>(widget.controller.editing, (
      field,
    ) {
      if (field != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _openEditor());
      }
    });
    unawaited(widget.controller.refresh());
    if (_membershipCurrent) {
      unawaited(widget.membership!.load().catchError((Object _) {}));
    }
  }

  bool get _membershipCurrent =>
      !widget.localEdition &&
      widget.controller.active &&
      widget.membership?.isCurrent == true &&
      widget.membership!.boundContextKey ==
          widget.controller.identity.boundContextKey;
  void _unmount() {
    widget.controller.setUserControl(false);
    _editingWatcher?.dispose();
    _adapter?.detach();
    _registration?.unregister();
  }

  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.route != widget.route ||
        oldWidget.uiControl != widget.uiControl ||
        oldWidget.localEdition != widget.localEdition ||
        oldWidget.tokenUsage != widget.tokenUsage) {
      oldWidget.controller.setUserControl(false);
      _unmount();
      _mount();
    }
  }

  @override
  void dispose() {
    _unmount();
    super.dispose();
  }

  void _takeOver() => _control?.coordinator.pauseForUserActivity(
    reason: 'profile_user_control',
  );
  Future<void> _openEditor() async {
    final admitted = widget.controller;
    if (!mounted ||
        _dialogOpen ||
        !admitted.active ||
        admitted.editing.value == null) {
      return;
    }
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ProfileEditor(controller: admitted, zh: zh, onUserAction: _takeOver),
    );
    _dialogOpen = false;
    if (admitted.active) admitted.cancelEdit();
  }

  void _edit(ProfileEditField field) {
    _takeOver();
    widget.controller.beginEdit(field);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = AppSecondaryPalette.of(context);
    return AppSecondaryScaffold(
      contentMaxWidth: 680,
      header: AppSecondaryHeader(
        title: tr('My profile', '个人信息'),
        onBack: () => appNavigation.pop(fallbackRoute: AppRouteCatalog.home),
      ),
      body: Listener(
        onPointerDown: (_) {
          widget.controller.setUserControl(true);
          _takeOver();
        },
        onPointerUp: (_) => widget.controller.setUserControl(false),
        onPointerCancel: (_) => widget.controller.setUserControl(false),
        child: AppReactiveBuilder(() {
          final c = widget.controller;
          final active = c.active;
          final identity = active ? c.identity.profile : null;
          final profile = active ? c.companion.profile.value : null;
          final usage = _membershipCurrent
              ? widget.membership!.usage.value
              : null;
          final expired =
              usage?.expiresAt?.isBefore(DateTime.now().toUtc()) == true;
          final tier = expired ? null : usage?.tier;
          final tierName = usage == null
              ? tr('Membership', '会员')
              : tier?.title ?? 'Free';
          final name = identity?.playerName ?? '';
          return ListView(
            key: const ValueKey('profile-content-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              if (!active)
                Text(
                  tr(
                    'Your account changed. Reopen this page.',
                    '账号已变化，请重新打开此页。',
                  ),
                ),
              if (c.loading.value && active) const LinearProgressIndicator(),
              Row(
                children: [
                  Semantics(
                    button: true,
                    label: tr('Change profile photo', '更换用户头像'),
                    child: InkWell(
                      key: const ValueKey('profile-avatar-edit'),
                      borderRadius: BorderRadius.circular(999),
                      onTap: c.canEdit
                          ? () => _edit(ProfileEditField.avatar)
                          : null,
                      child: Stack(
                        children: [
                          CompanionAvatar(profile: profile, size: 80),
                          PositionedDirectional(
                            end: 0,
                            bottom: 0,
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: palette.surface,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: palette.shadow,
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.photo_camera_outlined,
                                size: 14,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? tr('Your profile', '你的资料') : name,
                          key: const ValueKey('profile-player-name'),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontSize: 28,
                                height: 36 / 28,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('profile-nickname-edit'),
                          onPressed: c.canEdit
                              ? () => _edit(ProfileEditField.nickname)
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: colors.secondary,
                            minimumSize: const Size(48, 48),
                            padding: EdgeInsets.zero,
                            alignment: AlignmentDirectional.centerStart,
                            textStyle: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontSize: 13, height: 20 / 13),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 14),
                          iconAlignment: IconAlignment.end,
                          label: Text(tr('Edit nickname', '编辑昵称')),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!widget.localEdition) ...[
                const SizedBox(height: 20),
                Material(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('profile-membership-card'),
                    onTap: active
                        ? () {
                            _takeOver();
                            appNavigation.push(widget.membershipRoute);
                          }
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      child: DefaultTextStyle(
                        style:
                            (Theme.of(context).textTheme.bodySmall ??
                                    const TextStyle())
                                .copyWith(
                                  color: colors.onPrimary,
                                  fontSize: 13,
                                  height: 20 / 13,
                                ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    tr('Maaso membership', 'Maaso 会员'),
                                  ),
                                ),
                                Icon(
                                  Icons.north_east_rounded,
                                  color: colors.onPrimary,
                                  size: 20,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  tierName,
                                  key: const ValueKey(
                                    'profile-membership-tier',
                                  ),
                                  style: TextStyle(
                                    fontSize: 28,
                                    height: 36 / 28,
                                    fontWeight: FontWeight.w600,
                                    color: colors.onPrimary,
                                  ),
                                ),
                                if (usage != null)
                                  Text(tr('Current plan', '当前方案')),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              usage == null
                                  ? tr(
                                      'View plans and membership status',
                                      '查看方案与会员状态',
                                    )
                                  : expired || tier == null
                                  ? 'Doubao-Seed-Evolving'
                                  : usage.modelName.isNotEmpty
                                  ? usage.modelName
                                  : tier.modelDisplayName,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              DailyTokenUsageCard(
                key: ObjectKey(_tokenUsage),
                enabled: active,
                onInteraction: _takeOver,
                usage: active && _tokenUsage?.isCurrent == true
                    ? _tokenUsage!.today.value
                    : null,
                loading:
                    active &&
                    _tokenUsage?.isCurrent == true &&
                    _tokenUsage!.loading.value,
                unavailable:
                    !active ||
                    _tokenUsage?.isCurrent != true ||
                    _tokenUsage!.unavailable.value,
              ),
              const SizedBox(height: 16),
              _group(palette, [
                _row(
                  'relationship_hub.title'.tr,
                  tr('Profile · Activity · Memories', '档案 · 动态 · 记忆'),
                  active
                      ? () {
                          _takeOver();
                          appNavigation.push(AppRouteCatalog.memoryWall);
                        }
                      : null,
                  key: const ValueKey('profile-relationship-entry'),
                  icon: Icons.favorite_border_rounded,
                  prominentIcon: true,
                ),
              ]),
              _label(tr('My details', '我的资料')),
              _group(palette, [
                _row(
                  tr('My interests', '我的喜好'),
                  profile == null || profile.interests.isEmpty
                      ? tr('Not set', '未设置')
                      : '',
                  c.canEdit ? () => _edit(ProfileEditField.interests) : null,
                  key: const ValueKey('profile-interests-edit'),
                  icon: Icons.tune_rounded,
                  detail: profile == null || profile.interests.isEmpty
                      ? null
                      : Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final interest in profile.interests)
                              _interestChip(
                                companionInterestLabel(interest, zh),
                                palette,
                              ),
                          ],
                        ),
                ),
              ]),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.devices_outlined,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr(
                        'Chats and memories are stored on each device. Devices online together sync in real time.',
                        '聊天与记忆各自保存在设备上，同时在线的设备实时同步。',
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (active &&
                  (c.issue.value != null ||
                      profile == null ||
                      identity == null)) ...[
                const SizedBox(height: 16),
                Text(
                  tr(
                    'Some profile information is unavailable. Your current details are preserved.',
                    '部分资料暂时未能加载，已有内容仍会保留。',
                  ),
                ),
                TextButton.icon(
                  onPressed: c.loading.value
                      ? null
                      : () {
                          _takeOver();
                          unawaited(c.refresh());
                        },
                  icon: const Icon(Icons.refresh),
                  label: Text(tr('Retry', '重试')),
                ),
              ],
            ],
          );
        }),
      ),
    );
  }

  Widget _label(String value) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
    child: Text(
      value,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
  Widget _group(AppSecondaryPalette palette, List<Widget> children) => Material(
    color: palette.surfaceMuted,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
  Widget _row(
    String title,
    String value,
    VoidCallback? onTap, {
    Key? key,
    required IconData icon,
    bool prominentIcon = false,
    Widget? detail,
  }) => InkWell(
    key: key,
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 80),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (prominentIcon)
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppSecondaryPalette.of(context).surface,
                borderRadius: BorderRadius.circular(
                  MaasoFrostTokens.compactRadius,
                ),
              ),
              child: Icon(
                icon,
                size: 24,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          else
            Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.6,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (value.isNotEmpty)
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      height: 20 / 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (detail != null) ...[const SizedBox(height: 8), detail],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    ),
  );

  Widget _interestChip(String label, AppSecondaryPalette palette) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(MaasoFrostTokens.pillRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({
    required this.controller,
    required this.zh,
    required this.onUserAction,
  });
  final ProfileController controller;
  final bool zh;
  final VoidCallback onUserAction;
  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final _name = TextEditingController(
    text: widget.controller.nickname.value,
  );
  String tr(String en, String zh) => widget.zh ? zh : en;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    widget.onUserAction();
    final c = widget.controller;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (picked == null || !mounted || !c.active) return;
      if (await picked.length() > 8 * 1024 * 1024) {
        throw const FormatException('avatar_too_large');
      }
      final bytes = await picked.readAsBytes();
      if (mounted && c.active) await c.setAvatarImage(bytes);
    } catch (_) {
      if (mounted && c.active) c.issue.value = 'invalid_image';
    }
  }

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final c = widget.controller;
    final field = c.editing.value;
    final active = c.active;
    final busy = c.busy.value;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(
          !active
              ? tr('Account changed', '账号已变化')
              : switch (field) {
                  ProfileEditField.avatar => tr('Profile photo', '用户头像'),
                  ProfileEditField.interests => tr('My interests', '我的喜好'),
                  _ => tr('Edit nickname', '编辑昵称'),
                },
        ),
        content: SingleChildScrollView(
          child: active
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (field == ProfileEditField.nickname)
                      TextField(
                        key: const ValueKey('profile-nickname-input'),
                        controller: _name,
                        autofocus: true,
                        enabled: !busy,
                        maxLength: 40,
                        onTap: widget.onUserAction,
                        decoration: InputDecoration(
                          labelText: tr('Nickname', '昵称'),
                        ),
                        onChanged: (value) {
                          widget.onUserAction();
                          c.updateNickname(value);
                        },
                      ),
                    if (field == ProfileEditField.avatar) ...[
                      Center(
                        child: CompanionAvatar(
                          profile: c.draft.value,
                          size: 80,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final preset in CompanionProfile.avatarPresets)
                            Semantics(
                              selected: c.draft.value?.avatarPreset == preset,
                              child: IconButton(
                                key: ValueKey('profile-avatar-$preset'),
                                tooltip: companionPresetLabel(
                                  preset,
                                  widget.zh,
                                ),
                                onPressed: busy
                                    ? null
                                    : () {
                                        widget.onUserAction();
                                        c.setAvatarPreset(preset);
                                      },
                                icon: Icon(CompanionAvatar.iconFor(preset)),
                                style: IconButton.styleFrom(
                                  backgroundColor:
                                      c.draft.value?.avatarPreset == preset
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : AppSecondaryPalette.of(
                                          context,
                                        ).surfaceMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: busy ? null : _pickPhoto,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(tr('Choose from photos', '从相册选择')),
                      ),
                    ],
                    if (field == ProfileEditField.interests)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final interest in CompanionProfile.interestIds)
                            FilterChip(
                              key: ValueKey('profile-interest-$interest'),
                              label: Text(
                                companionInterestLabel(interest, widget.zh),
                              ),
                              selected:
                                  c.draft.value?.interests.contains(interest) ==
                                  true,
                              side: BorderSide.none,
                              onSelected: busy
                                  ? null
                                  : (_) {
                                      widget.onUserAction();
                                      c.toggleInterest(interest);
                                    },
                            ),
                        ],
                      ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: LinearProgressIndicator(),
                      ),
                    if (c.issue.value != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          c.issue.value == 'invalid_name'
                              ? tr(
                                  'Use 1–40 characters without control characters.',
                                  '请输入 1–40 个有效字符。',
                                )
                              : companionIssueLabel(c.issue.value!, widget.zh),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                )
              : Text(
                  tr(
                    'Close this form and reopen your current profile.',
                    '请关闭此表单，重新打开当前账号的资料。',
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: busy && active
                ? null
                : () {
                    widget.onUserAction();
                    Navigator.pop(context);
                  },
            child: Text(tr('Cancel', '取消')),
          ),
          FilledButton(
            key: const ValueKey('profile-human-save'),
            onPressed: !active || busy
                ? null
                : () async {
                    widget.onUserAction();
                    final saved = await c.save();
                    if (context.mounted && saved) Navigator.pop(context);
                  },
            child: Text(busy ? tr('Saving…', '保存中…') : tr('Save', '保存')),
          ),
        ],
      ),
    );
  });
}
