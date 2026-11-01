import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'stale retired options cannot load or commit even when reinserted into a picker',
    () async {
      final retired = _mattOption();
      final harness = await _Harness.create(
        databasePath: 'retired-selection-rejected.db',
        catalog: [_bundledAvatar, retired],
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      expect(
        harness.config.catalog.any((option) => option.isRetiredOfficial),
        isFalse,
      );
      expect(harness.config.canSelectOption(retired), isFalse);
      harness.config.catalog.add(retired);
      await expectLater(
        harness.config.select(retired.id),
        throwsA(isA<AvatarAuthoritativeSelectionUnavailableException>()),
      );
      expect(harness.runtime.loadedAvatars, isEmpty);
      expect(harness.transport.directCommitRequests, isEmpty);
      expect(harness.config.selectedId.value, 'agent');
    },
  );

  test(
    'packaged Joy switches to an uploaded voice model and back through authoritative clear',
    () async {
      final joy = AvatarConfigService.builtInCatalog.single;
      final matt = _reviewedVoiceAvatar;
      final harness = await _Harness.create(
        databasePath: 'joy-matt-round-trip.db',
        catalog: [joy, matt],
        platform: AppHostPlatform.ios,
        assetOptions: const AvatarSelectionAssetOptions.none(
          builtinCatalogVersion: avatarBuiltinCatalogVersion,
        ),
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(matt.id);
      expect(
        harness.config.voicePreferences.cloudVoiceId,
        AvatarVoiceService.maleCloudVoice,
      );
      await harness.config.select(joy.id);
      expect(harness.transport.directCommitRequests.map((r) => r.modelId), [
        44,
        null,
      ]);
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.config.selectedId.value, 'agent');
      expect(harness.runtime.loadedAvatars.last, joy.modelUrl);
      expect(
        harness.config.voicePreferences.cloudVoiceId,
        AvatarVoiceService.femaleCloudVoice,
      );
      expect(harness.persistedValues, [matt.id, null]);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'failed Joy clear restores the uploaded model selection and voice',
    () async {
      final joy = AvatarConfigService.builtInCatalog.single;
      final matt = _reviewedVoiceAvatar;
      final harness = await _Harness.create(
        databasePath: 'joy-clear-failed.db',
        catalog: [joy, matt],
        platform: AppHostPlatform.ios,
        assetOptions: const AvatarSelectionAssetOptions.none(
          builtinCatalogVersion: avatarBuiltinCatalogVersion,
        ),
        commitHandler: (request, transport) async {
          if (request.modelId == null) {
            throw const AvatarSelectionValidationException(code: 'REJECTED');
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(matt.id);
      await expectLater(
        harness.config.select(joy.id),
        throwsA(isA<AvatarSelectionValidationException>()),
      );
      expect(harness.config.selectedId.value, matt.id);
      expect(harness.transport.currentSnapshot.selection.modelId, 44);
      expect(harness.runtime.loadedAvatars.last, matt.modelUrl);
      expect(
        harness.config.voicePreferences.cloudVoiceId,
        AvatarVoiceService.maleCloudVoice,
      );
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'uploaded model preview CAS voice and restart retain remote capabilities',
    () async {
      final matt = _reviewedVoiceAvatar;
      final harness = await _Harness.create(
        databasePath: 'matt-select.db',
        catalog: [_bundledAvatar, matt],
        platform: AppHostPlatform.ios,
        assetOptions: const AvatarSelectionAssetOptions.none(
          builtinCatalogVersion: 2,
        ),
      );
      harness.config.markAuthoritativeSelectionReady();
      expect(harness.config.remoteModelSelectionAvailable, isTrue);
      expect(harness.config.canSelectOption(matt), isTrue);
      await harness.config.select(matt.id);
      expect(harness.transport.directCommitRequests.single.modelId, 44);
      expect(
        harness
            .transport
            .directCommitRequests
            .single
            .assetOptions
            .builtinCatalogVersion,
        2,
      );
      expect(harness.runtime.loadedAvatars.last, _reviewedVoiceAvatar.modelUrl);
      expect(
        harness.config.voicePreferences.cloudVoiceId,
        AvatarVoiceService.maleCloudVoice,
      );
      expect(
        harness.config.voicePreferences.voiceSid.value,
        AvatarVoiceService.defaultMaleSid,
      );
      expect(await harness.outbox.read(), isNull);
      final committed = harness.transport.currentSnapshot;
      await harness.close();

      final reopened = await _Harness.create(
        databasePath: 'matt-reopen.db',
        initialCurrent: committed,
        catalog: [_bundledAvatar, matt],
        platform: AppHostPlatform.ios,
        assetOptions: const AvatarSelectionAssetOptions.none(
          builtinCatalogVersion: 2,
        ),
      );
      addTearDown(reopened.close);
      reopened.config.markAuthoritativeSelectionReady();
      await reopened.coordinator.ensureCurrent();
      expect(reopened.config.canReconcileAuthoritative(committed), isTrue);
      await reopened.config.reconcileAuthoritative(committed);
      expect(reopened.config.selected.remoteModelId, 44);
      expect(
        reopened.config.voicePreferences.cloudVoiceId,
        AvatarVoiceService.maleCloudVoice,
      );
      expect(
        reopened.runtime.loadedAvatars.last,
        _reviewedVoiceAvatar.modelUrl,
      );
      expect(reopened.transport.directCommitRequests, isEmpty);
      await reopened.config.voicePreferences.selectManualSid(2);
      await reopened.config.reconcileAuthoritative(committed);
      expect(reopened.config.voicePreferences.voiceSid.value, 2);
    },
  );

  test(
    'failed uploaded model CAS preserves previous selection and voice',
    () async {
      final matt = _reviewedVoiceAvatar;
      final harness = await _Harness.create(
        databasePath: 'matt-failed-cas.db',
        catalog: [_bundledAvatar, matt],
        platform: AppHostPlatform.ios,
        assetOptions: const AvatarSelectionAssetOptions.none(
          builtinCatalogVersion: 2,
        ),
        commitHandler: (request, transport) async =>
            throw const AvatarSelectionValidationException(code: 'REJECTED'),
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await expectLater(
        harness.config.select(matt.id),
        throwsA(isA<AvatarSelectionValidationException>()),
      );
      expect(harness.config.selected.id, _bundledAvatar.id);
      expect(
        harness.config.voicePreferences.voiceSid.value,
        AvatarVoiceService.defaultFemaleSid,
      );
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
    },
  );

  test(
    'synchronizing and read-only authority reject remote selection with zero side effects',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-admission.db',
      );
      addTearDown(harness.close);

      Future<void> expectRejected() async {
        await expectLater(
          harness.config.select(_remoteAvatar.id),
          throwsA(
            isA<AvatarAuthoritativeSelectionUnavailableException>().having(
              (error) => error.code,
              'code',
              'avatar_selection_contract_not_ready',
            ),
          ),
        );
      }

      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.synchronizing,
      );
      await expectRejected();

      harness.config.markAuthoritativeSelectionReadOnly();
      await expectRejected();

      expect(harness.transport.currentCalls, 0);
      expect(harness.transport.directCommitRequests, isEmpty);
      expect(harness.transport.recoveryClaims, isEmpty);
      expect(harness.runtime.loadAttempts, isEmpty);
      expect(harness.persistedValues, isEmpty);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'ready remote selection performs GET then preview then CAS and persistence',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-ready.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();

      await harness.config.select(_remoteAvatar.id);

      expect(harness.events, <String>[
        'GET',
        'load:${_remoteAvatar.modelUrl}',
        'POST:set:42',
        'persist:${_remoteAvatar.id}',
      ]);
      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.directCommitRequests.single.modelId, 42);
      expect(harness.transport.directCommitRequests.single.expectedVersion, 0);
      expect(harness.transport.recoveryClaims, isEmpty);
      expect(harness.runtime.loadAttempts, <String>[_remoteAvatar.modelUrl]);
      expect(harness.persistedValues, <String?>[_remoteAvatar.id]);
      expect(harness.config.selectedId.value, _remoteAvatar.id);
      expect(harness.coordinator.current?.selection.modelId, 42);
      expect(harness.coordinator.current?.selection.version, 1);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'selected model is displayable only after the authoritative load',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-display-ready.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      final releaseLoad = Completer<void>();
      harness.runtime.loadBarriers[_remoteAvatar.modelUrl] = releaseLoad;

      final selecting = harness.config.select(_remoteAvatar.id);
      await _waitUntil(
        () => harness.runtime.loadAttempts.contains(_remoteAvatar.modelUrl),
      );
      expect(harness.config.selectionDisplayReady.value, isFalse);
      expect(harness.config.selectionDisplayGeneration.value, 0);

      releaseLoad.complete();
      await selecting;
      expect(harness.config.selectionDisplayReady.value, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);

      final detachHide = Completer<void>();
      harness.runtime.hideBarrier = detachHide;
      harness.runtime.isReady.value = false;
      expect(harness.config.selectionDisplayCurrent, isFalse);
      expect(harness.config.selectionDisplayReady.value, isFalse);
      harness.runtime.isReady.value = true;
      expect(harness.config.selectionDisplayCurrent, isFalse);
      detachHide.complete();
      await _waitUntil(() => harness.config.selectionDisplayCurrent);
      harness.runtime.hideBarrier = null;
      expect(harness.config.selectionDisplayCurrent, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);

      harness.runtime.invalidateModelLoadEpoch();
      expect(harness.config.selectionDisplayCurrent, isFalse);
      await harness.config.applyForBackend(AvatarBackendKind.unity);
      expect(harness.config.selectionDisplayCurrent, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);
      expect(harness.config.selectedId.value, _remoteAvatar.id);

      await harness.config.select(_remoteAvatar.id);
      expect(harness.config.selectionDisplayReady.value, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);

      final loadCount = harness.runtime.loadAttempts.length;
      await harness.config.applyForBackend(AvatarBackendKind.unity);
      expect(harness.runtime.loadAttempts, hasLength(loadCount));
      expect(harness.config.selectionDisplayReady.value, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);
    },
  );

  test(
    'renderer reset reloads the selected model without a Home remount',
    () async {
      final matt = _reviewedVoiceAvatar;
      final harness = await _Harness.create(
        databasePath: 'avatar-display-renderer-reset.db',
        catalog: [_bundledAvatar, matt],
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(matt.id);
      final previousLoads = harness.runtime.loadAttempts.length;

      harness.runtime.isReady.value = false;
      harness.runtime.invalidateModelLoadEpoch();
      expect(harness.config.selectionDisplayCurrent, isFalse);
      harness.runtime.isReady.value = true;
      final recovery = harness.config.ensureSelectedDisplayReady();
      expect(harness.config.ensureSelectedDisplayReady(), same(recovery));
      await recovery;

      expect(harness.runtime.loadAttempts, hasLength(previousLoads + 1));
      expect(harness.runtime.loadAttempts.last, _reviewedVoiceAvatar.modelUrl);
      expect(harness.config.selectionDisplayCurrent, isTrue);
      expect(harness.config.selectedId.value, matt.id);
    },
  );

  test(
    'failed native recovery stays hidden until the selected uploaded model retries',
    () async {
      final matt = _reviewedVoiceAvatar;
      final harness = await _Harness.create(
        databasePath: 'avatar-display-recovery-retry.db',
        catalog: [_bundledAvatar, matt],
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(matt.id);
      final previousLoads = harness.runtime.loadAttempts.length;

      harness.runtime.hideError = StateError('native hide failed');
      harness.runtime.isReady.value = false;
      harness.runtime.invalidateModelLoadEpoch();
      harness.runtime.isReady.value = true;
      await expectLater(
        harness.config.ensureSelectedDisplayReady(),
        throwsA(isA<StateError>()),
      );
      expect(harness.config.selectionDisplayCurrent, isFalse);
      expect(harness.runtime.loadAttempts, hasLength(previousLoads));

      harness.runtime.hideError = null;
      await harness.config.ensureSelectedDisplayReady();
      expect(harness.config.selectionDisplayCurrent, isTrue);
      expect(harness.runtime.loadAttempts, hasLength(previousLoads + 1));
      expect(harness.runtime.loadAttempts.last, _reviewedVoiceAvatar.modelUrl);
      expect(harness.config.selectedId.value, matt.id);
    },
  );

  test('native hide receipt precedes replacement model load', () async {
    final harness = await _Harness.create(
      databasePath: 'avatar-display-hide-before-load.db',
    );
    addTearDown(harness.close);
    harness.config.markAuthoritativeSelectionReady();
    final releaseHide = Completer<void>();
    harness.runtime.hideBarrier = releaseHide;
    addTearDown(() {
      if (!releaseHide.isCompleted) releaseHide.complete();
    });

    final selecting = harness.config.select(_remoteAvatar.id);
    await _waitUntil(() => harness.runtime.hideCalls > 0);
    expect(harness.runtime.loadAttempts, isEmpty);
    expect(harness.config.selectionDisplayReady.value, isFalse);

    releaseHide.complete();
    await selecting;
    expect(harness.runtime.loadAttempts, [_remoteAvatar.modelUrl]);
    expect(harness.config.selectionDisplayReady.value, isTrue);
  });

  test(
    'failed native hide keeps replacement hidden and allows a retry',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-display-hide-failure.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      harness.runtime.hideError = StateError('native hide failed');

      await expectLater(
        harness.config.select(_remoteAvatar.id),
        throwsA(isA<StateError>()),
      );
      expect(harness.runtime.loadAttempts, isEmpty);
      expect(harness.config.selectionDisplayCurrent, isFalse);
      expect(harness.config.isSwitching.value, isFalse);

      harness.runtime.hideError = null;
      await harness.config.select(_remoteAvatar.id);
      expect(harness.config.selectionDisplayCurrent, isTrue);

      harness.runtime.hideError = StateError('native hide failed again');
      expect(await harness.config.deactivateAndDrain(), isFalse);
      expect(harness.config.selectionDisplayCurrent, isFalse);
    },
  );

  test(
    'catalog omission does not rewrite an authoritative selected model',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-catalog-omission.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);
      final loadsBeforeRefresh = harness.runtime.loadAttempts.length;

      harness.config.replaceReviewedOptions(const <AvatarOption>[]);

      expect(harness.config.selectedId.value, _remoteAvatar.id);
      expect(harness.config.selected.modelUrl, _remoteAvatar.modelUrl);
      expect(harness.config.catalog.map((option) => option.id), [
        _bundledAvatar.id,
      ]);
      expect(harness.config.selectionDisplayReady.value, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);
      expect(harness.runtime.loadAttempts, hasLength(loadsBeforeRefresh));

      harness.config.markAuthoritativeSelectionReadOnly();
      expect(harness.config.selectionDisplayReady.value, isFalse);
    },
  );

  test('same bundled id still performs a fresh GET and CAS write', () async {
    final harness = await _Harness.create(
      databasePath: 'avatar-authority-same-bundled.db',
    );
    addTearDown(harness.close);
    harness.config.markAuthoritativeSelectionReady();

    await harness.config.select(_bundledAvatar.id);

    expect(harness.transport.currentCalls, 1);
    expect(harness.transport.directCommitRequests, hasLength(1));
    expect(harness.transport.directCommitRequests.single.modelId, isNull);
    expect(harness.transport.directCommitRequests.single.expectedVersion, 0);
    expect(
      harness.transport.directCommitRequests.single.idempotencyKey,
      'avatar_test_key_1',
    );
    expect(harness.runtime.loadAttempts, <String>[_bundledAvatar.modelUrl]);
    expect(harness.persistedValues, <String?>[null]);
    expect(harness.coordinator.current?.selection.version, 1);
    expect(await harness.outbox.read(), isNull);
  });

  test(
    'same remote id reuses proven current but performs a fresh CAS write',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-same-remote.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();

      await harness.config.select(_remoteAvatar.id);
      await harness.config.select(_remoteAvatar.id);

      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.directCommitRequests, hasLength(2));
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.modelId,
        ),
        <int?>[42, 42],
      );
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.expectedVersion,
        ),
        <int>[0, 1],
      );
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.idempotencyKey,
        ),
        <String>['avatar_test_key_1', 'avatar_test_key_3'],
      );
      expect(harness.runtime.loadAttempts, <String>[
        _remoteAvatar.modelUrl,
        _remoteAvatar.modelUrl,
      ]);
      expect(harness.persistedValues, <String?>[
        _remoteAvatar.id,
        _remoteAvatar.id,
      ]);
      expect(harness.coordinator.current?.selection.version, 2);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'same remote id converges to a newer server head on CAS conflict',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-same-remote-drift.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);
      final drifted = _snapshot(modelId: null, version: 5);
      harness.transport.currentSnapshot = drifted;

      await expectLater(
        harness.config.select(_remoteAvatar.id),
        throwsA(
          isA<AvatarSelectionVersionChangedException>().having(
            (error) => error.currentSelection.selection.version,
            'current version',
            5,
          ),
        ),
      );

      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.directCommitRequests, hasLength(2));
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.expectedVersion,
        ),
        <int>[0, 1],
      );
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.idempotencyKey,
        ),
        <String>['avatar_test_key_1', 'avatar_test_key_3'],
      );
      expect(harness.coordinator.current?.selection.version, 5);
      expect(harness.coordinator.current?.selection.modelId, isNull);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test('switching from remote to bundled commits modelId null', () async {
    final harness = await _Harness.create(
      databasePath: 'avatar-authority-clear.db',
    );
    addTearDown(harness.close);
    harness.config.markAuthoritativeSelectionReady();

    await harness.config.select(_remoteAvatar.id);
    await harness.config.select(_bundledAvatar.id);

    expect(harness.transport.currentCalls, 1);
    expect(harness.transport.directCommitRequests, hasLength(2));
    expect(
      harness.transport.directCommitRequests.map((request) => request.modelId),
      <int?>[42, null],
    );
    expect(
      harness.transport.directCommitRequests.map(
        (request) => request.expectedVersion,
      ),
      <int>[0, 1],
    );
    expect(harness.transport.recoveryClaims, isEmpty);
    expect(harness.runtime.loadAttempts, <String>[
      _remoteAvatar.modelUrl,
      _bundledAvatar.modelUrl,
    ]);
    expect(harness.persistedValues, <String?>[_remoteAvatar.id, null]);
    expect(harness.config.selectedId.value, _bundledAvatar.id);
    expect(harness.coordinator.current?.selection.modelId, isNull);
    expect(harness.coordinator.current?.selection.version, 2);
    expect(await harness.outbox.read(), isNull);
  });

  test(
    'contract unavailable marks selection read-only and restores bundled state',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-contract-unavailable.db',
        commitHandler: (request, _) async {
          if (request.modelId == 42) {
            throw const AvatarSelectionContractUnavailableException(
              statusCode: 404,
            );
          }
          throw StateError('unexpected commit');
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();

      await expectLater(
        harness.config.select(_remoteAvatar.id),
        throwsA(isA<AvatarSelectionContractUnavailableException>()),
      );

      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.readOnlyBundled,
      );
      expect(harness.config.remoteModelSelectionAvailable, isFalse);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.directCommitRequests.single.modelId, 42);
      expect(harness.transport.recoveryClaims, isEmpty);
      expect(harness.runtime.loadAttempts, <String>[
        _remoteAvatar.modelUrl,
        _bundledAvatar.modelUrl,
      ]);
      expect(harness.persistedValues, <String?>[null]);
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.transport.currentSnapshot.selection.version, 0);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'remote A to B contract unavailable ends read-only with bundled local state',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-remote-contract-unavailable.db',
        commitHandler: (request, transport) async {
          if (request.modelId == _remoteAvatarB.remoteModelId) {
            throw const AvatarSelectionContractUnavailableException(
              statusCode: 404,
            );
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      await expectLater(
        harness.config.select(_remoteAvatarB.id),
        throwsA(isA<AvatarSelectionContractUnavailableException>()),
      );

      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.readOnlyBundled,
      );
      expect(harness.config.remoteModelSelectionAvailable, isFalse);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
      expect(harness.config.isSwitching.value, isFalse);
      expect(harness.transport.currentSnapshot.selection.modelId, 42);
      expect(harness.transport.currentSnapshot.selection.version, 1);
      expect(harness.transport.directCommitRequests, hasLength(2));
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.modelId,
        ),
        <int?>[42, 43],
      );
      expect(harness.transport.recoveryClaims, isEmpty);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'capability revocation during pending POST compensates exactly to bundled',
    () async {
      final postStarted = Completer<void>();
      final releasePost = Completer<void>();
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-inflight-revocation.db',
        commitHandler: (request, transport) async {
          if (request.modelId == 42 && !postStarted.isCompleted) {
            postStarted.complete();
            await releasePost.future;
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(() {
        if (!releasePost.isCompleted) releasePost.complete();
      });
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();

      final selection = harness.config.select(_remoteAvatar.id);
      final selectionExpectation = expectLater(
        selection,
        throwsA(isA<AvatarSelectionCompensatedException>()),
      );
      await postStarted.future;

      harness.revokeRemoteCapability();
      releasePost.complete();
      await selectionExpectation;

      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.directCommitRequests.single.modelId, 42);
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.compensation,
      );
      expect(harness.transport.recoveryClaims.single.request.modelId, isNull);
      expect(
        harness.transport.recoveryClaims.single.request.expectedVersion,
        1,
      );
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.transport.currentSnapshot.selection.version, 2);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.runtime.loadAttempts.first, _remoteAvatar.modelUrl);
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues, isNotEmpty);
      expect(harness.persistedValues, everyElement(isNull));
      expect(harness.config.isSwitching.value, isFalse);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'remote B revoked in flight compensates to A then clears A authoritatively',
    () async {
      final postStarted = Completer<void>();
      final releasePost = Completer<void>();
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-inflight-remote-clear.db',
        commitHandler: (request, transport) async {
          final isInitialRemoteBRequest =
              request.modelId == _remoteAvatarB.remoteModelId &&
              transport.recoveryClaims.isEmpty &&
              !postStarted.isCompleted;
          if (isInitialRemoteBRequest) {
            postStarted.complete();
            await releasePost.future;
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(() {
        if (!releasePost.isCompleted) releasePost.complete();
      });
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      final selection = harness.config.select(_remoteAvatarB.id);
      final selectionExpectation = expectLater(
        selection,
        throwsA(isA<AvatarSelectionCompensatedException>()),
      );
      await postStarted.future;
      harness.revokeRemoteCapability();
      releasePost.complete();
      await selectionExpectation;

      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.compensation,
      );
      expect(
        harness.transport.recoveryClaims.single.request.modelId,
        _remoteAvatar.remoteModelId,
      );
      expect(
        harness.transport.recoveryClaims.single.request.expectedVersion,
        2,
      );
      expect(harness.transport.directCommitRequests, hasLength(3));
      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.modelId,
        ),
        <int?>[42, 43, null],
      );
      expect(harness.transport.directCommitRequests.last.expectedVersion, 3);
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.transport.currentSnapshot.selection.version, 4);
      expect(harness.coordinator.current?.selection.modelId, isNull);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.runtime.loadedAvatars.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
      expect(harness.config.isSwitching.value, isFalse);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'committed remote capability revocation retires with committed evidence',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-evidence-retirement.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value &&
            harness.transport.recoveryClaims.length == 1,
      );

      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.directCommitRequests.single.modelId, 42);
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.compensation,
      );
      expect(harness.transport.recoveryClaims.single.request.modelId, isNull);
      expect(
        harness.transport.recoveryClaims.single.request.expectedVersion,
        1,
      );
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.transport.currentSnapshot.selection.version, 2);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.runtime.loadAttempts.first, _remoteAvatar.modelUrl);
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues, <String?>[_remoteAvatar.id, null]);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test('superseded exact retirement preserves a newer server writer', () async {
    final harness = await _Harness.create(
      databasePath: 'avatar-authority-retirement-newer-writer.db',
    );
    addTearDown(harness.close);
    harness.config.markAuthoritativeSelectionReady();
    await harness.config.select(_remoteAvatar.id);
    await harness.config.select(_remoteAvatarB.id);
    final newerWriter = _snapshot(modelId: 44, version: 3);
    harness.transport.currentSnapshot = newerWriter;

    harness.revokeRemoteCapability();
    await _waitUntil(
      () =>
          harness.config.selectedId.value == _bundledAvatar.id &&
          !harness.config.isSwitching.value &&
          harness.transport.recoveryClaims.length == 1,
    );

    expect(harness.transport.directCommitRequests, hasLength(2));
    expect(
      harness.transport.directCommitRequests.map((request) => request.modelId),
      <int?>[42, 43],
    );
    expect(harness.transport.recoveryClaims, hasLength(1));
    expect(
      harness.transport.recoveryClaims.single.operation,
      AvatarSelectionRecoveryOperation.compensation,
    );
    expect(
      harness.transport.recoveryClaims.single.request.modelId,
      _remoteAvatar.remoteModelId,
    );
    expect(harness.transport.recoveryClaims.single.request.expectedVersion, 2);
    expect(harness.transport.currentSnapshot.selection.modelId, 44);
    expect(harness.transport.currentSnapshot.selection.version, 3);
    expect(harness.coordinator.current?.selection.modelId, 44);
    expect(harness.config.selectedId.value, _bundledAvatar.id);
    expect(harness.runtime.loadedAvatars.last, _bundledAvatar.modelUrl);
    expect(harness.persistedValues.last, isNull);
    expect(await harness.outbox.read(), isNull);

    final postCount = harness.transport.networkPostCount;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(harness.transport.networkPostCount, postCount);
    expect(harness.transport.currentSnapshot.selection.modelId, 44);
  });

  test(
    'contract-unavailable evidence retirement becomes read-only and never retries network',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-retirement-unavailable.db',
        commitHandler: (request, transport) async {
          if (request.modelId == null && transport.recoveryClaims.isNotEmpty) {
            throw const AvatarSelectionAmbiguousTransportException(
              cause: AvatarSelectionContractUnavailableException(
                statusCode: 404,
              ),
            );
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.config.selectionAuthorityState.value ==
                AvatarSelectionAuthorityState.readOnlyBundled &&
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value,
      );

      final postCount = harness.transport.networkPostCount;
      expect(postCount, 2);
      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.compensation,
      );
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
      expect(harness.config.remoteModelSelectionAvailable, isFalse);
      expect(
        (await harness.outbox.read())?.stage,
        AvatarSelectionOutboxStage.compensating,
      );

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(harness.transport.networkPostCount, postCount);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
    },
  );

  test(
    'late tracked Unity load re-converges locally after contract loss',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-late-local-side-effect.db',
        commitHandler: (request, transport) async {
          if (request.modelId == null) {
            throw const AvatarSelectionContractUnavailableException(
              statusCode: 404,
            );
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      final releaseLateLoad = Completer<void>();
      harness.runtime.loadBarriers[_remoteAvatar.modelUrl] = releaseLateLoad;
      harness.runtime.invalidateModelLoadEpoch();
      addTearDown(() {
        if (!releaseLateLoad.isCompleted) releaseLateLoad.complete();
      });
      final apply = harness.config.applyForBackend(AvatarBackendKind.unity);
      final applyExpectation = expectLater(
        apply,
        throwsA(isA<AvatarRemoteModelCapabilityException>()),
      );
      await _waitUntil(
        () =>
            harness.runtime.loadAttempts
                .where((url) => url == _remoteAvatar.modelUrl)
                .length ==
            2,
      );

      harness.refreshAllowedCapabilities();
      await applyExpectation;
      await _waitUntil(
        () =>
            harness.config.selectionAuthorityState.value ==
                AvatarSelectionAuthorityState.readOnlyBundled &&
            harness.config.selectedId.value == _bundledAvatar.id &&
            harness.runtime.loadedAvatars.last == _bundledAvatar.modelUrl,
      );

      final postCountBeforeLateCompletion = harness.transport.networkPostCount;
      final bundledLoadsBeforeLateCompletion = harness.runtime.loadedAvatars
          .where((url) => url == _bundledAvatar.modelUrl)
          .length;
      expect(postCountBeforeLateCompletion, 2);
      expect(harness.persistedValues.last, isNull);

      releaseLateLoad.complete();
      await _waitUntil(
        () =>
            harness.runtime.loadedAvatars
                    .where((url) => url == _bundledAvatar.modelUrl)
                    .length >
                bundledLoadsBeforeLateCompletion &&
            harness.runtime.loadedAvatars.last == _bundledAvatar.modelUrl &&
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value,
      );

      expect(harness.transport.networkPostCount, postCountBeforeLateCompletion);
      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.readOnlyBundled,
      );
      expect(harness.runtime.loadedAvatars.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(harness.transport.networkPostCount, postCountBeforeLateCompletion);
    },
  );

  test(
    'late tracked Unity load after exact retirement does not write again',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-late-exact-retirement.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      final releaseLateLoad = Completer<void>();
      final releaseRetirementPersistence = Completer<void>();
      harness.runtime.loadBarriers[_remoteAvatar.modelUrl] = releaseLateLoad;
      harness.runtime.invalidateModelLoadEpoch();
      harness.persistBarriers.add(releaseRetirementPersistence);
      addTearDown(() {
        if (!releaseLateLoad.isCompleted) releaseLateLoad.complete();
        if (!releaseRetirementPersistence.isCompleted) {
          releaseRetirementPersistence.complete();
        }
      });
      final applyExpectation = expectLater(
        harness.config.applyForBackend(AvatarBackendKind.unity),
        throwsA(isA<AvatarRemoteModelCapabilityException>()),
      );
      await _waitUntil(
        () =>
            harness.runtime.loadAttempts
                .where((url) => url == _remoteAvatar.modelUrl)
                .length ==
            2,
      );

      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.transport.currentSnapshot.selection.modelId == null &&
            harness.runtime.loadedAvatars.last == _bundledAvatar.modelUrl &&
            harness.persistedValues.last == null,
      );

      final postCountBeforeLateCompletion = harness.transport.networkPostCount;
      final bundledLoadsBeforeLateCompletion = harness.runtime.loadedAvatars
          .where((url) => url == _bundledAvatar.modelUrl)
          .length;
      expect(postCountBeforeLateCompletion, 2);
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(harness.transport.currentSnapshot.selection.version, 2);

      releaseLateLoad.complete();
      await applyExpectation;
      await _waitUntil(
        () => harness.runtime.loadedAvatars.last == _remoteAvatar.modelUrl,
      );

      releaseRetirementPersistence.complete();
      await _waitUntil(
        () =>
            harness.runtime.loadedAvatars
                    .where((url) => url == _bundledAvatar.modelUrl)
                    .length >
                bundledLoadsBeforeLateCompletion &&
            harness.runtime.loadedAvatars.last == _bundledAvatar.modelUrl &&
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value,
      );

      expect(harness.transport.networkPostCount, postCountBeforeLateCompletion);
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.transport.currentSnapshot.selection.version, 2);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.persistedValues.last, isNull);
    },
  );

  test(
    'late tracked Unity load after retirement conflict preserves newer writer',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-late-newer-writer.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      final releaseLateLoad = Completer<void>();
      final releaseRetirementPersistence = Completer<void>();
      harness.runtime.loadBarriers[_remoteAvatar.modelUrl] = releaseLateLoad;
      harness.runtime.invalidateModelLoadEpoch();
      harness.persistBarriers.add(releaseRetirementPersistence);
      addTearDown(() {
        if (!releaseLateLoad.isCompleted) releaseLateLoad.complete();
        if (!releaseRetirementPersistence.isCompleted) {
          releaseRetirementPersistence.complete();
        }
      });
      final applyExpectation = expectLater(
        harness.config.applyForBackend(AvatarBackendKind.unity),
        throwsA(isA<AvatarRemoteModelCapabilityException>()),
      );
      await _waitUntil(
        () =>
            harness.runtime.loadAttempts
                .where((url) => url == _remoteAvatar.modelUrl)
                .length ==
            2,
      );

      harness.transport.currentSnapshot = _snapshot(modelId: 43, version: 2);
      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.transport.recoveryClaims.length == 1 &&
            harness.runtime.loadedAvatars.last == _bundledAvatar.modelUrl &&
            harness.persistedValues.last == null,
      );

      final postCountBeforeLateCompletion = harness.transport.networkPostCount;
      final bundledLoadsBeforeLateCompletion = harness.runtime.loadedAvatars
          .where((url) => url == _bundledAvatar.modelUrl)
          .length;
      expect(postCountBeforeLateCompletion, 2);
      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.recoveryClaims, hasLength(1));

      releaseLateLoad.complete();
      await applyExpectation;
      await _waitUntil(
        () => harness.runtime.loadedAvatars.last == _remoteAvatar.modelUrl,
      );

      releaseRetirementPersistence.complete();
      await _waitUntil(
        () =>
            harness.runtime.loadedAvatars
                    .where((url) => url == _bundledAvatar.modelUrl)
                    .length >
                bundledLoadsBeforeLateCompletion &&
            harness.runtime.loadedAvatars.last == _bundledAvatar.modelUrl &&
            harness.coordinator.current?.selection.modelId == 43 &&
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value,
      );

      expect(harness.transport.networkPostCount, postCountBeforeLateCompletion);
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(harness.transport.currentSnapshot.selection.modelId, 43);
      expect(harness.transport.currentSnapshot.selection.version, 2);
      expect(harness.coordinator.current?.selection.modelId, 43);
      expect(harness.config.selectedId.value, _bundledAvatar.id);
      expect(harness.persistedValues.last, isNull);
    },
  );

  test('avatar config drain waits for a tracked Unity side effect', () async {
    final harness = await _Harness.create(
      databasePath: 'avatar-authority-local-drain.db',
    );
    addTearDown(harness.close);
    harness.config.markAuthoritativeSelectionReady();
    await harness.config.select(_remoteAvatar.id);

    final releaseLoad = Completer<void>();
    harness.runtime.loadBarriers[_remoteAvatar.modelUrl] = releaseLoad;
    harness.runtime.invalidateModelLoadEpoch();
    addTearDown(() {
      if (!releaseLoad.isCompleted) releaseLoad.complete();
    });
    final apply = harness.config.applyForBackend(AvatarBackendKind.unity);
    await _waitUntil(
      () =>
          harness.runtime.loadAttempts
              .where((url) => url == _remoteAvatar.modelUrl)
              .length ==
          2,
    );

    expect(
      await harness.config.deactivateAndDrain(
        timeout: const Duration(milliseconds: 10),
      ),
      isFalse,
    );
    var retryDrainCompleted = false;
    final retryDrain = harness.config
        .deactivateAndDrain(timeout: const Duration(seconds: 1))
        .then((value) {
          retryDrainCompleted = true;
          return value;
        });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(retryDrainCompleted, isFalse);

    releaseLoad.complete();
    await apply;
    expect(await retryDrain, isTrue);
    expect(retryDrainCompleted, isTrue);
    final loadAttemptCount = harness.runtime.loadAttempts.length;
    await harness.config.applyForBackend(AvatarBackendKind.unity);
    expect(harness.runtime.loadAttempts, hasLength(loadAttemptCount));
    final postCount = harness.transport.networkPostCount;
    await expectLater(
      harness.config.select(_remoteAvatarB.id),
      throwsA(isA<StateError>()),
    );
    expect(harness.transport.networkPostCount, postCount);
  });

  test(
    'avatar config drain fences voice projection and late catalog refresh',
    () async {
      final voice = _ControlledAvatarVoiceService();
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-voice-drain.db',
        voicePreferences: voice,
      );
      addTearDown(() async {
        voice.release();
        await harness.close();
      });
      await _waitUntil(() => voice.applyCalls == 1);

      expect(
        await harness.config.deactivateAndDrain(
          timeout: const Duration(milliseconds: 10),
        ),
        isFalse,
      );
      var retryDrainCompleted = false;
      final retryDrain = harness.config
          .deactivateAndDrain(timeout: const Duration(seconds: 1))
          .then((value) {
            retryDrainCompleted = true;
            return value;
          });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(retryDrainCompleted, isFalse);

      voice.release();
      expect(await retryDrain, isTrue);
      expect(retryDrainCompleted, isTrue);
      expect(voice.projectedGenders, hasLength(1));

      final catalogBefore = List<AvatarOption>.of(harness.config.catalog);
      expect(
        harness.config.replaceReviewedOptions(const <AvatarOption>[]),
        isFalse,
      );
      expect(harness.config.catalog, orderedEquals(catalogBefore));
      expect(voice.applyCalls, 1);
    },
  );

  test(
    'read-only authority cannot be reopened by a stale startup completion',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-read-only-cas.db',
      );
      addTearDown(harness.close);
      final config = harness.config;

      config.markAuthoritativeSelectionReadOnly();
      config.markAuthoritativeSelectionReady();
      expect(
        config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.readOnlyBundled,
      );

      config.beginAuthoritativeSelectionStartup();
      config.markAuthoritativeSelectionReady();
      expect(
        config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.ready,
      );
    },
  );

  test(
    'definitely uncommitted prepared B GETs exact A then clears A once',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-recovery-definite-clear.db',
        commitHandler: (request, transport) async {
          if (request.modelId == _remoteAvatarB.remoteModelId) {
            if (transport.recoveryClaims.isEmpty) {
              throw const AvatarSelectionAmbiguousTransportException();
            }
            throw const AvatarSelectionNotFoundException(statusCode: 404);
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);
      await expectLater(
        harness.config.select(_remoteAvatarB.id),
        throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
      );

      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.config.selectedId.value == _bundledAvatar.id &&
            harness.transport.currentSnapshot.selection.modelId == null &&
            !harness.config.isSwitching.value,
      );

      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.modelId,
        ),
        <int?>[42, 43, null],
      );
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.setReplay,
      );
      expect(harness.transport.currentSnapshot.selection.version, 2);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'preview revocation sends no B POST and retires A with exact evidence',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-preview-revoke.db',
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      final releasePreview = Completer<void>();
      harness.runtime.loadBarriers[_remoteAvatarB.modelUrl] = releasePreview;
      addTearDown(() {
        if (!releasePreview.isCompleted) releasePreview.complete();
      });
      final selection = harness.config.select(_remoteAvatarB.id);
      final selectionExpectation = expectLater(
        selection,
        throwsA(isA<AvatarRemoteModelCapabilityException>()),
      );
      await _waitUntil(
        () => harness.runtime.loadAttempts.contains(_remoteAvatarB.modelUrl),
      );

      harness.revokeRemoteCapability();
      releasePreview.complete();
      await selectionExpectation;
      await _waitUntil(
        () =>
            harness.config.selectedId.value == _bundledAvatar.id &&
            harness.transport.currentSnapshot.selection.modelId == null &&
            !harness.config.isSwitching.value,
      );

      expect(
        harness.transport.directCommitRequests.map(
          (request) => request.modelId,
        ),
        <int?>[42],
      );
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.compensation,
      );
      expect(harness.transport.recoveryClaims.single.request.modelId, isNull);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'outstanding preflight preserves remote owner so revoke can still retire it',
    () async {
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-outstanding-owner.db',
        commitHandler: (request, transport) async {
          final isInitialRemoteBRequest =
              request.modelId == _remoteAvatarB.remoteModelId &&
              transport.recoveryClaims.isEmpty;
          if (isInitialRemoteBRequest) {
            throw const AvatarSelectionAmbiguousTransportException();
          }
          return transport.applyCommit(request);
        },
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.config.select(_remoteAvatar.id);

      await expectLater(
        harness.config.select(_remoteAvatarB.id),
        throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
      );
      expect(harness.config.selectedId.value, _remoteAvatar.id);
      expect(
        (await harness.outbox.read())?.stage,
        AvatarSelectionOutboxStage.prepared,
      );

      await expectLater(
        harness.config.select(_bundledAvatar.id),
        throwsA(isA<AvatarSelectionOutstandingObligationException>()),
      );
      expect(harness.config.selectedId.value, _remoteAvatar.id);

      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value &&
            harness.transport.currentSnapshot.selection.modelId == null,
      );

      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(harness.persistedValues.last, isNull);
      expect(harness.transport.recoveryClaims, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.setReplay,
      );
      expect(
        harness.transport.recoveryClaims.single.request.modelId,
        _remoteAvatarB.remoteModelId,
      );
      expect(harness.transport.directCommitRequests.last.modelId, isNull);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'observed remote without evidence revokes through coordinator clear',
    () async {
      final observed = _snapshot(modelId: 42, version: 3);
      final harness = await _Harness.create(
        databasePath: 'avatar-authority-observed-retirement.db',
        initialCurrent: observed,
      );
      addTearDown(harness.close);
      harness.config.markAuthoritativeSelectionReady();
      await harness.coordinator.ensureCurrent();
      await harness.config.reconcileAuthoritative(observed);

      harness.revokeRemoteCapability();
      await _waitUntil(
        () =>
            harness.config.selectedId.value == _bundledAvatar.id &&
            !harness.config.isSwitching.value &&
            harness.transport.directCommitRequests.length == 1,
      );

      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.directCommitRequests, hasLength(1));
      expect(harness.transport.directCommitRequests.single.modelId, isNull);
      expect(harness.transport.directCommitRequests.single.expectedVersion, 3);
      expect(harness.transport.recoveryClaims, isEmpty);
      expect(harness.transport.currentSnapshot.selection.modelId, isNull);
      expect(harness.transport.currentSnapshot.selection.version, 4);
      expect(harness.persistedValues, <String?>[_remoteAvatar.id, null]);
      expect(harness.runtime.loadAttempts.first, _remoteAvatar.modelUrl);
      expect(harness.runtime.loadAttempts.last, _bundledAvatar.modelUrl);
      expect(await harness.outbox.read(), isNull);
    },
  );
}

