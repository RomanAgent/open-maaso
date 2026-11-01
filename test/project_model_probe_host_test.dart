import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import '../tool/project_harness/model_probe_host.dart';

String request(int id, [String text = 'Synthetic project requirements']) =>
    base64Encode(
      utf8.encode(
        jsonEncode({
          'invocationId': 'eval_${id.toRadixString(16).padLeft(32, '0')}',
          'messages': [
            {'role': 'user', 'content': text},
          ],
        }),
      ),
    );

void main() {
  test('exact invocation replay never makes another paid request', () async {
    var calls = 0;
    final result = Completer<String>();
    final host = ProjectModelProbeHost(
      admission: () => ProjectProbeAdmission(
        ready: true,
        isCurrent: () => true,
        generate: (_) {
          calls++;
          return result.future;
        },
      ),
    );
    final first = host.run(request(1));
    final replay = host.run(request(1));
    expect(
      (await host.run(request(1, 'changed')))['status'],
      'invocation_conflict',
    );
    expect((await host.run(request(2)))['status'], 'busy');
    result.complete('{"tool":"project.plan","arguments":{"steps":["build"]}}');
    expect(await first, await replay);
    expect((await host.run(request(1)))['status'], 'completed');
    expect(calls, 1);
    expect(
      host.readReceipt('eval_${'1'.padLeft(32, '0')}')['status'],
      'completed',
    );
  });

  test('unknown outcomes are retained and cannot redispatch', () async {
    var calls = 0;
    final host = ProjectModelProbeHost(
      admission: () => ProjectProbeAdmission(
        ready: true,
        isCurrent: () => true,
        generate: (_) async {
          calls++;
          throw StateError('PRIVATE_EXCEPTION');
        },
      ),
    );
    final result = await host.run(request(1));
    expect(result['status'], 'outcome_unknown');
    expect(result['usage'], isNull);
    expect(result['cost'], isNull);
    expect(jsonEncode(result), isNot(contains('PRIVATE_EXCEPTION')));
    expect(await host.run(request(1)), result);
    expect(calls, 1);
  });

  test('pilot stops at twelve calls including unknown outcomes', () async {
    var calls = 0;
    final host = ProjectModelProbeHost(
      admission: () => ProjectProbeAdmission(
        ready: true,
        isCurrent: () => true,
        generate: (_) async {
          calls++;
          return null;
        },
      ),
    );
    for (var i = 0; i < 12; i++) {
      await host.run(request(i));
    }
    expect((await host.run(request(12)))['status'], 'pilot_limit');
    expect(calls, 12);
    expect(host.readReadiness()['ready'], false);
  });

  test(
    'scope change discards response and readiness never calls provider',
    () async {
      var current = true;
      var calls = 0;
      final result = Completer<String>();
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: current,
          isCurrent: () => current,
          generate: (_) {
            calls++;
            return result.future;
          },
        ),
      );
      expect(host.readReadiness()['ready'], true);
      expect(calls, 0);
      final pending = host.run(request(1));
      current = false;
      result.complete('OLD_ACCOUNT_MODEL_SOURCE');
      final receipt = await pending;
      expect(receipt['status'], 'outcome_unknown');
      expect(receipt.containsKey('response'), false);
      expect((await host.run(request(2)))['status'], 'not_ready');
      expect(calls, 1);
    },
  );

  test('strict input validation precedes model admission', () async {
    var calls = 0;
    final host = ProjectModelProbeHost(
      admission: () => ProjectProbeAdmission(
        ready: true,
        isCurrent: () => true,
        generate: (_) async {
          calls++;
          return '{}';
        },
      ),
    );
    for (final raw in [
      'bad',
      base64Encode(
        utf8.encode('{"invocationId":"x","invocationId":"y","messages":[]}'),
      ),
      request(1, 'x' * 140000),
    ]) {
      expect((await host.run(raw))['status'], 'invalid_request');
    }
    expect(calls, 0);
  });
}
