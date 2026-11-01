import 'package:flutter/material.dart';

import '../domain/comment_reporting.dart';

/// Each report is a direct human menu selection. No Agent write adapter is
/// exposed, and success is displayed only after the persisted server receipt.
class CommentReportButton extends StatefulWidget {
  const CommentReportButton({
    super.key,
    required this.reporter,
    required this.target,
  });
  final ContentCommentReporter reporter;
  final CommentReportTarget target;

  @override
  State<CommentReportButton> createState() => _CommentReportButtonState();
}

class _CommentReportButtonState extends State<CommentReportButton> {
  late String _scope;
  bool _pending = false;
  bool _reported = false;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scope = widget.reporter.contextKey;
  }

  @override
  void didUpdateWidget(covariant CommentReportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.reporter, widget.reporter) ||
        oldWidget.target.surface != widget.target.surface ||
        oldWidget.target.contentId != widget.target.contentId ||
        oldWidget.target.commentId != widget.target.commentId ||
        widget.reporter.contextKey != _scope) {
      _generation++;
      _scope = widget.reporter.contextKey;
      _pending = _reported = _failed = false;
    }
  }

  Future<void> _report(CommentReportReason reason) async {
    if (_pending || _reported || widget.reporter.contextKey != _scope) return;
    final generation = _generation;
    bool current() =>
        mounted &&
        generation == _generation &&
        widget.reporter.contextKey == _scope;
    setState(() {
      _pending = true;
      _failed = false;
    });
    try {
      await widget.reporter.reportComment(widget.target, reason);
      if (current()) setState(() => _reported = true);
    } catch (_) {
      if (current()) setState(() => _failed = true);
    } finally {
      if (current()) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    if (_reported) {
      return Text(
        zh ? '已举报' : 'Reported',
        key: ValueKey('comment-reported-${widget.target.commentId}'),
      );
    }
    if (_pending) {
      return const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return PopupMenuButton<CommentReportReason>(
      key: ValueKey('comment-report-${widget.target.commentId}'),
      tooltip: zh ? '举报评论' : 'Report comment',
      onSelected: _report,
      itemBuilder: (_) => [
        PopupMenuItem(
          value: CommentReportReason.spam,
          child: Text(zh ? '垃圾信息' : 'Spam'),
        ),
        PopupMenuItem(
          value: CommentReportReason.harassment,
          child: Text(zh ? '骚扰' : 'Harassment'),
        ),
        PopupMenuItem(
          value: CommentReportReason.unsafe,
          child: Text(zh ? '不安全内容' : 'Unsafe content'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          _failed
              ? (zh ? '举报失败，重试' : 'Report failed. Retry')
              : (zh ? '举报' : 'Report'),
        ),
      ),
    );
  }
}
