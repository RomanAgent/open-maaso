import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/cloud_voice_privacy_gate.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/services/maaso_streaming_tts_session.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'maaso_streaming_tts_session_test.dart' show FakeMaasoTtsSocket;
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_service_test.dart' show PrivacyFake;

PrivacySnapshot voiceSnapshot({int revision = 1, bool allow = true}) {
  final raw = privacySnapshotJson(revision: revision, allow: allow);
  (((raw['policy'] as Map)['recipients'] as List).first as Map)['id'] =
      'volcengine';
  final consent = (raw['consents'] as List).first as Map;
  consent['recipientId'] = 'volcengine';
  consent['scope'] = PrivacyScopes.cloudVoice;
  return PrivacySnapshot.fromJson(raw);
}

Future<MaasoStreamingTtsSession> openedSocket(
  FakeMaasoTtsSocket socket, {
  required Future<void> Function() admit,
  Stream<Object?>? revocations,
}) async {
  final opening = MaasoStreamingTtsSession.openWithSocket(
    socket,
    turnId: 'voice-test',
    beforeDispatch: admit,
    privacyRevocations: revocations,
  );
  await Future<void>.delayed(Duration.zero);
  socket.incoming.add(
    jsonEncode({
      'type': 'started',
      'turnId': 'voice-test',
      'sampleRate': 24000,
      'channels': 1,
      'encoding': 'pcm_s16le',
    }),
  );
  return opening;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() async {
    await appServices.reset();
  });

  test(
    'denied HTTP and websocket voice admission sends no text or credential',
    () async {
      var requests = 0, tokens = 0, sockets = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 200);
      });
      final engine = MaasoProxyTtsEngine(
        baseUri: Uri.parse('https://maaso.test/'),
        accessTokenProvider: () async {
          tokens++;
          return 'private-token';
        },
        httpClient: client,
        beforeDispatch: () async {
          throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
        },
        socketConnector: (_, _) async {
          sockets++;
          return FakeMaasoTtsSocket();
        },
      );
      await expectLater(
        engine.synthesizeToWav('private words'),
        throwsA(isA<PrivacyException>()),
      );
      await expectLater(
        engine.openSession(turnId: 'private-turn'),
        throwsA(isA<PrivacyException>()),
      );
      expect([requests, tokens, sockets], [0, 0, 0]);
      engine.close();
      client.close();
    },
  );

  test(
    'an open speech socket rechecks each segment and cancels on denial',
    () async {
      var allowed = true;
      final socket = FakeMaasoTtsSocket();
      final session = await openedSocket(
        socket,
        admit: () async {
          if (!allowed) {
            throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
          }
        },
      );
      await session.sendText('first');
      allowed = false;
      await expectLater(
        session.sendText('must never leave'),
        throwsA(isA<PrivacyException>()),
      );
      expect(socket.closeCalled, isTrue);
      expect(
        socket.sentMessages.where((m) => m.contains('must never leave')),
        isEmpty,
      );
      expect(
        socket.sentMessages.where((m) => jsonDecode(m)['type'] == 'text'),
        hasLength(1),
      );
    },
  );

  test(
    'withdrawal closes an idle open socket without another text request',
    () async {
      final changes = StreamController<Object?>.broadcast(sync: true);
      final socket = FakeMaasoTtsSocket();
      await openedSocket(
        socket,
        admit: () async {},
        revocations: changes.stream,
      );
      changes.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(socket.closeCalled, isTrue);
      await changes.close();
    },
  );

  test('normal speech completion releases its privacy listener', () async {
    final changes = StreamController<Object?>.broadcast(sync: true);
    final socket = FakeMaasoTtsSocket();
    final session = await openedSocket(
      socket,
      admit: () async {},
      revocations: changes.stream,
    );
    expect(changes.hasListener, isTrue);
    final done = session.audioFrames.drain<void>();
    socket.incoming.add(jsonEncode({'type': 'done'}));
    await done;
    expect(changes.hasListener, isFalse);
    await changes.close();
  });

  test(
    'voice gate checks fresh consent and cannot borrow a different account',
    () async {
      final fake = PrivacyFake()..value = voiceSnapshot();
      fake.currentPolicy = fake.value.publicPolicy;
      appServices.put(PrivacyService(gateway: fake));
      final gate = CloudVoicePrivacyGate.capture();
      await gate.require();
      expect(fake.reads, 1);
      fake.value = voiceSnapshot(revision: 2, allow: false);
      await expectLater(gate.require(), throwsA(isA<PrivacyException>()));
      expect(fake.reads, 2);
      fake.requestContextKey = 'test|replacement-account';
      await expectLater(gate.require(), throwsA(isA<PrivacyException>()));
      expect(fake.reads, 2);
    },
  );

  test(
    'human withdrawal notifies active producers before an uncertain server response',
    () async {
      final fake = PrivacyFake()..value = voiceSnapshot();
      fake.currentPolicy = fake.value.publicPolicy;
      final service = appServices.put(PrivacyService(gateway: fake));
      await service.refresh();
      final response = Completer<PrivacySnapshot>();
      fake.writing = () => response.future;
      var revoked = false;
      final listener = service.revocations.listen((event) {
        revoked = event.affects('volcengine', PrivacyScopes.cloudVoice);
      });
      final mutation = service.humanSetConsent(
        reviewed: service.snapshot!,
        recipientId: 'volcengine',
        scope: PrivacyScopes.cloudVoice,
        allow: false,
      );
      expect(revoked, isTrue);
      final rejected = expectLater(mutation, throwsA(isA<StateError>()));
      response.completeError(StateError('uncertain network response'));
      await rejected;
      await expectLater(
        CloudVoicePrivacyGate.capture().require(),
        throwsA(isA<PrivacyException>()),
      );
      await listener.cancel();
    },
  );

  test(
    'a credential received after withdrawal cannot start native recording or RTC',
    () async {
      var allow = true;
      final credential = Completer<RealtimeSession>();
      final dispatched = Completer<void>();
      final rtc = _VoiceRtc();
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) {
              dispatched.complete();
              return credential.future;
            },
        rtcAdapter: rtc,
        connectActions: (_, {authority, agentId = 'self', locale}) async {},
        disconnectActions: () async {},
        beforeCloudUse: () async {
          if (!allow) throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
        },
      );
      final join = service.joinAgent();
      await dispatched.future;
      allow = false;
      final denied = expectLater(join, throwsA(isA<PrivacyException>()));
      credential.complete(_voiceCredential());
      await denied;
      expect(rtc.joins, 0);
      await service.shutdown();
    },
  );

  test('withdrawal leaves an already joined companion session', () async {
    final changes = StreamController<Object?>.broadcast(sync: true);
    final rtc = _VoiceRtc();
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => _voiceCredential(),
      rtcAdapter: rtc,
      connectActions: (_, {authority, agentId = 'self', locale}) async {},
      disconnectActions: () async {},
      beforeCloudUse: () async {},
      privacyRevocations: changes.stream,
    );
    await service.joinAgent();
    expect(rtc.joins, 1);
    changes.add(null);
    await service.leave();
    expect(service.isJoined.value, isFalse);
    expect(rtc.leaves, greaterThan(0));
    await service.shutdown();
    await changes.close();
  });
}

RealtimeSession _voiceCredential() => RealtimeSession(
  sessionId: 'voice-session',
  locale: 'en',
  rtcAppId: 'app',
  roomId: 'room',
  userId: 'viewer',
  agentUserId: 'agent',
  taskId: 'task',
  rtcToken: 'private-token',
  actionStreamUri: Uri.parse('https://maaso.test/actions'),
  createdAt: DateTime.utc(2026),
);

class _VoiceRtc implements VolcRtcNativeAdapter {
  int joins = 0, leaves = 0;
  @override
  Stream<VolcRtcTerminalEvent> get terminalEvents => const Stream.empty();
  @override
  Future<void> join(VolcRtcJoinConfig config) async {
    joins++;
  }

  @override
  Future<void> leave() async {
    leaves++;
  }

  @override
  Future<void> dispose() async {}
}
