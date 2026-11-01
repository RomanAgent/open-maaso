import 'persona_package_manifest.dart';

/// Importable package shape. Runtime account and generation are omitted and
/// must be rebound by the host at import time. Declarative content containing
/// the active account id is rejected rather than silently mutated.
abstract final class PersonaPackagePortableExporter {
  static Map<String, Object?> export(PersonaPackageManifest manifest) {
    final portable = manifest.toPortableJson();
    if (_containsAccountTaint(portable, manifest.scope.accountId)) {
      throw StateError('portable_export_contains_account_taint');
    }
    return portable;
  }
}

/// Non-importable support/diagnostic shape. Every string is recursively
/// account-taint scrubbed and credential-like values are replaced.
abstract final class PersonaPackageDiagnosticExporter {
  static Map<String, Object?> export(PersonaPackageManifest manifest) =>
      <String, Object?>{
        'exportKind': 'persona.diagnostic.redacted.v1',
        'scope': <String, Object?>{'account': 'redacted'},
        'manifest': _redact(
          manifest.toPortableJson(),
          accountId: manifest.scope.accountId,
        ),
      };
}

/// Compatibility name retained for callers that explicitly requested a
/// redacted diagnostic. This output is deliberately not package-importable.
abstract final class PersonaPackageRedactedExporter {
  static Map<String, Object?> export(PersonaPackageManifest manifest) =>
      PersonaPackageDiagnosticExporter.export(manifest);
}

bool _containsAccountTaint(Object? value, String accountId) {
  if (value is String) {
    return value.toLowerCase().contains(accountId.toLowerCase());
  }
  if (value is List) {
    return value.any((item) => _containsAccountTaint(item, accountId));
  }
  if (value is Map) {
    return value.entries.any(
      (entry) =>
          _containsAccountTaint(entry.key, accountId) ||
          _containsAccountTaint(entry.value, accountId),
    );
  }
  return false;
}

Object? _redact(Object? value, {required String accountId}) {
  if (value is String) {
    final accountPattern = RegExp(
      RegExp.escape(accountId),
      caseSensitive: false,
    );
    final withoutAccount = value.replaceAll(accountPattern, '[redacted]');
    final credentialPattern = RegExp(
      r'(token|cookie|credential|raw[_-]?memory|password|api[_-]?key|'
      r'authorization|bearer|private[_-]?key)',
      caseSensitive: false,
    );
    return credentialPattern.hasMatch(withoutAccount)
        ? '[redacted]'
        : withoutAccount;
  }
  if (value is List) {
    return value
        .map((item) => _redact(item, accountId: accountId))
        .toList(growable: false);
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key =
          _redact(entry.key.toString(), accountId: accountId)! as String;
      result[key] = _redact(entry.value, accountId: accountId);
    }
    return result;
  }
  return value;
}