typedef _CommitHandler =
    Future<AvatarSelectionCommitResult> Function(
      AvatarSelectionCommitRequest request,
      _StatefulTransport transport,
    );

final class _ControlledAvatarVoiceService extends AvatarVoiceService {
  final Completer<void> _release = Completer<void>();
  final List<AvatarVoiceGender> projectedGenders = <AvatarVoiceGender>[];
  int applyCalls = 0;

  @override
  Future<void> applyAvatar({
    required AvatarVoiceGender gender,
    int? preferredSid,
  }) async {
    applyCalls += 1;
    await _release.future;
    projectedGenders.add(gender);
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

final class _Harness {
  _Harness({
    required this.database,
    required this.storageScopes,
    required this.mount,
    required this.outbox,
    required this.coordinator,
    required this.transport,
    required this.snapshots,
    required this.runtime,
    required this.config,
    required this.events,
    required this.persistedValues,
    required this.persistBarriers,
  });

  static Future<_Harness> create({
    required String databasePath,
    AvatarSelectionSnapshot? initialCurrent,
    _CommitHandler? commitHandler,
    AvatarVoiceService? voicePreferences,
    List<AvatarOption> catalog = _avatarCatalog,
    AppHostPlatform platform = AppHostPlatform.macos,
    AvatarSelectionAssetOptions assetOptions =
        const AvatarSelectionAssetOptions.none(),
  }) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await SpUtils.init();

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: databasePath,
    );
    final storageScopes = AccountStorageScopeService();
    final scope = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: databasePath,
    );
    final mount = storageScopes.mount(scope);
    final outbox = SembastAvatarSelectionOutbox(
      accountDatabase: database,
      mount: mount,
      agentScope: scope.agent('self'),
      storageScopes: storageScopes,
    );
    final events = <String>[];
    final transport = _StatefulTransport(
      events: events,
      initialCurrent: initialCurrent ?? _snapshot(modelId: null, version: 0),
      commitHandler: commitHandler,
    );
    final coordinator = AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: outbox,
      idempotencyKeyFactory: _KeySequence().call,
      maxAmbiguousAttempts: 1,
    );
    final snapshots = _capabilitySnapshots(platform);
    final active = appServices.put(ActiveAvatarRuntime());
    final runtime = _RecordingAvatarRuntime(events);
    active.register(runtime);
    final persistedValues = <String?>[];
    final persistBarriers = <Completer<void>>[];
    final config = appServices.put(
      AvatarConfigService(
        initialCatalog: catalog,
        selectionAssetOptions: assetOptions,
        capabilitySnapshots: snapshots,
        selectionCoordinator: coordinator,
        voicePreferences: voicePreferences,
        persistSelection: (key, selectedId) async {
          persistedValues.add(selectedId);
          events.add('persist:${selectedId ?? 'bundled'}');
          final barrier = persistBarriers.isEmpty
              ? null
              : persistBarriers.removeAt(0);
          await barrier?.future;
          return true;
        },
      ).init(),
    );
    return _Harness(
      database: database,
      storageScopes: storageScopes,
      mount: mount,
      outbox: outbox,
      coordinator: coordinator,
      transport: transport,
      snapshots: snapshots,
      runtime: runtime,
      config: config,
      events: events,
      persistedValues: persistedValues,
      persistBarriers: persistBarriers,
    );
  }

  final DBService database;
  final AccountStorageScopeService storageScopes;
  final AccountStorageScopeMount mount;
  final SembastAvatarSelectionOutbox outbox;
  final AvatarSelectionCoordinator coordinator;
  final _StatefulTransport transport;
  final AppCapabilitySnapshotService snapshots;
  final _RecordingAvatarRuntime runtime;
  final AvatarConfigService config;
  final List<String> events;
  final List<String?> persistedValues;
  final List<Completer<void>> persistBarriers;

  void revokeRemoteCapability() {
    snapshots.refresh(
      AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.web,
        rolloutGeneration: snapshots.context.rolloutGeneration + 1,
      ),
    );
  }

  void refreshAllowedCapabilities() {
    snapshots.refresh(
      AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: snapshots.context.rolloutGeneration + 1,
      ),
    );
  }

  Future<void> close() async {
    await appServices.reset();
    snapshots.onClose();
    await coordinator.deactivateAndDrain();
    if (storageScopes.isCurrent(mount)) storageScopes.unmount(mount);
    await database.close();
  }
}

