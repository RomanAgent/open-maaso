import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

final class _Transport extends http.BaseClient {
  int sends = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    final reply = jsonEncode({'actionToken': null, 'comment': '一起玩。'});
    final sse =
        'event: reply.delta\ndata: ${jsonEncode({'delta': reply})}\n\n'
        'event: done\ndata: [DONE]\n\n';
    return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
  }
}

void main() {
  test('token refresh wait is fenced before actual HTTP send', () async {
    final token = Completer<String?>(), entered = Completer<void>();
    final transport = _Transport();
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://synthetic.example'),
      model: 'synthetic',
      httpClient: transport,
      accessTokenProvider: () {
        entered.complete();
        return token.future;
      },
    );
    var current = true, admissions = 0;
    final future = chatWithPrivacyAdmission(
      client,
      [Message.user('synthetic')],
      onAdmitted: () {
        if (!current) throw StateError('game_grant_revoked');
        admissions++;
      },
    );
    final rejected = expectLater(future, throwsStateError);
    await entered.future;
    expect(admissions, 0);
    current = false;
    token.complete('synthetic-access');
    await rejected;
    expect(transport.sends, 0);
    expect(admissions, 0);
  });

  test(
    'admitted companion response and ordinary SSE retain exact JSON',
    () async {
      final transport = _Transport();
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://synthetic.example'),
        model: 'synthetic',
        httpClient: transport,
        accessTokenProvider: () async => 'synthetic-access',
      );
      var admissions = 0;
      final expected = jsonEncode({'actionToken': null, 'comment': '一起玩。'});
      expect(
        await chatWithPrivacyAdmission(client, [
          Message.user('synthetic'),
        ], onAdmitted: () => admissions++),
        expected,
      );
      expect(admissions, 1);
      expect(transport.sends, 1);
      expect(await client.chat([Message.user('ordinary')]), expected);
      expect(admissions, 1);
      expect(transport.sends, 2);
    },
  );
}
