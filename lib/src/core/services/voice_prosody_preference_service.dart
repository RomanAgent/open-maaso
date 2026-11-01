import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

const int maxVoiceProsodyPreferenceRevision = 0x1fffffffffffff;

final class VoiceProsodyPreferenceSnapshot {
  const VoiceProsodyPreferenceSnapshot({
    required this.accountScopeDigest,
    required this.revision,
    required this.enabled,
  });

  static const int schemaVersion = 1;

  final String accountScopeDigest;
  final int revision;
  final bool enabled;

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'accountScopeDigest': accountScopeDigest,
    'revision': revision,
    'enabled': enabled,
  };

  factory VoiceProsodyPreferenceSnapshot.fromStorageJson(Object? source) {
    if (source is! Map) {
      throw const FormatException('voice prosody preference is invalid');
    }
    final json = Map<String, Object?>.from(source);
    const fields = <String>{
      'schemaVersion',
      'accountScopeDigest',
      'revision',
      'enabled',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion) {
      throw const FormatException('voice prosody preference schema is invalid');
    }
    final digest = json['accountScopeDigest'];
    final revision = json['revision'];
    final enabled = json['enabled'];
    if (digest is! String ||
        digest.trim().isEmpty ||
        digest.length > 128 ||
        revision is! int ||
        revision < 1 ||
        revision > maxVoiceProsodyPreferenceRevision ||
        enabled is! bool) {
      throw const FormatException(
        'voice prosody preference values are invalid',
      );
    }
    return VoiceProsodyPreferenceSnapshot(
      accountScopeDigest: digest.trim(),
      revision: revision,
      enabled: enabled,
    );
  }
}

abstract interface class VoiceProsodyPreferenceStore {
  Future<Map<String, Object?>?> read();

  Future<void> write(VoiceProsodyPreferenceSnapshot snapshot);
}

final class SembastVoiceProsodyPreferenceStore
    implements VoiceProsodyPreferenceStore {
  SembastVoiceProsodyPreferenceStore(this.database);

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('voice_prosody_preferences.v1');
  static const String _recordKey = 'self';

  final DBService database;

  @override
  Future<Map<String, Object?>?> read() async {
    final row = await _store.record(_recordKey).get(database.raw);
    return row == null ? null : Map<String, Object?>.from(row);
  }

  @override
  Future<void> write(VoiceProsodyPreferenceSnapshot snapshot) =>
      _store.record(_recordKey).put(database.raw, snapshot.toStorageJson());
}

enum _VoiceProsodyPreferenceLifecycle {
  created,
  initializing,
  active,
  degraded,
  retired,
}

/// Account-owned explicit consent for the desktop-only prosody shadow path.
///
/// The persisted choice is retained when the same account visits an
/// unsupported host, but [effectiveEnabled] always remains false there. This
/// lets mobile and web avoid constructing any local analyzer while preserving
/// the user's desktop choice.
final class VoiceProsodyPreferenceService extends AppService {
  VoiceProsodyPreferenceService({
    required VoiceProsodyPreferenceStore store,
    required AppPlatformCapabilities platformCapabilities,
    required String accountScopeDigest,
    required this.generation,
  }) : _store = store,
       _platformCapabilities = platformCapabilities,
       accountScopeDigest = _validatedScopeDigest(accountScopeDigest);

  final VoiceProsodyPreferenceStore _store;
  final AppPlatformCapabilities _platformCapabilities;
  final String accountScopeDigest;
  final int generation;
  final enabled = false.obs;

  Future<void> _mutationTail = Future<void>.value();
  _VoiceProsodyPreferenceLifecycle _lifecycle =
      _VoiceProsodyPreferenceLifecycle.created;
  int _revision = 0;

  bool get effectiveEnabled =>
      _lifecycle == _VoiceProsodyPreferenceLifecycle.active &&
      !isClosed &&
      _platformCapabilities.supportsOnDeviceSpeechModels &&
      enabled.value;

  Future<VoiceProsodyPreferenceService> init() async {
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
    if (isClosed || _lifecycle != _VoiceProsodyPreferenceLifecycle.created) {
      throw StateError('voice_prosody_preference_already_initialized');
    }
    _lifecycle = _VoiceProsodyPreferenceLifecycle.initializing;
    try {
      final row = await _store.read();
      if (_lifecycle != _VoiceProsodyPreferenceLifecycle.initializing ||
          isClosed) {
        return this;
      }
      if (row != null) {
        final restored = VoiceProsodyPreferenceSnapshot.fromStorageJson(row);
        if (restored.accountScopeDigest != accountScopeDigest) {
          throw const FormatException('voice prosody account scope mismatch');
        }
        _revision = restored.revision;
        enabled.value = restored.enabled;
      }
      _lifecycle = _VoiceProsodyPreferenceLifecycle.active;
    } on Object {
      if (_lifecycle == _VoiceProsodyPreferenceLifecycle.initializing) {
        _lifecycle = _VoiceProsodyPreferenceLifecycle.degraded;
        _revision = 0;
        enabled.value = false;
      }
    }
    return this;
  }

  Future<void> setEnabled(bool value) {
    if (_lifecycle != _VoiceProsodyPreferenceLifecycle.active || isClosed) {
      return Future<void>.error(
        StateError('voice_prosody_preference_unavailable'),
      );
    }
    if (value && !_platformCapabilities.supportsOnDeviceSpeechModels) {
      return Future<void>.error(UnsupportedError('voice_prosody_desktop_only'));
    }
    final previous = _mutationTail;
    late final Future<void> mutation;
    mutation = previous.then<void>(
      (_) => _writeAndPublish(value),
      onError: (Object _, StackTrace _) => _writeAndPublish(value),
    );
    _mutationTail = mutation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return mutation;
  }

  Future<void> _writeAndPublish(bool value) async {
    if (_lifecycle != _VoiceProsodyPreferenceLifecycle.active || isClosed) {
      throw StateError('voice_prosody_preference_retired');
    }
    final nextRevision = _revision + 1;
    if (nextRevision > maxVoiceProsodyPreferenceRevision) {
      throw StateError('voice_prosody_preference_revision_exhausted');
    }
    final snapshot = VoiceProsodyPreferenceSnapshot(
      accountScopeDigest: accountScopeDigest,
      revision: nextRevision,
      enabled: value,
    );
    await _store.write(snapshot);
    if (_lifecycle != _VoiceProsodyPreferenceLifecycle.active || isClosed) {
      return;
    }
    _revision = nextRevision;
    enabled.value = value;
  }

  Future<void> deactivateAndDrain() {
    _lifecycle = _VoiceProsodyPreferenceLifecycle.retired;
    enabled.value = false;
    return _mutationTail;
  }

  @override
  void onClose() {
    _lifecycle = _VoiceProsodyPreferenceLifecycle.retired;
    enabled.value = false;
    super.onClose();
  }

  static String _validatedScopeDigest(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw ArgumentError.value(value, 'accountScopeDigest', 'is invalid');
    }
    return normalized;
  }
}
