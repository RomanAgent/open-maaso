import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/tool_outcome.dart';

void main() {
  test('success serializes a stable typed result', () {
    final outcome = ToolOutcome.ok(
      data: const <String, Object?>{'value': 7},
      auditId: 'turn-1:call-2',
    );

    expect(jsonDecode(outcome.toJsonString()), <String, dynamic>{
      'status': 'ok',
      'code': 'ok',
      'data': <String, dynamic>{'value': 7},
      'retryable': false,
      'auditId': 'turn-1:call-2',
    });
  });

  test('legacy JSON errors become bounded machine codes', () {
    final stable = ToolOutcome.fromLegacyResult(
      jsonEncode(const <String, Object?>{'error': 'network_timeout'}),
    );
    final unsafe = ToolOutcome.fromLegacyResult(
      jsonEncode(const <String, Object?>{
        'error': 'Exception: secret details and stack trace',
      }),
    );

    expect(stable.status, ToolOutcomeStatus.failed);
    expect(stable.code, 'network_timeout');
    expect(unsafe.code, 'legacy_error');
  });

  test('legacy confirmation stays non-successful and explicit', () {
    final outcome = ToolOutcome.fromLegacyResult(
      jsonEncode(const <String, Object?>{
        'status': 'confirmation_required',
        'target': 'public-post',
      }),
    );

    expect(outcome.status, ToolOutcomeStatus.confirmationRequired);
    expect(outcome.isOk, isFalse);
    expect(outcome.code, 'confirmation_required');
    expect(
      jsonDecode(outcome.toJsonString())['status'],
      'confirmation_required',
    );
  });

  test('plain text is data rather than an error or executable payload', () {
    final outcome = ToolOutcome.fromLegacyResult('done');

    expect(outcome.isOk, isTrue);
    expect(outcome.data, <String, Object?>{'value': 'done'});
  });

  test('display is bounded and audit identifiers are validated', () {
    final outcome = ToolOutcome.ok(display: List.filled(300, 'x').join());
    expect(outcome.display, hasLength(240));

    expect(
      () => ToolOutcome.ok(auditId: 'contains spaces'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('model renderer fails closed for unsafe or oversized data', () {
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    final invalid = ToolOutcome.ok(data: cyclic).toJsonString();
    final oversized = ToolOutcomeModelRenderer(
      maxEncodedBytes: 128,
    ).render(ToolOutcome.ok(data: List<String>.filled(20, 'payload')));

    const expected = <String, Object?>{
      'status': 'failed',
      'code': 'invalid_tool_outcome',
      'retryable': false,
    };
    expect(jsonDecode(invalid), expected);
    expect(jsonDecode(oversized), expected);
  });
}
