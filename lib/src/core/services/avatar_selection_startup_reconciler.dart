import 'dart:async';

import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';

typedef AvatarSelectionReviewedCatalogLoader =
    Future<List<ApprovedAvatarModel>> Function();

enum AvatarSelectionStartupState { ready, readOnlyBundled }

/// The sanitized outcome of account-scoped Avatar startup reconciliation.
///
/// Network payloads, model URLs, account identifiers, and storage keys are
/// deliberately absent so callers can safely emit this result as telemetry.
final class AvatarSelectionStartupResult {
  const AvatarSelectionStartupResult({
    required this.state,
    required this.catalogSize,
    required this.serverClearCommitted,
    this.recoveryOutcome,
    this.contractErrorCode,
  });

  final AvatarSelectionStartupState state;
  final int catalogSize;
  final bool serverClearCommitted;
  final AvatarSelectionRecoveryOutcome? recoveryOutcome;
  final String? contractErrorCode;
}

/// Reconciles one mounted account's durable Avatar selection before it can be
/// treated as locally committed.
///
/// Durable recovery callbacks load the reviewed catalog and complete the local
/// renderer/preference phase before the coordinator is allowed to clear its
/// outbox. The mount guard is checked around every asynchronous boundary so a
/// late old-account result cannot affect a replacement account runtime.
final class AvatarSelectionStartupReconciler {
  AvatarSelectionStartupReconciler({
    required AvatarSelectionCoordinator coordinator,
    required AvatarConfigService config,
    required AvatarSelectionReviewedCatalogLoader loadReviewedCatalog,
    required AvatarSelectionAssetOptions assetOptions,
    required void Function() requireCurrentMount,
  }) : _coordinator = coordinator,
       _config = config,
       _loadReviewedCatalog = loadReviewedCatalog,
       _assetOptions = assetOptions,
       _requireCurrentMount = requireCurrentMount;

  final AvatarSelectionCoordinator _coordinator;
  final AvatarConfigService _config;
  final AvatarSelectionReviewedCatalogLoader _loadReviewedCatalog;
  final AvatarSelectionAssetOptions _assetOptions;
  final void Function() _requireCurrentMount;

  Future<AvatarSelectionStartupResult> reconcile() async {
    _requireCurrentMount();
    _config.beginAuthoritativeSelectionStartup();
    // Remove a device-global remote renderer left by another account before
    // any account-scoped network result can arrive.
    await _config.previewBundledFallback();
    _requireCurrentMount();

    var catalogLoaded = false;
    var catalogSize = 0;
    var localReconciled = false;
    var serverClearRequired = false;

    Future<void> ensureCatalog() async {
      if (catalogLoaded) return;
      _requireCurrentMount();
      final reviewed = await _loadReviewedCatalog();
      _requireCurrentMount();
      final loadable = reviewed
          .where((model) => model.isLoadableOnDevice)
          .toList(growable: false);
      _config.replaceReviewedOptions(
        loadable.map((model) => model.toAvatarOption()),
        restorePersistedSelection: false,
      );
      catalogSize = loadable.length;
      catalogLoaded = true;
    }

    Future<void> applyAuthoritative(
      AvatarSelectionSnapshot snapshot, {
      required bool fallbackToBundled,
    }) async {
      await ensureCatalog();
      _requireCurrentMount();
      final result = await _config.reconcileAuthoritative(
        snapshot,
        fallbackToBundled: fallbackToBundled,
      );
      _requireCurrentMount();
      localReconciled = true;
      serverClearRequired = serverClearRequired || result.serverClearRequired;
    }

    Future<void> previewBundled() async {
      _requireCurrentMount();
      await _config.previewBundledFallback();
      _requireCurrentMount();
    }

    final local = AvatarSelectionLocalPhases(
      preview: previewBundled,
      commit: (snapshot) =>
          applyAuthoritative(snapshot, fallbackToBundled: false),
      restore: (snapshot) =>
          applyAuthoritative(snapshot, fallbackToBundled: true),
    );

    try {
      final recovery = await _coordinator.recover(
        assetOptions: _assetOptions,
        decide: (entry) async {
          if (entry.resolution == AvatarSelectionOutboxResolution.compensate) {
            return AvatarSelectionRecoveryResolution.compensate;
          }
          final receipt = entry.appliedReceipt;
          if (receipt == null) {
            return AvatarSelectionRecoveryResolution.compensate;
          }
          final applied = AvatarSelectionSnapshot(
            selection: receipt.selection,
            asset: receipt.asset,
            selectionAvailable: receipt.selectionAvailable,
          );
          if (applied.selection.modelId == null ||
              applied.asset.isRetiredOfficial) {
            // Finish a proven historical receipt locally on Joy, then clear
            // the current server head with CAS. Compensation could otherwise
            // replay another retired model from the previous selection.
            return AvatarSelectionRecoveryResolution.rollForward;
          }
          await ensureCatalog();
          _requireCurrentMount();
          return _config.canReconcileAuthoritative(applied)
              ? AvatarSelectionRecoveryResolution.rollForward
              : AvatarSelectionRecoveryResolution.compensate;
        },
        local: local,
      );

      await ensureCatalog();
      if (!localReconciled) {
        await applyAuthoritative(recovery.current, fallbackToBundled: true);
      }

      var serverClearCommitted = false;
      if (serverClearRequired && recovery.current.selection.modelId != null) {
        for (var attempt = 0; attempt < 2; attempt += 1) {
          _requireCurrentMount();
          try {
            await _coordinator.commit(
              modelId: null,
              assetOptions: _assetOptions,
              local: local,
            );
            _requireCurrentMount();
            serverClearCommitted = true;
            break;
          } on AvatarSelectionVersionChangedException catch (error) {
            _requireCurrentMount();
            await ensureCatalog();
            final currentIsSafe =
                error.currentSelection.selection.modelId == null ||
                _config.canReconcileAuthoritative(error.currentSelection);
            if (currentIsSafe) {
              // The coordinator already restored this current snapshot before
              // surfacing the CAS conflict. It belongs to a newer writer and
              // must not be cleared by this startup pass.
              break;
            }
            if (attempt == 1) rethrow;
          }
        }
      }

      _config.markAuthoritativeSelectionReady();

      return AvatarSelectionStartupResult(
        state: AvatarSelectionStartupState.ready,
        catalogSize: catalogSize,
        serverClearCommitted: serverClearCommitted,
        recoveryOutcome: recovery.outcome,
      );
    } on Object catch (error) {
      final contractError = _contractUnavailable(error);
      if (contractError == null) rethrow;
      // V2 selection is fail-closed across GET, replay, and required clear.
      // The reviewed catalog remains useful for a read-only picker, while any
      // ambiguous durable outbox obligation remains untouched for recovery.
      _config.markAuthoritativeSelectionReadOnly();
      await ensureCatalog();
      await previewBundled();
      return AvatarSelectionStartupResult(
        state: AvatarSelectionStartupState.readOnlyBundled,
        catalogSize: catalogSize,
        serverClearCommitted: false,
        contractErrorCode: contractError.code,
      );
    }
  }
}

AvatarSelectionContractUnavailableException? _contractUnavailable(
  Object error,
) {
  if (error is AvatarSelectionContractUnavailableException) return error;
  if (error is AvatarSelectionAmbiguousTransportException &&
      error.cause is AvatarSelectionContractUnavailableException) {
    return error.cause! as AvatarSelectionContractUnavailableException;
  }
  return null;
}
