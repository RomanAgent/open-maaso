import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

import 'conversation_proxy_probe.dart';

const stagingConversationProbeOrigin = 'https://api-test.futurpals.com.cn';

/// These are observations, not a login operation or a new account role.
final class StagingProbeReadiness {
  const StagingProbeReadiness({
    required this.origin,
    required this.committedSessionPresent,
    required this.sessionValid,
    required this.authIdle,
    required this.mountedAccountMatches,
    required this.runtimeIdle,
    required this.privacyReady,
    required this.proxyMode,
    required this.originApproved,
    this.accountHash,
  });
  final String? origin, accountHash;
  final bool committedSessionPresent,
      sessionValid,
      authIdle,
      mountedAccountMatches,
      runtimeIdle,
      privacyReady,
      proxyMode,
      originApproved;
  String? get blockedReason {
    if (!originApproved) return 'staging_origin_required';
    if (!committedSessionPresent) return 'committed_session_required';
    if (!sessionValid) return 'session_expired_or_near_expiry_no_refresh';
    if (!authIdle) return 'authentication_busy';
    if (!mountedAccountMatches) return 'account_mount_unavailable';
    if (!runtimeIdle) return 'runtime_not_idle';
    if (!proxyMode) return 'managed_proxy_mode_required';
    if (!privacyReady) return 'loaded_privacy_permission_required';
    return null;
  }

  bool get ready => blockedReason == null;
  Map<String, Object?> toJson() => {
    'origin': origin,
    'expectedOrigin': stagingConversationProbeOrigin,
    'originApproved': originApproved,
    'committedSessionPresent': committedSessionPresent,
    'sessionValid': sessionValid,
    'authIdle': authIdle,
    'mountedAccountMatches': mountedAccountMatches,
    'runtimeIdle': runtimeIdle,
    'privacyReady': privacyReady,
    'proxyMode': proxyMode,
    'accountHash': accountHash,
    'canRunSingleProbe': ready,
    'blockedReason': blockedReason,
    'scope': 'stateless_cloud_http_only',
    'serverMeteringWrites': true,
    'providerMayTokenizeBeforeCompletion': true,
    'providerReceivesExistingAccountUserId': true,
    'dedicatedBenchmarkAccountProven': false,
    'fullPipelineBenchmarkAllowed': false,
  };
}

final class StagingProbeTransport {
  const StagingProbeTransport(this.client, this.close);
  final PresentationStreamingLLMClient client;
  final void Function() close;
}

/// Its closures remain inside the authenticated process. Nothing returned by
/// readReadiness/runOnce contains the session, token, messages or provider prose.
final class StagingProbeAdmission {
  const StagingProbeAdmission({
    required this.readiness,
    required this.isCurrent,
    required this.openTransport,
  });
  final StagingProbeReadiness readiness;
  final bool Function() isCurrent;
  final StagingProbeTransport Function(void Function() onHttpDispatch)
  openTransport;
}

final class ConversationStagingProbeHost {
  ConversationStagingProbeHost({
    required StagingProbeAdmission Function() admission,
    this.timeout = ConversationProxyProbe.maxTimeout,
    this.contextPollInterval = const Duration(milliseconds: 25),
  }) : _admission = admission {
    if (timeout <= Duration.zero ||
        timeout > ConversationProxyProbe.maxTimeout ||
        contextPollInterval <= Duration.zero) {
      throw ArgumentError('Invalid bounded probe duration');
    }
  }
  factory ConversationStagingProbeHost.fromApp({
    http.Client Function()? httpClientFactory,
    Duration timeout = ConversationProxyProbe.maxTimeout,
  }) => ConversationStagingProbeHost(
    admission: () => _appAdmission(httpClientFactory ?? http.Client.new),
    timeout: timeout,
  );
  final StagingProbeAdmission Function() _admission;
  final Duration timeout, contextPollInterval;
  Future<Map<String, Object?>>? _operation;
  Map<String, Object?>? lastReceipt;

  /// Synchronous, network-free and storage-free. Does not consume the attempt.
  Map<String, Object?> readReadiness() {
    final readiness = _admission().readiness;
    return {
      ...readiness.toJson(),
      'canRunSingleProbe': _operation == null && readiness.ready,
      'blockedReason': _operation == null
          ? readiness.blockedReason
          : 'single_probe_consumed',
      'singleProbeConsumed': _operation != null,
    };
  }

