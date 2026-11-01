import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/account_runtime_discovery_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';

/// Owns the resources created for one mounted account runtime.
///
/// [close] must be retry-safe. The storage generation is fenced before close
/// starts; a failure retains this lease as a hard gate so a different account
/// or environment cannot replace a runtime that has not finished shutting
/// down.
abstract interface class AccountRuntimeLease {
  Future<void> close();
}

/// Reports that account graph construction failed and its rollback still owns
/// resources that must be closed before another account can mount.
final class AccountRuntimeMountFailure implements Exception {
  const AccountRuntimeMountFailure({
    required this.cause,
    required this.causeStackTrace,
    required this.cleanupLease,
    required this.cleanupError,
    required this.cleanupStackTrace,
  });

  final Object cause;
  final StackTrace causeStackTrace;
  final AccountRuntimeLease cleanupLease;
  final Object cleanupError;
  final StackTrace cleanupStackTrace;

  @override
  String toString() => 'Account runtime mount rollback did not finish.';
}

/// Reports independent failures from both account teardown stages.
///
/// The retained teardown lease remembers which stages completed, so a retry
/// runs only the failed projection cleanup and/or runtime close operation.
final class AccountRuntimeTeardownFailure implements Exception {
  const AccountRuntimeTeardownFailure({
    required this.projectionError,
    required this.projectionStackTrace,
    required this.runtimeError,
    required this.runtimeStackTrace,
  });

  final Object projectionError;
  final StackTrace projectionStackTrace;
  final Object runtimeError;
  final StackTrace runtimeStackTrace;

  @override
  String toString() =>
      'Account runtime teardown failed while clearing the session projection '
      '($projectionError) and closing the runtime ($runtimeError).';
}

final class _AccountRuntimeTeardownLease implements AccountRuntimeLease {
  _AccountRuntimeTeardownLease({
    required Future<void> Function() unpublishSession,
    AccountRuntimeLease? runtime,
    Future<void> Function()? releaseRemoteLease,
    bool projectionAlreadyCleared = false,
  }) : _unpublishSession = unpublishSession,
       _runtime = runtime,
       _releaseRemoteLease = releaseRemoteLease,
       _projectionCleared = projectionAlreadyCleared;

  final Future<void> Function() _unpublishSession;
  final AccountRuntimeLease? _runtime;
  final Future<void> Function()? _releaseRemoteLease;
  bool _projectionCleared;
  bool _runtimeClosed = false;
  bool _remoteLeaseReleased = false;
  Future<void>? _inFlight;

  @override
  Future<void> close() => _inFlight ??= _closeOnce();

  Future<void> _closeOnce() async {
    try {
      Object? projectionError;
      StackTrace? projectionStackTrace;
      if (!_projectionCleared) {
        try {
          await _unpublishSession();
          _projectionCleared = true;
        } catch (error, stackTrace) {
          projectionError = error;
          projectionStackTrace = stackTrace;
        }
      }

      Object? runtimeError;
      StackTrace? runtimeStackTrace;
      if (!_runtimeClosed) {
        try {
          await _runtime?.close();
          _runtimeClosed = true;
        } catch (error, stackTrace) {
          runtimeError = error;
          runtimeStackTrace = stackTrace;
        }
      }

      if (projectionError != null && runtimeError != null) {
        final failure = AccountRuntimeTeardownFailure(
          projectionError: projectionError,
          projectionStackTrace: projectionStackTrace!,
          runtimeError: runtimeError,
          runtimeStackTrace: runtimeStackTrace!,
        );
        Error.throwWithStackTrace(failure, runtimeStackTrace);
      }
      if (projectionError != null) {
        Error.throwWithStackTrace(projectionError, projectionStackTrace!);
      }
      if (runtimeError != null) {
        Error.throwWithStackTrace(runtimeError, runtimeStackTrace!);
      }

      // Remote authority is relinquished only after both local teardown
      // stages have completed. A failed local close deliberately keeps the
      // exact remote lease for this retry-safe teardown lease.
      if (!_remoteLeaseReleased) {
        await _releaseRemoteLease?.call();
        _remoteLeaseReleased = true;
      }
    } finally {
      _inFlight = null;
    }
  }
}

final class _AccountRuntimeMountAuthorityAttempt {
  _AccountRuntimeMountAuthorityAttempt(this.receipt);

  final AccountDeviceLeaseReceipt receipt;
  AccountStorageScopeMount? mount;
  Timer? watchdog;
  Object? failure;
  bool sessionPublished = false;
  bool fenced = false;
  bool committed = false;
}

final class _AccountRuntimeRepublishAuthorityAttempt {
  _AccountRuntimeRepublishAuthorityAttempt({
    required this.receipt,
    required this.mount,
  });

  AccountDeviceLeaseReceipt receipt;
  final AccountStorageScopeMount mount;
  final Completer<void> operationSettled = Completer<void>();
  Timer? watchdog;
  Object? failure;
  bool fenced = false;
  bool completed = false;
}

final class _AccountRuntimeRepublishTeardownLease
    implements AccountRuntimeLease {
  _AccountRuntimeRepublishTeardownLease({
    required Future<void> operationSettled,
    required AccountRuntimeLease runtime,
  }) : _operationSettled = operationSettled,
       _runtime = runtime;

  final Future<void> _operationSettled;
  final AccountRuntimeLease _runtime;
  Future<void>? _inFlight;

  @override
  Future<void> close() => _inFlight ??= _closeOnce();

  Future<void> _closeOnce() async {
    try {
      await _operationSettled;
      await _runtime.close();
    } finally {
      _inFlight = null;
    }
  }
}

final class _RuntimeAuthorityPolicyRequestAnchor {
  const _RuntimeAuthorityPolicyRequestAnchor({
    required this.wallDispatchedAt,
    required this.monotonicDispatchedAt,
  });

  final DateTime wallDispatchedAt;
  final Duration monotonicDispatchedAt;
}

final class _ValidatedRuntimeAuthorityPolicy {
  const _ValidatedRuntimeAuthorityPolicy({
    required this.policy,
    required this.deadline,
    required this.pollDeadline,
  });

  final AccountRuntimeAuthorityPolicy policy;
  final Duration deadline;
  final Duration pollDeadline;
}

final class _AccountRuntimePolicyAdmissionAttempt {
  _AccountRuntimePolicyAdmissionAttempt({
    required this.scope,
    required this.revision,
    required this.deadline,
    required this.workerGeneration,
  });

  final AccountStorageScope scope;
  final int revision;
  final Duration deadline;
  final int workerGeneration;
  Object? failure;
  bool fenced = false;
}

final Stopwatch _runtimeAuthorityPolicyMonotonicClock = Stopwatch()..start();

/// Builds a fully ready runtime for [mount].
///
/// If the callback throws before returning a lease, it owns rollback of every
/// partially-created resource. Once a lease is returned, the lifecycle service
/// owns it and always awaits [AccountRuntimeLease.close] before another scope
/// can mount.
typedef AccountRuntimeMountCallback =
    Future<AccountRuntimeLease> Function(AccountStorageScopeMount mount);

/// Publishes the exact account authority before [AccountRuntimeMountCallback]
/// is allowed to construct account-owned services.
///
/// Consumers must project only derived identifiers such as
/// [AccountStorageScope.accountDigest], never the raw account UUID.
typedef AccountRuntimeBoundaryActivateCallback =
    void Function(AccountStorageScopeMount mount);

/// Revokes a previously published account authority.
///
/// The callback receives the retired storage generation so the projection can
/// reject a late cleanup from an older account instead of clearing a newer
/// account's authority.
typedef AccountRuntimeBoundaryRetireCallback =
    void Function(int accountGeneration);

/// Starts account-runtime retirement synchronously and returns its drain.
///
/// Production injects [AgentRuntimeRegistry.shutdown]. Calling that method
/// flips the registry's admission fence before its returned Future is awaited.
typedef AccountRuntimeFenceCallback = Future<void> Function();

/// Creates the deadline watchdog that protects the acquire-to-mount gap.
///
/// Tests inject a manual timer so a monotonic lease deadline can be crossed
/// without waiting on wall-clock time.
typedef AccountRuntimeAuthorityWatchdogFactory =
    Timer Function(Duration delay, void Function() callback);

enum AccountRuntimeRole { companion, owner }

enum AccountSessionLifecyclePhase {
  signedOut,
  restoring,
  authenticating,
  authenticatedStandby,
  acquiringLease,
  leaseConflict,
  verificationRequired,
  switchingEnvironment,
  mounting,
  mounted,
  retiring,
  unmounting,
  faulted,
  closed,
}

/// Serializes authentication, environment, and account-runtime boundaries.
///
/// This service intentionally does not decide which concrete DB, memory,
/// avatar, or Agent services belong to an account. The injected
/// [mountRuntime] callback builds that graph and returns its async disposal
/// lease. The storage mount is published only for the lifetime of that lease.
class AccountSessionLifecycleService extends AppService implements Listenable {
  AccountSessionLifecycleService({
    required AuthSessionService auth,
    required AppEnvironmentService environment,
    required AccountRuntimeMountCallback mountRuntime,
    AccountRuntimeMountCallback? mountCompanionRuntime,
    AccountRuntimeBoundaryActivateCallback? activateRuntimeBoundary,
    AccountRuntimeBoundaryRetireCallback? retireRuntimeBoundary,
    AccountStorageScopeService? storageScopes,
    AccountDeviceLeaseCoordinator? deviceLeaseCoordinator,
    AccountRuntimeAuthorityPolicyGateway? authorityPolicyGateway,
    AccountRuntimeDiscoveryService? runtimeDiscovery,
    AccountRuntimeAuthorityMode authorityCompileMaximum =
        AccountRuntimeAuthorityMode.off,
    bool requireExclusiveDeviceLease = false,
    AccountRuntimeFenceCallback? fenceRuntime,
    AccountRuntimeAuthorityWatchdogFactory? authorityWatchdogFactory,
    AccountRuntimeAuthorityWatchdogFactory? policyWatchdogFactory,
    AccountRuntimeAuthorityWatchdogFactory? shadowWatchdogFactory,
    AccountRuntimeAuthorityWatchdogFactory? recoveryWatchdogFactory,
    DateTime Function()? policyWallClock,
    Duration Function()? policyMonotonicNow,
    Duration maximumPolicyTtl = const Duration(days: 1),
    Duration policySafetyMargin = const Duration(milliseconds: 500),
    String deviceLabel = 'Maaso device',
    String devicePlatform = 'unknown',
    String appVersion = '',
  }) : _auth = auth,
       _environment = environment,
       _mountRuntime = mountRuntime,
       _mountCompanionRuntime = mountCompanionRuntime,
       _activateRuntimeBoundary = activateRuntimeBoundary,
       _retireRuntimeBoundary = retireRuntimeBoundary,
       _storageScopes = storageScopes ?? AccountStorageScopeService(),
       _deviceLeaseCoordinator = deviceLeaseCoordinator,
       _authorityPolicyGateway = authorityPolicyGateway,
       _runtimeDiscovery = runtimeDiscovery,
       _authorityCompileMaximum = authorityCompileMaximum,
       _requireExclusiveDeviceLease = requireExclusiveDeviceLease,
       _fenceRuntime = fenceRuntime,
       _authorityWatchdogFactory = authorityWatchdogFactory ?? Timer.new,
       _policyWatchdogFactory = policyWatchdogFactory ?? Timer.new,
       _shadowWatchdogFactory = shadowWatchdogFactory ?? Timer.new,
       _recoveryWatchdogFactory = recoveryWatchdogFactory ?? Timer.new,
       _policyWallClock = policyWallClock ?? DateTime.now,
       _policyMonotonicNow =
           policyMonotonicNow ??
           (() => _runtimeAuthorityPolicyMonotonicClock.elapsed),
       _maximumPolicyTtl = maximumPolicyTtl,
       _policySafetyMargin = policySafetyMargin,
       _deviceLabel = deviceLabel,
       _devicePlatform = devicePlatform,
       _appVersion = appVersion {
    if (_mountCompanionRuntime != null && !_requireExclusiveDeviceLease) {
      throw ArgumentError(
        'Companion mounting requires exclusive Agent execution leases.',
      );
    }
    if ((_activateRuntimeBoundary == null) !=
        (_retireRuntimeBoundary == null)) {
      throw ArgumentError(
        'Account runtime boundary activation and retirement callbacks must '
        'be provided together.',
      );
    }
    if ((_requireExclusiveDeviceLease ||
            _authorityCompileMaximum != AccountRuntimeAuthorityMode.off) &&
        (_deviceLeaseCoordinator == null || _authorityPolicyGateway == null)) {
      throw ArgumentError(
        'Runtime authority rollout requires both policy and lease gateways.',
      );
    }
    if (_maximumPolicyTtl <= Duration.zero ||
        _maximumPolicyTtl > AccountRuntimeAuthorityPolicy.maximumRemainingTtl) {
      throw ArgumentError.value(
        _maximumPolicyTtl,
        'maximumPolicyTtl',
        'must be positive and at most one day',
      );
    }
    if (_policySafetyMargin.isNegative ||
        _policySafetyMargin >= _maximumPolicyTtl) {
      throw ArgumentError.value(
        _policySafetyMargin,
        'policySafetyMargin',
        'must be non-negative and below maximumPolicyTtl',
      );
    }
    _previousBeforeCredentialsCleared = _auth.beforeCredentialsCleared;
    _credentialsClearHook = () async {
      await _beforeCredentialsCleared();
      await _previousBeforeCredentialsCleared?.call();
    };
    _auth.beforeCredentialsCleared = _credentialsClearHook;
    _previousCredentialCleanupFailureObserver =
        _auth.credentialCleanupFailureObserver;
    _credentialCleanupFailureObserver = (failure) async {
      final observedGeneration = generation;
      final retained = await _handleCredentialCleanupFailure(
        failure,
        observedGeneration: observedGeneration,
      );
      if (retained) {
        await _previousCredentialCleanupFailureObserver?.call(failure);
      }
    };
    _auth.credentialCleanupFailureObserver = _credentialCleanupFailureObserver;
    _phaseWorker = phase.listen((_) {
      _maintainExclusivePresenceForPhase();
      _phaseChanges.emit();
    });
  }

  final AuthSessionService _auth;
  final AppEnvironmentService _environment;
  final AccountRuntimeMountCallback _mountRuntime;
  final AccountRuntimeMountCallback? _mountCompanionRuntime;
  final AccountRuntimeBoundaryActivateCallback? _activateRuntimeBoundary;
  final AccountRuntimeBoundaryRetireCallback? _retireRuntimeBoundary;
  final AccountStorageScopeService _storageScopes;
  final AccountDeviceLeaseCoordinator? _deviceLeaseCoordinator;
  final AccountRuntimeAuthorityPolicyGateway? _authorityPolicyGateway;
  final AccountRuntimeDiscoveryService? _runtimeDiscovery;
  final AccountRuntimeAuthorityMode _authorityCompileMaximum;
  final bool _requireExclusiveDeviceLease;
  final AccountRuntimeFenceCallback? _fenceRuntime;
  final AccountRuntimeAuthorityWatchdogFactory _authorityWatchdogFactory;
  final AccountRuntimeAuthorityWatchdogFactory _policyWatchdogFactory;
  final AccountRuntimeAuthorityWatchdogFactory _shadowWatchdogFactory;
  final AccountRuntimeAuthorityWatchdogFactory _recoveryWatchdogFactory;
  final DateTime Function() _policyWallClock;
  final Duration Function() _policyMonotonicNow;
  final Duration _maximumPolicyTtl;
  final Duration _policySafetyMargin;
  final String _deviceLabel;
  final String _devicePlatform;
  final String _appVersion;

