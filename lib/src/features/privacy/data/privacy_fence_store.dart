import 'dart:convert';

import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

import '../domain/privacy_models.dart';

/// A remembered restriction, not a consent record. Pending human withdrawals
/// survive uncertain network results until a later explicit grant succeeds.
final class PrivacyFenceDenial {
  PrivacyFenceDenial({
    this.observedRevision,
    this.pendingRevision,
    Set<String> origins = const {},
  }) : origins = Set.unmodifiable(origins);

  final int? observedRevision;
  final int? pendingRevision;
  final Set<String> origins;
}

/// No birth date, grant, policy body, account ID or credential is stored here.
final class PrivacyFenceState {
  PrivacyFenceState({
    this.minimumRevision = 0,
    this.ageIneligibleRevision,
    Map<String, PrivacyFenceDenial> denials = const {},
  }) : denials = Map.unmodifiable(denials);

  final int minimumRevision;
  final int? ageIneligibleRevision;
  final Map<String, PrivacyFenceDenial> denials;
}

abstract interface class PrivacyFenceStore {
  String get scopeKey;
  Future<PrivacyFenceState?> read();
  Future<void> write(PrivacyFenceState state);
}

/// Holds the captured mounted account database. Already-admitted writes may
/// finish during retirement; the service drains them before that DB is closed.
/// It never resolves a new account's database through a global service locator.
final class SembastPrivacyFenceStore implements PrivacyFenceStore {
  SembastPrivacyFenceStore({
    required Database database,
    required AccountStorageScope scope,
  }) : _database = database,
       scopeKey = scope.storageNamespace;

  final Database _database;
  @override
  final String scopeKey;
  static final _store = stringMapStoreFactory.store('privacy_local_fences.v1');
  static const _maximumRevision = 9007199254740991;
  static const _maximumBytes = 256 * 1024;

  @override
  Future<PrivacyFenceState?> read() async {
    final raw = await _store.record(scopeKey).get(_database);
    return raw == null ? null : _decode(raw);
  }

  @override
  Future<void> write(PrivacyFenceState state) async {
    final encoded = _encode(state);
    // Validate the entire immutable value before opening a write transaction.
    final checked = _decode(encoded);
    await _database.transaction((tx) async {
      final record = _store.record(scopeKey);
      final previous = await record.get(tx);
      if (previous != null &&
          _decode(previous).minimumRevision > checked.minimumRevision) {
        throw StateError('privacy_fence_revision_conflict');
      }
      await record.put(tx, encoded);
    });
  }

  Map<String, Object?> _encode(PrivacyFenceState state) => {
    'schemaVersion': 1,
    'scopeKey': scopeKey,
    'minimumRevision': state.minimumRevision,
    'ageIneligibleRevision': state.ageIneligibleRevision,
    'denials': [
      for (final key in state.denials.keys.toList()..sort())
        {
          'key': key,
          'observedRevision': state.denials[key]!.observedRevision,
          'pendingRevision': state.denials[key]!.pendingRevision,
          'origins': state.denials[key]!.origins.toList()..sort(),
        },
    ],
  };

  PrivacyFenceState _decode(Map<String, Object?> raw) {
    Never invalid() => throw StateError('privacy_fence_corrupt');
    bool exact(Map<String, Object?> map, Set<String> keys) =>
        map.length == keys.length && map.keys.every(keys.contains);
    int revision(Object? value) {
      if (value is! int || value < 0 || value > _maximumRevision) invalid();
      return value;
    }

    if (!exact(raw, {
          'schemaVersion',
          'scopeKey',
          'minimumRevision',
          'ageIneligibleRevision',
          'denials',
        }) ||
        raw['schemaVersion'] != 1 ||
        raw['scopeKey'] != scopeKey ||
        utf8.encode(jsonEncode(raw)).length > _maximumBytes) {
      invalid();
    }
    final minimum = revision(raw['minimumRevision']);
    final age = raw['ageIneligibleRevision'] == null
        ? null
        : revision(raw['ageIneligibleRevision']);
    if (age != null && age > minimum) invalid();
    final rows = raw['denials'];
    if (rows is! List || rows.length > 128) invalid();
    final denials = <String, PrivacyFenceDenial>{};
    for (final value in rows) {
      if (value is! Map || value.keys.any((key) => key is! String)) invalid();
      final row = Map<String, Object?>.from(value);
      if (!exact(row, {
        'key',
        'observedRevision',
        'pendingRevision',
        'origins',
      })) {
        invalid();
      }
      final key = row['key'];
      if (key is! String || denials.containsKey(key)) invalid();
      final parts = key.split('|');
      if (parts.length != 2 ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(parts[0]) ||
          !PrivacyScopes.all.contains(parts[1])) {
        invalid();
      }
      final observed = row['observedRevision'] == null
          ? null
          : revision(row['observedRevision']);
      final pending = row['pendingRevision'] == null
          ? null
          : revision(row['pendingRevision']);
      if ((observed == null && pending == null) ||
          (observed != null && observed > minimum) ||
          (pending != null && pending > minimum)) {
        invalid();
      }
      final values = row['origins'];
      if (values is! List || values.length > 64) invalid();
      final origins = <String>{};
      for (final value in values) {
        if (value is! String || value.length > 512) invalid();
        final uri = Uri.tryParse(value);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.path.isNotEmpty ||
            uri.origin != value ||
            !origins.add(value)) {
          invalid();
        }
      }
      denials[key] = PrivacyFenceDenial(
        observedRevision: observed,
        pendingRevision: pending,
        origins: origins,
      );
    }
    return PrivacyFenceState(
      minimumRevision: minimum,
      ageIneligibleRevision: age,
      denials: denials,
    );
  }
}
