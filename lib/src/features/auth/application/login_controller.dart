import 'dart:async';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'login_doorway_coordinator.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/offline/local_edition_policy.dart';
import 'package:maaso/src/offline/local_test_auth_client.dart';

class LoginController extends AppController {
  final AppEnvironmentService _environment = appServices
      .find<AppEnvironmentService>();
  final AuthSessionService _auth = appServices.find<AuthSessionService>();
  final AccountSessionLifecycleService _accountLifecycle = appServices
      .find<AccountSessionLifecycleService>();

  late final TextEditingController email;
  late final TextEditingController password;
  late final TextEditingController code;
  late final Rx<MaasoEnvironment> selectedEnvironment;
  late final RxBool isLoading;
  late final RxBool isSignupMode;
  late final RxBool isSendingCode;
  late final RxnInt signupCodeId;
  late final RxnString error;
  late final RxnString notice;
  late final RxBool canRetryCredentialCleanup;
  late final RxBool isRetryingCredentialCleanup;
  Worker? _accountLifecycleWorker;
  bool _requiresReauthentication = false;
  final _submissionInFlight = false.obs;
  bool get busy => isLoading.value || _submissionInFlight.value;
  Future<void> Function()? beforeAuthenticatedNavigation;

  List<MaasoEnvironment> get allowedEnvironments =>
      _environment.allowedEnvironments;

  @override
  void onInit() {
    super.onInit();
    email = TextEditingController(
      text: kOpenMaasoLocalEdition ? LocalTestAuthClient.username : null,
    );
    password = TextEditingController(
      text: kOpenMaasoLocalEdition ? LocalTestAuthClient.password : null,
    );
    code = TextEditingController();
    selectedEnvironment = _environment.environment.value.obs;
    isLoading = _auth.isLoading;
    isSignupMode = false.obs;
    isSendingCode = false.obs;
    signupCodeId = RxnInt();
    error = _auth.error;
    notice = RxnString();
    canRetryCredentialCleanup = false.obs;
    isRetryingCredentialCleanup = false.obs;
    _accountLifecycleWorker = _accountLifecycle.phase.listen(
      _handleAccountLifecyclePhase,
    );
    // LoginController is created while LoginPage's State is mounted. Applying
    // an existing lifecycle fault synchronously here mutates Riverpod during
    // that build. Preserve live updates, but replay the current phase after
    // the widget tree has finished the synchronous mount.
    scheduleMicrotask(() {
      if (_accountLifecycleWorker == null) return;
      _handleAccountLifecyclePhase(_accountLifecycle.phase.value);
    });
  }

  Future<void> setEnvironment(MaasoEnvironment next) async {
    await _accountLifecycle.switchEnvironment(next);
    selectedEnvironment.value = _environment.environment.value;
    error.value = null;
    notice.value = null;
    signupCodeId.value = null;
    if (appServices.isRegistered<RealtimeAgentConfig>()) {
      appServices.find<RealtimeAgentConfig>().updateBaseUrl(
        _environment.baseUrl,
      );
    }
    await _installProxyTtsEngine();
  }

  void setSignupMode(bool next) {
    isSignupMode.value = next;
    clearTransientMessages();
    code.clear();
  }

  void clearTransientMessages() {
    error.value = null;
    notice.value = null;
    signupCodeId.value = null;
  }

  void providerLoginUnavailable(String provider) {
    notice.value = null;
    error.value = 'auth.provider_unavailable'.trParams({'provider': provider});
  }

  Future<void> submit() async {
    if (isClosed || _submissionInFlight.value) return;
    _submissionInFlight.value = true;
    try {
      await (isSignupMode.value ? signup() : login());
    } finally {
      _submissionInFlight.value = false;
    }
  }

