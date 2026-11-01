import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import '../application/people_safety_controller.dart';
import '../application/people_safety_page_adapter.dart';
import '../data/people_safety_client.dart';
import '../domain/people_block.dart';

class PeopleSafetyPage extends StatefulWidget {
  const PeopleSafetyPage({
    super.key,
    required this.route,
    this.gateway,
    this.uiControl,
  });
  final String route;
  final PeopleBlockGateway? gateway;
  final AgentUiControlService? uiControl;
  @override
  State<PeopleSafetyPage> createState() => _PeopleSafetyPageState();
}

class _PeopleSafetyPageState extends State<PeopleSafetyPage> {
  PeopleSafetyController? _controller;
  AgentUiControlService? _ui;
  PeopleSafetyPageAdapter? _adapter;
  PageAgentAdapterRegistration<PeopleSafetyPageAdapter>? _registration;
  String _t(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  @override
  void initState() {
    super.initState();
    final gateway =
        widget.gateway ?? appServices.maybeFind<PeopleSafetyClient>();
    if (gateway == null) return;
    final c = PeopleSafetyController(gateway);
    _controller = c;
    c.addListener(_changed);
    _ui = widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    if (_ui != null) {
      final a = PeopleSafetyPageAdapter(
        route: widget.route,
        controller: c,
        coordinator: _ui!.coordinator,
      );
      _adapter = a;
      _registration = _ui!.adapters.register(a);
    }
    unawaited(c.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _takeover() {
    _controller?.userActivity();
    _ui?.coordinator.pauseForUserActivity(reason: 'people_safety_input');
  }

  @override
  void dispose() {
    _adapter?.detach();
    _registration?.unregister();
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final active = c?.active == true;
    final draft = c?.draft;
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: _t('Blocked accounts', '屏蔽管理'),
        onBack: () => appNavigation.pop(),
        trailing: IconButton(
          tooltip: _t('Refresh', '刷新'),
          onPressed: active && c?.busy == false
              ? () {
                  _takeover();
                  unawaited(c!.refresh());
                }
              : null,
          icon: const Icon(Icons.refresh),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  _t(
                    'Blocking hides each other’s content and prevents future interactions in the signed-in app. It covers the player and their Agent. Existing media connections and shared links may remain accessible.',
                    '屏蔽后，双方在登录的 App 内互相隐藏内容并停止后续互动，范围包括玩家及其 Agent。已有媒体连接和分享链接可能仍可访问。',
                  ),
                ),
                const SizedBox(height: 16),
                if (!active)
                  Text(_t('Sign in to manage blocked accounts.', '登录后管理屏蔽列表。'))
                else ...[
                  if (c!.busy) const LinearProgressIndicator(),
                  if (c.error != null)
                    Text(
                      _t(
                        c.error == 'state_changed'
                            ? 'This block changed. Refresh before trying again.'
                            : 'Could not complete the request. Retry to check the result.',
                        '请求未完成或状态已变化，请刷新或重试确认结果。',
                      ),
                    ),
                  if (!c.busy && c.items.isEmpty)
                    Text(_t('No blocked accounts.', '暂无屏蔽的账号。')),
                  for (final row in c.items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${row.actor.name} (${row.actor.kind == 'agent' ? _t('Native', '原住民') : _t('Alien', '外星人')})',
                      ),
                      trailing: TextButton(
                        onPressed: c.busy || draft != null
                            ? null
                            : () {
                                _takeover();
                                c.prepareUnblock(row.actor.id, row.actor.kind);
                              },
                        child: Text(_t('Unblock', '解除屏蔽')),
                      ),
                    ),
                  if (draft != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _t(
                                'Unblock ${draft.before.actor.name}?',
                                '解除对 ${draft.before.actor.name} 的屏蔽？',
                              ),
                            ),
                            Text(
                              _t(
                                'Your block of this player and their Agent will be removed. They may still have blocked you.',
                                '你对该玩家及其 Agent 的屏蔽会被解除。对方仍可能屏蔽了你。',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: c.busy
                                      ? null
                                      : () {
                                          _takeover();
                                          c.cancel();
                                        },
                                  child: Text(_t('Cancel', '取消')),
                                ),
                                FilledButton(
                                  onPressed: c.busy
                                      ? null
                                      : () {
                                          _takeover();
                                          unawaited(c.confirm());
                                        },
                                  child: Text(_t('Confirm unblock', '确认解除屏蔽')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
