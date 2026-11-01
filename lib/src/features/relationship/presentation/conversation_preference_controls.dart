import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

String _label(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

String _humorLabel(
  BuildContext context,
  ConversationHumorStyle style,
) => switch (style) {
  ConversationHumorStyle.subdued => _label(context, '少开玩笑', 'Keep jokes rare'),
  ConversationHumorStyle.playful => _label(
    context,
    '偶尔逗我',
    'Occasionally playful',
  ),
  ConversationHumorStyle.lightBanter => _label(context, '适度互损', 'Light banter'),
};

String _topicLabel(BuildContext context, String topic) {
  const labels = {
    'gaming': ('游戏', 'Gaming'),
    'work': ('工作小插曲', 'Work mishaps'),
    'study': ('学习小插曲', 'Study mishaps'),
    'cooking': ('做饭', 'Cooking'),
    'procrastination': ('拖延', 'Procrastination'),
    'daily_mixups': ('日常乌龙', 'Everyday mix-ups'),
    'general': ('所有个人调侃', 'All personal teasing'),
    'appearance': ('外貌', 'Appearance'),
    'health': ('健康', 'Health'),
    'family': ('家庭', 'Family'),
    'relationships': ('感情关系', 'Relationships'),
    'finances': ('经济状况', 'Finances'),
    'identity': ('身份背景', 'Identity'),
    'trauma': ('创伤经历', 'Trauma'),
  };
  final pair = labels[topic]!;
  return _label(context, pair.$1, pair.$2);
}

/// User-confirmed persona memories, edited through the existing preference
/// service so learned memories cannot silently overwrite explicit choices.
class ConversationPreferenceControls extends StatefulWidget {
  const ConversationPreferenceControls({super.key});
  @override
  State<ConversationPreferenceControls> createState() =>
      _ConversationPreferenceControlsState();
}

class _ConversationPreferenceControlsState
    extends State<ConversationPreferenceControls> {
  bool _saving = false;
  String? _error;

  Future<void> _save(
    ConversationPreferenceService service,
    Future<void> Function() operation,
  ) async {
    if (_saving ||
        !identical(
          appServices.maybeFind<ConversationPreferenceService>(),
          service,
        )) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await operation();
    } on Object {
      if (mounted) {
        _error = _label(context, '设置未保存，请重试。', 'Could not save. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = appServices.maybeFind<ConversationPreferenceService>();
    if (service == null) return const SizedBox.shrink();
    return AppReactiveBuilder(() {
      final value = service.state.value;
      final enabled = service.isAvailable && !_saving;
      return AppSecondarySection(
        title: _label(context, '聊天方式', 'How we chat'),
        subtitle: _label(
          context,
          '这些偏好会作为 Agent 的记忆，之后聊天时参考。你可以随时修改。',
          'Your Agent remembers these preferences for future chats. Change them anytime.',
        ),
        child: AppSecondaryCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!service.isAvailable)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _label(
                      context,
                      '聊天设置暂不可用。可以清空此处设置后重新选择。',
                      'Chat settings are unavailable. Clear these settings to choose again.',
                    ),
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: enabled,
                title: Text(_label(context, '开玩笑的方式', 'Humor')),
                subtitle: Text(_humorLabel(context, value.humorStyle)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final selected = await showDialog<ConversationHumorStyle>(
                    context: context,
                    builder: (dialogContext) => SimpleDialog(
                      title: Text(_label(context, '开玩笑的方式', 'Humor')),
                      children: [
                        for (final style in ConversationHumorStyle.values)
                          ListTile(
                            title: Text(_humorLabel(context, style)),
                            selected: value.humorStyle == style,
                            trailing: value.humorStyle == style
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => Navigator.pop(dialogContext, style),
                          ),
                      ],
                    ),
                  );
                  if (selected != null && mounted) {
                    await _save(service, () => service.setHumorStyle(selected));
                  }
                },
              ),
              if (value.humorStyle == ConversationHumorStyle.lightBanter)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: enabled,
                  title: Text(
                    _label(context, '允许轻轻吐槽的话题', 'Topics for light banter'),
                  ),
                  subtitle: Text(
                    _label(
                      context,
                      '逐项选择；未选就不默认许可。',
                      'Choose each topic. Nothing is allowed by default.',
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _topics(context, service, allow: true),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: enabled,
                title: Text(_label(context, '怎么称呼我', 'Call me')),
                subtitle: Text(
                  value.preferredAddress ??
                      _label(context, '未指定', 'Not specified'),
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _address(context, service, forbidden: false),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: enabled,
                title: Text(_label(context, '不要这样称呼我', 'Never call me')),
                subtitle: Text(
                  value.forbiddenAddresses.isEmpty
                      ? _label(context, '未设置', 'Not set')
                      : value.forbiddenAddresses.join('、'),
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _address(context, service, forbidden: true),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: enabled,
                title: Text(
                  _label(context, '不想被调侃的话题', 'Topics to avoid teasing about'),
                ),
                subtitle: Text(
                  value.banterBoundaries.entries
                      .where(
                        (entry) => entry.value == BanterDisposition.forbidden,
                      )
                      .map((entry) => _topicLabel(context, entry.key))
                      .join('、')
                      .ifEmpty(_label(context, '未设置', 'Not set')),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _topics(context, service, allow: false),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              TextButton(
                onPressed: _saving ? null : () => _save(service, service.clear),
                child: Text(
                  _saving
                      ? _label(context, '正在保存…', 'Saving…')
                      : _label(
                          context,
                          '清空这些聊天设置',
                          'Clear these chat settings',
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _address(
    BuildContext context,
    ConversationPreferenceService service, {
    required bool forbidden,
  }) => showDialog<void>(
    context: context,
    builder: (_) =>
        _AddressPreferenceDialog(service: service, forbidden: forbidden),
  );

  Future<void> _topics(
    BuildContext context,
    ConversationPreferenceService service, {
    required bool allow,
  }) async {
    final base = service.effectiveSnapshot;
    final disposition = allow
        ? BanterDisposition.accepted
        : BanterDisposition.forbidden;
    final selected = base.banterBoundaries.entries
        .where((entry) => entry.value == disposition)
        .map((entry) => entry.key)
        .toSet();
    final choices = allow
        ? conversationLightBanterTopics
        : conversationBanterTopics;
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: Text(
            _label(
              context,
              allow ? '允许轻轻吐槽的话题' : '不想被调侃的话题',
              allow ? 'Topics for light banter' : 'Topics to avoid',
            ),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (allow)
                    Text(
                      _label(
                        context,
                        '只允许轻微调侃，仍要看场合；避雷话题优先。',
                        'Only gentle banter when appropriate. Avoided topics take priority.',
                      ),
                    ),
                  for (final topic in choices)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_topicLabel(context, topic)),
                      value: selected.contains(topic),
                      onChanged:
                          saving ||
                              allow &&
                                  base.banterBoundaries[topic] ==
                                      BanterDisposition.forbidden
                          ? null
                          : (checked) => refresh(() {
                              if (checked == true) {
                                selected.add(topic);
                              } else {
                                selected.remove(topic);
                              }
                            }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: Text(_label(context, '取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      refresh(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        if (!identical(
                          appServices
                              .maybeFind<ConversationPreferenceService>(),
                          service,
                        )) {
                          throw StateError('account changed');
                        }
                        await service.setBanterBoundaries({
                          for (final entry in base.banterBoundaries.entries)
                            if (entry.value != disposition &&
                                !selected.contains(entry.key))
                              entry.key: entry.value,
                          for (final topic in selected) topic: disposition,
                        }, expectedRevision: base.revision);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } on Object {
                        if (dialogContext.mounted) {
                          refresh(() {
                            saving = false;
                            error = _label(
                              context,
                              '未保存。请重试；如设置已变化，请重新打开。',
                              'Not saved. Retry, or reopen if the settings changed.',
                            );
                          });
                        }
                      }
                    },
              child: Text(
                saving
                    ? _label(context, '正在保存…', 'Saving…')
                    : _label(context, '保存', 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _AddressPreferenceDialog extends StatefulWidget {
  const _AddressPreferenceDialog({
    required this.service,
    required this.forbidden,
  });
  final ConversationPreferenceService service;
  final bool forbidden;
  @override
  State<_AddressPreferenceDialog> createState() =>
      _AddressPreferenceDialogState();
}

class _AddressPreferenceDialogState extends State<_AddressPreferenceDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _input = TextEditingController(
    text: widget.forbidden
        ? widget.service.effectiveSnapshot.forbiddenAddresses.join('\n')
        : widget.service.effectiveSnapshot.preferredAddress ?? '',
  );
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  List<String> get _addresses => _input.text
      .split(RegExp(r'[,，、\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!identical(
        appServices.maybeFind<ConversationPreferenceService>(),
        widget.service,
      )) {
        throw StateError('account changed');
      }
      if (widget.forbidden) {
        await widget.service.setForbiddenAddresses(_addresses);
      } else {
        await widget.service.setPreferredAddress(_input.text);
      }
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _label(
            context,
            '未保存。请检查称呼是否在禁用列表中，或稍后重试。',
            'Not saved. Check the forbidden names, or try again.',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      _label(
        context,
        widget.forbidden ? '不要这样称呼我' : '怎么称呼我',
        widget.forbidden ? 'Never call me' : 'Call me',
      ),
    ),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormField<String>(
              validator: (_) {
                final values = widget.forbidden
                    ? _addresses
                    : [_input.text.trim()];
                if (values.length > 16 ||
                    values.any(
                      (value) =>
                          value.isNotEmpty &&
                          !ConversationPreferenceSnapshot.supportsAddress(
                            value,
                          ),
                    )) {
                  return _label(
                    context,
                    '最多16个称呼，每个不超过32个字。请填写名字，如小林、Alex；支持中英文、数字、空格、横线和下划线。',
                    'Up to 16 names, 32 characters each. Start with a Chinese or English letter; use letters, numbers, spaces, hyphens or underscores, such as Alex.',
                  );
                }
                return null;
              },
              builder: (field) => AppGlassField(
                controller: _input,
                enabled: !_saving,
                maxLines: widget.forbidden ? 4 : 1,
                decoration: InputDecoration(
                  labelText: _label(context, '称呼', 'Name'),
                  hintText: widget.forbidden
                      ? _label(
                          context,
                          '用逗号或换行分开',
                          'Separate with commas or new lines',
                        )
                      : null,
                  errorText: field.errorText,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _label(
                context,
                '例如小林、Alex。留空并保存即可清空。',
                'For example, Alex or 小林. Leave blank and save to clear.',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(_label(context, '取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(
          _saving
              ? _label(context, '正在保存…', 'Saving…')
              : _label(context, '保存', 'Save'),
        ),
      ),
    ],
  );
}