  Future<void> login() async {
    notice.value = null;
    final mail = email.text.trim();
    final pass = password.text;
    if (mail.isEmpty || pass.isEmpty) {
      error.value = 'auth.email_password_required'.tr;
      return;
    }
    final attempt = DateTime.now().microsecondsSinceEpoch;
    final elapsed = Stopwatch()..start();
    Log.i(
      '[AuthFlow/$attempt] login start '
      'environment=${selectedEnvironment.value.key} '
      'lifecycle=${_accountLifecycle.phase.value.name}',
    );
    try {
      final mounted = await _accountLifecycle.authenticateAndMount(
        () => _auth.loginCandidate(email: mail, password: pass),
      );
      if (!mounted) {
        Log.w(
          '[AuthFlow/$attempt] login not mounted '
          'environment=${selectedEnvironment.value.key} '
          'lifecycle=${_accountLifecycle.phase.value.name} '
          'lifecycleErrorType=${_accountLifecycle.error.value?.runtimeType} '
          'elapsedMs=${elapsed.elapsedMilliseconds}',
        );
        return;
      }
      await _finishAuthenticatedLogin();
      Log.i(
        '[AuthFlow/$attempt] login complete '
        'environment=${selectedEnvironment.value.key} '
        'elapsedMs=${elapsed.elapsedMilliseconds}',
      );
      appNavigation.go(
        IdentityRoutePolicy.redirect(AppRouteCatalog.home) ??
            AppRouteCatalog.home,
      );
    } catch (caught, stackTrace) {
      Log.e(
        '[AuthFlow/$attempt] login failed '
        'environment=${selectedEnvironment.value.key} '
        'lifecycle=${_accountLifecycle.phase.value.name} '
        'errorType=${caught.runtimeType} '
        'elapsedMs=${elapsed.elapsedMilliseconds}',
        stackTrace: stackTrace,
      );
      if (caught is AccountRuntimeMountFailure) {
        Log.e(
          '[AuthFlow/$attempt] runtime mount rollback failed '
          'causeType=${caught.cause.runtimeType} '
          'cleanupErrorType=${caught.cleanupError.runtimeType}',
          stackTrace: caught.causeStackTrace,
        );
        Log.e(
          '[AuthFlow/$attempt] runtime rollback cleanup stack '
          'cleanupErrorType=${caught.cleanupError.runtimeType}',
          stackTrace: caught.cleanupStackTrace,
        );
      }
      if (error.value?.trim().isEmpty ?? true) {
        error.value = 'common.request_failed'.tr;
      }
    } finally {
      elapsed.stop();
    }
  }

  Future<void> sendSignupCode() async {
    final mail = email.text.trim();
    if (mail.isEmpty) {
      error.value = 'auth.email_required'.tr;
      return;
    }
    isSendingCode.value = true;
    notice.value = null;
    try {
      signupCodeId.value = await _auth.issueEmailCaptcha(email: mail);
      error.value = null;
      notice.value = 'auth.code_sent'.tr;
    } catch (_) {
      notice.value = null;
    } finally {
      isSendingCode.value = false;
    }
  }

  Future<void> signup() async {
    notice.value = null;
    final mail = email.text.trim();
    final pass = password.text;
    final captcha = code.text.trim();
    final codeId = signupCodeId.value;
    if (mail.isEmpty || pass.isEmpty) {
      error.value = 'auth.email_password_required'.tr;
      return;
    }
    if (captcha.isEmpty) {
      error.value = 'auth.code_required'.tr;
      return;
    }
    if (codeId == null || codeId <= 0) {
      error.value = 'auth.send_code_first'.tr;
      return;
    }
    try {
      final mounted = await _accountLifecycle.authenticateAndMount(
        () => _auth.signupCandidate(
          email: mail,
          password: pass,
          codeId: codeId,
          code: captcha,
        ),
      );
      if (!mounted) return;
      await _finishAuthenticatedLogin();
      appNavigation.go(
        IdentityRoutePolicy.redirect(AppRouteCatalog.home) ??
            AppRouteCatalog.home,
      );
    } catch (_) {
      if (error.value?.trim().isEmpty ?? true) {
        error.value = 'common.request_failed'.tr;
      }
    }
  }

  Future<void> retryCredentialCleanup() async {
    if (isRetryingCredentialCleanup.value || _requiresReauthentication) return;
    final attempt = DateTime.now().microsecondsSinceEpoch;
    final elapsed = Stopwatch()..start();
    isRetryingCredentialCleanup.value = true;
    notice.value = null;
    Log.i(
      '[AuthFlow/$attempt] credential cleanup retry start '
      'lifecycle=${_accountLifecycle.phase.value.name} '
      'lifecycleErrorType=${_accountLifecycle.error.value?.runtimeType}',
    );
    try {
      await _accountLifecycle.retryFaultedCleanup();
      canRetryCredentialCleanup.value = false;
      error.value = null;
      Log.i(
        '[AuthFlow/$attempt] credential cleanup retry complete '
        'lifecycle=${_accountLifecycle.phase.value.name} '
        'elapsedMs=${elapsed.elapsedMilliseconds}',
      );
    } catch (caught, stackTrace) {
      _reportRecoveryFailure('retry_failed', caught);
      Log.e(
        '[AuthFlow/$attempt] credential cleanup retry failed '
        'lifecycle=${_accountLifecycle.phase.value.name} '
        'errorType=${caught.runtimeType} '
        'elapsedMs=${elapsed.elapsedMilliseconds}',
        stackTrace: stackTrace,
      );
      _requiresReauthentication |= _isReauthenticationFailure(caught);
      canRetryCredentialCleanup.value = !_requiresReauthentication;
      error.value = _requiresReauthentication
          ? 'auth.session_reauthentication_required'.tr
          : 'common.request_failed'.tr;
    } finally {
      elapsed.stop();
      isRetryingCredentialCleanup.value = false;
    }
  }

