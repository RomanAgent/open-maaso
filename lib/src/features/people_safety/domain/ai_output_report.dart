abstract interface class AIOutputReportGateway {
  bool get active;
  String get contextKey;
  Stream<void> get changes;
  Future<AIOutputReportReceipt> submitAIReport({
    required String requestId,
    required String text,
    required String reason,
  });
}

class AIOutputReportReceipt {
  const AIOutputReportReceipt({
    required this.caseId,
    required this.status,
    required this.duplicate,
  });
  final String caseId;
  final String status;
  final bool duplicate;

  factory AIOutputReportReceipt.fromJson(Map<String, dynamic> json) {
    final id = json['caseId'];
    final status = json['status'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,47}$').hasMatch(id) ||
        !{'open', 'in_review', 'actioned', 'dismissed'}.contains(status) ||
        json['duplicate'] is! bool) {
      throw const FormatException('invalid_ai_report_receipt');
    }
    return AIOutputReportReceipt(
      caseId: id,
      status: status as String,
      duplicate: json['duplicate'] as bool,
    );
  }
}
