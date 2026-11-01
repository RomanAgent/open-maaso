import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/voice_prosody_preference_service.dart';

void main() {
  test('desktop consent is durable before it becomes effective', () async {
    final store = _FakeStore()..holdWrites = true;
    final service = await _service(store: store).init();

    final write = service.setEnabled(true);
    await pumpEventQueue();

    expect(service.effectiveEnabled, isFalse);
    expect(store.writes, hasLength(1));
    store.releaseWrite();
    await write;

    expect(service.effectiveEnabled, isTrue);
    expect(store.writes.single.revision, 1);
  });

  test(
    'exact account row restores and a mismatched row fails closed',
    () async {
      final matching = _FakeStore(
        row: const VoiceProsodyPreferenceSnapshot(
          accountScopeDigest: 'scope-a',
          revision: 4,
          enabled: true,
        ).toStorageJson(),
      );
      final restored = await _service(store: matching).init();
      expect(restored.effectiveEnabled, isTrue);

      final mismatched = _FakeStore(
        row: const VoiceProsodyPreferenceSnapshot(
          accountScopeDigest: 'scope-b',
          revision: 4,
          enabled: true,
        ).toStorageJson(),
      );
      final rejected = await _service(store: mismatched).init();
      expect(rejected.effectiveEnabled, isFalse);
      expect(() => rejected.setEnabled(true), throwsA(isA<StateError>()));
    },
  );

  test(
    'unsupported hosts retain storage but can never enable locally',
    () async {
      for (final platform in <AppHostPlatform>[
        AppHostPlatform.android,
        AppHostPlatform.ios,
        AppHostPlatform.web,
        AppHostPlatform.fuchsia,
      ]) {
        final store = _FakeStore(
          row: const VoiceProsodyPreferenceSnapshot(
            accountScopeDigest: 'scope-a',
            revision: 2,
            enabled: true,
          ).toStorageJson(),
        );
        final service = await _service(store: store, platform: platform).init();

        expect(service.enabled.value, isTrue, reason: platform.name);
        expect(service.effectiveEnabled, isFalse, reason: platform.name);
        await expectLater(
          service.setEnabled(true),
          throwsA(isA<UnsupportedError>()),
        );
        expect(store.writes, isEmpty, reason: platform.name);
      }
    },
  );

  test('corrupt schema and retirement both fail closed', () async {
    final corrupt = await _service(
      store: _FakeStore(row: <String, Object?>{'enabled': true}),
    ).init();
    expect(corrupt.effectiveEnabled, isFalse);

    final store = _FakeStore()..holdWrites = true;
    final service = await _service(store: store).init();
    final write = service.setEnabled(true);
    await pumpEventQueue();
    final draining = service.deactivateAndDrain();
    expect(service.effectiveEnabled, isFalse);
    store.releaseWrite();
    await Future.wait<void>(<Future<void>>[write, draining]);
    expect(service.effectiveEnabled, isFalse);
    await expectLater(service.setEnabled(true), throwsA(isA<StateError>()));
  });

  test('snapshot parser rejects unknown fields and invalid revisions', () {
    expect(
      () => VoiceProsodyPreferenceSnapshot.fromStorageJson(<String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': 'scope-a',
        'revision': 1,
        'enabled': false,
        'secret': 'unexpected',
      }),
      throwsFormatException,
    );
    expect(
      () => VoiceProsodyPreferenceSnapshot.fromStorageJson(<String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': 'scope-a',
        'revision': 0,
        'enabled': false,
      }),
      throwsFormatException,
    );
  });
}

VoiceProsodyPreferenceService _service({
  required _FakeStore store,
  AppHostPlatform platform = AppHostPlatform.macos,
}) => VoiceProsodyPreferenceService(
  store: store,
  platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
  accountScopeDigest: 'scope-a',
  generation: 3,
);

final class _FakeStore implements VoiceProsodyPreferenceStore {
  _FakeStore({this.row});

  Map<String, Object?>? row;
  bool holdWrites = false;
  final List<VoiceProsodyPreferenceSnapshot> writes =
      <VoiceProsodyPreferenceSnapshot>[];
  Completer<void>? _pending;

  @override
  Future<Map<String, Object?>?> read() async => row;

  @override
  Future<void> write(VoiceProsodyPreferenceSnapshot snapshot) {
    writes.add(snapshot);
    if (!holdWrites) return Future<void>.value();
    final pending = Completer<void>();
    _pending = pending;
    return pending.future;
  }

  void releaseWrite() {
    final pending = _pending;
    _pending = null;
    pending?.complete();
  }
}
