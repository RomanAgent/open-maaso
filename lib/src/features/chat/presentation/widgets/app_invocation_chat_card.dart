import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/app_invocation_chat_reference.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_recovery_service.dart';

/// The message carries only claims. Verify the journal before displaying a
/// source/status as trusted or enabling a recovery control.
class AppInvocationChatCard extends StatefulWidget {
  const AppInvocationChatCard({
    super.key,
    required this.reference,
    required this.sessionId,
    this.enabled = true,
    this.onRecover,
    this.onRestore,
    this.service,
  });
  final AppInvocationChatReference reference;
  final String sessionId;
  final bool enabled;
  final Future<void> Function(AppInvocationChatReference)? onRecover, onRestore;
  final AppInvocationRecoveryService? service;

  @override
  State<AppInvocationChatCard> createState() => _AppInvocationChatCardState();
}

class _AppInvocationChatCardState extends State<AppInvocationChatCard> {
  AppInvocationRecoveryService? _service;
  Future<AppInvocationRecoveryView>? _inspection;
  int _generation = 0;
  bool _acting = false;
  bool _failed = false;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(AppInvocationChatCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final service =
        widget.service ?? appServices.maybeFind<AppInvocationRecoveryService>();
    if (!identical(service, _service) ||
        oldWidget.sessionId != widget.sessionId ||
        jsonEncode(oldWidget.reference.toJson()) !=
            jsonEncode(widget.reference.toJson())) {
      _acting = false;
      _failed = false;
      _refresh();
    }
  }

  void _refresh() {
    _generation++;
    _service =
        widget.service ?? appServices.maybeFind<AppInvocationRecoveryService>();
    _inspection = _service?.inspect(
      widget.reference,
      sessionId: widget.sessionId,
    );
  }

  Future<void> _act(
    AppInvocationRecoveryView view, {
    required bool restore,
  }) async {
    final callback = restore ? widget.onRestore : widget.onRecover;
    final service = _service;
    if (_acting ||
        !widget.enabled ||
        !view.isCurrent ||
        callback == null ||
        service == null) {
      return;
    }
    final generation = _generation;
    setState(() {
      _acting = true;
      _failed = false;
    });
    try {
      final current = await service.inspect(
        view.reference,
        sessionId: widget.sessionId,
      );
      if (!mounted ||
          generation != _generation ||
          !current.isCurrent ||
          !widget.enabled ||
          (restore ? !current.canRestoreDraft : !current.canFetchResult)) {
        return;
      }
      await callback(current.reference);
    } on Object {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _acting = false;
          _refresh();
        });
      }
    }
  }

  String _status(AppInvocationChatStatus status) => switch (status) {
    AppInvocationChatStatus.working => _zh ? '正在调用' : 'Running',
    AppInvocationChatStatus.completed => _zh ? '已完成' : 'Completed',
    AppInvocationChatStatus.resultUnavailable =>
      _zh ? '执行已完成，结果待获取' : 'Finished; result ready to retrieve',
    AppInvocationChatStatus.outcomeUnknown =>
      _zh ? '结果尚无法确认' : 'The result is not yet confirmed',
    AppInvocationChatStatus.cancelled => _zh ? '已停止' : 'Stopped',
    AppInvocationChatStatus.failed =>
      _zh ? '调用未完成' : 'The action did not finish',
  };

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final secondary = Color.lerp(
      glass.foregroundPrimary,
      glass.foregroundSecondary,
      .5,
    )!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FutureBuilder<AppInvocationRecoveryView>(
        future: _inspection,
        builder: (context, snapshot) {
          final view = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done ||
              view == null ||
              !view.isCurrent) {
            return Text(
              _inspection != null &&
                      snapshot.connectionState != ConnectionState.done
                  ? (_zh ? '正在读取调用记录' : 'Reading action record')
                  : (_zh ? '调用记录不可用' : 'Action record unavailable'),
              style: TextStyle(color: secondary, fontSize: 13),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.apps_rounded,
                      size: 20,
                      color: glass.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      view.sourceTitle,
                      style: TextStyle(
                        color: glass.accent,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Semantics(
                liveRegion: true,
                child: Text(
                  _status(view.status),
                  style: TextStyle(color: secondary, fontSize: 13, height: 1.4),
                ),
              ),
              if (widget.enabled &&
                  ((view.canFetchResult && widget.onRecover != null) ||
                      (view.canRestoreDraft && widget.onRestore != null)))
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (view.canFetchResult && widget.onRecover != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          foregroundColor: glass.accent,
                        ),
                        onPressed: _acting
                            ? null
                            : () => _act(view, restore: false),
                        child: Text(_zh ? '重试获取结果' : 'Retrieve result'),
                      ),
                    if (view.canRestoreDraft && widget.onRestore != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          foregroundColor: glass.accent,
                        ),
                        onPressed: _acting
                            ? null
                            : () => _act(view, restore: true),
                        child: Text(_zh ? '恢复为草稿' : 'Restore draft'),
                      ),
                  ],
                ),
              if (_acting)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _zh ? '正在处理…' : 'Working…',
                    style: TextStyle(color: secondary, fontSize: 13),
                  ),
                ),
              if (_failed)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _zh ? '暂时无法处理，请重试' : 'Unable to finish. Try again.',
                    style: TextStyle(color: secondary, fontSize: 13),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
