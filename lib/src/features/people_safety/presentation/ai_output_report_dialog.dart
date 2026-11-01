import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../domain/ai_output_report.dart';

/// Only a direct button press submits the preview. There is no Agent action
/// adapter or background retry that can upload private conversation evidence.
Future<void> showAIOutputReportDialog({
  required BuildContext context,
  required AIOutputReportGateway gateway,
  required String selectedText,
  VoidCallback? onUserActivity,
}) async {
  if (!gateway.active || selectedText.trim().isEmpty) return;
  final text = String.fromCharCodes(selectedText.runes.take(16000));
  await showDialog<void>(
    context: context,
    builder: (_) => AIOutputReportDialog(
      gateway: gateway,
      text: text,
      shortened: text != selectedText,
      onUserActivity: onUserActivity,
    ),
  );
}

class AIOutputReportDialog extends StatefulWidget {
  const AIOutputReportDialog({
    super.key,
    required this.gateway,
    required this.text,
    this.shortened = false,
    this.onUserActivity,
  });
  final AIOutputReportGateway gateway;
  final String text;
  final bool shortened;
  final VoidCallback? onUserActivity;

  @override
  State<AIOutputReportDialog> createState() => _AIOutputReportDialogState();
}

class _AIOutputReportDialogState extends State<AIOutputReportDialog> {
  late final String _contextKey = widget.gateway.contextKey;
  final String _requestId = _newReportRequestId();
  StreamSubscription<void>? _changes;
  String _reason = 'unsafe';
  String? _submittedReason;
  bool _sending = false;
  bool _failed = false;
  AIOutputReportReceipt? _receipt;

  bool get _active =>
      widget.gateway.active && widget.gateway.contextKey == _contextKey;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  @override
  void initState() {
    super.initState();
    _changes = widget.gateway.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending || !_active || _receipt != null) return;
    widget.onUserActivity?.call();
    setState(() {
      _sending = true;
      _failed = false;
      _submittedReason ??= _reason;
    });
    try {
      final receipt = await widget.gateway.submitAIReport(
        requestId: _requestId,
        text: widget.text,
        reason: _submittedReason!,
      );
      if (mounted && _active) setState(() => _receipt = receipt);
    } catch (_) {
      if (mounted && _active) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return AlertDialog(
      title: Text(_zh ? '举报这条 AI 回复' : 'Report this AI reply'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!active)
                Text(
                  _zh
                      ? '账号已切换，请重新打开举报。'
                      : 'Account changed. Open the report again.',
                )
              else if (_receipt != null)
                Text(
                  _zh
                      ? '已收到举报，审核团队会处理所选内容。编号：${_receipt!.caseId}'
                      : 'Report received for review. Reference: ${_receipt!.caseId}',
                  key: const ValueKey('ai-report-receipt'),
                )
              else ...[
                Text(
                  _zh
                      ? '仅下方这条回复和你选择的原因会提交审核，不会附带其他聊天、记忆或录音。'
                      : 'Only the reply below and your reason will be sent for review. Other messages, memories and recordings are excluded.',
                ),
                if (widget.shortened)
                  Text(
                    _zh
                        ? '回复较长，本次仅提交下方前 16,000 个字符。'
                        : 'This report includes the first 16,000 characters shown below.',
                  ),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 240),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      widget.text,
                      key: const ValueKey('ai-report-evidence-preview'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: _reason,
                  isExpanded: true,
                  onChanged: _submittedReason != null
                      ? null
                      : (value) {
                          widget.onUserActivity?.call();
                          setState(() => _reason = value!);
                        },
                  items: [
                    DropdownMenuItem(
                      value: 'unsafe',
                      child: Text(_zh ? '不安全或有害内容' : 'Unsafe or harmful'),
                    ),
                    DropdownMenuItem(
                      value: 'harassment',
                      child: Text(_zh ? '骚扰或攻击' : 'Harassment or abuse'),
                    ),
                    DropdownMenuItem(
                      value: 'other',
                      child: Text(_zh ? '其他问题' : 'Other concern'),
                    ),
                  ],
                ),
                if (_failed)
                  Text(
                    _zh
                        ? '尚未确认提交结果。重试会使用同一编号，不会重复举报。'
                        : 'Submission is unconfirmed. Retry uses the same reference to avoid duplicate reports.',
                    key: const ValueKey('ai-report-error'),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.onUserActivity?.call();
            Navigator.of(context).pop();
          },
          child: Text(_zh ? '关闭' : 'Close'),
        ),
        if (active && _receipt == null)
          FilledButton(
            key: const ValueKey('ai-report-submit'),
            onPressed: _sending ? null : _submit,
            child: Text(
              _sending
                  ? (_zh ? '提交中…' : 'Sending…')
                  : (_failed
                        ? (_zh ? '重试' : 'Retry')
                        : (_zh ? '提交举报' : 'Send report')),
            ),
          ),
      ],
    );
  }
}

String _newReportRequestId() {
  final random = Random.secure();
  return 'air_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}