  Future<Map<String, Object?>> runOnce() {
    final existing = _operation;
    if (existing != null) return existing;
    final admission = _admission();
    if (!admission.readiness.ready || !admission.isCurrent()) {
      return Future.value(
        lastReceipt = {
          'status': 'not_ready',
          'networkRequested': false,
          'readiness': admission.readiness.toJson(),
        },
      );
    }
    // Set the one-shot gate before any asynchronous dispatch can be repeated.
    final completion = Completer<Map<String, Object?>>();
    _operation = completion.future;
    unawaited(
      _run(admission).then((receipt) {
        lastReceipt = receipt;
        completion.complete(receipt);
      }),
    );
    return completion.future;
  }

  Future<Map<String, Object?>> _run(StagingProbeAdmission admission) async {
    final total = Stopwatch()..start();
    final cloud = Stopwatch();
    var dispatches = 0;
    var contextChanged = false;
    var closed = false;
    StagingProbeTransport? transport;
    Timer? contextTimer;
    _TimedPresentationClient? timed;
    void close() {
      if (closed) return;
      closed = true;
      try {
        transport?.close();
      } catch (_) {
        /* fixed sanitized result only */
      }
    }

    try {
      transport = admission.openTransport(() {
        if (!admission.isCurrent() || dispatches != 0) {
          throw StateError('probe_dispatch_fenced');
        }
        dispatches++;
        cloud.start();
      });
      timed = _TimedPresentationClient(
        transport.client,
        cloud,
        admission.isCurrent,
      );
      contextTimer = Timer.periodic(contextPollInterval, (_) {
        var current = false;
        try {
          current = admission.isCurrent();
        } catch (_) {
          /* fail closed */
        }
        if (!current) {
          contextChanged = true;
          close();
        }
      });
      final result = await const ConversationProxyProbe().run(
        timed,
        timeout: timeout,
      );
      contextChanged = contextChanged || !admission.isCurrent();
      return {
        ...result.toJson(),
        if (contextChanged) 'status': 'context_changed',
        if (contextChanged) 'supportsContract': false,
        'networkRequested': dispatches == 1,
        'appHttpDispatchCount': dispatches,
        'readiness': admission.readiness.toJson(),
        'metrics': {
          'first_cloud_delta_ms': contextChanged ? null : timed.firstDeltaMs,
          'finish_ms': contextChanged ? null : timed.finishMs,
          'terminal_elapsed_ms': total.elapsedMicroseconds / 1000,
        },
        'finishBoundary': contextChanged ? null : timed.finishBoundary,
        'measurementStart': 'immediately_before_http_send',
        'notMeasured': ['first_visible', 'first_acoustic', 'task_complete'],
      };
    } catch (_) {
      return {
        'status': 'probe_setup_failed',
        'networkRequested': dispatches == 1,
        'appHttpDispatchCount': dispatches,
        'readiness': admission.readiness.toJson(),
        'metrics': {
          'first_cloud_delta_ms': null,
          'finish_ms': null,
          'terminal_elapsed_ms': total.elapsedMicroseconds / 1000,
        },
        'notMeasured': ['first_visible', 'first_acoustic', 'task_complete'],
      };
    } finally {
      contextTimer?.cancel();
      close();
    }
  }
}

