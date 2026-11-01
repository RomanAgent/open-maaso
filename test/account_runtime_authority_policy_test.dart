import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';

void main() {
  Map<String, Object?> validPolicy() => <String, Object?>{
    'mode': 'shadow',
    'revision': 17,
    'expiresAt': '2026-08-21T12:05:00.123456Z',
    'remainingTtlMs': 300000,
    'pollAfterMs': 15000,
  };

  test('parses the exact runtime authority policy contract', () {
    final policy = AccountRuntimeAuthorityPolicy.fromJson(validPolicy());

    expect(policy.mode, AccountRuntimeAuthorityMode.shadow);
    expect(policy.revision, 17);
    expect(policy.expiresAt, DateTime.utc(2026, 8, 21, 12, 5, 0, 123, 456));
    expect(policy.remainingTtl, const Duration(minutes: 5));
    expect(policy.pollAfter, const Duration(seconds: 15));
    expect(
      AccountRuntimeAuthorityMode.enforce.cappedBy(
        AccountRuntimeAuthorityMode.shadow,
      ),
      AccountRuntimeAuthorityMode.shadow,
    );
  });

  test('rejects unknown, missing, and invalid exact policy fields', () {
    final invalid = <Object?>[
      <String, Object?>{...validPolicy(), 'unknown': true},
      <String, Object?>{...validPolicy()}..remove('revision'),
      <String, Object?>{...validPolicy(), 'mode': 'ENFORCE'},
      <String, Object?>{...validPolicy(), 'revision': 0},
      <String, Object?>{
        ...validPolicy(),
        'revision': maxAccountRuntimeAuthorityPolicyRevision + 1,
      },
      <String, Object?>{...validPolicy(), 'pollAfterMs': 0},
      <String, Object?>{...validPolicy(), 'remainingTtlMs': 0},
      <String, Object?>{
        ...validPolicy(),
        'remainingTtlMs':
            AccountRuntimeAuthorityPolicy.maximumRemainingTtl.inMilliseconds +
            1,
      },
      <String, Object?>{
        ...validPolicy(),
        'remainingTtlMs': 1000,
        'pollAfterMs': 1001,
      },
      <String, Object?>{
        ...validPolicy(),
        'pollAfterMs':
            AccountRuntimeAuthorityPolicy.maximumPollAfter.inMilliseconds + 1,
      },
      <String, Object?>{
        ...validPolicy(),
        'expiresAt': '2026-08-21T20:05:00+08:00',
      },
      <String, Object?>{...validPolicy(), 'expiresAt': '2026-02-30T12:05:00Z'},
    ];

    for (final source in invalid) {
      expect(
        () => AccountRuntimeAuthorityPolicy.fromJson(source),
        throwsFormatException,
        reason: '$source',
      );
    }
  });

  test('compile maximum parser fails closed on unsupported values', () {
    expect(
      AccountRuntimeAuthorityMode.parseCompileMaximum('off'),
      AccountRuntimeAuthorityMode.off,
    );
    expect(
      () => AccountRuntimeAuthorityMode.parseCompileMaximum('legacy'),
      throwsFormatException,
    );
    expect(
      () => AccountRuntimeAuthorityMode.parseCompileMaximum(''),
      throwsFormatException,
    );
  });

  test('same revision permits rolling expiry but not stable-field drift', () {
    final first = AccountRuntimeAuthorityPolicy.fromJson(validPolicy());
    final rolled = AccountRuntimeAuthorityPolicy.fromJson(<String, Object?>{
      ...validPolicy(),
      'expiresAt': '2026-08-21T12:06:00Z',
    });
    final changedMode = AccountRuntimeAuthorityPolicy.fromJson(
      <String, Object?>{...validPolicy(), 'mode': 'enforce'},
    );

    expect(first.hasSameRevisionContents(rolled), isTrue);
    expect(first.hasSameRevisionContents(changedMode), isFalse);
  });
}
