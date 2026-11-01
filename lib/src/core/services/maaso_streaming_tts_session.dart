import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';

export 'package:maaso/src/features/agent/data/bridge/tts_engine.dart'
    show
        CorrelatedTtsSession,
        TtsAudioFrame,
        TtsSegmentEvent,
        TtsSegmentEventKind,
        TtsSegmentIdentity,
        TtsSession;

abstract class MaasoTtsSocket {
  Stream<dynamic> get stream;
  void add(String data);
  Future<void> close([int? code, String? reason]);
}

typedef MaasoTtsSocketConnector =
    Future<MaasoTtsSocket> Function(Uri uri, Map<String, String> headers);

class IoMaasoTtsSocket implements MaasoTtsSocket {
  IoMaasoTtsSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void add(String data) => _socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) {
    return _socket.close(code, reason);
  }
}

class MaasoStreamingTtsSession implements CorrelatedTtsSession {
  MaasoStreamingTtsSession._(this._socket, this.turnId) {
    _subscription = _socket.stream.listen(
      _handleMessage,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: true,
    );
  }

  final MaasoTtsSocket _socket;
  @override
  final String turnId;
  final _audioFrames = StreamController<TtsAudioFrame>.broadcast();
  final _segmentEvents = StreamController<TtsSegmentEvent>.broadcast();
  final _ready = Completer<void>();
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, TtsSegmentIdentity> _sentSegments = {};
  final Map<int, _TtsSegmentPhase> _segmentPhases = {};
  final Map<int, int> _lastAudioSequence = {};
  var _sendSeq = 0;
  var _nextSegmentOrdinal = 1;
  var _segmentProtocolVersion = 0;
  var _closed = false;
  Future<void> Function()? _beforeDispatch;
  StreamSubscription<Object?>? _privacySubscription;

  Future<void> _admit() async {
    if (_closed) throw StateError('tts_session_closed');
    try {
      await _beforeDispatch?.call();
      if (_closed) throw StateError('tts_session_closed');
    } catch (_) {
      await cancel('privacy_changed');
      rethrow;
    }
  }

  static Future<MaasoStreamingTtsSession> open({
    required Uri baseUri,
    required Future<String?> Function() accessTokenProvider,
    required String turnId,
    String? voice,
    String? language,
    int sampleRate = 24000,
    MaasoTtsSocketConnector? connector,
    Future<void> Function()? beforeDispatch,
    Stream<Object?>? privacyRevocations,
  }) async {
    final token = (await accessTokenProvider())?.trim();
    final headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    await beforeDispatch?.call();
    final socket = await (connector ?? _defaultConnector)(
      _sessionUri(baseUri, turnId),
      headers,
    );
    return openWithSocket(
      socket,
      turnId: turnId,
      voice: voice,
      language: language,
      sampleRate: sampleRate,
      beforeDispatch: beforeDispatch,
      privacyRevocations: privacyRevocations,
    );
  }

