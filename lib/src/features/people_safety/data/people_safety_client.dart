import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';

import '../domain/ai_output_report.dart';
import '../domain/people_block.dart';

/// Owned by one account mount. Creating the client performs no network work.
class PeopleSafetyClient extends AppService
    implements AIOutputReportGateway, PeopleBlockGateway {
  PeopleSafetyClient({
    required Uri Function() baseUri,
    required String Function() accountId,
    required Future<String> Function() accessToken,
    http.Client? client,
  }) : _baseUri = baseUri,
       _accountId = accountId,
       _accessToken = accessToken,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri Function() _baseUri;
  final String Function() _accountId;
  final Future<String> Function() _accessToken;
  final http.Client _client;
  final bool _ownsClient;
  final _changes = StreamController<void>.broadcast(sync: true);
  bool _closed = false;

  @override
  bool get active => !_closed && _accountId().trim().isNotEmpty;
  @override
  String get contextKey => '${_baseUri()}|${_accountId().trim()}';
  @override
  Stream<void> get changes => _changes.stream;

  void _check(String key) {
    if (!active || contextKey != key) {
      throw StateError('people_safety_account_changed');
    }
  }

  @override
  Future<AIOutputReportReceipt> submitAIReport({
    required String requestId,
    required String text,
    required String reason,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(requestId) ||
        text.trim().isEmpty ||
        text.runes.length > 16000 ||
        !{'unsafe', 'harassment', 'other'}.contains(reason)) {
      throw const FormatException('invalid_ai_report_input');
    }
    final key = contextKey;
    _check(key);
    final uri = _baseUri().resolve('v1/moderation/ai-output-reports');
    final token = await _accessToken();
    _check(key);
    if (token.trim().isEmpty) throw StateError('people_safety_auth_required');
    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'requestId': requestId,
            'text': text,
            'reason': reason,
          }),
        )
        .timeout(const Duration(seconds: 20));
    _check(key);
    if (response.bodyBytes.length > 65536) {
      throw const FormatException('invalid_ai_report_response');
    }
    if (response.statusCode != 200) {
      throw StateError('ai_report_http_${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['code'] != 'OK') {
      throw const FormatException('invalid_ai_report_response');
    }
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('invalid_ai_report_response');
    }
    return AIOutputReportReceipt.fromJson(data);
  }

  Future<Map<String, dynamic>> _blockRequest(
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? input,
  }) async {
    final key = contextKey;
    _check(key);
    final uri = _baseUri().resolve(path).replace(queryParameters: query);
    final token = await _accessToken();
    _check(key);
    if (token.trim().isEmpty) throw StateError('people_safety_auth_required');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final response =
        await (input == null
                ? _client.get(uri, headers: headers)
                : _client.post(uri, headers: headers, body: jsonEncode(input)))
            .timeout(const Duration(seconds: 20));
    _check(key);
    if (response.bodyBytes.length > 262144) {
      throw const FormatException('invalid_people_response');
    }
    if (response.statusCode != 200) {
      throw StateError('people_http_${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> ||
        body['code'] != 'OK' ||
        body['data'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_people_response');
    }
    return body['data'] as Map<String, dynamic>;
  }

  @override
  Future<List<PeopleBlock>> listBlocks() async {
    final data = await _blockRequest('v1/people/blocks');
    final rows = data['items'];
    if (rows is! List || rows.length > 500) {
      throw const FormatException('invalid_people_response');
    }
    return List.unmodifiable(
      rows.map((row) {
        if (row is! Map<String, dynamic>) {
          throw const FormatException('invalid_people_response');
        }
        return PeopleBlock.fromJson(row);
      }),
    );
  }

  @override
  Future<PeopleBlock> blockState(PeopleActor actor) async {
    if (!PeopleActor.validId(actor.id) ||
        !{'user', 'agent'}.contains(actor.kind)) {
      throw const FormatException('invalid_people_actor');
    }
    final row = PeopleBlock.fromJson(
      await _blockRequest(
        'v1/people/block-state',
        query: {'actorId': actor.id, 'actorKind': actor.kind},
      ),
    );
    if (row.actor.key != actor.key) {
      throw const FormatException('invalid_people_target');
    }
    return row;
  }

  @override
  Future<PeopleBlock> setBlock(PeopleBlockDraft draft) async {
    final actor = draft.before.actor;
    if (!PeopleActor.validId(actor.id) ||
        !{'user', 'agent'}.contains(actor.kind)) {
      throw const FormatException('invalid_people_actor');
    }
    final row = PeopleBlock.fromJson(
      await _blockRequest(
        'v1/people/blocks',
        input: {
          'requestId': draft.requestId,
          'actorId': actor.id,
          'actorKind': actor.kind,
          'blocked': draft.blocked,
          'expectedVersion': draft.before.version,
        },
      ),
    );
    if (row.actor.key != actor.key ||
        row.blocked != draft.blocked ||
        row.version != draft.before.version + 1) {
      throw const FormatException('invalid_people_target');
    }
    _changes.add(null);
    return row;
  }

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    _changes.add(null);
    unawaited(_changes.close());
    if (_ownsClient) _client.close();
    super.onClose();
  }
}