final class _KeySequence {
  int _value = 0;

  String call() {
    _value += 1;
    return 'avatar_test_key_$_value';
  }
}

final class _StatefulTransport
    implements AvatarSelectionTransport, AvatarSelectionRecoveryTransport {
  _StatefulTransport({
    required this.events,
    required AvatarSelectionSnapshot initialCurrent,
    _CommitHandler? commitHandler,
  }) : currentSnapshot = initialCurrent,
       _commitHandler = commitHandler;

  final List<String> events;
  final _CommitHandler? _commitHandler;
  final List<AvatarSelectionCommitRequest> directCommitRequests =
      <AvatarSelectionCommitRequest>[];
  final List<AvatarSelectionRecoveryClaim> recoveryClaims =
      <AvatarSelectionRecoveryClaim>[];
  AvatarSelectionSnapshot currentSnapshot;
  int currentCalls = 0;

  int get networkPostCount =>
      directCommitRequests.length + recoveryClaims.length;

  @override
  Future<AvatarSelectionSnapshot> current({
    required String agentId,
    required AvatarSelectionAssetOptions assetOptions,
  }) async {
    currentCalls += 1;
    events.add('GET');
    return currentSnapshot;
  }

  @override
  Future<AvatarSelectionCommitResult> commit(
    AvatarSelectionCommitRequest request,
  ) async {
    directCommitRequests.add(request);
    events.add('POST:set:${request.modelId ?? 'bundled'}');
    return _dispatch(request);
  }

  @override
  Future<AvatarSelectionCommitResult> replay(
    AvatarSelectionRecoveryClaim claim,
  ) async {
    recoveryClaims.add(claim);
    events.add(
      'POST:${claim.operation.name}:${claim.request.modelId ?? 'bundled'}',
    );
    return _dispatch(claim.request);
  }

  Future<AvatarSelectionCommitResult> _dispatch(
    AvatarSelectionCommitRequest request,
  ) => _commitHandler?.call(request, this) ?? applyCommit(request);

  Future<AvatarSelectionCommitResult> applyCommit(
    AvatarSelectionCommitRequest request,
  ) async {
    if (request.expectedVersion != currentSnapshot.selection.version) {
      throw AvatarSelectionVersionChangedException(
        currentSelection: currentSnapshot,
      );
    }
    final result = _result(request, currentSnapshot.selection);
    currentSnapshot = AvatarSelectionSnapshot(
      selection: result.receipt.selection,
      asset: result.receipt.asset,
      selectionAvailable: result.receipt.selectionAvailable,
    );
    return result;
  }
}