StagingProbeAdmission _appAdmission(http.Client Function() httpClientFactory) {
  final environment = appServices.peek<AppEnvironmentService>();
  final config = appServices.peek<RealtimeAgentConfig>();
  final auth = appServices.peek<AuthSessionService>();
  final session = auth?.session.value;
  final scopes = appServices.peek<AccountStorageScopeService>();
  final mount = scopes?.activeMount;
  final registry = appServices.peek<AgentRuntimeRegistry>();
  final privacy = appServices.peek<PrivacyService>();
  final modes = appServices.peek<MaasoAgentModeService>();
  final base = config?.baseUri;
  bool originApproved() =>
      environment?.environment.value == MaasoEnvironment.test &&
      config?.isReady == true &&
      base != null &&
      config!.baseUri == base &&
      base.scheme == 'https' &&
      base.host == 'api-test.futurpals.com.cn' &&
      base.port == 443 &&
      base.userInfo.isEmpty &&
      !base.hasQuery &&
      !base.hasFragment &&
      (base.path.isEmpty || base.path == '/');
  bool mountMatches() =>
      session != null &&
      mount != null &&
      scopes!.isCurrent(mount) &&
      mount.scope.environmentKey == 'test' &&
      mount.scope.accountUuid == session.accountUuid;
  bool committed() =>
      auth?.hasCommittedSessionForEnvironment(MaasoEnvironment.test) == true &&
      identical(auth?.session.value, session);
  bool permission() =>
      privacy?.allowsLoadedConsent(
        recipientId: 'ark',
        scope: PrivacyScopes.cloudText,
      ) ==
      true;
  bool proxyMode() => modes != null && modes.pipelineMode.value.usesProxyLlm;
  final readiness = StagingProbeReadiness(
    origin:
        base != null &&
            {'http', 'https'}.contains(base.scheme) &&
            base.host.isNotEmpty
        ? base.origin
        : null,
    originApproved: originApproved(),
    committedSessionPresent: committed(),
    sessionValid: session?.isValid == true,
    authIdle: auth?.isLoading.value == false,
    mountedAccountMatches: mountMatches(),
    runtimeIdle: registry?.isIdleForDiagnostics == true,
    privacyReady: permission(),
    proxyMode: proxyMode(),
    accountHash: mountMatches() ? mount!.scope.accountDigest : null,
  );
  bool isCurrent() =>
      readiness.ready &&
      originApproved() &&
      committed() &&
      session!.isValid &&
      auth!.isLoading.value == false &&
      mountMatches() &&
      registry!.isIdleForDiagnostics &&
      permission() &&
      proxyMode() &&
      identical(environment, appServices.peek<AppEnvironmentService>()) &&
      identical(config, appServices.peek<RealtimeAgentConfig>()) &&
      identical(auth, appServices.peek<AuthSessionService>()) &&
      identical(scopes, appServices.peek<AccountStorageScopeService>()) &&
      identical(registry, appServices.peek<AgentRuntimeRegistry>()) &&
      identical(privacy, appServices.peek<PrivacyService>()) &&
      identical(modes, appServices.peek<MaasoAgentModeService>());
  return StagingProbeAdmission(
    readiness: readiness,
    isCurrent: isCurrent,
    openTransport: (onDispatch) {
      if (!isCurrent()) throw StateError('probe_session_unavailable');
      final transport = _StagingOnlyHttpClient(
        httpClientFactory(),
        isCurrent,
        onDispatch,
      );
      final client = MaasoThinProxyLLMClient(
        baseUri: base!,
        model: LLMDefaults.model,
        accessTokenProvider: () async {
          if (!isCurrent()) throw StateError('probe_session_changed');
          return session!.accessToken;
        },
        httpClient: transport,
      );
      return StagingProbeTransport(client, transport.close);
    },
  );
}

final class _StagingOnlyHttpClient extends http.BaseClient {
  _StagingOnlyHttpClient(this.inner, this.isCurrent, this.onDispatch);
  final http.Client inner;
  final bool Function() isCurrent;
  final void Function() onDispatch;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!isCurrent() ||
        request.method != 'POST' ||
        request.url.toString() !=
            '$stagingConversationProbeOrigin/v1/proxy/llm/stream') {
      throw StateError('probe_endpoint_rejected');
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    onDispatch();
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

final class _TimedPresentationClient extends LLMClient {
  _TimedPresentationClient(this.inner, this.clock, this.isCurrent);
  final PresentationStreamingLLMClient inner;
  final Stopwatch clock;
  final bool Function() isCurrent;
  double? firstDeltaMs, finishMs;
  String? finishBoundary;
  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await for (final event in inner.streamPresentationChatEvents(
      messages,
      timeout: timeout,
    )) {
      if (!isCurrent()) throw StateError('probe_context_changed');
      if (clock.isRunning && event.isReplyDelta && event.deltaText.isNotEmpty) {
        firstDeltaMs ??= clock.elapsedMicroseconds / 1000;
      }
      if (clock.isRunning && event.isDone) {
        finishMs ??= clock.elapsedMicroseconds / 1000;
        finishBoundary = 'protocol_done';
      }
      yield event;
    }
    if (clock.isRunning && finishMs == null) {
      finishMs = clock.elapsedMicroseconds / 1000;
      finishBoundary = 'transport_eof';
    }
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw UnsupportedError('probe_stream_only');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('probe_stream_only');
}