  late final Future<void> Function() _credentialsClearHook;
  Future<void> Function()? _previousBeforeCredentialsCleared;
  late final Future<void> Function(AuthCredentialCleanupFailure)
  _credentialCleanupFailureObserver;
  Future<void> Function(AuthCredentialCleanupFailure)?
  _previousCredentialCleanupFailureObserver;
  Future<void> _operationTail = Future<void>.value();
  AccountStorageScopeMount? _activeMount;
  int? _activeRuntimeBoundaryGeneration;
  AccountRuntimeLease? _runtimeLease;
  AccountRuntimeLease? _companionRuntimeLease;
  AccountRuntimeLease? _closingOwnerLease;
  bool _ownerActivationInProgress = false;
  bool _companionCredentialsRejected = false;
  AccountRuntimeLease? _closingLease;
  _AccountRuntimeTeardownLease? _retainedPolicyAdmissionCleanupLease;
  Future<void>? _closingDrain;
  AccountStorageScope? _remoteScope;
  AccountDeviceLeaseReceipt? _activeDeviceLease;
  AccountDeviceLeaseConflict? _leaseConflict;
  _AccountRuntimePolicyAdmissionAttempt? _policyAdmissionAttempt;
  _AccountRuntimeMountAuthorityAttempt? _mountAuthorityAttempt;
  _AccountRuntimeRepublishAuthorityAttempt? _republishAuthorityAttempt;
  Timer? _leaseHeartbeatTimer;
  Timer? _activeLeaseWatchdog;
  Timer? _policyPollTimer;
  Timer? _policyExpiryTimer;
  Future<void>? _policyRefreshInFlight;
  int? _policyRefreshGeneration;
  int _leaseWorkerGeneration = 0;
  int _policyWorkerGeneration = 0;
  AccountStorageScope? _policyScope;
  MaasoEnvironment? _policyEnvironment;
  AccountRuntimeAuthorityPolicy? _policy;
  Duration? _policyDeadline;
  AccountRuntimeAuthorityMode _effectiveAuthorityMode =
      AccountRuntimeAuthorityMode.off;
  bool _enforcementActivated = false;
  int _shadowWorkerGeneration = 0;
  Future<void>? _shadowObservation;
  Timer? _shadowHeartbeatTimer;
  Timer? _presenceRecoveryTimer;
  Future<bool>? _presenceRecoveryOperation;
  bool Function()? _companionRecoveryIsCurrent;
  Future<void>? _applicationExitOperation;
  bool _applicationForeground = false;
  bool _applicationExitRequested = false;
  bool _handoffInProgress = false;
  bool _presenceRecoveryInProgress = false;
  AccountDeviceLeaseHolder? _observedRemoteHolder;
  AccountStorageScope? _observedRemoteScope;
  Duration? _observedRemoteDeadline;
  bool _shadowPresenceOwnedByObservation = false;
  bool _signOutOwnsUnmountBoundary = false;
  bool _credentialCleanupRetryPending = false;
  bool _credentialCleanupIsAuthenticationSupersedable = false;
  bool _closed = false;
  final _AccountSessionPhaseNotifier _phaseChanges =
      _AccountSessionPhaseNotifier();
  late final Worker _phaseWorker;

  final phase = AccountSessionLifecyclePhase.signedOut.obs;
  final error = Rxn<Object>();

  bool get isMounted => hasCompanionRuntime
      ? !_companionCredentialsRejected &&
            phase.value != AccountSessionLifecyclePhase.retiring &&
            phase.value != AccountSessionLifecyclePhase.faulted
      : phase.value == AccountSessionLifecyclePhase.mounted &&
            _runtimeLease != null;

  /// The account/page graph remains mounted when execution moves elsewhere.
  bool get hasCompanionRuntime =>
      !_closed &&
      _companionRuntimeLease != null &&
      _activeMount != null &&
      _storageScopes.isCurrent(_activeMount!);

  AccountRuntimeRole? get runtimeRole => !isMounted
      ? null
      : hasCompanionRuntime && _runtimeLease == null
      ? AccountRuntimeRole.companion
      : AccountRuntimeRole.owner;

  /// Allows shared execution to initialize its fenced host before publishing
  /// the owner role. Local user turns use [canChatLocally] independently.
  bool get ownerActivationInProgress =>
      _ownerActivationInProgress &&
      !_closed &&
      _mountAuthorityAttempt?.fenced == false &&
      _deviceLeaseCoordinator?.canAdmitMutations == true;

  /// Device exclusivity is independent of the RTC authority rollout mode.
  bool get usesExclusiveDeviceLease =>
      _requireExclusiveDeviceLease ||
      _effectiveAuthorityMode == AccountRuntimeAuthorityMode.enforce;

  /// Each mounted account owns its local presentation independently of the
  /// execution lease. Account retirement still closes the local display.
  bool get canPresentAvatar => isMounted;

  /// A mounted device owns its local dialogue, voice and creation runtime.
  /// Shared account mutations retain their independent execution lease below.
  bool get canChatLocally => isMounted;

  /// Lease authority for shared execution such as RTC and proactive tasks.
  /// This does not control local dialogue or Avatar presentation.
  bool get canExecuteAgent {
    if (!isMounted || (hasCompanionRuntime && _runtimeLease == null)) {
      return false;
    }
    if (!usesExclusiveDeviceLease) return true;
    final coordinator = _deviceLeaseCoordinator;
    final expected = _activeDeviceLease;
    final current = coordinator?.currentReceipt;
    return coordinator?.canAdmitMutations == true &&
        expected != null &&
        current != null &&
        _sameLeaseAuthority(expected, current);
  }

  bool get isFaulted => phase.value == AccountSessionLifecyclePhase.faulted;

  bool get hasAuthenticatedCandidate {
    final candidate = _auth.candidate;
    return candidate != null && candidate.session.isValid;
  }

  bool get requiresStandbyRoute =>
      !_companionCredentialsRejected &&
      (_requireExclusiveDeviceLease ||
          (_authorityCompileMaximum == AccountRuntimeAuthorityMode.enforce &&
              (_enforcementActivated ||
                  _effectiveAuthorityMode ==
                      AccountRuntimeAuthorityMode.enforce ||
                  phase.value ==
                      AccountSessionLifecyclePhase.verificationRequired ||
                  phase.value ==
                      AccountSessionLifecyclePhase.leaseConflict))) &&
      !isMounted &&
      hasAuthenticatedCandidate &&
      phase.value != AccountSessionLifecyclePhase.signedOut &&
      phase.value != AccountSessionLifecyclePhase.closed;

  AccountDeviceLeaseConflict? get leaseConflict => _leaseConflict;

  bool get presenceRecoveryInProgress => _presenceRecoveryInProgress;

  /// Display-only evidence. A lost local receipt is not evidence of a remote
  /// owner, and another process on this installation is not another device.
  AccountDeviceLeaseHolder? get canonicalRemoteHolder {
    final holder = _observedRemoteHolder;
    final deadline = _observedRemoteDeadline;
    final localInstallation =
        _deviceLeaseCoordinator?.currentPresence?.installationId ??
        _activeDeviceLease?.installationId;
    if (canExecuteAgent ||
        holder == null ||
        localInstallation == null ||
        holder.installationId == localInstallation ||
        _observedRemoteScope != activeScope ||
        deadline == null ||
        _policyMonotonicNow() >= deadline) {
      return null;
    }
    return holder;
  }

  AccountDeviceLeaseReceipt? get activeDeviceLease => _activeDeviceLease;

  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      _effectiveAuthorityMode;

  bool get enforcementActivated => _enforcementActivated;

  int get generation => _storageScopes.generation;

  AccountStorageScope? get activeScope =>
      isMounted ? _activeMount?.scope : null;

  AccountStorageScopeMount? get activeMount => isMounted ? _activeMount : null;

  AccountStorageScopeService get storageScopes => _storageScopes;

  @override
  void addListener(VoidCallback listener) =>
      _phaseChanges.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _phaseChanges.removeListener(listener);

  /// Restores the current environment's credentials and mounts only after a
  /// valid, account-addressable session has been established.
  Future<bool> restoreAndMount() => _runSerialized(() async {
    await _unmountLocked();
    phase.value = AccountSessionLifecyclePhase.restoring;
    try {
      if (!await _auth.restoreCandidate()) {
        phase.value = AccountSessionLifecyclePhase.signedOut;
        return false;
      }
      return _mountCurrentSessionLocked();
    } catch (exception) {
      error.value = exception;
      if (exception is AuthCredentialCleanupFailure &&
          _auth.isCredentialCleanupFailureCurrent(exception)) {
        _retainCredentialCleanupFailure(exception);
      }
      if (!isFaulted && !requiresStandbyRoute) {
        phase.value = AccountSessionLifecyclePhase.signedOut;
      }
      rethrow;
    }
  });

  /// Runs one login/signup operation between account-runtime boundaries.
  Future<bool> authenticateAndMount(Future<void> Function() authenticate) =>
      _runSerialized(() async {
        final supersedingCredentialOnlyCleanup =
            _credentialCleanupRetryPending &&
            _credentialCleanupIsAuthenticationSupersedable &&
            _closingLease != null &&
            _closingDrain == null &&
            _runtimeLease == null &&
            _activeMount == null &&
            _activeDeviceLease == null &&
            _remoteScope == null &&
            _deviceLeaseCoordinator?.currentReceipt == null &&
            _deviceLeaseCoordinator?.currentPresence == null &&
            _deviceLeaseCoordinator?.hasPendingAcquire != true;
        if (!supersedingCredentialOnlyCleanup) {
          await _unmountLocked();
        }
        // Authentication may replace the account candidate. Close the old
        // account's exact presence while its credentials are still current so
        // the coordinator cannot carry that scope into the new account.
        await _closeRemotePresenceLocked();
        phase.value = AccountSessionLifecyclePhase.authenticating;
        try {
          await authenticate();
          if (supersedingCredentialOnlyCleanup) {
            // A fully committed fresh login atomically clears the old logout
            // fence and AuthSessionService retry lease. Retire the lifecycle's
            // now-obsolete credential-only fault before mounting the account.
            await _unmountLocked();
          }
          return _mountCurrentSessionLocked();
        } catch (exception) {
          error.value = exception;
          if (exception is AuthCredentialCleanupFailure &&
              _auth.isCredentialCleanupFailureCurrent(exception)) {
            _retainCredentialCleanupFailure(exception);
          }
          if (supersedingCredentialOnlyCleanup &&
              _credentialCleanupRetryPending &&
              _closingLease != null) {
            // Failed authentication must not erase or disguise the original
            // fail-closed credential cleanup. A corrected login may retry.
            phase.value = AccountSessionLifecyclePhase.faulted;
          } else if (!isFaulted && !requiresStandbyRoute) {
            phase.value = AccountSessionLifecyclePhase.signedOut;
          }
          rethrow;
        }
      });

  /// Changes the backend environment without implicitly entering a stored
  /// session from the target environment.
  ///
  /// Callers on the login surface stay on that surface until an explicit
  /// authentication operation mounts the account runtime.
  Future<void> switchEnvironment(MaasoEnvironment next) =>
      _runSerialized(() async {
        await _unmountLocked();
        _cancelPolicyWatchdogs(clearPolicy: true);
        await _closeRemotePresenceLocked();
        phase.value = AccountSessionLifecyclePhase.switchingEnvironment;
        try {
          await _environment.setEnvironment(next);
          // Load (but do not publish) the target environment's durable
          // candidate. A later explicit login/restore operation decides
          // whether that candidate may mount.
          await _auth.activateCurrentEnvironment();
          phase.value = AccountSessionLifecyclePhase.signedOut;
        } catch (exception) {
          error.value = exception;
          if (exception is AuthCredentialCleanupFailure &&
              _auth.isCredentialCleanupFailureCurrent(exception)) {
            _retainCredentialCleanupFailure(exception);
          } else {
            phase.value = AccountSessionLifecyclePhase.signedOut;
          }
          rethrow;
        }
      });

  Future<bool> mountCurrentSession() =>
      _runSerialized(_mountCurrentSessionLocked);

  /// The app shell supplies visibility independently of avatar visibility.
  /// A hidden avatar must not prevent the account from recovering its lease.
  void updateApplicationPresence({
    required bool foreground,
    bool handoffInProgress = false,
  }) {
    if (_closed || _applicationExitRequested) return;
    final resumed = foreground && !_applicationForeground;
    final handoffFinished = _handoffInProgress && !handoffInProgress;
    _applicationForeground = foreground;
    _handoffInProgress = handoffInProgress;
    if (!foreground || handoffInProgress) {
      _presenceRecoveryTimer?.cancel();
      _presenceRecoveryTimer = null;
      return;
    }
    if (resumed && canExecuteAgent) {
      // Refresh promptly after suspension; the old watchdog may still be
      // queued, so all checks continue to use the monotonic lease deadline.
      unawaited(
        _runSerialized(() async {
              if (!_applicationForeground ||
                  _applicationExitRequested ||
                  _handoffInProgress ||
                  !hasCompanionRuntime) {
                return;
              }
              if (_runtimeLease != null) {
                await _heartbeatRemoteLeaseLocked(_leaseWorkerGeneration);
              }
            })
            .whenComplete(() {
              _schedulePresenceRecovery(immediate: true);
            })
            .catchError((Object _, StackTrace _) {}),
      );
    }
    _schedulePresenceRecovery(immediate: resumed || handoffFinished);
  }

  bool get _canAutomaticallyRecover =>
      !_closed &&
      !_applicationExitRequested &&
      _applicationForeground &&
      !_handoffInProgress &&
      hasCompanionRuntime &&
      isMounted &&
      usesExclusiveDeviceLease &&
      !canExecuteAgent;

  void _schedulePresenceRecovery({bool immediate = false}) {
    if (!_canAutomaticallyRecover) {
      _presenceRecoveryTimer?.cancel();
      _presenceRecoveryTimer = null;
      return;
    }
    if (_presenceRecoveryOperation != null) return;
    if (_presenceRecoveryTimer != null && !immediate) return;
    _presenceRecoveryTimer?.cancel();
    _presenceRecoveryTimer = _recoveryWatchdogFactory(
      immediate ? Duration.zero : const Duration(seconds: 2),
      () {
        _presenceRecoveryTimer = null;
        if (!_canAutomaticallyRecover) return;
        unawaited(
          _recoverCompanionExecution(
            automatic: true,
          ).catchError((Object _, StackTrace _) => false),
        );
      },
    );
  }

  void _rememberRemoteHolder(
    AccountDeviceLeaseHolder? holder,
    Duration remainingTtl, {
    Duration? dispatchedAt,
  }) {
    _observedRemoteHolder = holder;
    _observedRemoteScope = _activeMount?.scope;
    final freshness = remainingTtl < const Duration(seconds: 10)
        ? remainingTtl
        : const Duration(seconds: 10);
    _observedRemoteDeadline = holder == null
        ? null
        : (dispatchedAt ?? _policyMonotonicNow()) + freshness;
  }