final class _RecordingAvatarRuntime extends AvatarRuntime {
  _RecordingAvatarRuntime(this.events);

  final List<String> events;
  final List<String> loadAttempts = <String>[];
  final List<String> loadedAvatars = <String>[];
  final Map<String, Completer<void>> loadBarriers = <String, Completer<void>>{};
  Completer<void>? hideBarrier;
  Object? hideError;
  int hideCalls = 0;
  int _modelLoadEpoch = 0;

  @override
  int get modelLoadEpoch => _modelLoadEpoch;

  void invalidateModelLoadEpoch() => _modelLoadEpoch++;

  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    if (!visible) {
      hideCalls++;
      await hideBarrier?.future;
      if (hideError != null) throw hideError!;
    }
  }

  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = true.obs;

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const <String, dynamic>{},
  ]) async {
    loadAttempts.add(modelUrl);
    events.add('load:$modelUrl');
    final barrier = loadBarriers.remove(modelUrl);
    await barrier?.future;
    loadedAvatars.add(modelUrl);
  }

  @override
  Future<void> clearGaze() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {}

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {}

  @override
  Future<void> setFraming(String mode) async {}

  @override
  Future<void> setGaze(AvatarGaze gaze) async {}

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}

AppCapabilitySnapshotService _capabilitySnapshots(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const []),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

