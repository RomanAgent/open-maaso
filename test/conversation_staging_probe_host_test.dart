import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_proxy_probe.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_staging_probe_host.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_service_test.dart' show PrivacyFake;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test('readiness cannot instantiate lazy services or run their lifecycle', () {
    var initialized = 0;
    appServices.lazyPut<RealtimeAgentConfig>(() {
      initialized++;
      return RealtimeAgentConfig(
        enabled: true,
        baseUri: Uri.parse('$stagingConversationProbeOrigin/'),
      );
    });
    appServices.lazyPut<AgentRuntimeRegistry>(() {
      initialized++;
      return AgentRuntimeRegistry();
    });
    expect(appServices.peek<RealtimeAgentConfig>(), isNull);
    final host = ConversationStagingProbeHost.fromApp();
    expect(host.readReadiness()['canRunSingleProbe'], isFalse);
    expect(initialized, 0);
    expect(appServices.peek<AgentRuntimeRegistry>(), isNull);
  });

  test(
    'readiness observes published test account without storage or network and exposes only hash',
    () async {
      final h = await _Harness.create();
      var factories = 0;
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () {
          factories++;
          throw StateError('must not open');
        },
      );
      for (var i = 0; i < 3; i++) {
        final ready = host.readReadiness();
        expect(ready['canRunSingleProbe'], isTrue);
        expect(ready['origin'], stagingConversationProbeOrigin);
        expect(ready['accountHash'], matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(ready['singleProbeConsumed'], isFalse);
        expect(jsonEncode(ready), isNot(contains(_account)));
        expect(jsonEncode(ready), isNot(contains(_token)));
      }
      expect(factories, 0);
      h.expectNoIo();
    },
  );

  test(
    'durable candidate or directly assigned session is not a committed standard session',
    () async {
      final h = await _Harness.create(publish: false);
      final host = ConversationStagingProbeHost.fromApp();
      expect(
        host.readReadiness()['blockedReason'],
        'committed_session_required',
      );
      h.auth.session.value = h.auth.candidate!.session;
      expect(
        host.readReadiness()['blockedReason'],
        'committed_session_required',
      );
      expect((await host.runOnce())['networkRequested'], isFalse);
      h.expectNoIo();
    },
  );

  test(
    'committed publication checks exact candidate identity and environment',
    () async {
      final h = await _Harness.create();
      expect(
        h.auth.hasCommittedSessionForEnvironment(MaasoEnvironment.test),
        isTrue,
      );
      expect(
        h.auth.hasCommittedSessionForEnvironment(MaasoEnvironment.production),
        isFalse,
      );
      final old = h.auth.session.value!;
      h.auth.session.value = MaasoAuthSession(
        accountUuid: old.accountUuid,
        accessToken: old.accessToken,
        refreshToken: old.refreshToken,
        expiresAt: old.expiresAt,
      );
      expect(
        h.auth.hasCommittedSessionForEnvironment(MaasoEnvironment.test),
        isFalse,
      );
      h.expectNoIo();
    },
  );

  test(
    'expired committed session is reported and never restored or refreshed',
    () async {
      final h = await _Harness.create(expired: true);
      final host = ConversationStagingProbeHost.fromApp();
      expect(host.readReadiness()['committedSessionPresent'], isTrue);
      expect(
        host.readReadiness()['blockedReason'],
        'session_expired_or_near_expiry_no_refresh',
      );
      expect((await host.runOnce())['networkRequested'], isFalse);
      h.expectNoIo();
    },
  );

  test(
    'origin mismatch, account mount and runtime activity fail closed without consuming attempt',
    () async {
      final h = await _Harness.create();
      final host = ConversationStagingProbeHost.fromApp();
      h.config.baseUri = Uri.parse('https://api.futurpals.com/');
      expect(host.readReadiness()['blockedReason'], 'staging_origin_required');
      h.config.baseUri = Uri.parse('$stagingConversationProbeOrigin/');
      final gate = Completer<void>();
      final operation = h.registry.runRequiredAccountOperation(
        () => gate.future,
      );
      expect(host.readReadiness()['blockedReason'], 'runtime_not_idle');
      expect((await host.runOnce())['networkRequested'], isFalse);
      gate.complete();
      await operation;
      expect(host.readReadiness()['canRunSingleProbe'], isTrue);
      h.scopes.unmount(h.scopes.activeMount!);
      expect(
        host.readReadiness()['blockedReason'],
        'account_mount_unavailable',
      );
      expect(host.readReadiness()['singleProbeConsumed'], isFalse);
      h.expectNoIo();
    },
  );

  test(
    'one explicit stateless POST preserves done timing and refuses redirect following',
    () async {
      final h = await _Harness.create();
      final requests = <http.Request>[];
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () => MockClient((request) async {
          requests.add(request);
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            '$stagingConversationProbeOrigin/v1/proxy/llm/stream',
          );
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          expect(request.headers['authorization'], 'Bearer $_token');
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], LLMDefaults.model);
          expect(body['maxTokens'], 384);
          expect(body['streamProtocol'], 'maaso.sse.v2.presentation');
          expect(
            body.keys,
            unorderedEquals([
              'turnId',
              'model',
              'messages',
              'temperature',
              'maxTokens',
              'streamProtocol',
            ]),
          );
          final messages = body['messages'] as List;
          expect(messages, hasLength(2));
          expect(
            messages.last['content'],
            ConversationProxyProbe.expectedResponse,
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return http.Response(
            _sse,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final first = host.runOnce();
      final second = host.runOnce();
      expect(identical(first, second), isTrue);
      final result = await first;
      expect(result['status'], 'jsonSupported');
      expect(result['doneObserved'], isTrue);
      expect(result['appHttpDispatchCount'], 1);
      expect(result['finishBoundary'], 'protocol_done');
      final metrics = result['metrics'] as Map;
      expect(metrics['first_cloud_delta_ms'], isA<double>());
      expect(
        metrics['finish_ms'] as double,
        greaterThanOrEqualTo(metrics['first_cloud_delta_ms'] as double),
      );
      expect(
        result['notMeasured'],
        containsAll(['first_visible', 'first_acoustic', 'task_complete']),
      );
      expect(await host.runOnce(), same(result));
      expect(requests, hasLength(1));
      final receipt = jsonEncode(result);
      for (final secret in [
        _token,
        _account,
        'private-provider-trace',
        'Alpha.',
      ]) {
        expect(receipt, isNot(contains(secret)));
      }
      expect(host.readReadiness()['singleProbeConsumed'], isTrue);
      expect(host.readReadiness()['canRunSingleProbe'], isFalse);
      h.expectNoIo();
    },
  );

  test(
    'typed-only stream reports no first_cloud_delta and records explicit done',
    () async {
      final h = await _Harness.create();
      final actions =
          (jsonDecode(ConversationProxyProbe.expectedResponse)
                  as Map)['actions']
              as List;
      final chunks = actions
          .map((a) => 'event: reply.utterance\ndata: ${jsonEncode(a)}\n\n')
          .join();
      final response = '${chunks}event: done\ndata: [DONE]\n\n';
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () =>
            MockClient((_) async => http.Response(response, 200)),
      );
      final result = await host.runOnce();
      expect(result['status'], 'typedSupported');
      expect(result['finishBoundary'], 'protocol_done');
      expect((result['metrics'] as Map)['first_cloud_delta_ms'], isNull);
      expect((result['metrics'] as Map)['finish_ms'], isNotNull);
      h.expectNoIo();
    },
  );

  test(
    'total deadline closes isolated transport without retry or false finish',
    () async {
      final h = await _Harness.create();
      final client = _HeldHttpClient();
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () => client,
        timeout: const Duration(milliseconds: 20),
      );
      final result = await host.runOnce();
      expect(result['status'], 'timedOut');
      expect(client.requests, 1);
      expect(client.closes, 1);
      expect((result['metrics'] as Map)['finish_ms'], isNull);
      await host.runOnce();
      expect(client.requests, 1);
      h.expectNoIo();
    },
  );

  test(
    'HTTP redirect is a sanitized failed attempt, not a second request',
    () async {
      final h = await _Harness.create();
      var requests = 0;
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () => MockClient((request) async {
          requests++;
          expect(request.followRedirects, isFalse);
          return http.Response(
            'private-provider-error',
            302,
            headers: {'location': 'https://other.invalid/secret'},
          );
        }),
      );
      final result = await host.runOnce();
      expect(result['status'], 'transportError');
      expect(result['appHttpDispatchCount'], 1);
      expect((result['metrics'] as Map)['first_cloud_delta_ms'], isNull);
      expect(jsonEncode(result), isNot(contains('private-provider-error')));
      await host.runOnce();
      expect(requests, 1);
      h.expectNoIo();
    },
  );

  test(
    'account retirement during streaming closes only probe transport and drops timings',
    () async {
      final h = await _Harness.create();
      final client = _HeldHttpClient();
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () => client,
      );
      final future = host.runOnce();
      await until(() => client.requests == 1);
      h.scopes.unmount(h.scopes.activeMount!);
      final result = await future.timeout(const Duration(seconds: 2));
      expect(result['status'], 'context_changed');
      expect(result['supportsContract'], isFalse);
      expect(client.closes, 1);
      expect((result['metrics'] as Map)['finish_ms'], isNull);
      h.expectNoIo();
    },
  );

  test(
    'a user turn starting during probe cancels the isolated transport',
    () async {
      final h = await _Harness.create();
      final client = _HeldHttpClient();
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () => client,
      );
      final future = host.runOnce();
      await until(() => client.requests == 1);
      final gate = Completer<void>();
      final operation = h.registry.runRequiredAccountOperation(
        () => gate.future,
      );
      final result = await future.timeout(const Duration(seconds: 2));
      expect(result['status'], 'context_changed');
      expect(client.closes, 1);
      gate.complete();
      await operation;
      h.expectNoIo();
    },
  );

  test(
    'already-loaded privacy check performs no refresh and retains local withdrawal fence',
    () async {
      final h = await _Harness.create();
      expect(
        h.privacy.allowsLoadedConsent(
          recipientId: 'ark',
          scope: PrivacyScopes.cloudText,
        ),
        isTrue,
      );
      h.expectNoIo();
      h.privacyGateway.writing = () =>
          Future.error(StateError('fixture-offline'));
      await expectLater(
        h.privacy.humanSetConsent(
          reviewed: h.privacy.snapshot!,
          recipientId: 'ark',
          scope: PrivacyScopes.cloudText,
          allow: false,
        ),
        throwsStateError,
      );
      final reads = h.privacyGateway.reads, writes = h.privacyGateway.writes;
      expect(
        h.privacy.allowsLoadedConsent(
          recipientId: 'ark',
          scope: PrivacyScopes.cloudText,
        ),
        isFalse,
      );
      expect(
        ConversationStagingProbeHost.fromApp().readReadiness()['blockedReason'],
        'loaded_privacy_permission_required',
      );
      expect(h.privacyGateway.reads, reads);
      expect(h.privacyGateway.writes, writes);
    },
  );

  test(
    'unloaded privacy uses default availability and direct cloud mode never creates transport',
    () async {
      final h = await _Harness.create(loadPrivacy: false);
      var factories = 0;
      final host = ConversationStagingProbeHost.fromApp(
        httpClientFactory: () {
          factories++;
          throw StateError('forbidden');
        },
      );
      final readiness = host.readReadiness();
      expect(readiness['canRunSingleProbe'], isTrue);
      expect(readiness['blockedReason'], isNull);
      expect(factories, 0);
      h.expectNoIo();
      h.mode.pipelineMode.value = AgentPipelineMode.directCloud;
      expect(
        host.readReadiness()['blockedReason'],
        'managed_proxy_mode_required',
      );
      await host.runOnce();
      expect(factories, 0);
      h.expectNoIo();
    },
  );
}