  /// Fences synchronously, then drains and releases exactly this runtime's
  /// authority. Credentials remain stored; reopening does not require login.
  Future<void> prepareForApplicationExit() {
    final pending = _applicationExitOperation;
    if (pending != null) return pending;
    if (_closed) return Future<void>.value();
    _applicationExitRequested = true;
    _applicationForeground = false;
    _presenceRecoveryTimer?.cancel();
    _presenceRecoveryTimer = null;
    _deviceLeaseCoordinator?.fence();
    _fenceRuntimeAdmission();
    _stopLeaseHeartbeat();
    _phaseChanges.emit();
    final exitTiming = TurnTrace.stopwatch('presence.exit_release');
    return _applicationExitOperation = _runSerialized(() async {
      try {
        await _unmountLocked();
        await _closeRemotePresenceLocked();
      } finally {
        TurnTrace.done('presence.exit_release', exitTiming);
      }
    });
  }

  /// Call outside a tracked account operation: restoring the owner may drain
  /// that operation boundary. Pending proofs are replayed, never replaced.
  Future<bool> recoverCompanionExecutionIfUnowned() =>
      _recoverCompanionExecution(automatic: false);

  Future<bool> _recoverCompanionExecution({required bool automatic}) {
    final pending = _presenceRecoveryOperation;
    if (pending != null) return pending;
    if (_closed || _applicationExitRequested) return Future.value(false);
    final mount = _activeMount;
    var candidate = _auth.candidate;
    final environment = _environment.environment.value;
    _presenceRecoveryTimer?.cancel();
    _presenceRecoveryTimer = null;
    _presenceRecoveryInProgress = true;
    late final Future<bool> operation;
    operation =
        _runSerialized(() async {
          bool requestIsCurrent({bool requireValidCredentials = true}) {
            final expected = candidate;
            return !_closed &&
                !_applicationExitRequested &&
                !_handoffInProgress &&
                (!automatic || _applicationForeground) &&
                mount != null &&
                expected != null &&
                (!requireValidCredentials || expected.session.isValid) &&
                identical(_auth.candidate, expected) &&
                identical(_activeMount, mount) &&
                _activeRuntimeBoundaryGeneration == mount.generation &&
                _storageScopes.isCurrent(mount) &&
                _environment.environment.value == environment &&
                expected.environment == environment &&
                mount.scope.environmentKey == environment.key &&
                mount.scope.accountUuid ==
                    expected.session.accountUuid.trim() &&
                isMounted;
          }

          if (!requestIsCurrent(requireValidCredentials: false)) return false;
          if (candidate?.session.isValid != true) {
            // A suspended app can outlive its access token as well as its
            // lease. Refresh the published companion session in place; do not
            // activate another account environment or rebuild the chat graph.
            if (!await _auth.restoreOrRefresh()) return false;
            candidate = _auth.candidate;
          }
          if (!requestIsCurrent()) return false;
          if (canExecuteAgent) return true;
          final coordinator = _deviceLeaseCoordinator;
          if (!hasCompanionRuntime ||
              _handoffInProgress ||
              !usesExclusiveDeviceLease ||
              coordinator == null) {
            return false;
          }

          // Resume can run before the expired watchdog. Retire the old host first
          // instead of treating an existing but unusable host as a remote owner.
          if (_runtimeLease != null) {
            coordinator.enforceLocalDeadline();
            _retireCompanionOwnerSynchronously(
              StateError('Restoring expired local Agent execution.'),
            );
          }
          await _drainCompanionOwnerLocked();
          if (!requestIsCurrent()) return false;
          if (coordinator.hasTransferredLeaseAwaitingMount) return false;

          // A prior network failure can leave an exact release to retry. Do not
          // discard its proof or let a canonical active-self view block cleanup.
          final retained = coordinator.currentReceipt;
          if (retained != null) {
            coordinator.fence();
            _closingOwnerLease = _companionOwnerTeardown(null, retained);
            await _drainCompanionOwnerLocked();
            if (!requestIsCurrent()) return false;
          }

          // The server may already have accepted this exact acquire before its
          // response was lost. Only the coordinator's original request/proof can
          // resolve that ambiguity; a device name or installation ID cannot.
          if (coordinator.hasPendingAcquire) {
            return _mountCompanionRecoveryLocked(requestIsCurrent);
          }
          final dispatchedAt = _policyMonotonicNow();
          final snapshot = await coordinator.inspectCurrent(
            environment: environment,
            accountUuid: mount!.scope.accountUuid,
          );
          if (!requestIsCurrent()) return false;
          _rememberRemoteHolder(
            snapshot.lease?.holder,
            snapshot.lease?.remainingTtl ?? Duration.zero,
            dispatchedAt: dispatchedAt,
          );
          if (snapshot.state != AccountDeviceLeaseRemoteState.inactive ||
              snapshot.lease != null) {
            return false;
          }

          return _mountCompanionRecoveryLocked(requestIsCurrent);
        }).whenComplete(() {
          if (identical(_presenceRecoveryOperation, operation)) {
            _presenceRecoveryOperation = null;
            _presenceRecoveryInProgress = false;
            if (!_closed) _phaseChanges.emit();
            _schedulePresenceRecovery();
          }
        });
    _presenceRecoveryOperation = operation;
    _phaseChanges.emit();
    return operation;
  }