AvatarSelectionCommitResult _result(
  AvatarSelectionCommitRequest request,
  AvatarSelectionState previous,
) {
  final selection = AvatarSelectionState(
    selectionId: previous.selectionId ?? 10,
    agentId: previous.agentId,
    modelId: request.modelId,
    version: previous.version + 1,
    selectedAt: DateTime.utc(2026, 9, 2, 8, previous.version + 1),
  );
  return AvatarSelectionCommitResult(
    receipt: AvatarSelectionReceipt(
      idempotencyKey: request.idempotencyKey,
      previousSelection: previous,
      selection: selection,
      asset: _asset(request.modelId),
      selectionAvailable: true,
    ),
    replayed: false,
    request: request,
  );
}

AvatarSelectionSnapshot _snapshot({
  required int? modelId,
  required int version,
}) => AvatarSelectionSnapshot(
  selection: version == 0
      ? AvatarSelectionState(
          selectionId: null,
          agentId: 'self',
          modelId: null,
          version: 0,
          selectedAt: null,
        )
      : AvatarSelectionState(
          selectionId: 10,
          agentId: 'self',
          modelId: modelId,
          version: version,
          selectedAt: DateTime.utc(2026, 9, 2, 8, version),
        ),
  asset: _asset(modelId),
  selectionAvailable: true,
);