  static Future<MaasoStreamingTtsSession> openWithSocket(
    MaasoTtsSocket socket, {
    required String turnId,
    String? voice,
    String? language,
    int sampleRate = 24000,
    Future<void> Function()? beforeDispatch,
    Stream<Object?>? privacyRevocations,
  }) async {
    final session = MaasoStreamingTtsSession._(socket, turnId);
    // Admission may fail before the normal readiness await below is reached.
    unawaited(
      session._ready.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    session._beforeDispatch = beforeDispatch;
    session._privacySubscription = privacyRevocations?.listen((_) {
      unawaited(session.cancel('privacy_changed').catchError((Object _) {}));
    });
    if (beforeDispatch != null) await session._admit();
    session._send({
      'type': 'start',
      'turnId': turnId,
      'voice': voice,
      'language': language,
      'format': 'pcm',
      'sampleRate': sampleRate,
    });
    await session._ready.future.timeout(const Duration(seconds: 10));
    return session;
  }

  @override
  Stream<TtsAudioFrame> get audioFrames => _audioFrames.stream;

  @override
  Stream<TtsSegmentEvent> get segmentEvents => _segmentEvents.stream;

  @override
  int get segmentProtocolVersion => _segmentProtocolVersion;

  @override
  Future<void> sendText(String text, {bool flush = false}) async {
    if (_closed) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _admit();
    _send({'type': 'text', 'seq': ++_sendSeq, 'text': trimmed, 'flush': flush});
  }

  @override
  Future<TtsSegmentIdentity> sendSegment({
    required String utteranceId,
    required String text,
    bool flush = false,
  }) async {
    if (_closed) throw StateError('tts_session_closed');
    if (_segmentProtocolVersion != 1) {
      throw StateError('tts_segment_protocol_unavailable');
    }
    final trimmedText = text.trim();
    final trimmedUtteranceId = utteranceId.trim();
    if (trimmedText.isEmpty) throw ArgumentError.value(text, 'text');
    if (trimmedUtteranceId.isEmpty ||
        trimmedUtteranceId != utteranceId ||
        trimmedUtteranceId.length > 128) {
      throw ArgumentError.value(utteranceId, 'utteranceId');
    }
    await _admit();
    final sequence = ++_sendSeq;
    final identity = TtsSegmentIdentity(
      turnId: turnId,
      textSequence: sequence,
      utteranceId: trimmedUtteranceId,
      segmentOrdinal: sequence,
    );
    _sentSegments[sequence] = identity;
    _segmentPhases[sequence] = _TtsSegmentPhase.sent;
    _send({
      'type': 'text',
      'turnId': turnId,
      'textSeq': sequence,
      'utteranceId': trimmedUtteranceId,
      'segmentOrdinal': sequence,
      'text': trimmedText,
      'flush': flush,
    });
    return identity;
  }

  @override
  Future<void> finish() async {
    if (_closed) return;
    await _admit();
    _send({'type': 'finish', 'reason': 'completed'});
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    if (_closed) return;
    _send({'type': 'cancel', 'reason': reason});
    await _closeSocket();
  }

  void _send(Map<String, dynamic> message) {
    final clean = <String, dynamic>{};
    for (final entry in message.entries) {
      if (entry.value != null) clean[entry.key] = entry.value;
    }
    _socket.add(jsonEncode(clean));
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    final dynamic decodedValue;
    try {
      decodedValue = jsonDecode(raw);
    } catch (_) {
      _handleError(StateError('tts_protocol_invalid_json'));
      return;
    }
    if (decodedValue is! Map) return;
    final decoded = Map<Object?, Object?>.of(decodedValue);
    final type = decoded['type'];
    if (type == 'started') {
      final receivedTurnId = decoded['turnId'];
      if (receivedTurnId != null && receivedTurnId != turnId) {
        _handleError(StateError('tts_protocol_turn_mismatch'));
        return;
      }
      _segmentProtocolVersion = decoded['segmentProtocol'] is int
          ? decoded['segmentProtocol'] as int
          : 0;
      if (_segmentProtocolVersion != 1) _segmentProtocolVersion = 0;
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (type == 'audio') {
      final audioBase64 = decoded['audioBase64'];
      if (audioBase64 is! String || audioBase64.isEmpty) return;
      final TtsAudioFrame frame;
      try {
        frame = TtsAudioFrame(
          bytes: Uint8List.fromList(base64Decode(audioBase64)),
          sampleRate: _intValue(decoded['sampleRate'], fallback: 24000),
          channels: _intValue(decoded['channels'], fallback: 1),
          encoding: decoded['encoding']?.toString() ?? 'pcm_s16le',
          sequence: _intValue(decoded['seq'], fallback: 0),
        );
      } catch (_) {
        _handleError(StateError('tts_protocol_invalid_audio'));
        return;
      }
      if (_segmentProtocolVersion == 1 &&
          _hasAnySegmentCorrelationField(decoded)) {
        final identity = _readCorrelatedIdentity(decoded);
        if (identity == null || !_acceptAudio(identity, frame.sequence)) {
          _handleError(StateError('tts_protocol_invalid_segment_audio'));
          return;
        }
        _segmentEvents.add(
          TtsSegmentEvent(
            kind: TtsSegmentEventKind.audio,
            identity: identity,
            audioFrame: frame,
          ),
        );
      } else if (_segmentProtocolVersion == 1 && _sentSegments.isNotEmpty) {
        _handleError(StateError('tts_protocol_missing_segment_identity'));
        return;
      }
      _audioFrames.add(frame);
      return;
    }
    if (type == 'segment_started') {
      final identity = _readCorrelatedIdentity(decoded);
      if (identity == null ||
          identity.segmentOrdinal != _nextSegmentOrdinal ||
          _segmentPhases[identity.textSequence] != _TtsSegmentPhase.sent) {
        _handleError(StateError('tts_protocol_invalid_segment_start'));
        return;
      }
      _segmentPhases[identity.textSequence] = _TtsSegmentPhase.started;
      _segmentEvents.add(
        TtsSegmentEvent(kind: TtsSegmentEventKind.started, identity: identity),
      );
      return;
    }
    if (type == 'segment_done') {
      final identity = _readCorrelatedIdentity(decoded);
      if (identity == null ||
          decoded['status'] != 'completed' ||
          _segmentPhases[identity.textSequence] != _TtsSegmentPhase.started) {
        _handleError(StateError('tts_protocol_invalid_segment_done'));
        return;
      }
      _segmentPhases[identity.textSequence] = _TtsSegmentPhase.completed;
      _nextSegmentOrdinal++;
      _segmentEvents.add(
        TtsSegmentEvent(
          kind: TtsSegmentEventKind.completed,
          identity: identity,
        ),
      );
      return;
    }
    if (type == 'done') {
      _handleDone();
      return;
    }
    if (type == 'error') {
      if (_segmentProtocolVersion == 1 &&
          _hasAnySegmentCorrelationField(decoded)) {
        final identity = _readCorrelatedIdentity(decoded);
        final phase = identity == null
            ? null
            : _segmentPhases[identity.textSequence];
        if (identity == null ||
            identity.segmentOrdinal != _nextSegmentOrdinal ||
            phase == _TtsSegmentPhase.completed ||
            phase == _TtsSegmentPhase.failed) {
          _handleError(StateError('tts_protocol_invalid_segment_error'));
          return;
        }
        _segmentPhases[identity.textSequence] = _TtsSegmentPhase.failed;
        _segmentEvents.add(
          TtsSegmentEvent(kind: TtsSegmentEventKind.failed, identity: identity),
        );
        unawaited(
          _closeSocket().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
        return;
      }
      final message = decoded['message']?.toString() ?? 'tts session error';
      _handleError(StateError(message));
    }
  }

  bool _hasAnySegmentCorrelationField(Map<Object?, Object?> decoded) =>
      decoded.containsKey('textSeq') ||
      decoded.containsKey('utteranceId') ||
      decoded.containsKey('segmentOrdinal');

  TtsSegmentIdentity? _readCorrelatedIdentity(Map<Object?, Object?> decoded) {
    if (_segmentProtocolVersion != 1) return null;
    final receivedTurnId = decoded['turnId'];
    final textSequence = decoded['textSeq'];
    final utteranceId = decoded['utteranceId'];
    final segmentOrdinal = decoded['segmentOrdinal'];
    if (receivedTurnId is! String ||
        receivedTurnId != turnId ||
        textSequence is! int ||
        textSequence <= 0 ||
        utteranceId is! String ||
        utteranceId.isEmpty ||
        segmentOrdinal is! int ||
        segmentOrdinal <= 0) {
      return null;
    }
    final expected = _sentSegments[textSequence];
    if (expected == null ||
        expected.utteranceId != utteranceId ||
        expected.segmentOrdinal != segmentOrdinal) {
      return null;
    }
    return expected;
  }

  bool _acceptAudio(TtsSegmentIdentity identity, int audioSequence) {
    if (_segmentPhases[identity.textSequence] != _TtsSegmentPhase.started ||
        audioSequence <= 0) {
      return false;
    }
    final last = _lastAudioSequence[identity.textSequence] ?? 0;
    if (audioSequence != last + 1) return false;
    _lastAudioSequence[identity.textSequence] = audioSequence;
    return true;
  }

  void _handleError(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_audioFrames.isClosed) _audioFrames.addError(error);
    if (!_segmentEvents.isClosed) _segmentEvents.addError(error);
    _handleDone();
  }

  void _handleDone() {
    if (_closed) return;
    _closed = true;
    final privacySubscription = _privacySubscription;
    _privacySubscription = null;
    if (privacySubscription != null) unawaited(privacySubscription.cancel());
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('tts session closed before start'));
    }
    unawaited(_subscription.cancel());
    unawaited(_audioFrames.close());
    unawaited(_segmentEvents.close());
  }

  Future<void> _closeSocket() async {
    _handleDone();
    await _privacySubscription?.cancel();
    _privacySubscription = null;
    await _socket.close();
  }

  static int _intValue(dynamic value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  static Future<MaasoTtsSocket> _defaultConnector(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final socket = await WebSocket.connect(uri.toString(), headers: headers);
    return IoMaasoTtsSocket(socket);
  }

  static Uri _sessionUri(Uri baseUri, String turnId) {
    final normalized = _normalizeBase(baseUri);
    final scheme = normalized.scheme == 'https' ? 'wss' : 'ws';
    final base = normalized.replace(scheme: scheme);
    return base
        .resolve('/v1/proxy/tts/session')
        .replace(
          queryParameters: {
            if (turnId.trim().isNotEmpty) 'turnId': turnId.trim(),
          },
        );
  }

  static Uri _normalizeBase(Uri uri) {
    final text = uri.toString();
    return text.endsWith('/') ? uri : Uri.parse('$text/');
  }
}

enum _TtsSegmentPhase { sent, started, completed, failed }
