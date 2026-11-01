import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_streaming_tts_session.dart';

void main() {
  test('streaming TTS session sends text and emits audio frames', () async {
    final socket = FakeMaasoTtsSocket();
    final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
      socket,
      turnId: 'turn-1',
      voice: 'zh_female_vv_uranus_bigtts',
      language: 'zh',
      sampleRate: 24000,
    );

    expect(socket.sentMessages, hasLength(1));
    expect(jsonDecode(socket.sentMessages.single), {
      'type': 'start',
      'turnId': 'turn-1',
      'voice': 'zh_female_vv_uranus_bigtts',
      'language': 'zh',
      'format': 'pcm',
      'sampleRate': 24000,
    });

    socket.incoming.add(
      jsonEncode({
        'type': 'started',
        'turnId': 'turn-1',
        'sampleRate': 24000,
        'channels': 1,
        'encoding': 'pcm_s16le',
      }),
    );
    final session = await sessionFuture;

    final frames = <TtsAudioFrame>[];
    final sub = session.audioFrames.listen(frames.add);
    await session.sendText('你好，', flush: false);
    expect(jsonDecode(socket.sentMessages.last), {
      'type': 'text',
      'seq': 1,
      'text': '你好，',
      'flush': false,
    });

    socket.incoming.add(
      jsonEncode({
        'type': 'audio',
        'seq': 1,
        'sampleRate': 24000,
        'channels': 1,
        'encoding': 'pcm_s16le',
        'audioBase64': base64Encode([1, 2, 3, 4]),
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    expect(frames.single.bytes, Uint8List.fromList([1, 2, 3, 4]));
    expect(frames.single.sequence, 1);
    expect(frames.single.encoding, 'pcm_s16le');

    await session.finish();
    expect(jsonDecode(socket.sentMessages.last), {
      'type': 'finish',
      'reason': 'completed',
    });
    socket.incoming.add(jsonEncode({'type': 'done', 'reason': 'completed'}));
    await expectLater(session.audioFrames, emitsDone);
    await sub.cancel();
  });

  test(
    'correlated protocol preserves request identity and event order',
    () async {
      final socket = FakeMaasoTtsSocket();
      final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
        socket,
        turnId: 'turn-correlated',
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'started',
          'turnId': 'turn-correlated',
          'segmentProtocol': 1,
        }),
      );
      final session = await sessionFuture;
      expect(session.segmentProtocolVersion, 1);

      final events = <TtsSegmentEvent>[];
      final frames = <TtsAudioFrame>[];
      final sub = session.segmentEvents.listen(events.add);
      final frameSub = session.audioFrames.listen(frames.add);
      final identity = await session.sendSegment(
        utteranceId: 'utterance-1',
        text: '第一段',
      );
      expect(
        identity,
        const TtsSegmentIdentity(
          turnId: 'turn-correlated',
          textSequence: 1,
          utteranceId: 'utterance-1',
          segmentOrdinal: 1,
        ),
      );
      expect(jsonDecode(socket.sentMessages.last), {
        'type': 'text',
        'turnId': 'turn-correlated',
        'textSeq': 1,
        'utteranceId': 'utterance-1',
        'segmentOrdinal': 1,
        'text': '第一段',
        'flush': false,
      });

      socket.incoming.add(
        jsonEncode({
          'type': 'segment_started',
          'turnId': 'turn-correlated',
          'textSeq': 1,
          'utteranceId': 'utterance-1',
          'segmentOrdinal': 1,
        }),
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'audio',
          'turnId': 'turn-correlated',
          'textSeq': 1,
          'utteranceId': 'utterance-1',
          'segmentOrdinal': 1,
          'seq': 1,
          'sampleRate': 24000,
          'channels': 1,
          'encoding': 'pcm_s16le',
          'audioBase64': base64Encode([1, 2, 3, 4]),
        }),
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'segment_done',
          'turnId': 'turn-correlated',
          'textSeq': 1,
          'utteranceId': 'utterance-1',
          'segmentOrdinal': 1,
          'status': 'completed',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events.map((event) => event.kind), [
        TtsSegmentEventKind.started,
        TtsSegmentEventKind.audio,
        TtsSegmentEventKind.completed,
      ]);
      expect(events.map((event) => event.identity).toSet(), {identity});
      expect(events[1].audioFrame!.sequence, 1);
      expect(events[1].audioFrame!.bytes, Uint8List.fromList([1, 2, 3, 4]));
      expect(frames.single, same(events[1].audioFrame));

      await session.cancel('test_complete');
      await frameSub.cancel();
      await sub.cancel();
    },
  );

  test('correlated protocol rejects a mismatched segment identity', () async {
    final socket = FakeMaasoTtsSocket();
    final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
      socket,
      turnId: 'turn-strict',
    );
    socket.incoming.add(
      jsonEncode({
        'type': 'started',
        'turnId': 'turn-strict',
        'segmentProtocol': 1,
      }),
    );
    final session = await sessionFuture;
    await session.sendSegment(utteranceId: 'u1', text: 'hello');

    final errors = <Object>[];
    final done = Completer<void>();
    session.segmentEvents.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    );
    socket.incoming.add(
      jsonEncode({
        'type': 'segment_started',
        'turnId': 'turn-strict',
        'textSeq': 1,
        'utteranceId': 'wrong',
        'segmentOrdinal': 1,
      }),
    );
    await done.future.timeout(const Duration(seconds: 1));
    expect(errors, hasLength(1));
    await expectLater(
      session.sendSegment(utteranceId: 'u2', text: 'later'),
      throwsStateError,
    );
  });

  test(
    'correlated protocol rejects duplicate audio within a segment',
    () async {
      final socket = FakeMaasoTtsSocket();
      final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
        socket,
        turnId: 'turn-duplicate',
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'started',
          'turnId': 'turn-duplicate',
          'segmentProtocol': 1,
        }),
      );
      final session = await sessionFuture;
      await session.sendSegment(utteranceId: 'u1', text: 'hello');

      final errors = <Object>[];
      final done = Completer<void>();
      session.segmentEvents.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'segment_started',
          'turnId': 'turn-duplicate',
          'textSeq': 1,
          'utteranceId': 'u1',
          'segmentOrdinal': 1,
        }),
      );
      for (var count = 0; count < 2; count++) {
        socket.incoming.add(
          jsonEncode({
            'type': 'audio',
            'turnId': 'turn-duplicate',
            'textSeq': 1,
            'utteranceId': 'u1',
            'segmentOrdinal': 1,
            'seq': 1,
            'audioBase64': base64Encode([1, 2]),
          }),
        );
      }
      await done.future.timeout(const Duration(seconds: 1));
      expect(errors, hasLength(1));
    },
  );

  test('correlated protocol rejects stale turn audio', () async {
    final socket = FakeMaasoTtsSocket();
    final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
      socket,
      turnId: 'turn-current',
    );
    socket.incoming.add(
      jsonEncode({
        'type': 'started',
        'turnId': 'turn-current',
        'segmentProtocol': 1,
      }),
    );
    final session = await sessionFuture;
    await session.sendSegment(utteranceId: 'u1', text: 'hello');

    final errors = <Object>[];
    final done = Completer<void>();
    session.segmentEvents.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    );
    socket.incoming.add(
      jsonEncode({
        'type': 'audio',
        'turnId': 'turn-old',
        'textSeq': 1,
        'utteranceId': 'u1',
        'segmentOrdinal': 1,
        'seq': 1,
        'audioBase64': base64Encode([1, 2]),
      }),
    );
    await done.future.timeout(const Duration(seconds: 1));
    expect(errors, hasLength(1));
  });

  test(
    'correlated protocol rejects a future segment before the prior done',
    () async {
      final socket = FakeMaasoTtsSocket();
      final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
        socket,
        turnId: 'turn-order',
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'started',
          'turnId': 'turn-order',
          'segmentProtocol': 1,
        }),
      );
      final session = await sessionFuture;
      await session.sendSegment(utteranceId: 'u1', text: 'one');
      await session.sendSegment(utteranceId: 'u2', text: 'two');

      final errors = <Object>[];
      final done = Completer<void>();
      session.segmentEvents.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      socket.incoming.add(
        jsonEncode({
          'type': 'segment_started',
          'turnId': 'turn-order',
          'textSeq': 2,
          'utteranceId': 'u2',
          'segmentOrdinal': 2,
        }),
      );
      await done.future.timeout(const Duration(seconds: 1));
      expect(errors, hasLength(1));
    },
  );

  test('correlated segment error terminates the whole session', () async {
    final socket = FakeMaasoTtsSocket();
    final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
      socket,
      turnId: 'turn-failed',
    );
    socket.incoming.add(
      jsonEncode({
        'type': 'started',
        'turnId': 'turn-failed',
        'segmentProtocol': 1,
      }),
    );
    final session = await sessionFuture;
    await session.sendSegment(utteranceId: 'u1', text: 'one');
    await session.sendSegment(utteranceId: 'u2', text: 'two');

    final events = <TtsSegmentEvent>[];
    final done = Completer<void>();
    session.segmentEvents.listen(events.add, onDone: done.complete);
    socket.incoming.add(
      jsonEncode({
        'type': 'segment_started',
        'turnId': 'turn-failed',
        'textSeq': 1,
        'utteranceId': 'u1',
        'segmentOrdinal': 1,
      }),
    );
    socket.incoming.add(
      jsonEncode({
        'type': 'error',
        'turnId': 'turn-failed',
        'textSeq': 1,
        'utteranceId': 'u1',
        'segmentOrdinal': 1,
        'message': 'provider failed',
      }),
    );

    await done.future.timeout(const Duration(seconds: 1));
    expect(events.map((event) => event.kind), [
      TtsSegmentEventKind.started,
      TtsSegmentEventKind.failed,
    ]);
    expect(socket.closeCalled, isTrue);
    await expectLater(
      session.sendSegment(utteranceId: 'u3', text: 'three'),
      throwsStateError,
    );
  });

  test('missing capability keeps legacy whole-session transport', () async {
    final socket = FakeMaasoTtsSocket();
    final sessionFuture = MaasoStreamingTtsSession.openWithSocket(
      socket,
      turnId: 'turn-legacy',
    );
    socket.incoming.add(
      jsonEncode({'type': 'started', 'turnId': 'turn-legacy'}),
    );
    final session = await sessionFuture;
    expect(session.segmentProtocolVersion, 0);
    await expectLater(
      session.sendSegment(utteranceId: 'u1', text: 'hello'),
      throwsStateError,
    );

    final frames = <TtsAudioFrame>[];
    final sub = session.audioFrames.listen(frames.add);
    await session.sendText('legacy');
    socket.incoming.add(
      jsonEncode({
        'type': 'audio',
        'turnId': 'turn-legacy',
        'seq': 7,
        'audioBase64': base64Encode([5, 6]),
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(frames.single.sequence, 7);
    await session.cancel('test_complete');
    await sub.cancel();
  });
}

class FakeMaasoTtsSocket implements MaasoTtsSocket {
  final incoming = StreamController<dynamic>();
  final sentMessages = <String>[];
  var closeCalled = false;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  void add(String data) {
    sentMessages.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCalled = true;
    await incoming.close();
  }
}