const _account = 'account-sensitive-fixture';
const _token = 'access-sensitive-fixture';
String get _sse =>
    'event: trace\ndata: private-provider-trace\n\n'
    'event: reply.delta\ndata: ${jsonEncode({'delta': ConversationProxyProbe.expectedResponse})}\n\n'
    'event: done\ndata: [DONE]\n\n';
Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}

class _Harness {
  _Harness(
    this.storage,
    this.auth,
    this.config,
    this.scopes,
    this.registry,
    this.privacy,
    this.privacyGateway,
    this.mode,
    this.authRequests,
  );
  final _Storage storage;
  final AuthSessionService auth;
  final RealtimeAgentConfig config;
  final AccountStorageScopeService scopes;
  final AgentRuntimeRegistry registry;
  final PrivacyService privacy;
  final PrivacyFake privacyGateway;
  final MaasoAgentModeService mode;
  final List<http.Request> authRequests;
  static Future<_Harness> create({
    bool publish = true,
    bool expired = false,
    bool loadPrivacy = true,
  }) async {
    final storage =
        appServices.put<SecureStorageService>(_Storage()) as _Storage;
    final environment = appServices.put(AppEnvironmentService());
    final authRequests = <http.Request>[];
    final auth = appServices.put(
      AuthSessionService(
        httpClient: MockClient((request) async {
          authRequests.add(request);
          if (request.url.path != '/v1/login/email') {
            throw StateError('unexpected-auth-request');
          }
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {
                'account_uuid': _account,
                'access_token': _token,
                'refresh_token': 'refresh-fixture',
                'expires_at':
                    (expired
                            ? DateTime.utc(2020)
                            : DateTime.now().add(const Duration(days: 1)))
                        .toIso8601String(),
                'token_type': 'Bearer',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    await auth.loginCandidate(
      email: 'synthetic@example.test',
      password: 'synthetic',
    );
    if (publish) await auth.publishCandidate();
    final scopes = appServices.put(AccountStorageScopeService());
    scopes.mount(
      AccountStorageScope(
        environmentKey: environment.environment.value.key,
        accountUuid: _account,
      ),
    );
    final config = appServices.put(
      RealtimeAgentConfig(
        enabled: true,
        baseUri: Uri.parse('$stagingConversationProbeOrigin/'),
      ),
    );
    final registry = appServices.put(AgentRuntimeRegistry());
    final raw = privacySnapshotJson();
    ((raw['policy'] as Map)['recipients'] as List).single['id'] = 'ark';
    (raw['consents'] as List).single['recipientId'] = 'ark';
    final gateway = PrivacyFake()..value = PrivacySnapshot.fromJson(raw);
    final privacy = appServices.put(PrivacyService(gateway: gateway));
    if (loadPrivacy) await privacy.refresh();
    final mode = appServices.put(MaasoAgentModeService());
    storage.reads = 0;
    storage.writes = 0;
    authRequests.clear();
    gateway.reads = 0;
    gateway.writes = 0;
    gateway.policies = 0;
    return _Harness(
      storage,
      auth,
      config,
      scopes,
      registry,
      privacy,
      gateway,
      mode,
      authRequests,
    );
  }

  void expectNoIo() {
    expect(storage.reads, 0);
    expect(storage.writes, 0);
    expect(authRequests, isEmpty);
    expect(
      privacyGateway.reads + privacyGateway.writes + privacyGateway.policies,
      0,
    );
  }
}

class _Storage extends SecureStorageService {
  final values = <String, String>{};
  int reads = 0, writes = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    return values[key];
  }

  @override
  Future<bool> write(String key, String? value) async {
    writes++;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    writes++;
    values.remove(key);
    return true;
  }
}

class _HeldHttpClient extends http.BaseClient {
  final controller = StreamController<List<int>>();
  int requests = 0, closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(controller.stream, 200);
  }

  @override
  void close() {
    closes++;
    unawaited(controller.close());
  }
}