  Future<bool> _mountCompanionRecoveryLocked(bool Function() current) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!current()) return false;
      // An inactive snapshot can race a competing device; ordinary acquire
      // still arbitrates ownership on the server.
      _companionRecoveryIsCurrent = current;
      final recoveryTiming = TurnTrace.stopwatch('presence.recovery_mount');
      try {
        await _mountCurrentSessionLocked();
      } finally {
        _companionRecoveryIsCurrent = null;
        TurnTrace.done(
          'presence.recovery_mount',
          recoveryTiming,
          details: 'active=$canExecuteAgent',
        );
      }
      if (!current()) return false;
      if (canExecuteAgent) return true;
      final failure = error.value;
      if (attempt == 0 &&
          failure is AccountDeviceLeaseRequestException &&
          failure.code == 'STALE_RUNTIME_PRESENCE') {
        // This exact rejection proves the stale presence did not acquire.
        // The coordinator cleared it, so retry once with a fresh presence.
        continue;
      }
      if (failure is AccountDeviceLeaseConflict) return false;
      throw failure ?? StateError('Agent execution could not be restored.');
    }
    return false;
  }

  /// Uses the same queue as lease heartbeats so network handoff operations
  /// cannot make a healthy heartbeat fail with "operation already in flight".
  Future<T> serializeDeviceHandoff<T>(Future<T> Function() work) =>
      _runSerialized(work);

  Future<void> quiesceForDeviceHandoff() => _runSerialized(() async {
    if (_runtimeLease == null ||
        !usesExclusiveDeviceLease ||
        _deviceLeaseCoordinator?.canAdmitMutations != true) {
      throw StateError('handoff_requires_active_runtime_authority');
    }
    await _fenceRuntime?.call();
  });

  Future<bool> mountTransferredHandoff() => _runSerialized(() async {
    if (_deviceLeaseCoordinator?.hasTransferredLeaseAwaitingMount != true ||
        _runtimeLease != null) {
      throw StateError('handoff_target_mount_not_admissible');
    }
    await _mountCurrentSessionLocked();
    return canExecuteAgent;
  });

  Future<bool> restoreCancelledHandoff() => _runSerialized(() async {
    if (hasCompanionRuntime) {
      _retireCompanionOwnerSynchronously(
        StateError('Owner execution is being restored.'),
      );
      await _drainCompanionOwnerLocked();
    } else {
      await _unmountLocked();
    }
    await _mountCurrentSessionLocked();
    return canExecuteAgent;
  });

  /// Ends only local Agent execution after a handoff. Account pages remain.
  Future<void> retireAgentExecution() {
    if (_mountCompanionRuntime == null) return unmount();
    return _runSerialized(() async {
      _retireCompanionOwnerSynchronously(
        StateError('Agent execution moved to another device.'),
      );
      await _drainCompanionOwnerLocked();
    });
  }

  Future<void> unmount() => _runSerialized(_unmountLocked);

  /// Retries every retained cleanup stage without requiring a new login.
  Future<void> retryFaultedCleanup() => _runSerialized(_unmountLocked);

  Future<void> signOutAndUnmount({
    AccountStorageScope? expectedScope,
    Future<void> Function()? afterSignOut,
  }) => _runSerialized(() async {
    if (expectedScope != null) {
      final candidate = _auth.candidate;
      final published = _auth.session.value;
      if (_environment.environment.value.key != expectedScope.environmentKey ||
          (candidate != null &&
              (candidate.environment.key != expectedScope.environmentKey ||
                  candidate.session.accountUuid !=
                      expectedScope.accountUuid)) ||
          (published != null &&
              published.accountUuid != expectedScope.accountUuid) ||
          (_activeMount != null && _activeMount!.scope != expectedScope) ||
          (_remoteScope != null && _remoteScope != expectedScope)) {
        throw StateError('The captured account no longer owns this session.');
      }
    }
    Object? teardownError;
    StackTrace? teardownStackTrace;
    try {
      await _unmountLocked();
      await _closeRemotePresenceLocked();
    } catch (exception, stackTrace) {
      teardownError = exception;
      teardownStackTrace = stackTrace;
    }

    Object? signOutError;
    StackTrace? signOutStackTrace;
    try {
      // Clearing credentials is best-effort even when runtime disposal fails.
      // The failed lease remains fenced and retryable through [unmount].
      await _clearCredentialsWithoutReentry();
    } catch (exception, stackTrace) {
      signOutError = exception;
      signOutStackTrace = stackTrace;
    }

    if (teardownError != null && _hasRetainedPolicyAdmissionCleanup) {
      try {
        _abandonRetainedPolicyAdmissionCleanup();
        teardownError = null;
        teardownStackTrace = null;
      } catch (exception, stackTrace) {
        teardownError = exception;
        teardownStackTrace = stackTrace;
      }
    }

    if (signOutError is AuthCredentialCleanupFailure &&
        _auth.isCredentialCleanupFailureCurrent(signOutError)) {
      _retainCredentialCleanupFailure(signOutError);
    }

    if (teardownError != null) {
      error.value = teardownError;
      phase.value = AccountSessionLifecyclePhase.faulted;
      Error.throwWithStackTrace(teardownError, teardownStackTrace!);
    }

    if (signOutError != null) {
      error.value = signOutError;
      final credentialCleanupIsRetryable =
          signOutError is AuthCredentialCleanupFailure &&
          _auth.isCredentialCleanupFailureCurrent(signOutError);
      phase.value = credentialCleanupIsRetryable
          ? AccountSessionLifecyclePhase.faulted
          : AccountSessionLifecyclePhase.signedOut;
      Error.throwWithStackTrace(signOutError, signOutStackTrace!);
    }
    phase.value = AccountSessionLifecyclePhase.signedOut;
    error.value = null;
    // Keep destructive scoped cleanup inside this queue: a later login must
    // wait until every database handle is closed and erasure has finished.
    await afterSignOut?.call();
  });

  Future<void> _clearCredentialsWithoutReentry() async {
    _signOutOwnsUnmountBoundary = true;
    try {
      await _auth.signOut();
    } finally {
      _signOutOwnsUnmountBoundary = false;
    }
  }

  Future<AccountRuntimeAuthorityMode?> _resolveAuthorityModeForMountLocked({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
  }) async {
    if (_policyScope != null &&
        (_policyScope != scope || _policyEnvironment != environment)) {
      // A different-scope runtime has already been synchronously retired by
      // the mount path. Cancel its independent watchdogs before any new-scope
      // policy request is allowed to wait on the network.
      _cancelPolicyWatchdogs(clearPolicy: true);
    }
    if (!_requireExclusiveDeviceLease &&
        _authorityCompileMaximum == AccountRuntimeAuthorityMode.off) {
      _effectiveAuthorityMode = AccountRuntimeAuthorityMode.off;
      return AccountRuntimeAuthorityMode.off;
    }
    if (!_requireExclusiveDeviceLease &&
        _authorityCompileMaximum == AccountRuntimeAuthorityMode.shadow) {
      _startPolicyObservation(environment: environment, scope: scope);
      return AccountRuntimeAuthorityMode.off;
    }

    try {
      final validated = await _fetchValidatedPolicy(
        environment: environment,
        scope: scope,
      );
      if (!_installValidatedPolicy(
        environment: environment,
        scope: scope,
        validated: validated,
      )) {
        return null;
      }
      return _effectiveAuthorityMode;
    } catch (exception) {
      final deadline = _policyDeadline;
      final hasUsableCachedPolicy =
          !_enforcementActivated &&
          _policyScope == scope &&
          _policy != null &&
          deadline != null &&
          _policyMonotonicNow() < deadline;
      if (hasUsableCachedPolicy) return _effectiveAuthorityMode;
      _invalidatePolicyAuthority(exception);
      return null;
    }
  }

  Future<_ValidatedRuntimeAuthorityPolicy> _fetchValidatedPolicy({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
  }) async {
    final anchor = _RuntimeAuthorityPolicyRequestAnchor(
      wallDispatchedAt: _policyWallClock().toUtc(),
      monotonicDispatchedAt: _policyMonotonicNow(),
    );
    final policy = await _authorityPolicyGateway!.fetchRuntimeAuthorityPolicy(
      environment: environment,
      accountUuid: scope.accountUuid,
    );
    return _validatePolicyAtDispatchAnchor(policy, anchor);
  }

  _ValidatedRuntimeAuthorityPolicy _validatePolicyAtDispatchAnchor(
    AccountRuntimeAuthorityPolicy policy,
    _RuntimeAuthorityPolicyRequestAnchor anchor,
  ) {
    var conservativeTtl = policy.remainingTtl;
    final absoluteTtl = policy.expiresAt.difference(anchor.wallDispatchedAt);
    if (absoluteTtl < conservativeTtl) conservativeTtl = absoluteTtl;
    if (_maximumPolicyTtl < conservativeTtl) {
      conservativeTtl = _maximumPolicyTtl;
    }
    final usableTtl = conservativeTtl - _policySafetyMargin;
    final deadline =
        anchor.monotonicDispatchedAt +
        (usableTtl.isNegative ? Duration.zero : usableTtl);
    if (usableTtl <= Duration.zero || _policyMonotonicNow() >= deadline) {
      throw const FormatException(
        'runtime authority policy is already expired locally',
      );
    }
    var pollAfter = policy.pollAfter;
    if (usableTtl < pollAfter) pollAfter = usableTtl;
    return _ValidatedRuntimeAuthorityPolicy(
      policy: policy,
      deadline: deadline,
      pollDeadline: anchor.monotonicDispatchedAt + pollAfter,
    );
  }

  bool _installValidatedPolicy({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required _ValidatedRuntimeAuthorityPolicy validated,
  }) {
    final previousPolicy = _policyScope == scope ? _policy : null;
    if (previousPolicy != null) {
      if (validated.policy.revision < previousPolicy.revision) {
        throw const FormatException(
          'runtime authority policy revision moved backwards',
        );
      }
      if (validated.policy.revision == previousPolicy.revision &&
          !validated.policy.hasSameRevisionContents(previousPolicy)) {
        throw const FormatException(
          'runtime authority policy revision changed stable fields',
        );
      }
    }

    final previousMode = _effectiveAuthorityMode;
    _policyScope = scope;
    _policyEnvironment = environment;
    _policy = validated.policy;
    _policyDeadline = validated.deadline;
    _effectiveAuthorityMode = validated.policy.mode.cappedBy(
      _authorityCompileMaximum,
    );
    _armPolicyWatchdogs(validated);

    if (!_requireExclusiveDeviceLease &&
        previousMode == AccountRuntimeAuthorityMode.shadow &&
        _effectiveAuthorityMode != AccountRuntimeAuthorityMode.shadow) {
      _cancelShadowObservationAndRelease(
        closePresence:
            _effectiveAuthorityMode == AccountRuntimeAuthorityMode.off,
      );
    }

    if (_enforcementActivated &&
        _effectiveAuthorityMode != AccountRuntimeAuthorityMode.enforce) {
      _invalidatePolicyAuthority(
        StateError(
          'Runtime authority policy downgraded after enforce activation.',
        ),
      );
      return false;
    }
    if (_effectiveAuthorityMode == AccountRuntimeAuthorityMode.enforce) {
      _enforcementActivated = true;
      if (_runtimeLease != null &&
          (_activeDeviceLease == null ||
              previousMode != AccountRuntimeAuthorityMode.enforce)) {
        _invalidatePolicyAuthority(
          StateError(
            'Runtime authority enforcement activated for a legacy runtime.',
          ),
        );
        return false;
      }
    }
    return true;
  }

  void _armPolicyWatchdogs(_ValidatedRuntimeAuthorityPolicy validated) {
    _policyPollTimer?.cancel();
    _policyExpiryTimer?.cancel();
    final workerGeneration = ++_policyWorkerGeneration;
    final now = _policyMonotonicNow();
    final expiryDelay = validated.deadline - now;
    _policyExpiryTimer = _policyWatchdogFactory(
      expiryDelay.isNegative ? Duration.zero : expiryDelay,
      () => _handlePolicyExpiry(workerGeneration, validated.deadline),
    );
    final pollDelay = validated.pollDeadline - now;
    _policyPollTimer = _policyWatchdogFactory(
      pollDelay.isNegative ? Duration.zero : pollDelay,
      () => _handlePolicyPoll(workerGeneration),
    );
  }

  void _handlePolicyExpiry(int workerGeneration, Duration expectedDeadline) {
    if (_closed ||
        workerGeneration != _policyWorkerGeneration ||
        _policyDeadline != expectedDeadline) {
      return;
    }
    if (_policyMonotonicNow() < expectedDeadline) {
      final delay = expectedDeadline - _policyMonotonicNow();
      _policyExpiryTimer = _policyWatchdogFactory(
        delay.isNegative ? Duration.zero : delay,
        () => _handlePolicyExpiry(workerGeneration, expectedDeadline),
      );
      return;
    }
    _policyExpiryTimer = null;
    _policyPollTimer?.cancel();
    _policyPollTimer = null;
    _policy = null;
    _policyDeadline = null;
    final expiredMode = _effectiveAuthorityMode;
    _effectiveAuthorityMode = AccountRuntimeAuthorityMode.off;
    if (!_requireExclusiveDeviceLease &&
        expiredMode == AccountRuntimeAuthorityMode.shadow) {
      _cancelShadowObservationAndRelease(closePresence: true);
    }
    if (_requireExclusiveDeviceLease ||
        _authorityCompileMaximum == AccountRuntimeAuthorityMode.enforce) {
      _invalidatePolicyAuthority(
        StateError('Runtime authority policy expired locally.'),
      );
      return;
    }
    final environment = _policyEnvironment;
    final scope = _policyScope;
    if (environment != null && scope != null) {
      _startPolicyObservation(environment: environment, scope: scope);
    }
  }

  void _handlePolicyPoll(int workerGeneration) {
    if (_closed || workerGeneration != _policyWorkerGeneration) return;
    _policyPollTimer = null;
    final environment = _policyEnvironment;
    final scope = _policyScope;
    if (environment == null || scope == null) return;
    _startPolicyRefresh(
      environment: environment,
      scope: scope,
      workerGeneration: workerGeneration,
    );
  }

  void _startPolicyObservation({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
  }) {
    if (_closed ||
        (!_requireExclusiveDeviceLease &&
            _authorityCompileMaximum == AccountRuntimeAuthorityMode.off)) {
      return;
    }
    if (_policyScope != scope) {
      _cancelPolicyWatchdogs(clearPolicy: true);
      _policyScope = scope;
      _policyEnvironment = environment;
    }
    final deadline = _policyDeadline;
    if (_policy != null &&
        deadline != null &&
        _policyMonotonicNow() < deadline) {
      return;
    }
    final workerGeneration = _policyWorkerGeneration;
    _startPolicyRefresh(
      environment: environment,
      scope: scope,
      workerGeneration: workerGeneration,
    );
  }

  void _startPolicyRefresh({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required int workerGeneration,
  }) {
    if (_policyRefreshInFlight != null &&
        _policyRefreshGeneration == workerGeneration) {
      return;
    }
    late final Future<void> refresh;
    refresh =
        _refreshPolicyInBackground(
          environment: environment,
          scope: scope,
          workerGeneration: workerGeneration,
        ).whenComplete(() {
          if (identical(_policyRefreshInFlight, refresh)) {
            _policyRefreshInFlight = null;
            _policyRefreshGeneration = null;
          }
        });
    _policyRefreshInFlight = refresh;
    _policyRefreshGeneration = workerGeneration;
    unawaited(refresh);
  }

  Future<void> _refreshPolicyInBackground({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required int workerGeneration,
  }) async {
    try {
      final validated = await _fetchValidatedPolicy(
        environment: environment,
        scope: scope,
      );
      if (_closed ||
          workerGeneration != _policyWorkerGeneration ||
          _policyScope != scope) {
        return;
      }
      final accepted = _installValidatedPolicy(
        environment: environment,
        scope: scope,
        validated: validated,
      );
      if (accepted &&
          _effectiveAuthorityMode == AccountRuntimeAuthorityMode.shadow) {
        _startShadowLeaseObservation(environment: environment, scope: scope);
      }
    } catch (exception) {
      if (_closed ||
          workerGeneration != _policyWorkerGeneration ||
          _policyScope != scope) {
        return;
      }
      if ((_requireExclusiveDeviceLease ||
              _authorityCompileMaximum ==
                  AccountRuntimeAuthorityMode.enforce) &&
          (_enforcementActivated ||
              _policy == null ||
              _policyDeadline == null ||
              _policyMonotonicNow() >= _policyDeadline!)) {
        _invalidatePolicyAuthority(exception);
        return;
      }
      final policy = _policy;
      final deadline = _policyDeadline;
      if (policy != null && deadline != null) {
        final now = _policyMonotonicNow();
        var delay = policy.pollAfter;
        final remaining = deadline - now;
        if (remaining < delay) delay = remaining;
        _policyPollTimer = _policyWatchdogFactory(
          delay.isNegative ? Duration.zero : delay,
          () => _handlePolicyPoll(workerGeneration),
        );
      }
    }
  }

  void _cancelPolicyWatchdogs({required bool clearPolicy}) {
    _policyPollTimer?.cancel();
    _policyExpiryTimer?.cancel();
    _policyPollTimer = null;
    _policyExpiryTimer = null;
    _policyWorkerGeneration++;
    if (clearPolicy) {
      _policy = null;
      _policyDeadline = null;
      _policyScope = null;
      _policyEnvironment = null;
      _effectiveAuthorityMode = AccountRuntimeAuthorityMode.off;
    }
  }

  void _invalidatePolicyAuthority(Object exception) {
    _cancelPolicyWatchdogs(clearPolicy: false);
    error.value = exception;
    final policyAdmissionAttempt = _policyAdmissionAttempt;
    if (policyAdmissionAttempt != null) {
      _fencePolicyAdmissionAttempt(policyAdmissionAttempt, exception);
    }
    final mountAttempt = _mountAuthorityAttempt;
    if (mountAttempt != null) {
      _fenceMountAuthorityAttempt(mountAttempt, exception);
    }
    final republishAttempt = _republishAuthorityAttempt;
    if (republishAttempt != null) {
      _fenceRepublishAuthorityAttempt(republishAttempt, exception);
    } else if (_runtimeLease != null && _activeMount != null) {
      _retireMountedRuntimeSynchronously(exception);
    } else if (mountAttempt == null && !hasCompanionRuntime) {
      phase.value = AccountSessionLifecyclePhase.verificationRequired;
    }
    if (hasCompanionRuntime) {
      _notifyCompanionRole();
      if (_isCompanionCredentialRejection(exception)) {
        _companionCredentialsRejected = true;
        _phaseChanges.emit();
        unawaited(
          _runSerialized(
            _rejectCompanionCredentialsLocked,
          ).catchError((Object _, StackTrace _) {}),
        );
      }
    }
  }

  bool _exclusivePresenceIsCurrent(int workerGeneration) {
    final candidate = _auth.candidate;
    final scope = hasCompanionRuntime ? _activeMount?.scope : _policyScope;
    final deadline = _policyDeadline;
    return _requireExclusiveDeviceLease &&
        !_closed &&
        !_companionCredentialsRejected &&
        workerGeneration == _shadowWorkerGeneration &&
        candidate != null &&
        candidate.session.isValid &&
        scope != null &&
        scope.accountUuid == candidate.session.accountUuid &&
        scope.environmentKey == _environment.environment.value.key &&
        candidate.environment == _environment.environment.value &&
        (hasCompanionRuntime ||
            (candidate.environment == _policyEnvironment &&
                _policy != null &&
                deadline != null &&
                _policyMonotonicNow() < deadline &&
                (isMounted ||
                    phase.value ==
                        AccountSessionLifecyclePhase.authenticatedStandby ||
                    phase.value ==
                        AccountSessionLifecyclePhase.leaseConflict)));
  }

  void _maintainExclusivePresenceForPhase() {
    _schedulePresenceRecovery();
    if (!_requireExclusiveDeviceLease) return;
    if (!_exclusivePresenceIsCurrent(_shadowWorkerGeneration)) {
      _shadowWorkerGeneration++;
      _shadowHeartbeatTimer?.cancel();
      _shadowHeartbeatTimer = null;
      _runtimeDiscovery?.stop();
      return;
    }
    final presenceScope = hasCompanionRuntime
        ? _activeMount!.scope
        : _policyScope!;
    final presenceEnvironment = hasCompanionRuntime
        ? _environment.environment.value
        : _policyEnvironment!;
    try {
      _runtimeDiscovery?.start(
        environment: presenceEnvironment,
        accountUuid: presenceScope.accountUuid,
      );
    } catch (_) {
      // Read-only discovery availability cannot change the lease decision.
    }
    final coordinator = _deviceLeaseCoordinator!;
    if (coordinator.currentReceipt != null || coordinator.hasPendingAcquire) {
      // Active authority owns its heartbeat; never renew it as an observer.
      return;
    }
    if (_shadowHeartbeatTimer != null) return;
    var delay =
        coordinator.currentPresence?.renewAfter ?? const Duration(seconds: 3);
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    final workerGeneration = _shadowWorkerGeneration;
    _shadowHeartbeatTimer = _shadowWatchdogFactory(delay, () {
      _shadowHeartbeatTimer = null;
      unawaited(
        _runSerialized(() async {
          if (!_exclusivePresenceIsCurrent(workerGeneration) ||
              coordinator.currentReceipt != null ||
              coordinator.hasPendingAcquire) {
            return;
          }
          try {
            if (coordinator.currentPresence == null) {
              await coordinator.openObservationPresence(
                environment: presenceEnvironment,
                accountUuid: presenceScope.accountUuid,
                deviceLabel: _deviceLabel,
                platform: _devicePlatform,
                appVersion: _appVersion,
              );
            } else {
              await coordinator.heartbeatObservationPresence();
            }
            if (_exclusivePresenceIsCurrent(workerGeneration)) {
              _remoteScope = presenceScope;
            }
          } catch (_) {
            // Presence is discovery-only. A future mount still needs acquisition.
          }
          if (_exclusivePresenceIsCurrent(workerGeneration)) {
            _maintainExclusivePresenceForPhase();
          }
        }).catchError((Object _, StackTrace _) {}),
      );
    });
  }

  void _startShadowLeaseObservation({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
  }) {
    if (_closed ||
        usesExclusiveDeviceLease ||
        _effectiveAuthorityMode != AccountRuntimeAuthorityMode.shadow ||
        _runtimeLease == null ||
        _activeMount?.scope != scope) {
      return;
    }
    try {
      _runtimeDiscovery?.start(
        environment: environment,
        accountUuid: scope.accountUuid,
      );
    } catch (_) {
      // Discovery is telemetry-only in shadow and cannot disturb legacy mount.
    }
    if (_shadowObservation != null) return;
    final workerGeneration = _shadowWorkerGeneration;
    late final Future<void> observation;
    observation =
        _observeShadowLease(
          environment: environment,
          scope: scope,
          workerGeneration: workerGeneration,
        ).whenComplete(() {
          if (identical(_shadowObservation, observation)) {
            _shadowObservation = null;
          }
        });
    _shadowObservation = observation;
    unawaited(observation);
  }

  Future<void> _observeShadowLease({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required int workerGeneration,
  }) async {
    final coordinator = _deviceLeaseCoordinator;
    if (coordinator == null) return;
    late final AccountDevicePresenceReceipt receipt;
    try {
      receipt = coordinator.currentPresence == null
          ? await coordinator.openObservationPresence(
              environment: environment,
              accountUuid: scope.accountUuid,
              deviceLabel: _deviceLabel,
              platform: _devicePlatform,
              appVersion: _appVersion,
            )
          : await coordinator.heartbeatObservationPresence();
    } catch (_) {
      if (_shadowObservationIsCurrent(
        environment: environment,
        scope: scope,
        workerGeneration: workerGeneration,
      )) {
        _scheduleShadowObservation(
          environment: environment,
          scope: scope,
          workerGeneration: workerGeneration,
          delay: const Duration(seconds: 3),
        );
      }
      return;
    }
    if (!_shadowObservationIsCurrent(
      environment: environment,
      scope: scope,
      workerGeneration: workerGeneration,
    )) {
      return;
    }
    _remoteScope = scope;
    _shadowPresenceOwnedByObservation = true;
    _scheduleShadowObservation(
      environment: environment,
      scope: scope,
      workerGeneration: workerGeneration,
      delay: receipt.renewAfter,
    );
  }

  bool _shadowObservationIsCurrent({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required int workerGeneration,
  }) =>
      !_closed &&
      !usesExclusiveDeviceLease &&
      workerGeneration == _shadowWorkerGeneration &&
      _effectiveAuthorityMode == AccountRuntimeAuthorityMode.shadow &&
      _runtimeLease != null &&
      _activeMount?.scope == scope &&
      _environment.environment.value == environment;

  void _scheduleShadowObservation({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required int workerGeneration,
    required Duration delay,
  }) {
    if (!_shadowObservationIsCurrent(
      environment: environment,
      scope: scope,
      workerGeneration: workerGeneration,
    )) {
      return;
    }
    _shadowHeartbeatTimer?.cancel();
    final boundedDelay = delay < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : delay;
    _shadowHeartbeatTimer = _shadowWatchdogFactory(boundedDelay, () {
      _shadowHeartbeatTimer = null;
      if (!_shadowObservationIsCurrent(
        environment: environment,
        scope: scope,
        workerGeneration: workerGeneration,
      )) {
        return;
      }
      _startShadowLeaseObservation(environment: environment, scope: scope);
    });
  }

  void _cancelShadowObservationAndRelease({bool closePresence = false}) {
    _shadowWorkerGeneration++;
    _shadowHeartbeatTimer?.cancel();
    _shadowHeartbeatTimer = null;
    _runtimeDiscovery?.stop();
    final observationWasInFlight = _shadowObservation != null;
    _shadowObservation = null;
    final coordinator = _deviceLeaseCoordinator;
    if (observationWasInFlight &&
        coordinator != null &&
        coordinator.currentReceipt == null) {
      try {
        coordinator.cancelObservationPresence();
        if (coordinator.currentPresence == null) {
          _shadowPresenceOwnedByObservation = false;
        }
      } catch (_) {
        // A concurrent enforce operation owns any non-observation authority.
      }
    }
    if (closePresence && coordinator?.currentPresence != null) {
      unawaited(
        _runSerialized(
          _closeRemotePresenceLocked,
        ).catchError((Object _, StackTrace _) {}),
      );
    }
  }

  _AccountRuntimePolicyAdmissionAttempt _beginPolicyAdmissionAttempt(
    AccountStorageScope scope,
  ) {
    final policy = _policy;
    final deadline = _policyDeadline;
    if (!usesExclusiveDeviceLease ||
        policy == null ||
        deadline == null ||
        _policyScope != scope ||
        _policyMonotonicNow() >= deadline) {
      throw StateError(
        'Runtime authority policy is not admissible for lease acquisition.',
      );
    }
    final attempt = _AccountRuntimePolicyAdmissionAttempt(
      scope: scope,
      revision: policy.revision,
      deadline: deadline,
      workerGeneration: _policyWorkerGeneration,
    );
    _policyAdmissionAttempt = attempt;
    return attempt;
  }

  void _requirePolicyAdmissionCurrent(
    _AccountRuntimePolicyAdmissionAttempt attempt,
  ) {
    final policy = _policy;
    if (identical(_policyAdmissionAttempt, attempt) &&
        !attempt.fenced &&
        usesExclusiveDeviceLease &&
        _policyScope == attempt.scope &&
        policy?.revision == attempt.revision &&
        _policyDeadline == attempt.deadline &&
        _policyWorkerGeneration == attempt.workerGeneration &&
        _policyMonotonicNow() < attempt.deadline) {
      return;
    }
    final failure =
        attempt.failure ??
        StateError(
          'Runtime authority policy changed during lease acquisition.',
        );
    _fencePolicyAdmissionAttempt(attempt, failure);
    throw failure;
  }

  void _fencePolicyAdmissionAttempt(
    _AccountRuntimePolicyAdmissionAttempt attempt,
    Object failure,
  ) {
    if (!identical(_policyAdmissionAttempt, attempt) || attempt.fenced) return;
    attempt
      ..fenced = true
      ..failure = failure;
    _deviceLeaseCoordinator?.fence();
  }

  void _finishPolicyAdmissionAttempt(
    _AccountRuntimePolicyAdmissionAttempt? attempt,
  ) {
    if (attempt != null && identical(_policyAdmissionAttempt, attempt)) {
      _policyAdmissionAttempt = null;
    }
  }

  Future<void> _discardPolicyAdmissionAuthority(
    AccountDeviceLeaseReceipt? expected,
  ) async {
    final coordinator = _deviceLeaseCoordinator;
    if (coordinator == null) return;
    final current = coordinator.currentReceipt;
    if (current != null) {
      final exact = expected ?? current;
      if (!_sameLeaseAuthority(exact, current)) {
        throw StateError(
          'Refusing to discard a different runtime lease authority.',
        );
      }
      await _releaseExactRemoteLease(exact);
    }
    if (coordinator.currentReceipt == null &&
        coordinator.currentPresence != null) {
      await _closeRemotePresenceLocked();
    } else if (coordinator.currentPresence == null) {
      _remoteScope = null;
    }
  }

  Future<bool> _discardPolicyAdmissionAuthorityOrRetain({
    required _AccountRuntimePolicyAdmissionAttempt attempt,
    required AccountDeviceLeaseReceipt? expected,
  }) async {
    try {
      await _discardPolicyAdmissionAuthority(expected);
      _finishPolicyAdmissionAttempt(attempt);
      return true;
    } catch (cleanupError) {
      _retainPolicyAdmissionCleanup(attempt, expected, cleanupError);
      return false;
    }
  }

  void _retainPolicyAdmissionCleanup(
    _AccountRuntimePolicyAdmissionAttempt attempt,
    AccountDeviceLeaseReceipt? expected,
    Object cleanupError,
  ) {
    if (!identical(_policyAdmissionAttempt, attempt) || !attempt.fenced) {
      throw StateError(
        'Cannot retain cleanup for a different policy admission attempt.',
      );
    }
    if (hasCompanionRuntime) {
      _closingOwnerLease = _AccountRuntimeTeardownLease(
        unpublishSession: () async {},
        releaseRemoteLease: () async {
          await _discardPolicyAdmissionAuthority(expected);
          _finishPolicyAdmissionAttempt(attempt);
        },
      );
      error.value = cleanupError;
      _notifyCompanionRole();
      return;
    }
    if (_runtimeLease != null ||
        _activeMount != null ||
        _closingLease != null) {
      throw StateError(
        'Rejected policy authority cannot coexist with runtime cleanup.',
      );
    }
    late final _AccountRuntimeTeardownLease retainedCleanup;
    retainedCleanup = _AccountRuntimeTeardownLease(
      unpublishSession: () async {},
      projectionAlreadyCleared: true,
      releaseRemoteLease: () async {
        await _discardPolicyAdmissionAuthority(expected);
        _finishPolicyAdmissionAttempt(attempt);
        if (identical(_retainedPolicyAdmissionCleanupLease, retainedCleanup)) {
          _retainedPolicyAdmissionCleanupLease = null;
        }
      },
    );
    _retainedPolicyAdmissionCleanupLease = retainedCleanup;
    _closingLease = retainedCleanup;
    error.value = cleanupError;
    phase.value = AccountSessionLifecyclePhase.faulted;
  }

  bool get _hasRetainedPolicyAdmissionCleanup =>
      _retainedPolicyAdmissionCleanupLease != null;

  void _abandonRetainedPolicyAdmissionCleanup() {
    if (!_hasRetainedPolicyAdmissionCleanup ||
        _runtimeLease != null ||
        _activeMount != null) {
      throw StateError(
        'Only rejected pre-mount authority may be abandoned at sign-out.',
      );
    }
    _deviceLeaseCoordinator?.abandonLocalAuthority();
    _remoteScope = null;
    _activeDeviceLease = null;
    _leaseConflict = null;
    _finishPolicyAdmissionAttempt(_policyAdmissionAttempt);
    _closingDrain = null;
    _closingLease = null;
    _retainedPolicyAdmissionCleanupLease = null;
  }

  void _activateRuntimeBoundaryForMount(AccountStorageScopeMount mount) {
    final activeGeneration = _activeRuntimeBoundaryGeneration;
    if (activeGeneration != null) {
      throw StateError(
        'Account runtime boundary generation $activeGeneration is still active.',
      );
    }
    _activeRuntimeBoundaryGeneration = mount.generation;
    try {
      _activateRuntimeBoundary?.call(mount);
    } catch (_) {
      _retireRuntimeBoundaryGeneration(mount.generation);
      rethrow;
    }
  }

  void _retireRuntimeBoundaryGeneration(int accountGeneration) {
    if (_activeRuntimeBoundaryGeneration != accountGeneration) return;
    // Clear only after the external projection confirms retirement. If it
    // throws, retaining this generation is a hard gate against mounting a
    // replacement account over authority that may still be published.
    _retireRuntimeBoundary?.call(accountGeneration);
    _activeRuntimeBoundaryGeneration = null;
  }

  void _requireRuntimeBoundaryCurrent(AccountStorageScopeMount mount) {
    if (_closed ||
        !identical(_activeMount, mount) ||
        _activeRuntimeBoundaryGeneration != mount.generation ||
        !_storageScopes.isCurrent(mount)) {
      throw StateError('Account runtime boundary was retired while mounting.');
    }
  }

  Future<bool> _mountCompanionSessionLocked(
    MaasoAuthCandidate candidate,
    MaasoEnvironment environment,
    AccountStorageScope scope,
  ) async {
    if (_companionRuntimeLease == null) {
      await _unmountLocked();
      _companionCredentialsRejected = false;
      phase.value = AccountSessionLifecyclePhase.mounting;
      await _storageScopes.whenBoundaryReleased;
      final mount = _storageScopes.mount(scope);
      _activeMount = mount;
      AccountRuntimeLease? base;
      try {
        _activateRuntimeBoundaryForMount(mount);
        base = await _mountCompanionRuntime!(mount);
        _requireRuntimeBoundaryCurrent(mount);
        await _auth.publishCandidate(candidate);
        _requireRuntimeBoundaryCurrent(mount);
        _companionRuntimeLease = _AccountRuntimeTeardownLease(
          unpublishSession: _auth.unpublishSession,
          runtime: base,
        );
      } catch (failure, stack) {
        _retireRuntimeBoundaryGeneration(mount.generation);
        if (_storageScopes.isCurrent(mount)) _storageScopes.unmount(mount);
        _activeMount = null;
        final rollback = _AccountRuntimeTeardownLease(
          unpublishSession: _auth.unpublishSession,
          runtime: failure is AccountRuntimeMountFailure
              ? failure.cleanupLease
              : base,
        );
        _closingLease = rollback;
        try {
          await rollback.close();
          _closingLease = null;
        } catch (cleanupError) {
          error.value = cleanupError;
          phase.value = AccountSessionLifecyclePhase.faulted;
          rethrow;
        }
        error.value = failure;
        phase.value = _closed
            ? AccountSessionLifecyclePhase.closed
            : AccountSessionLifecyclePhase.signedOut;
        Error.throwWithStackTrace(failure, stack);
      }
      _notifyCompanionRole();
    }

    // The authenticated page graph is already usable. Authority policy and
    // network availability can only decide whether its local Agent may run.
    try {
      await _drainCompanionOwnerLocked();
    } catch (failure) {
      error.value = failure;
      _notifyCompanionRole();
      return isMounted;
    }
    final mode = await _resolveAuthorityModeForMountLocked(
      environment: environment,
      scope: scope,
    );
    if (mode == null) return _finishCompanionMountOutcome();
    if (_companionRecoveryIsCurrent?.call() == false) return isMounted;
    if (_runtimeLease != null) {
      await _revalidateActiveLeaseLocked(scope, candidate);
      return _finishCompanionMountOutcome();
    }

    final mount = _activeMount!;
    _AccountRuntimePolicyAdmissionAttempt? admission;
    _AccountRuntimeMountAuthorityAttempt? attempt;
    AccountDeviceLeaseReceipt? receipt;
    AccountRuntimeLease? owner;
    try {
      admission = _beginPolicyAdmissionAttempt(scope);
      receipt = await _acquireRemoteLeaseLocked(
        environment: environment,
        scope: scope,
        policyAdmissionAttempt: admission,
      );
      if (receipt == null) {
        if (!admission.fenced) _finishPolicyAdmissionAttempt(admission);
        final unadmitted = _deviceLeaseCoordinator?.currentReceipt;
        if (unadmitted != null && _closingOwnerLease == null) {
          _closingOwnerLease = _companionOwnerTeardown(null, unadmitted);
        }
        return await _finishCompanionMountOutcome();
      }
      _requireCompanionRecoveryCurrent();
      _requirePolicyAdmissionCurrent(admission);
      _activeDeviceLease = receipt;
      attempt = _AccountRuntimeMountAuthorityAttempt(receipt)..mount = mount;
      _mountAuthorityAttempt = attempt;
      _finishPolicyAdmissionAttempt(admission);
      _armMountAuthorityWatchdog(attempt);
      _requireMountAuthorityCurrent(attempt, mount);
      _ownerActivationInProgress = true;
      _phaseChanges.emit();
      owner = await _mountRuntime(mount);
      _requireCompanionRecoveryCurrent();
      _requireRuntimeBoundaryCurrent(mount);
      _requireMountAuthorityCurrent(attempt, mount);
      _runtimeLease = _companionOwnerTeardown(owner, receipt);
      _ownerActivationInProgress = false;
      _commitMountAuthorityAttempt(attempt);
      _leaseConflict = null;
      error.value = null;
      _notifyCompanionRole();
      _startLeaseHeartbeat(receipt);
      return true;
    } catch (failure) {
      _ownerActivationInProgress = false;
      if (attempt != null) _finishMountAuthorityAttempt(attempt);
      if (admission != null) _finishPolicyAdmissionAttempt(admission);
      _deviceLeaseCoordinator?.fence();
      _fenceRuntimeAdmission();
      final cleanupOwner = failure is AccountRuntimeMountFailure
          ? failure.cleanupLease
          : owner;
      final exact = receipt ?? _deviceLeaseCoordinator?.currentReceipt;
      if (cleanupOwner != null || exact != null) {
        _closingOwnerLease = _companionOwnerTeardown(cleanupOwner, exact);
        try {
          await _drainCompanionOwnerLocked();
        } catch (_) {
          // Retain host rollback for the next execution attempt/sign-out;
          // shared pages are independent of this owner-only cleanup failure.
        }
      }
      error.value = failure;
      return _finishCompanionMountOutcome();
    } finally {
      _ownerActivationInProgress = false;
    }
  }

  void _requireCompanionRecoveryCurrent() {
    if (_companionRecoveryIsCurrent?.call() == false) {
      throw StateError(
        'Agent recovery was superseded before owner activation.',
      );
    }
  }

  AccountRuntimeLease _companionOwnerTeardown(
    AccountRuntimeLease? owner,
    AccountDeviceLeaseReceipt? receipt,
  ) => _AccountRuntimeTeardownLease(
    unpublishSession: () async {},
    runtime: owner,
    releaseRemoteLease: receipt == null
        ? null
        : () => _releaseExactRemoteLease(receipt),
  );

  Future<bool> _finishCompanionMountOutcome() async {
    if (_isCompanionCredentialRejection(error.value)) {
      _companionCredentialsRejected = true;
      _phaseChanges.emit();
      await _rejectCompanionCredentialsLocked();
      return false;
    }
    _notifyCompanionRole();
    return isMounted;
  }

  bool _isCompanionCredentialRejection(Object? failure) =>
      failure is AccountDeviceLeaseRequestException &&
      _requiresCredentialVerification(failure);

  Future<void> _rejectCompanionCredentialsLocked() async {
    if (!_companionCredentialsRejected) return;
    try {
      await _unmountLocked();
      await _closeRemotePresenceLocked();
    } finally {
      _cancelPolicyWatchdogs(clearPolicy: true);
      await _clearCredentialsWithoutReentry();
      phase.value = _companionRuntimeLease == null && _closingLease == null
          ? AccountSessionLifecyclePhase.signedOut
          : AccountSessionLifecyclePhase.faulted;
    }
  }

  void _notifyCompanionRole() {
    if (_closed || !hasCompanionRuntime) return;
    phase.value = _companionCredentialsRejected
        ? AccountSessionLifecyclePhase.verificationRequired
        : AccountSessionLifecyclePhase.mounted;
    _maintainExclusivePresenceForPhase();
    // Role can change while the account phase remains mounted.
    _phaseChanges.emit();
  }

  void _retireCompanionOwnerSynchronously(Object failure) {
    final owner = _runtimeLease;
    if (owner == null) return;
    _deviceLeaseCoordinator?.fence();
    _fenceRuntimeAdmission();
    _stopLeaseHeartbeat();
    _runtimeLease = null;
    _closingOwnerLease = owner;
    error.value = failure;
    _notifyCompanionRole();
    unawaited(
      _runSerialized(
        _drainCompanionOwnerLocked,
      ).catchError((Object _, StackTrace _) {}),
    );
  }

  Future<void> _drainCompanionOwnerLocked() async {
    final owner = _closingOwnerLease;
    if (owner == null) return;
    await owner.close();
    if (identical(_closingOwnerLease, owner)) {
      _closingOwnerLease = null;
      _activeDeviceLease = null;
    }
    _notifyCompanionRole();
  }

  Future<void> _unmountCompanionAccountLocked() async {
    final base = _companionRuntimeLease!;
    _cancelShadowObservationAndRelease();
    _stopLeaseHeartbeat();
    _ownerActivationInProgress = false;
    if (_runtimeLease != null) {
      _deviceLeaseCoordinator?.fence();
      _fenceRuntimeAdmission();
      _closingOwnerLease = _runtimeLease;
      _runtimeLease = null;
    }
    final mount = _activeMount;
    phase.value = AccountSessionLifecyclePhase.retiring;
    try {
      if (mount != null) {
        _retireRuntimeBoundaryGeneration(mount.generation);
        if (_storageScopes.isCurrent(mount)) _storageScopes.unmount(mount);
        _activeMount = null;
      }
      await _storageScopes.whenBoundaryReleased;
      await _drainCompanionOwnerLocked();
      await base.close();
      _companionRuntimeLease = null;
      _activeDeviceLease = null;
      error.value = null;
      phase.value = _phaseAfterRuntimeStops;
    } catch (failure) {
      error.value = failure;
      phase.value = AccountSessionLifecyclePhase.faulted;
      rethrow;
    }
  }

  Future<bool> _mountCurrentSessionLocked() async {
    if (_closingLease != null || isFaulted) {
      throw StateError(
        'Cannot mount an account runtime until the failed lease closes.',
      );
    }
    final candidate = _auth.candidate;
    if (candidate == null || !candidate.session.isValid) {
      await _unmountLocked();
      phase.value = AccountSessionLifecyclePhase.signedOut;
      return false;
    }
    final session = candidate.session;

    final environment = _environment.environment.value;
    if (candidate.environment != environment) {
      await _unmountLocked();
      phase.value = AccountSessionLifecyclePhase.signedOut;
      throw StateError('The authentication candidate environment is stale.');
    }

    final accountUuid = session.accountUuid.trim();
    if (accountUuid.isEmpty) {
      await _unmountLocked();
      await _auth.signOut();
      phase.value = AccountSessionLifecyclePhase.signedOut;
      return false;
    }

    final scope = AccountStorageScope(
      environmentKey: environment.key,
      accountUuid: accountUuid,
    );
    var currentMount = _activeMount;
    if ((_runtimeLease != null || _companionRuntimeLease != null) &&
        currentMount != null &&
        currentMount.scope != scope) {
      // Retire the old producer/storage generation before a new-scope policy
      // request can wait on the network. Old policy watchdogs remain armed
      // until the synchronous retirement fence has started.
      await _unmountLocked();
      currentMount = _activeMount;
    }
    if (_mountCompanionRuntime != null) {
      return _mountCompanionSessionLocked(candidate, environment, scope);
    }
    final authorityMode = await _resolveAuthorityModeForMountLocked(
      environment: environment,
      scope: scope,
    );
    if (authorityMode == null) return false;
    if (_runtimeLease != null && currentMount?.scope == scope) {
      if (usesExclusiveDeviceLease &&
          !await _revalidateActiveLeaseLocked(scope, candidate)) {
        return false;
      }
      if (!usesExclusiveDeviceLease) {
        _storageScopes.requireCurrent(currentMount!);
        await _auth.publishCandidate(candidate);
        _storageScopes.requireCurrent(currentMount);
      }
      phase.value = AccountSessionLifecyclePhase.mounted;
      if (authorityMode == AccountRuntimeAuthorityMode.shadow) {
        _startShadowLeaseObservation(environment: environment, scope: scope);
      }
      return true;
    }

    await _unmountLocked();
    AccountDeviceLeaseReceipt? deviceLease;
    _AccountRuntimePolicyAdmissionAttempt? policyAdmissionAttempt;
    _AccountRuntimeMountAuthorityAttempt? authorityAttempt;
    if (usesExclusiveDeviceLease) {
      try {
        policyAdmissionAttempt = _beginPolicyAdmissionAttempt(scope);
      } catch (exception) {
        _invalidatePolicyAuthority(exception);
        return false;
      }
      deviceLease = await _acquireRemoteLeaseLocked(
        environment: environment,
        scope: scope,
        policyAdmissionAttempt: policyAdmissionAttempt,
      );
      if (deviceLease == null) {
        if (!policyAdmissionAttempt.fenced) {
          _finishPolicyAdmissionAttempt(policyAdmissionAttempt);
        }
        return false;
      }
      try {
        _requirePolicyAdmissionCurrent(policyAdmissionAttempt);
      } catch (exception) {
        final cleaned = await _discardPolicyAdmissionAuthorityOrRetain(
          attempt: policyAdmissionAttempt,
          expected: deviceLease,
        );
        if (cleaned) {
          error.value = exception;
          phase.value = AccountSessionLifecyclePhase.verificationRequired;
        }
        return false;
      }
      _activeDeviceLease = deviceLease;
      authorityAttempt = _AccountRuntimeMountAuthorityAttempt(deviceLease);
      _mountAuthorityAttempt = authorityAttempt;
      _finishPolicyAdmissionAttempt(policyAdmissionAttempt);
    }

    phase.value = AccountSessionLifecyclePhase.mounting;
    error.value = null;
    AccountStorageScopeMount? mount;
    AccountRuntimeLease? lease;
    final releaseRemoteLease = deviceLease == null
        ? null
        : () => _releaseExactRemoteLease(deviceLease!);
    try {
      if (authorityAttempt != null) {
        // No await separates acquire from this arm: the independent watchdog
        // owns the entire storage/runtime construction gap.
        _armMountAuthorityWatchdog(authorityAttempt);
      }
      // A prior account generation may already be invalid while its modal
      // confirmation surface is still acknowledging dismissal. Never publish
      // the replacement scope across that privacy boundary.
      await _storageScopes.whenBoundaryReleased;
      if (_closed) {
        throw StateError('account_session_lifecycle_service_closed');
      }
      mount = _storageScopes.mount(scope);
      _activeMount = mount;
      authorityAttempt?.mount = mount;
      if (authorityAttempt != null) {
        _requireMountAuthorityCurrent(authorityAttempt, mount);
      }
      _activateRuntimeBoundaryForMount(mount);
      _requireRuntimeBoundaryCurrent(mount);
      lease = await _mountRuntime(mount);
      _requireRuntimeBoundaryCurrent(mount);
      if (authorityAttempt != null) {
        _requireMountAuthorityCurrent(authorityAttempt, mount);
      }
      await _auth.publishCandidate(candidate);
      _requireRuntimeBoundaryCurrent(mount);
      if (authorityAttempt != null) {
        authorityAttempt.sessionPublished = true;
        _requireMountAuthorityCurrent(authorityAttempt, mount);
      }
      _runtimeLease = _AccountRuntimeTeardownLease(
        unpublishSession: _auth.unpublishSession,
        runtime: lease,
        releaseRemoteLease: releaseRemoteLease,
      );
      _commitMountAuthorityAttempt(authorityAttempt);
      _leaseConflict = null;
      phase.value = AccountSessionLifecyclePhase.mounted;
      if (deviceLease != null) _startLeaseHeartbeat(deviceLease);
      if (authorityMode == AccountRuntimeAuthorityMode.shadow) {
        _startShadowLeaseObservation(environment: environment, scope: scope);
      }
      return true;
    } catch (mountError, mountStackTrace) {
      if (mount != null) {
        _retireRuntimeBoundaryGeneration(mount.generation);
      }
      _activeMount = null;
      if (mount != null && _storageScopes.isCurrent(mount)) {
        _storageScopes.unmount(mount);
      }

      if (mountError is AccountRuntimeMountFailure) {
        var projectionCleared = _projectionAlreadyCleared(authorityAttempt);
        if (!projectionCleared) {
          try {
            await _auth.unpublishSession();
            projectionCleared = true;
          } catch (_) {
            // The retained teardown lease retries both projection cleanup and
            // runtime rollback before any future account can mount.
          }
        }
        _closingLease = _AccountRuntimeTeardownLease(
          unpublishSession: _auth.unpublishSession,
          runtime: mountError.cleanupLease,
          releaseRemoteLease: releaseRemoteLease,
          projectionAlreadyCleared: projectionCleared,
        );
        _finishMountAuthorityAttempt(authorityAttempt);
        error.value = mountError;
        phase.value = _closed
            ? AccountSessionLifecyclePhase.closed
            : AccountSessionLifecyclePhase.faulted;
        Error.throwWithStackTrace(mountError, mountStackTrace);
      }

      final teardown = _AccountRuntimeTeardownLease(
        unpublishSession: _auth.unpublishSession,
        runtime: lease,
        releaseRemoteLease: releaseRemoteLease,
        projectionAlreadyCleared: _projectionAlreadyCleared(authorityAttempt),
      );
      try {
        await teardown.close();
        _activeDeviceLease = null;
        _finishMountAuthorityAttempt(authorityAttempt);
      } catch (cleanupError, cleanupStackTrace) {
        final failure = AccountRuntimeMountFailure(
          cause: mountError,
          causeStackTrace: mountStackTrace,
          cleanupLease: teardown,
          cleanupError: cleanupError,
          cleanupStackTrace: cleanupStackTrace,
        );
        _closingLease = teardown;
        _finishMountAuthorityAttempt(authorityAttempt);
        error.value = failure;
        phase.value = _closed
            ? AccountSessionLifecyclePhase.closed
            : AccountSessionLifecyclePhase.faulted;
        Error.throwWithStackTrace(failure, mountStackTrace);
      }
      error.value = mountError;
      phase.value = _closed
          ? AccountSessionLifecyclePhase.closed
          : deviceLease == null
          ? AccountSessionLifecyclePhase.signedOut
          : AccountSessionLifecyclePhase.authenticatedStandby;
      Error.throwWithStackTrace(mountError, mountStackTrace);
    }
  }

  Future<AccountDeviceLeaseReceipt?> _acquireRemoteLeaseLocked({
    required MaasoEnvironment environment,
    required AccountStorageScope scope,
    required _AccountRuntimePolicyAdmissionAttempt policyAdmissionAttempt,
  }) async {
    final coordinator = _deviceLeaseCoordinator!;
    _cancelShadowObservationAndRelease();
    if (_remoteScope != null && _remoteScope != scope) {
      await _closeRemotePresenceLocked();
    }
    _remoteScope = scope;
    _leaseConflict = null;
    error.value = null;
    phase.value = AccountSessionLifecyclePhase.acquiringLease;
    final acquiringFromShadowPresence = _shadowPresenceOwnedByObservation;
    // Once acquire is dispatched, the server may have committed a lease even
    // if the response is lost. Treat the presence as strict until an exact
    // conflict proves that this runtime did not acquire authority.
    _shadowPresenceOwnedByObservation = false;
    try {
      final receipt = coordinator.hasTransferredLeaseAwaitingMount
          ? coordinator.consumeTransferredLeaseForMount()
          : await coordinator.acquire(
              environment: environment,
              accountUuid: scope.accountUuid,
              deviceLabel: _deviceLabel,
              platform: _devicePlatform,
              appVersion: _appVersion,
            );
      _requirePolicyAdmissionCurrent(policyAdmissionAttempt);
      return receipt;
    } catch (exception) {
      if (acquiringFromShadowPresence &&
          !coordinator.hasPendingAcquire &&
          coordinator.currentReceipt == null &&
          coordinator.currentPresence != null) {
        _shadowPresenceOwnedByObservation = true;
      }
      if (policyAdmissionAttempt.fenced) {
        final reported = policyAdmissionAttempt.failure ?? exception;
        final cleaned = await _discardPolicyAdmissionAuthorityOrRetain(
          attempt: policyAdmissionAttempt,
          expected: coordinator.currentReceipt,
        );
        if (cleaned) {
          error.value = reported;
          phase.value = AccountSessionLifecyclePhase.verificationRequired;
        }
        return null;
      }
      if (exception is AccountDeviceLeaseConflict) {
        _leaseConflict = exception;
        _rememberRemoteHolder(exception.holder, exception.remainingTtl);
        error.value = exception;
        phase.value = AccountSessionLifecyclePhase.leaseConflict;
        return null;
      }
      if (exception is AccountDeviceLeaseRequestException) {
        error.value = exception;
        phase.value = _requiresCredentialVerification(exception)
            ? AccountSessionLifecyclePhase.verificationRequired
            : AccountSessionLifecyclePhase.authenticatedStandby;
        return null;
      }
      error.value = exception;
      phase.value = AccountSessionLifecyclePhase.authenticatedStandby;
      return null;
    }
  }

  Future<bool> _revalidateActiveLeaseLocked(
    AccountStorageScope expectedScope,
    MaasoAuthCandidate candidate,
  ) async {
    final coordinator = _deviceLeaseCoordinator!;
    final expectedLease = _activeDeviceLease;
    final mount = _activeMount;
    if (expectedLease == null ||
        mount == null ||
        mount.scope != expectedScope ||
        _remoteScope != expectedScope) {
      final exception = StateError(
        'Mounted account runtime is missing its remote lease receipt.',
      );
      error.value = exception;
      phase.value = AccountSessionLifecyclePhase.faulted;
      throw exception;
    }

    final attempt = _AccountRuntimeRepublishAuthorityAttempt(
      receipt: expectedLease,
      mount: mount,
    );
    _republishAuthorityAttempt = attempt;
    _stopLeaseHeartbeat();
    phase.value = AccountSessionLifecyclePhase.acquiringLease;
    _armRepublishAuthorityWatchdog(attempt);
    try {
      _requireRepublishAuthorityCurrent(attempt);
      final renewed = await coordinator.heartbeat();
      if (!_sameLeaseAuthority(expectedLease, renewed)) {
        throw StateError('Remote lease revalidation changed exact authority.');
      }
      attempt.receipt = renewed;
      _activeDeviceLease = renewed;
      _requireRepublishAuthorityCurrent(attempt);
      _armRepublishAuthorityWatchdog(attempt);
      _requireRepublishAuthorityCurrent(attempt);
      await _auth.publishCandidate(candidate);
      _requireRepublishAuthorityCurrent(attempt);
      attempt.completed = true;
      error.value = null;
      phase.value = AccountSessionLifecyclePhase.mounted;
      _startLeaseHeartbeat(renewed);
      return true;
    } catch (exception) {
      _fenceRepublishAuthorityAttempt(attempt, exception);
      return false;
    } finally {
      if (!attempt.operationSettled.isCompleted) {
        attempt.operationSettled.complete();
      }
      _finishRepublishAuthorityAttempt(attempt);
    }
  }

  Future<void> _releaseExactRemoteLease(
    AccountDeviceLeaseReceipt expected,
  ) async {
    final coordinator = _deviceLeaseCoordinator;
    if (coordinator == null) return;
    final current = coordinator.currentReceipt;
    if (current == null) {
      if (coordinator.state == AccountDeviceLeaseCoordinatorState.fenced ||
          coordinator.state == AccountDeviceLeaseCoordinatorState.standby ||
          coordinator.state == AccountDeviceLeaseCoordinatorState.idle) {
        return;
      }
      throw StateError('Remote lease authority disappeared before release.');
    }
    if (!_sameLeaseAuthority(expected, current)) {
      throw StateError('Refusing to release a different remote lease receipt.');
    }
    try {
      await coordinator.release();
    } on AccountDeviceLeaseRequestException catch (exception) {
      // A server-side fence already made this exact authority inert. The
      // coordinator has cleared it locally, so teardown can converge.
      if (!exception.isStaleAuthority) rethrow;
    }
  }

  Future<void> _closeRemotePresenceLocked() async {
    final coordinator = _deviceLeaseCoordinator;
    if (coordinator == null) {
      _remoteScope = null;
      _shadowPresenceOwnedByObservation = false;
      return;
    }
    if (coordinator.hasPendingAcquire) {
      await _settlePendingAcquireForPresenceCloseLocked(coordinator);
    }
    if (coordinator.currentPresence == null) {
      _remoteScope = null;
      _shadowPresenceOwnedByObservation = false;
      return;
    }
    if (coordinator.currentReceipt != null) {
      throw StateError('Cannot close runtime presence while a lease is held.');
    }
    try {
      await coordinator.closePresence();
    } on AccountDeviceLeaseRequestException catch (exception) {
      final authenticationUnavailable =
          exception.code == 'AUTHENTICATION_REQUIRED' ||
          exception.statusCode == 401 ||
          exception.statusCode == 403;
      if (authenticationUnavailable &&
          !coordinator.hasPendingAcquire &&
          coordinator.currentReceipt == null) {
        // A proof-free presence cannot grant mutations. If its account
        // credentials are no longer usable while leaving this scope, forget
        // it locally and let the remote receipt expire by TTL so a future
        // login is not permanently blocked on credentials it cannot recover.
        coordinator.abandonLocalAuthority();
      } else if (!exception.isStaleAuthority) {
        if (!_shadowPresenceOwnedByObservation) rethrow;
        _abandonShadowPresenceAfterCloseFailure(coordinator);
      }
    } catch (_) {
      if (!_shadowPresenceOwnedByObservation) rethrow;
      _abandonShadowPresenceAfterCloseFailure(coordinator);
    }
    _remoteScope = null;
    _shadowPresenceOwnedByObservation = false;
  }

  Future<void> _settlePendingAcquireForPresenceCloseLocked(
    AccountDeviceLeaseCoordinator coordinator,
  ) async {
    final scope = _remoteScope;
    final environment = _environment.environment.value;
    if (scope == null || scope.environmentKey != environment.key) {
      throw StateError(
        'Cannot resolve a pending lease outside its account environment.',
      );
    }
    try {
      await coordinator.acquire(
        environment: environment,
        accountUuid: scope.accountUuid,
        deviceLabel: _deviceLabel,
        platform: _devicePlatform,
        appVersion: _appVersion,
      );
    } on AccountDeviceLeaseConflict {
      if (coordinator.hasPendingAcquire || coordinator.currentReceipt != null) {
        rethrow;
      }
      // A definitive conflict proves this presence never obtained authority.
      _shadowPresenceOwnedByObservation = coordinator.currentPresence != null;
      return;
    } on AccountDeviceLeaseRequestException catch (exception) {
      if (exception.code == 'STALE_RUNTIME_LEASE' &&
          !coordinator.hasPendingAcquire &&
          coordinator.currentReceipt == null) {
        // The exact replay aged past its committed lease. No live authority
        // remains, and the coordinator retained only the proof-free presence
        // so teardown can close it before credentials are cleared.
        _shadowPresenceOwnedByObservation = coordinator.currentPresence != null;
        return;
      }
      if (exception.code == 'STALE_RUNTIME_PRESENCE' &&
          !coordinator.hasPendingAcquire &&
          coordinator.currentReceipt == null &&
          coordinator.currentPresence == null) {
        // The pending command never left live authority behind and its
        // presence has also expired, so there is nothing left to close.
        _shadowPresenceOwnedByObservation = false;
        return;
      }
      final authenticationUnavailable =
          exception.code == 'AUTHENTICATION_REQUIRED' ||
          exception.statusCode == 401 ||
          exception.statusCode == 403;
      if (authenticationUnavailable &&
          coordinator.hasPendingAcquire &&
          coordinator.currentReceipt == null) {
        // This path only runs while leaving the current account/environment.
        // Without usable credentials the exact command cannot be settled, so
        // fail closed locally and let any remotely committed lease/presence
        // expire by TTL instead of retaining an unusable proof forever.
        coordinator.abandonLocalAuthority();
        _shadowPresenceOwnedByObservation = false;
        return;
      }
      if (coordinator.currentReceipt == null) rethrow;
    } catch (_) {
      // A locally expired response can still install the exact receipt/proof
      // for cleanup. Any other uncertain failure must retain the pending
      // request and proof rather than falling through to presence close.
      if (coordinator.currentReceipt == null) rethrow;
    }

    _shadowPresenceOwnedByObservation = false;
    if (coordinator.currentReceipt == null) {
      throw StateError('Pending runtime lease did not resolve exactly.');
    }
    try {
      await coordinator.release();
    } on AccountDeviceLeaseRequestException catch (exception) {
      if (!exception.isStaleAuthority) rethrow;
    }
  }

  void _abandonShadowPresenceAfterCloseFailure(
    AccountDeviceLeaseCoordinator coordinator,
  ) {
    try {
      coordinator.abandonLocalAuthority();
    } catch (_) {
      // Credentials must not be retained for proof-free shadow cleanup. The
      // remote presence has no mutation authority and expires by server TTL.
    }
  }

  bool _projectionAlreadyCleared(
    _AccountRuntimeMountAuthorityAttempt? attempt,
  ) =>
      attempt != null &&
      !attempt.sessionPublished &&
      _auth.session.value == null;

  void _armRepublishAuthorityWatchdog(
    _AccountRuntimeRepublishAuthorityAttempt attempt,
  ) {
    if (!identical(_republishAuthorityAttempt, attempt) ||
        attempt.fenced ||
        attempt.completed) {
      return;
    }
    final remaining = _deviceLeaseCoordinator?.admissionTimeRemaining;
    if (remaining == null) {
      _fenceRepublishAuthorityAttempt(
        attempt,
        StateError('Republish authority has no monotonic deadline.'),
      );
      return;
    }
    attempt.watchdog?.cancel();
    attempt.watchdog = _authorityWatchdogFactory(
      remaining.isNegative ? Duration.zero : remaining,
      () => _handleRepublishAuthorityWatchdog(attempt),
    );
  }

  void _handleRepublishAuthorityWatchdog(
    _AccountRuntimeRepublishAuthorityAttempt attempt,
  ) {
    if (!identical(_republishAuthorityAttempt, attempt) ||
        attempt.fenced ||
        attempt.completed) {
      return;
    }
    final coordinator = _deviceLeaseCoordinator!;
    coordinator.enforceLocalDeadline();
    if (_hasExactRepublishAuthority(attempt)) {
      _armRepublishAuthorityWatchdog(attempt);
      return;
    }
    _fenceRepublishAuthorityAttempt(
      attempt,
      StateError('Account runtime authority expired while republishing.'),
    );
  }

  void _requireRepublishAuthorityCurrent(
    _AccountRuntimeRepublishAuthorityAttempt attempt,
  ) {
    _deviceLeaseCoordinator!.enforceLocalDeadline();
    if (!attempt.fenced &&
        identical(_republishAuthorityAttempt, attempt) &&
        _hasExactRepublishAuthority(attempt)) {
      return;
    }
    final failure =
        attempt.failure ??
        StateError('Account runtime authority was lost while republishing.');
    _fenceRepublishAuthorityAttempt(attempt, failure);
    throw failure;
  }

  bool _hasExactRepublishAuthority(
    _AccountRuntimeRepublishAuthorityAttempt attempt,
  ) {
    final coordinator = _deviceLeaseCoordinator;
    final current = coordinator?.currentReceipt;
    final active = _activeDeviceLease;
    return coordinator != null &&
        coordinator.canAdmitMutations &&
        current != null &&
        active != null &&
        identical(_activeMount, attempt.mount) &&
        _storageScopes.isCurrent(attempt.mount) &&
        _sameLeaseAuthority(attempt.receipt, current) &&
        _sameLeaseAuthority(attempt.receipt, active);
  }

  void _fenceRepublishAuthorityAttempt(
    _AccountRuntimeRepublishAuthorityAttempt attempt,
    Object failure,
  ) {
    if (!identical(_republishAuthorityAttempt, attempt) ||
        attempt.fenced ||
        attempt.completed) {
      return;
    }
    attempt
      ..fenced = true
      ..failure = failure;
    attempt.watchdog?.cancel();
    attempt.watchdog = null;
    _deviceLeaseCoordinator?.fence();
    _retireMountedRuntimeSynchronously(failure, republishAttempt: attempt);
  }

  void _finishRepublishAuthorityAttempt(
    _AccountRuntimeRepublishAuthorityAttempt attempt,
  ) {
    attempt.watchdog?.cancel();
    attempt.watchdog = null;
    if (identical(_republishAuthorityAttempt, attempt)) {
      _republishAuthorityAttempt = null;
    }
  }

  void _retireMountedRuntimeSynchronously(
    Object exception, {
    _AccountRuntimeRepublishAuthorityAttempt? republishAttempt,
    bool deferCleanupToQueue = false,
  }) {
    if (hasCompanionRuntime) {
      _retireCompanionOwnerSynchronously(exception);
      return;
    }
    final lease = _runtimeLease;
    final mount = _activeMount;
    if (lease == null || mount == null || _closingLease != null) return;

    _deviceLeaseCoordinator?.fence();
    _fenceRuntimeAdmission();
    _retireRuntimeBoundaryGeneration(mount.generation);
    Object? storageFenceError;
    try {
      if (_storageScopes.isCurrent(mount)) {
        _storageScopes.unmount(mount);
      }
    } catch (fenceError) {
      storageFenceError = fenceError;
    }
    _stopLeaseHeartbeat();
    _runtimeLease = null;
    _activeMount = null;
    final closing = republishAttempt == null
        ? lease
        : _AccountRuntimeRepublishTeardownLease(
            operationSettled: republishAttempt.operationSettled.future,
            runtime: lease,
          );
    _closingLease = closing;
    if (republishAttempt != null) {
      try {
        final immediateUnpublish = _auth.unpublishSession();
        unawaited(immediateUnpublish.catchError((Object _, StackTrace _) {}));
      } catch (_) {
        // The retained teardown lease performs the final post-publish retry.
      }
    }
    if (!deferCleanupToQueue) {
      final drain = closing.close();
      _closingDrain = drain;
      unawaited(drain.catchError((Object _, StackTrace _) {}));
    }
    error.value = storageFenceError ?? exception;
    phase.value = storageFenceError == null
        ? AccountSessionLifecyclePhase.retiring
        : AccountSessionLifecyclePhase.faulted;
    unawaited(
      _runSerialized<void>(
        _unmountLocked,
      ).catchError((Object _, StackTrace _) {}),
    );
  }

  void _armMountAuthorityWatchdog(
    _AccountRuntimeMountAuthorityAttempt attempt,
  ) {
    if (!identical(_mountAuthorityAttempt, attempt) ||
        attempt.fenced ||
        attempt.committed) {
      return;
    }
    final remaining = _deviceLeaseCoordinator?.admissionTimeRemaining;
    if (remaining == null) {
      _fenceMountAuthorityAttempt(
        attempt,
        StateError('Mount authority has no monotonic admission deadline.'),
      );
      return;
    }
    attempt.watchdog?.cancel();
    attempt.watchdog = _authorityWatchdogFactory(
      remaining.isNegative ? Duration.zero : remaining,
      () => _handleMountAuthorityWatchdog(attempt),
    );
  }

  void _handleMountAuthorityWatchdog(
    _AccountRuntimeMountAuthorityAttempt attempt,
  ) {
    if (!identical(_mountAuthorityAttempt, attempt) ||
        attempt.fenced ||
        attempt.committed) {
      return;
    }
    final coordinator = _deviceLeaseCoordinator!;
    coordinator.enforceLocalDeadline();
    if (_hasExactMountAuthority(attempt) &&
        (attempt.mount == null || _storageScopes.isCurrent(attempt.mount!))) {
      // A platform timer may run slightly early. Re-arm from the coordinator's
      // monotonic remainder instead of treating wall-clock scheduling as
      // authority.
      _armMountAuthorityWatchdog(attempt);
      return;
    }
    _fenceMountAuthorityAttempt(
      attempt,
      StateError('Account runtime authority expired while mounting.'),
    );
  }

  void _requireMountAuthorityCurrent(
    _AccountRuntimeMountAuthorityAttempt attempt,
    AccountStorageScopeMount mount,
  ) {
    final coordinator = _deviceLeaseCoordinator!;
    coordinator.enforceLocalDeadline();
    if (!attempt.fenced &&
        identical(_mountAuthorityAttempt, attempt) &&
        identical(attempt.mount, mount) &&
        _hasExactMountAuthority(attempt) &&
        _storageScopes.isCurrent(mount)) {
      return;
    }
    final failure =
        attempt.failure ??
        StateError('Account runtime authority was lost while mounting.');
    _fenceMountAuthorityAttempt(attempt, failure);
    throw failure;
  }

  bool _hasExactMountAuthority(_AccountRuntimeMountAuthorityAttempt attempt) {
    final coordinator = _deviceLeaseCoordinator;
    final current = coordinator?.currentReceipt;
    final active = _activeDeviceLease;
    return coordinator != null &&
        coordinator.canAdmitMutations &&
        current != null &&
        active != null &&
        _sameLeaseAuthority(attempt.receipt, current) &&
        _sameLeaseAuthority(attempt.receipt, active);
  }

  void _fenceMountAuthorityAttempt(
    _AccountRuntimeMountAuthorityAttempt attempt,
    Object failure,
  ) {
    if (!identical(_mountAuthorityAttempt, attempt) ||
        attempt.fenced ||
        attempt.committed) {
      return;
    }
    attempt
      ..fenced = true
      ..failure = failure;
    attempt.watchdog?.cancel();
    attempt.watchdog = null;

    // This callback deliberately bypasses the serialized lifecycle tail. The
    // in-flight mount may be awaiting an arbitrarily slow runtime builder.
    final coordinator = _deviceLeaseCoordinator!;
    coordinator.enforceLocalDeadline();
    coordinator.fence();
    _fenceRuntimeAdmission();
    if (hasCompanionRuntime) {
      error.value = failure;
      _notifyCompanionRole();
      return;
    }

    final mount = attempt.mount;
    if (mount != null) {
      _retireRuntimeBoundaryGeneration(mount.generation);
      try {
        if (_storageScopes.isCurrent(mount)) {
          _storageScopes.unmount(mount);
        }
      } catch (fenceError) {
        attempt.failure = fenceError;
        error.value = fenceError;
        phase.value = AccountSessionLifecyclePhase.faulted;
        return;
      } finally {
        if (identical(_activeMount, mount)) _activeMount = null;
      }
    }
    error.value = failure;
    phase.value = AccountSessionLifecyclePhase.retiring;
  }

  void _fenceRuntimeAdmission() {
    try {
      final drain = _fenceRuntime?.call();
      if (drain != null) {
        unawaited(drain.catchError((Object _, StackTrace _) {}));
      }
    } catch (_) {
      // The retained runtime/rollback lease owns retryable cleanup.
    }
  }

  void _commitMountAuthorityAttempt(
    _AccountRuntimeMountAuthorityAttempt? attempt,
  ) {
    if (attempt == null) return;
    attempt.committed = true;
    _finishMountAuthorityAttempt(attempt);
  }

  void _finishMountAuthorityAttempt(
    _AccountRuntimeMountAuthorityAttempt? attempt,
  ) {
    if (attempt == null) return;
    attempt.watchdog?.cancel();
    attempt.watchdog = null;
    if (identical(_mountAuthorityAttempt, attempt)) {
      _mountAuthorityAttempt = null;
    }
  }

  void _startLeaseHeartbeat(AccountDeviceLeaseReceipt receipt) {
    final coordinator = _deviceLeaseCoordinator;
    final mount = _activeMount;
    if (coordinator == null || _runtimeLease == null || mount == null) return;
    _leaseHeartbeatTimer?.cancel();
    final workerGeneration = ++_leaseWorkerGeneration;
    _armActiveLeaseWatchdog(receipt, mount, workerGeneration);
    if (workerGeneration != _leaseWorkerGeneration) return;
    var delay = receipt.renewAfter;
    if (delay < const Duration(seconds: 1)) {
      delay = const Duration(seconds: 1);
    }
    final remaining = coordinator.admissionTimeRemaining;
    if (remaining != null && remaining < delay) delay = remaining;
    if (delay.isNegative) delay = Duration.zero;
    _leaseHeartbeatTimer = Timer(delay, () {
      unawaited(
        _runSerialized<void>(
          () => _heartbeatRemoteLeaseLocked(workerGeneration),
        ).catchError((Object _, StackTrace _) {}),
      );
    });
  }

  void _armActiveLeaseWatchdog(
    AccountDeviceLeaseReceipt receipt,
    AccountStorageScopeMount mount,
    int workerGeneration,
  ) {
    _activeLeaseWatchdog?.cancel();
    final remaining = _deviceLeaseCoordinator?.admissionTimeRemaining;
    if (remaining == null) {
      _retireMountedRuntimeSynchronously(
        StateError('Mounted runtime authority has no monotonic deadline.'),
        deferCleanupToQueue: true,
      );
      return;
    }
    _activeLeaseWatchdog = _authorityWatchdogFactory(
      remaining.isNegative ? Duration.zero : remaining,
      () => _handleActiveLeaseWatchdog(receipt, mount, workerGeneration),
    );
  }

  void _handleActiveLeaseWatchdog(
    AccountDeviceLeaseReceipt receipt,
    AccountStorageScopeMount mount,
    int workerGeneration,
  ) {
    final active = _activeDeviceLease;
    if (_closed ||
        workerGeneration != _leaseWorkerGeneration ||
        _runtimeLease == null ||
        !identical(_activeMount, mount) ||
        active == null ||
        !_sameLeaseAuthority(receipt, active)) {
      return;
    }
    final coordinator = _deviceLeaseCoordinator!;
    coordinator.enforceLocalDeadline();
    final current = coordinator.currentReceipt;
    if (coordinator.canAdmitMutations &&
        current != null &&
        _sameLeaseAuthority(receipt, current) &&
        _storageScopes.isCurrent(mount)) {
      // Platform timers can fire early. Only the coordinator's monotonic
      // deadline can decide whether a renewed receipt still grants authority.
      _armActiveLeaseWatchdog(receipt, mount, workerGeneration);
      return;
    }
    // Do not wait for a heartbeat HTTP request or a handoff operation occupying
    // the queue. Fence producers/storage and notify presentation immediately;
    // exact remote release must wait until that in-flight operation settles.
    _retireMountedRuntimeSynchronously(
      StateError('Mounted runtime authority expired locally.'),
      deferCleanupToQueue: true,
    );
  }

  Future<void> _heartbeatRemoteLeaseLocked(int workerGeneration) async {
    if (workerGeneration != _leaseWorkerGeneration ||
        _runtimeLease == null ||
        _activeMount == null) {
      return;
    }
    final coordinator = _deviceLeaseCoordinator!;
    final expected = _activeDeviceLease;
    if (expected == null) {
      _fenceMountedRuntimeForLeaseLoss(
        workerGeneration,
        StateError('Mounted runtime lost its remote lease receipt.'),
      );
      return;
    }
    try {
      final renewed = await coordinator.heartbeat();
      if (!_sameLeaseAuthority(expected, renewed)) {
        throw StateError('Remote heartbeat changed exact lease authority.');
      }
      if (workerGeneration != _leaseWorkerGeneration) return;
      _activeDeviceLease = renewed;
      _startLeaseHeartbeat(renewed);
    } catch (exception) {
      _fenceMountedRuntimeForLeaseLoss(workerGeneration, exception);
    }
  }

  void _fenceMountedRuntimeForLeaseLoss(
    int workerGeneration,
    Object exception,
  ) {
    if (workerGeneration != _leaseWorkerGeneration) return;
    _retireMountedRuntimeSynchronously(exception);
  }

  void _stopLeaseHeartbeat() {
    _leaseHeartbeatTimer?.cancel();
    _leaseHeartbeatTimer = null;
    _activeLeaseWatchdog?.cancel();
    _activeLeaseWatchdog = null;
    _leaseWorkerGeneration++;
  }

  static bool _requiresCredentialVerification(
    AccountDeviceLeaseRequestException exception,
  ) =>
      exception.code == 'AUTHENTICATION_REQUIRED' ||
      exception.statusCode == 401 ||
      exception.statusCode == 403;

  static bool _sameLeaseAuthority(
    AccountDeviceLeaseReceipt left,
    AccountDeviceLeaseReceipt right,
  ) =>
      left.agentId == right.agentId &&
      left.leaseId == right.leaseId &&
      left.epoch == right.epoch &&
      left.installationId == right.installationId &&
      left.runtimeInstanceId == right.runtimeInstanceId &&
      left.presenceSessionId == right.presenceSessionId;

  Future<void> _unmountLocked() async {
    if (_companionRuntimeLease != null) {
      await _unmountCompanionAccountLocked();
      return;
    }
    _cancelShadowObservationAndRelease();
    if (_closingLease != null &&
        (_runtimeLease != null || _activeMount != null)) {
      final exception = StateError(
        'Closing and active account runtime leases cannot coexist.',
      );
      error.value = exception;
      phase.value = AccountSessionLifecyclePhase.faulted;
      throw exception;
    }
    final closingLease = _closingLease;
    if (closingLease != null) {
      _stopLeaseHeartbeat();
      phase.value = AccountSessionLifecyclePhase.retiring;
      try {
        await (_closingDrain ??= closingLease.close());
        _closingDrain = null;
        _closingLease = null;
        _activeDeviceLease = null;
        _credentialCleanupRetryPending = false;
        error.value = null;
        phase.value = _phaseAfterRuntimeStops;
      } catch (exception) {
        _closingDrain = null;
        error.value = exception;
        phase.value = AccountSessionLifecyclePhase.faulted;
        rethrow;
      }
      return;
    }

    final lease = _runtimeLease;
    final mount = _activeMount;
    if (lease == null && mount == null) {
      if (_auth.session.value != null) {
        final teardown = _AccountRuntimeTeardownLease(
          unpublishSession: _auth.unpublishSession,
        );
        _closingLease = teardown;
        phase.value = AccountSessionLifecyclePhase.retiring;
        try {
          await (_closingDrain ??= teardown.close());
          _closingDrain = null;
          _closingLease = null;
          error.value = null;
        } catch (exception) {
          _closingDrain = null;
          error.value = exception;
          phase.value = AccountSessionLifecyclePhase.faulted;
          rethrow;
        }
      }
      if (!isFaulted) {
        phase.value = _phaseAfterRuntimeStops;
      }
      return;
    }
    if (lease == null || mount == null) {
      if (mount != null) {
        _retireRuntimeBoundaryGeneration(mount.generation);
      }
      final exception = StateError(
        'Account runtime mount and lease are inconsistent.',
      );
      error.value = exception;
      phase.value = AccountSessionLifecyclePhase.faulted;
      throw exception;
    }

    // Fence the runtime synchronously before waiting for any async disposal.
    // A stale writer loses its storage generation immediately, while a failed
    // close retains [_closingLease] as a hard block on every future mount.
    _stopLeaseHeartbeat();
    _fenceRuntimeAdmission();
    _retireRuntimeBoundaryGeneration(mount.generation);
    phase.value = AccountSessionLifecyclePhase.retiring;
    error.value = null;
    try {
      _storageScopes.unmount(mount);
      // The storage generation is fenced synchronously above. Keep this
      // serialized lifecycle operation at the boundary until every old-account
      // sensitive surface confirms that it is no longer visible.
      await _storageScopes.whenBoundaryReleased;
    } catch (exception) {
      error.value = exception;
      phase.value = AccountSessionLifecyclePhase.faulted;
      rethrow;
    }
    _runtimeLease = null;
    _activeMount = null;
    _closingLease = lease;
    try {
      await (_closingDrain ??= lease.close());
      _closingDrain = null;
      _closingLease = null;
      _activeDeviceLease = null;
      phase.value = _phaseAfterRuntimeStops;
    } catch (exception) {
      _closingDrain = null;
      error.value = exception;
      phase.value = AccountSessionLifecyclePhase.faulted;
      rethrow;
    }
  }

  Future<void> _beforeCredentialsCleared() {
    _cancelPolicyWatchdogs(clearPolicy: true);
    _cancelShadowObservationAndRelease();
    // signOutAndUnmount already attempted this retained lease inside the
    // serialized operation. Re-enqueueing here would wait on that same
    // operation forever; credentials may still be cleared while the faulted
    // lease remains fenced for an explicit retry.
    if (_signOutOwnsUnmountBoundary) {
      return Future<void>.value();
    }
    if (_runtimeLease == null &&
        _activeMount == null &&
        _closingLease == null) {
      if (_deviceLeaseCoordinator?.currentPresence != null) {
        return _runSerialized(_closeRemotePresenceLocked);
      }
      return Future<void>.value();
    }
    return _runSerialized(() async {
      await _unmountLocked();
      await _closeRemotePresenceLocked();
    });
  }

  AccountSessionLifecyclePhase get _phaseAfterRuntimeStops =>
      (_requireExclusiveDeviceLease ||
              (_authorityCompileMaximum ==
                      AccountRuntimeAuthorityMode.enforce &&
                  (_enforcementActivated ||
                      _effectiveAuthorityMode ==
                          AccountRuntimeAuthorityMode.enforce))) &&
          hasAuthenticatedCandidate
      ? AccountSessionLifecyclePhase.authenticatedStandby
      : AccountSessionLifecyclePhase.signedOut;

  Future<bool> _handleCredentialCleanupFailure(
    AuthCredentialCleanupFailure failure, {
    required int observedGeneration,
  }) => _runSerialized(() async {
    if (!_auth.isCredentialCleanupFailureCurrent(failure) ||
        generation != observedGeneration) {
      return false;
    }

    // A same-epoch failure must fence and retain its own active runtime before
    // installing the credential retry. A newer account necessarily changes
    // the auth epoch or storage generation and was rejected above.
    if (_runtimeLease != null || _activeMount != null) {
      try {
        await _unmountLocked();
      } catch (_) {
        // _unmountLocked retained the failed runtime in _closingLease.
      }
    }
    _retainCredentialCleanupFailure(failure);
    return true;
  });

  void _retainCredentialCleanupFailure(Object exception) {
    if (_closed) return;
    if (_runtimeLease != null || _activeMount != null) {
      throw StateError(
        'Credential cleanup cannot be retained beside an active runtime.',
      );
    }
    if (!_credentialCleanupRetryPending) {
      final retainedCleanup = _closingLease;
      _closingLease = _AccountRuntimeTeardownLease(
        unpublishSession: _auth.retryCredentialCleanup,
        runtime: retainedCleanup,
      );
      _credentialCleanupRetryPending = true;
      // Only a credential-only fault may be superseded by a server-validated
      // fresh login. Any retained runtime/remote cleanup remains a hard gate.
      _credentialCleanupIsAuthenticationSupersedable = retainedCleanup == null;
    }
    error.value = exception;
    phase.value = AccountSessionLifecyclePhase.faulted;
  }

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      if (_closed) {
        completer.completeError(
          StateError('account_session_lifecycle_service_closed'),
        );
        return;
      }
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    _applicationForeground = false;
    _presenceRecoveryTimer?.cancel();
    _presenceRecoveryTimer = null;
    _finishMountAuthorityAttempt(_mountAuthorityAttempt);
    final republishAttempt = _republishAuthorityAttempt;
    if (republishAttempt != null) {
      if (!republishAttempt.operationSettled.isCompleted) {
        republishAttempt.operationSettled.complete();
      }
      _finishRepublishAuthorityAttempt(republishAttempt);
    }
    _cancelPolicyWatchdogs(clearPolicy: true);
    _cancelShadowObservationAndRelease();
    _stopLeaseHeartbeat();
    final mount = _activeMount;
    if (mount != null) {
      _fenceRuntimeAdmission();
      try {
        _retireRuntimeBoundaryGeneration(mount.generation);
      } catch (exception) {
        error.value = exception;
      }
      try {
        if (_storageScopes.isCurrent(mount)) {
          _storageScopes.unmount(mount);
        }
      } catch (exception) {
        error.value ??= exception;
      } finally {
        if (identical(_activeMount, mount)) _activeMount = null;
      }
    }
    phase.value = AccountSessionLifecyclePhase.closed;
    _phaseWorker.dispose();
    _phaseChanges.dispose();
    if (identical(_auth.beforeCredentialsCleared, _credentialsClearHook)) {
      _auth.beforeCredentialsCleared = _previousBeforeCredentialsCleared;
    }
    if (identical(
      _auth.credentialCleanupFailureObserver,
      _credentialCleanupFailureObserver,
    )) {
      _auth.credentialCleanupFailureObserver =
          _previousCredentialCleanupFailureObserver;
    }
    super.onClose();
  }
}

class _AccountSessionPhaseNotifier extends ChangeNotifier {
  void emit() => notifyListeners();
}
