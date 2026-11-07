import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/network/backend_client.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import '../domain/content_engagement.dart';
import '../domain/comment_reporting.dart';
import '../domain/content_review.dart';

/// The account mount owns this client. Token resolution must use that exact
/// mount; every await is fenced against an account/environment change.
class ContentEngagementClient extends AppService
    implements
        ContentEngagementGateway,
        ContentCommentReporter,
        ContentReviewGateway {
  ContentEngagementClient({
    required Uri Function() baseUri,
    required String Function() accountId,
    required Future<String> Function() accessToken,
    http.Client? client,
  }) : _baseUri = baseUri,
       _accountId = accountId,
       _accessToken = accessToken,
       _client = client ?? createMaasoBackendClient(),
       _ownsClient = client == null;

  final Uri Function() _baseUri;
  final String Function() _accountId;
  final Future<String> Function() _accessToken;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;
  final _reviewChanges = StreamController<void>.broadcast(sync: true);

  @override
  bool get reviewActive => !_closed && _accountId().trim().isNotEmpty;
  @override
  Stream<void> get reviewChanges => _reviewChanges.stream;

  @override
  Future<List<ContentReview>> reviews() async {
    final data = await _request(
      'v1/moderation/reviews',
      query: {'limit': '50'},
    );
    final rows = data['items'];
    if (rows is! List || rows.length > 50) {
      throw const FormatException('invalid_review_page');
    }
    final items = rows.map((row) => ContentReview.fromJson(_map(row))).toList();
    if (items.map((row) => row.id).toSet().length != items.length) {
      throw const FormatException('duplicate_review');
    }
    return List.unmodifiable(items);
  }

  @override
  Future<void> appealReview(ContentReview review, String reason) async {
    final body = reason.trim();
    if (review.state != ContentReviewState.rejected ||
        body.isEmpty ||
        body.runes.length > 600) {
      throw const FormatException('invalid_appeal');
    }
    final id = reviewKey(review.id, 40);
    final result = await _request(
      'v1/moderation/reviews/$id/appeals',
      body: {'expectedVersion': review.version, 'reason': body},
    );
    reviewKey(result['id'], 40);
    if (result['reviewId'] != id ||
        result['reviewVersion'] != review.version ||
        result['state'] != 'pending' ||
        result['version'] != 1) {
      throw const FormatException('invalid_appeal_receipt');
    }
  }

  @override
  String get contextKey => '${_baseUri()}|${_accountId().trim()}';

  @override
  Future<CommentReportReceipt> reportComment(
    CommentReportTarget target,
    CommentReportReason reason,
  ) async {
    final validKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$');
    if (target.contentId.length > 48 ||
        target.commentId.length > 40 ||
        !validKey.hasMatch(target.contentId) ||
        !validKey.hasMatch(target.commentId)) {
      throw const FormatException('invalid_comment_report_target');
    }
    final result = await _request(
      'v1/public-engagement/comments/report',
      body: {
        'surface': target.surface.name,
        'targetId': target.contentId,
        'commentId': target.commentId,
        'reason': reason.name,
      },
    );
    final caseId = _text(result['caseId'], 48);
    final status = result['status'];
    if (!validKey.hasMatch(caseId) ||
        !const {
          'open',
          'in_review',
          'actioned',
          'dismissed',
        }.contains(status) ||
        result['duplicate'] is! bool) {
      throw const FormatException('invalid_comment_report_receipt');
    }
    return CommentReportReceipt(
      caseId: caseId,
      status: status as String,
      duplicate: result['duplicate'] as bool,
    );
  }

  @override
  Future<ContentConsumptionSession> start(
    ContentConsumptionTarget target,
    String requestId,
  ) async => _session(
    await _request(
      'v1/content-engagement/consumption/start',
      body: {
        'requestId': requestId,
        'kind': target.kind.name,
        'contentId': target.contentId,
      },
    ),
  );

  @override
  Future<ContentConsumptionSession> pulse(
    String sessionId,
    int sequence,
    String event,
    int progress,
  ) async => _session(
    await _request(
      'v1/content-engagement/consumption/pulse',
      body: {
        'sessionId': sessionId,
        'sequence': sequence,
        'event': event,
        'progress': progress,
      },
    ),
  );

  @override
  Future<ContentConsumptionSession> finish(
    String sessionId,
    int sequence,
  ) async => _session(
    await _request(
      'v1/content-engagement/consumption/finish',
      body: {'sessionId': sessionId, 'sequence': sequence},
    ),
  );

  void _check(String captured) {
    if (_closed || contextKey != captured || _accountId().trim().isEmpty) {
      throw const ContentEngagementException('CONTEXT_CHANGED');
    }
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    final captured = contextKey;
    _check(captured);
    final uri = _baseUri().resolve(path).replace(queryParameters: query);
    final token = await _accessToken();
    _check(captured);
    if (token.trim().isEmpty) {
      throw const ContentEngagementException('AUTHENTICATION_REQUIRED');
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
    };
    final response =
        await (body == null
                ? _client.get(uri, headers: headers)
                : _client.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 12));
    _check(captured);
    if (response.bodyBytes.length > 256 * 1024) {
      throw const FormatException('oversized_content_response');
    }
    final envelope = _map(jsonDecode(utf8.decode(response.bodyBytes)));
    if (response.statusCode != 200 || envelope['code'] != 'OK') {
      throw ContentEngagementException(
        envelope['code'] is String ? envelope['code'] as String : 'UNAVAILABLE',
      );
    }
    return _map(envelope['data']);
  }

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    _reviewChanges.add(null);
    unawaited(_reviewChanges.close());
    if (_ownsClient) _client.close();
    super.onClose();
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_content_response');
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String || value.trim().isEmpty || value.runes.length > max) {
    throw const FormatException('invalid_content_text');
  }
  return value;
}

ContentConsumptionSession _session(Map<String, dynamic> data) {
  final sequence = data['sequence'];
  final activeMillis = data['activeMillis'];
  final state = data['state'];
  if (sequence is! int ||
      sequence < 0 ||
      sequence > 3600 ||
      activeMillis is! int ||
      activeMillis < 0 ||
      activeMillis > 1800000 ||
      !{'active', 'superseded', 'insufficient', 'recorded'}.contains(state)) {
    throw const FormatException('invalid_consumption_session');
  }
  return ContentConsumptionSession(
    sessionId: _text(data['sessionId'], 36),
    sequence: sequence,
    state: state as String,
    activeMillis: activeMillis,
    expiresAt: DateTime.parse(_text(data['expiresAt'], 64)),
  );
}