AvatarSelectionAssetDescriptor _asset(int? modelId) {
  if (modelId == 44) {
    return AvatarSelectionAssetDescriptor(
      id: 44,
      modelKey: 'uploaded-test-44',
      displayName: 'Uploaded test model',
      modelSource: 'uploaded',
      assetUrl: _reviewedVoiceAvatar.modelUrl,
      assetSha256: _avatarSha256,
      runtimeConfig: _reviewedVoiceAvatar.config,
      compatibility: const {
        'backends': ['unity'],
      },
    );
  }
  final bundled = modelId == null;
  final remoteUrl = modelId == _remoteAvatarB.remoteModelId
      ? _remoteAvatarB.modelUrl
      : _remoteAvatar.modelUrl;
  return AvatarSelectionAssetDescriptor(
    id: modelId ?? 1,
    modelKey: bundled ? 'masso.bundled.agent' : 'model-$modelId',
    displayName: bundled ? 'Maaso Agent' : 'Model $modelId',
    modelSource: bundled ? 'bundled' : 'reviewed',
    assetUrl: bundled ? _bundledAvatar.modelUrl : remoteUrl,
    assetSha256: _avatarSha256,
    runtimeConfig: bundled
        ? const <String, Object?>{}
        : const <String, Object?>{'assetName': 'Avatar/Remote'},
    compatibility: bundled
        ? const <String, Object?>{}
        : const <String, Object?>{
            'backends': <Object?>['unity'],
          },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition was not reached before timeout');
}

const _avatarSha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const _bundledAvatar = AvatarOption(
  id: 'agent',
  name: 'Agent',
  backend: AvatarBackendKind.unity,
  modelUrl: 'unity://masso/avatar_agent',
  isDefault: true,
);

const _remoteAvatar = AvatarOption(
  id: 'reviewed-model-42',
  name: 'Remote 42',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/model-42.glb',
  config: <String, dynamic>{'assetName': 'Avatar/Remote'},
  remoteModelId: 42,
  modelSource: 'reviewed',
);

const _remoteAvatarB = AvatarOption(
  id: 'reviewed-model-43',
  name: 'Remote 43',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/model-43.glb',
  config: <String, dynamic>{'assetName': 'Avatar/RemoteB'},
  remoteModelId: 43,
  modelSource: 'reviewed',
);

const _avatarCatalog = <AvatarOption>[
  _bundledAvatar,
  _remoteAvatar,
  _remoteAvatarB,
];

const _reviewedVoiceAvatar = AvatarOption(
  id: 'reviewed-model-44',
  name: 'Uploaded test model',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/uploaded-test-44.bundle',
  config: {
    'assetName': 'Avatar/Remote',
    'modelKey': 'uploaded-test-44',
    'approvedAssetSha256': _avatarSha256,
  },
  remoteModelId: 44,
  modelSource: 'uploaded',
  voiceGender: AvatarVoiceGender.male,
  preferredVoiceSid: AvatarVoiceService.defaultMaleSid,
);

Map<String, dynamic> _mattDescriptor() => {
  'id': 44,
  'modelKey': BundledAvatarContract.mattModelKey,
  'displayName': 'Matt',
  'modelSource': 'official',
  'assetUrl': BundledAvatarContract.mattAssetUrl,
  'assetSha256': BundledAvatarContract.mattAssetSha256,
  'runtimeConfig': BundledAvatarContract.mattRuntimeConfig,
  'compatibility': {
    'backends': ['unity'],
  },
};
AvatarOption _mattOption() =>
    ApprovedAvatarModel.fromJson(_mattDescriptor()).toAvatarOption();
