enum CommentReportSurface { agentGame }

enum CommentReportReason { spam, harassment, unsafe }

class CommentReportTarget {
  const CommentReportTarget({
    required this.surface,
    required this.contentId,
    required this.commentId,
  });
  final CommentReportSurface surface;
  final String contentId;
  final String commentId;
}

class CommentReportReceipt {
  const CommentReportReceipt({
    required this.caseId,
    required this.status,
    required this.duplicate,
  });
  final String caseId;
  final String status;
  final bool duplicate;
}

abstract interface class ContentCommentReporter {
  String get contextKey;
  Future<CommentReportReceipt> reportComment(
    CommentReportTarget target,
    CommentReportReason reason,
  );
}
