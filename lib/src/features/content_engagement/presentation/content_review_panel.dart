import 'dart:async';
import 'package:flutter/material.dart';
import '../application/content_review_controller.dart';
import '../domain/content_review.dart';

Future<void> showContentReviews(
  BuildContext context,
  ContentReviewGateway gateway,
) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
      child: ContentReviewPanel(gateway: gateway),
    ),
  ),
);

class ContentReviewPanel extends StatefulWidget {
  const ContentReviewPanel({
    super.key,
    required this.gateway,
    this.controller,
    this.onUserActivity,
  });

  /// The panel retires this controller when it closes, including injected ones.
  final ContentReviewController? controller;
  final VoidCallback? onUserActivity;
  final ContentReviewGateway gateway;
  @override
  State<ContentReviewPanel> createState() => _ContentReviewPanelState();
}

class _ContentReviewPanelState extends State<ContentReviewPanel> {
  late ContentReviewController _controller;
  final _reason = TextEditingController();
  final _focus = FocusNode();
  final _draftAnchor = GlobalKey();
  @override
  void initState() {
    super.initState();
    _controller = (widget.controller ?? ContentReviewController(widget.gateway))
      ..addListener(_changed);
    assert(identical(_controller.gateway, widget.gateway));
    _focus.addListener(() {
      _controller.userControl = _focus.hasFocus;
      if (_focus.hasFocus) widget.onUserActivity?.call();
    });
    unawaited(_controller.refresh());
  }

  void _changed() {
    if (_reason.text != _controller.draft) {
      _reason.value = TextEditingValue(
        text: _controller.draft,
        selection: TextSelection.collapsed(offset: _controller.draft.length),
      );
    }
    if (mounted) {
      setState(() {});
      if (_controller.selected != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final anchor = _draftAnchor.currentContext;
          if (mounted && anchor != null) {
            unawaited(Scrollable.ensureVisible(anchor));
          }
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant ContentReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gateway, widget.gateway) ||
        !identical(oldWidget.controller, widget.controller)) {
      _controller.dispose();
      _reason.clear();
      _controller =
          (widget.controller ?? ContentReviewController(widget.gateway))
            ..addListener(_changed);
      unawaited(_controller.refresh());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _reason.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String t(String en, String cn) => zh ? cn : en;
    final c = _controller;
    if (!c.active) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(t('This account is no longer active.', '账号状态已变化。')),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t('My reviews', '我的审核'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: t('Refresh', '刷新'),
                onPressed: c.loading || c.submitting
                    ? null
                    : () {
                        widget.onUserActivity?.call();
                        unawaited(c.refresh());
                      },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Text(
            t(
              'Comments publish only when you retry after approval. Approved consumption can enter a reward pool subject to capacity; normal settlement starts on the next UTC day. Review approval does not guarantee reward settlement.',
              '评论通过后需由你重试发送。消费审核通过后根据容量进入奖励池，正常结算最早从下一个 UTC 日开始；审核通过不代表奖励已结算。',
            ),
          ),
          const SizedBox(height: 12),
          if (c.loading) const LinearProgressIndicator(),
          if (!c.loading && c.items.isEmpty && c.error == null)
            Text(t('No reviews yet.', '暂无审核记录。')),
          for (final r in c.items)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${switch (r.kind) {
                        ContentReviewKind.comment => t('Comment', '评论'),
                        ContentReviewKind.consumption => t('Creator reward', '创作收益'),
                        ContentReviewKind.delivery => t('Reward review', '奖励复核'),
                      }} · ${r.targetId}',
                    ),
                    if (r.commentText != null) Text(r.commentText!),
                    Text(switch (r.state) {
                      ContentReviewState.pending => t('Awaiting review', '审核中'),
                      ContentReviewState.approved =>
                        r.kind == ContentReviewKind.delivery
                            ? t('Accepted by a reward pool', '已进入奖励池')
                            : t('Approved', '已通过'),
                      ContentReviewState.rejected => t('Not approved', '未通过'),
                      ContentReviewState.processing => t(
                        'Retry queued or in progress',
                        '重试已排队或正在执行',
                      ),
                    }),
                    if (r.delivery case final delivery?) ...[
                      Text(
                        delivery.exceptionReason == 'pool_already_settled'
                            ? t(
                                'The original reward pool was already settled.',
                                '原奖励池已结算。',
                              )
                            : t(
                                'The original activity record conflicted.',
                                '原活动记录存在冲突。',
                              ),
                      ),
                      Text(
                        '${t('Activity (UTC)', '活动时间（UTC）')}: ${delivery.activityOccurredAt.toIso8601String()}',
                      ),
                      if (r.reasonCode == 'delivery_retry_unavailable')
                        Text(
                          t(
                            'Automatic retry stopped. An operator must review the outcome.',
                            '自动重试已停止，等待审核员处理结果。',
                          ),
                        ),
                      Text(
                        t(
                          'Final reward settlement is separate from this review status.',
                          '最终奖励结算与此处的审核状态分开处理。',
                        ),
                      ),
                    ],
                    if (c.appealed(r.id))
                      Text(
                        t(
                          r.appealState == ContentReviewAppealState.upheld
                              ? 'Appeal reviewed. The original decision was upheld.'
                              : 'Appeal submitted. A different reviewer will assess it.',
                          r.appealState == ContentReviewAppealState.upheld
                              ? '申诉已审核，原决定维持。'
                              : '申诉已提交，将由另一位审核员处理。',
                        ),
                      ),
                    if (r.state == ContentReviewState.rejected &&
                        !c.appealed(r.id))
                      TextButton(
                        key: ValueKey('review-appeal-${r.id}'),
                        onPressed: c.submitting
                            ? null
                            : () {
                                widget.onUserActivity?.call();
                                c.prepare(r.id, '');
                              },
                        child: Text(t('Appeal', '申诉')),
                      ),
                  ],
                ),
              ),
            ),
          if (c.selected != null) ...[
            SizedBox(key: _draftAnchor),
            TextField(
              key: const ValueKey('review-appeal-reason'),
              controller: _reason,
              focusNode: _focus,
              enabled: !c.submitting,
              minLines: 2,
              maxLines: 5,
              onChanged: (value) {
                widget.onUserActivity?.call();
                c.edit(value);
              },
              decoration: InputDecoration(
                labelText: t(
                  'Why should this be reviewed again?',
                  '请说明重新审核的理由',
                ),
                helperText: '${c.draft.trim().runes.length}/600',
              ),
            ),
            Text(
              t(
                'Submitting sends this reason to reviewers. An appeal does not automatically approve content, publish it, or grant coins.',
                '提交后审核员会看到此理由。申诉不会自动通过、发布内容或发放币。',
              ),
            ),
            FilledButton(
              key: const ValueKey('review-appeal-submit'),
              onPressed: c.canSubmit
                  ? () {
                      widget.onUserActivity?.call();
                      unawaited(c.submitByUser());
                    }
                  : null,
              child: Text(t('Submit appeal', '提交申诉')),
            ),
          ],
          if (c.error != null)
            Text(
              t(
                'Unable to complete. Your draft is kept; refresh or retry.',
                '暂时无法完成，草稿已保留，请刷新或重试。',
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