  void _handleAccountLifecyclePhase(AccountSessionLifecyclePhase phase) {
    if (phase == AccountSessionLifecyclePhase.faulted) {
      _reportRecoveryFailure('fault_observed', _accountLifecycle.error.value);
      final hasReauthenticationFailure = _isReauthenticationFailure(
        _accountLifecycle.error.value,
      );
      final newlyRequiresReauthentication =
          !_requiresReauthentication &&
          (hasReauthenticationFailure ||
              _auth.requiresCredentialReauthentication);
      _requiresReauthentication |= newlyRequiresReauthentication;
      canRetryCredentialCleanup.value = !_requiresReauthentication;
      notice.value = null;
      if ((newlyRequiresReauthentication && hasReauthenticationFailure) ||
          (_requiresReauthentication &&
              (error.value?.trim().isEmpty ?? true))) {
        error.value = 'auth.session_reauthentication_required'.tr;
      } else if (error.value?.trim().isEmpty ?? true) {
        error.value = 'common.request_failed'.tr;
      }
      return;
    }
    // A rejected login replaces lifecycle.error with its own failure. Keep the
    // recovery choice through authenticating/faulted so an incorrect password
    // cannot bring back a cleanup action that will never resolve this state.
    if (phase == AccountSessionLifecyclePhase.signedOut ||
        phase == AccountSessionLifecyclePhase.mounted ||
        phase == AccountSessionLifecyclePhase.closed) {
      _requiresReauthentication = false;
    }
    if (!isRetryingCredentialCleanup.value) {
      canRetryCredentialCleanup.value = false;
    }
  }

  bool _isReauthenticationFailure(Object? failure) =>
      failure is AuthCredentialReauthenticationRequired ||
      (failure is AuthCredentialCleanupFailure &&
          failure.cause is AuthCredentialReauthenticationRequired);

  void _reportRecoveryFailure(String stage, Object? failure) {
    // The general Logger uses a debug-only filter. Keep this recovery boundary
    // diagnosable on release devices without enabling arbitrary auth logs.
    final fields = <String>[
      '[AuthRecovery] stage=$stage',
      'phase=${_accountLifecycle.phase.value.name}',
    ];
    void appendFailure(String path, Object? error, int depth) {
      fields.add('$path.type=${error?.runtimeType}');
      // flutter_secure_storage_darwin emits this fixed code with an integer
      // OSStatus. No other platform details, messages, or credentials are safe
      // to include in this diagnostic.
      if (error is PlatformException &&
          error.code == 'Unexpected security result code' &&
          error.details is int) {
        fields.add('$path.osStatus=${error.details as int}');
      }
      if (depth >= 2) return;
      if (error is AuthCredentialCleanupFailure) {
        appendFailure('$path.cause', error.cause, depth + 1);
      } else if (error is AccountRuntimeMountFailure) {
        appendFailure('$path.cause', error.cause, depth + 1);
        appendFailure('$path.cleanup', error.cleanupError, depth + 1);
      } else if (error is AccountRuntimeTeardownFailure) {
        appendFailure('$path.projection', error.projectionError, depth + 1);
        appendFailure('$path.runtime', error.runtimeError, depth + 1);
      }
    }

    appendFailure('error', failure, 0);
    debugPrint(fields.join(' '));
  }

  Future<void> _finishAuthenticatedLogin() async {
    await _installProxyTtsEngine();
    LoginDoorwayCoordinator.ensure().requestAuthenticated();
    try {
      await beforeAuthenticatedNavigation?.call();
    } catch (_) {
      // Authentication should not be blocked by optional entrance choreography.
    }
  }

  Future<void> _installProxyTtsEngine() async {
    if (appServices.isRegistered<AgentPipelineRuntimeService>()) {
      await appServices
          .find<AgentPipelineRuntimeService>()
          .refreshForCurrentMode();
    }
  }

  @override
  void onClose() {
    final accountLifecycleWorker = _accountLifecycleWorker;
    _accountLifecycleWorker = null;
    accountLifecycleWorker?.dispose();
    email.dispose();
    password.dispose();
    code.dispose();
    super.onClose();
  }
}
