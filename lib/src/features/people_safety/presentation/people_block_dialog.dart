import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import '../data/people_safety_client.dart';
import '../domain/people_block.dart';

Future<void> showPeopleBlockDialog(
  BuildContext context,
  PeopleActor actor,
) async {
  final gateway = appServices.maybeFind<PeopleSafetyClient>();
  if (gateway?.active != true) return;
  appServices
      .maybeFind<AgentUiControlService>()
      ?.coordinator
      .pauseForUserActivity(reason: 'people_block_preview');
  await showDialog<void>(
    context: context,
    builder: (_) => PeopleBlockDialog(gateway: gateway!, actor: actor),
  );
}

class PeopleBlockDialog extends StatefulWidget {
  const PeopleBlockDialog({
    super.key,
    required this.gateway,
    required this.actor,
  });
  final PeopleBlockGateway gateway;
  final PeopleActor actor;
  @override
  State<PeopleBlockDialog> createState() => _PeopleBlockDialogState();
}

class _PeopleBlockDialogState extends State<PeopleBlockDialog> {
  late final _key = widget.gateway.contextKey;
  StreamSubscription<void>? _subscription;
  PeopleBlock? _state;
  PeopleBlockDraft? _draft;
  bool _busy = true;
  bool _done = false;
  bool _failed = false;
  bool get active => widget.gateway.active && widget.gateway.contextKey == _key;
  String _t(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  @override
  void initState() {
    super.initState();
    _subscription = widget.gateway.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final row = await widget.gateway.blockState(widget.actor);
      if (mounted && active) {
        setState(() {
          _state = row;
          _busy = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && active) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _confirm() async {
    if (!active || _busy || _state == null) return;
    appServices
        .maybeFind<AgentUiControlService>()
        ?.coordinator
        .pauseForUserActivity(reason: 'people_block_confirm');
    final draft = _draft ??= PeopleBlockDraft(
      before: _state!,
      blocked: !_state!.blocked,
    );
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.gateway.setBlock(draft);
      if (mounted && active) {
        setState(() {
          _busy = false;
          _done = true;
        });
      }
    } catch (e) {
      if (mounted && active) {
        setState(() {
          _busy = false;
          _failed = true;
          if (e.toString().contains('409')) {
            _draft = null;
            _state = null;
          }
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = active ? _state : null;
    return AlertDialog(
      title: Text(
        active
            ? _t('Account controls', '账号互动设置')
            : _t('Account changed', '账号已切换'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (active) ...[
            Text(widget.actor.name),
            if (_busy) const LinearProgressIndicator(),
            if (_done)
              Text(_t('Updated.', '已更新。'))
            else if (row != null)
              Text(
                row.blocked
                    ? _t(
                        'Remove your block of this player and their Agent?',
                        '解除对该玩家及其 Agent 的屏蔽？',
                      )
                    : _t(
                        'Hide each other’s content and stop future interactions in the signed-in app? This covers the player and their Agent. Existing connections and shared links may remain accessible.',
                        '在登录的 App 内互相隐藏内容并停止后续互动？范围包括该玩家及其 Agent。已有连接和分享链接可能仍可访问。',
                      ),
              ),
            if (_failed)
              Text(
                _t(
                  'The result is not confirmed. Retry to check it.',
                  '结果尚未确认，请重试核实。',
                ),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy && active ? null : () => Navigator.of(context).pop(),
          child: Text(_t('Close', '关闭')),
        ),
        if (active && !_done)
          FilledButton(
            onPressed: _busy
                ? null
                : row == null
                ? () {
                    setState(() {
                      _busy = true;
                    });
                    unawaited(_load());
                  }
                : _confirm,
            child: Text(
              row == null
                  ? _t('Retry', '重试')
                  : row.blocked
                  ? _t('Confirm unblock', '确认解除屏蔽')
                  : _t('Confirm block', '确认屏蔽'),
            ),
          ),
      ],
    );
  }
}
