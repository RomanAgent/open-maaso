import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/agent_handoff_device_directory.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';

String handoffText(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

String handoffPhaseText(BuildContext context, AgentHandoffPhase phase) =>
    switch (phase) {
      AgentHandoffPhase.preparing => handoffText(
        context,
        '正在准备执行设备…',
        'Preparing the execution device…',
      ),
      AgentHandoffPhase.waitingForTarget ||
      AgentHandoffPhase.targetPreparing => handoffText(
        context,
        '正在准备另一台执行设备…',
        'Preparing the other execution device…',
      ),
      AgentHandoffPhase.sourceExiting => handoffText(
        context,
        '正在移交执行…',
        'Transferring execution…',
      ),
      AgentHandoffPhase.awaitingCommit => handoffText(
        context,
        '正在确认执行权…',
        'Confirming execution authority…',
      ),
      AgentHandoffPhase.targetEntering => handoffText(
        context,
        '正在接管执行…',
        'Adopting execution…',
      ),
      AgentHandoffPhase.away => handoffText(
        context,
        '执行已切换到另一台设备',
        'Execution is on the other device',
      ),
      AgentHandoffPhase.completed => handoffText(
        context,
        '执行设备已切换',
        'Execution device switched',
      ),
      AgentHandoffPhase.failed => handoffText(
        context,
        '执行切换尚未完成，正在确认状态…',
        'Execution switch is unfinished. Checking its status…',
      ),
      AgentHandoffPhase.idle => handoffText(
        context,
        '选择执行设备',
        'Choose an execution device',
      ),
    };

/// The existing settings page owns this control; it adds no new destination.
class DeviceHandoffPanel extends StatefulWidget {
  const DeviceHandoffPanel({super.key, this.directory, this.handoff});
  final AgentHandoffDeviceDirectory? directory;
  final AgentHandoffService? handoff;

  @override
  State<DeviceHandoffPanel> createState() => _DeviceHandoffPanelState();
}

class _DeviceHandoffPanelState extends State<DeviceHandoffPanel> {
  late final AgentHandoffService? _handoff =
      widget.handoff ?? appServices.maybeFind<AgentHandoffService>();
  late final AgentHandoffDeviceDirectory? _directory =
      widget.directory ?? appServices.maybeFind<AgentHandoffDeviceDirectory>();
  List<AccountDevicePresenceView> _targets = const [];
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _handoff?.addListener(_changed);
    if (_handoff?.canRequest == true) unawaited(_refresh());
  }

  @override
  void dispose() {
    _handoff?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (_loading || _directory == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final targets = await _directory.listTargets();
      if (mounted) setState(() => _targets = targets);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _targets = const [];
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _move(AccountDevicePresenceView target) async {
    try {
      // Re-read the account's devices immediately before using a displayed ID.
      final current = await _directory!.listTargets();
      if (!mounted || _handoff?.canRequest != true) return;
      if (!current.any(
        (device) => device.presenceSessionId == target.presenceSessionId,
      )) {
        setState(() {
          _targets = current;
          _failed = true;
        });
        return;
      }
      await _handoff!.request(target.presenceSessionId);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _handoff;
    final enabled = service?.canRequest == true;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    handoffText(context, '执行设备切换', 'Switch execution device'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: handoffText(context, '刷新设备', 'Refresh devices'),
                  onPressed: enabled && !_loading ? _refresh : null,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            Text(
              handoffText(
                context,
                '各设备可同时显示人物，此操作只切换 Agent 执行设备。',
                'Each device can show the Avatar. This changes the device that executes Agent actions.',
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator()
            else if (service?.isBusy == true)
              Text(handoffPhaseText(context, service!.phase))
            else if (_failed)
              Text(
                handoffText(
                  context,
                  '未能切换，请刷新设备后重试。',
                  'Could not switch execution. Refresh devices and retry.',
                ),
              )
            else if (!enabled)
              Text(
                handoffText(
                  context,
                  '当前暂不能切换执行设备。',
                  'Execution switching is currently unavailable.',
                ),
              )
            else if (_targets.isEmpty)
              Text(
                handoffText(
                  context,
                  '还没有发现在线的其它设备。',
                  'No other devices are online yet.',
                ),
              ),
            if (service?.canCancel == true)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('handoff-cancel'),
                  onPressed: () => unawaited(service!.cancel()),
                  child: Text(handoffText(context, '取消切换', 'Cancel switch')),
                ),
              ),
            if (!_loading && enabled)
              ..._targets.map(
                (device) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    const {'macos', 'windows'}.contains(device.platform)
                        ? Icons.computer_rounded
                        : Icons.smartphone_rounded,
                  ),
                  title: Text(
                    device.deviceLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(device.platform),
                  trailing: FilledButton.tonal(
                    // App-wide filled buttons expand to a full row. A tile's
                    // trailing control must leave room for its device label.
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 44),
                    ),
                    onPressed: () => unawaited(_move(device)),
                    child: Text(handoffText(context, '切换到此设备', 'Switch here')),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
