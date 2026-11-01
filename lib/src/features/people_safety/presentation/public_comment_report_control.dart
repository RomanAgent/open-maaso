import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/domain/comment_reporting.dart';
import 'package:maaso/src/features/content_engagement/presentation/comment_report_button.dart';

/// The selected server content/row identifiers are fixed by its visible card.
/// The shared button asks the player for a reason and posts only after a tap.
class PublicCommentReportControl extends StatelessWidget {
  const PublicCommentReportControl({
    super.key,
    required this.surface,
    required this.contentId,
    required this.commentId,
  });
  final CommentReportSurface surface;
  final String contentId;
  final String commentId;
  @override
  Widget build(BuildContext context) {
    final client = appServices.maybeFind<ContentEngagementClient>();
    if (client == null || !client.reviewActive) return const SizedBox.shrink();
    return CommentReportButton(
      reporter: client,
      target: CommentReportTarget(
        surface: surface,
        contentId: contentId,
        commentId: commentId,
      ),
    );
  }
}
