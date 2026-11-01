import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'auth_logout_pending_store.dart';

const int authLogoutPendingRecordSchema = 1;

final class AuthLogoutPendingRecord {
  const AuthLogoutPendingRecord({
    required this.environmentKey,
    required this.revision,
    required this.pending,
    required this.token,
    this.ownerFingerprint,
  });

  final String environmentKey;
  final int revision;
  final bool pending;
  final String token;
  final String? ownerFingerprint;

  String encode() {
    final state = pending ? 'pending' : 'cleared';
    final body = <String, Object>{
      'environment': environmentKey,
      'revision': revision,
      'schema': authLogoutPendingRecordSchema,
      'state': state,
      'token': token,
      'owner': ?ownerFingerprint,
    };
    final canonical = jsonEncode(body);
    return jsonEncode(<String, Object>{
      ...body,
      'checksum': sha256.convert(utf8.encode(canonical)).toString(),
    });
  }

  AuthLogoutPendingSnapshot get snapshot => AuthLogoutPendingSnapshot(
    pending: pending,
    revision: revision,
    token: token,
    ownerFingerprint: ownerFingerprint,
  );

  static AuthLogoutPendingRecord? tryParse(
    String? encoded, {
    required String environmentKey,
  }) {
    if (encoded == null || encoded.length > 4096) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return null;
      final schema = decoded['schema'];
      final environment = decoded['environment'];
      final revision = decoded['revision'];
      final state = decoded['state'];
      final token = decoded['token'];
      final owner = decoded['owner'];
      final checksum = decoded['checksum'];
      if (schema != authLogoutPendingRecordSchema ||
          environment != environmentKey ||
          revision is! int ||
          revision < 1 ||
          (state != 'pending' && state != 'cleared') ||
          token is! String ||
          token.isEmpty ||
          (owner != null &&
              (owner is! String ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(owner))) ||
          checksum is! String) {
        return null;
      }
      final body = <String, Object>{
        'environment': environment,
        'revision': revision,
        'schema': schema,
        'state': state,
        'token': token,
        if (owner != null) 'owner': owner as String,
      };
      final expected = sha256.convert(utf8.encode(jsonEncode(body))).toString();
      if (checksum != expected) return null;
      return AuthLogoutPendingRecord(
        environmentKey: environmentKey,
        revision: revision,
        pending: state == 'pending',
        token: token,
        ownerFingerprint: owner as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

AuthLogoutPendingSnapshot authLogoutPendingSnapshotFromSingleRecord({
  required String environmentKey,
  required String? encoded,
}) {
  final record = AuthLogoutPendingRecord.tryParse(
    encoded,
    environmentKey: environmentKey,
  );
  if (record != null) return record.snapshot;
  return _invalidSnapshot(
    environmentKey: environmentKey,
    encodedSlots: <String?>[encoded],
    records: <AuthLogoutPendingRecord?>[record],
  );
}

AuthLogoutPendingSnapshot authLogoutPendingSnapshotFromRedundantSlots({
  required String environmentKey,
  required List<String?> encodedSlots,
}) {
  if (encodedSlots.length != 2) {
    throw ArgumentError.value(
      encodedSlots.length,
      'encodedSlots',
      'native logout fencing requires exactly two copies',
    );
  }
  final records = encodedSlots
      .map(
        (encoded) => AuthLogoutPendingRecord.tryParse(
          encoded,
          environmentKey: environmentKey,
        ),
      )
      .toList(growable: false);
  final first = records[0];
  final second = records[1];
  if (first != null &&
      second != null &&
      first.revision == second.revision &&
      first.pending == second.pending &&
      first.token == second.token &&
      first.ownerFingerprint == second.ownerFingerprint) {
    return first.snapshot;
  }

  return _invalidSnapshot(
    environmentKey: environmentKey,
    encodedSlots: encodedSlots,
    records: records,
  );
}

AuthLogoutPendingSnapshot _invalidSnapshot({
  required String environmentKey,
  required List<String?> encodedSlots,
  required List<AuthLogoutPendingRecord?> records,
}) {
  var highestRevision = 0;
  for (final record in records) {
    if (record != null && record.revision > highestRevision) {
      highestRevision = record.revision;
    }
  }
  final highestPendingOwners = records
      .whereType<AuthLogoutPendingRecord>()
      .where(
        (record) =>
            record.pending &&
            record.revision == highestRevision &&
            record.ownerFingerprint != null,
      )
      .map((record) => record.ownerFingerprint!)
      .toSet();
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode(<Object?>[
            authLogoutPendingRecordSchema,
            environmentKey,
            ...encodedSlots.map((value) => value ?? '<missing>'),
          ]),
        ),
      )
      .toString();
  return AuthLogoutPendingSnapshot(
    pending: true,
    revision: highestRevision,
    token: 'invalid:$fingerprint',
    ownerFingerprint: highestPendingOwners.length == 1
        ? highestPendingOwners.single
        : null,
  );
}

String newAuthLogoutPendingToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
