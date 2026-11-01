import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/core/services/maaso_streaming_tts_session.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/pcm_wav_stream_normalizer.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

class MaasoProxyTtsEngine implements FullDuplexTTSEngine {
  MaasoProxyTtsEngine({
    required Uri baseUri,
    required MaasoAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
    MaasoTtsSocketConnector? socketConnector,
    Future<void> Function()? beforeDispatch,
    Stream<Object?>? privacyRevocations,
  }) : _baseUri = _normalizeBase(baseUri),
       _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _socketConnector = socketConnector,
       _beforeDispatch = beforeDispatch,
       _privacyRevocations = privacyRevocations,
       _ownsClient = httpClient == null;

  final Uri _baseUri;
  final MaasoAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;
  final MaasoTtsSocketConnector? _socketConnector;
  final bool _ownsClient;
  final Future<void> Function()? _beforeDispatch;
  final Stream<Object?>? _privacyRevocations;
  final Set<TtsSession> _sessions = {};
  bool _closed = false;

  Future<void> _admit() async {
    if (_closed) throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
    await _beforeDispatch?.call();
    if (_closed) throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
  }

  @override
  bool get isReady => true;

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async {
    onProgress?.call(1.0, phase: 'proxy');
    return true;
  }

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) async {
    await _admit();
    final request = http.Request(
      'POST',
      _baseUri.resolve('/v1/proxy/tts/stream'),
    );
    request.headers.addAll({
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'audio/wav',
    });
    final token = (await _accessTokenProvider())?.trim();
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.body = jsonEncode({
      'text': text,
      if (voice?.trim().isNotEmpty == true) 'voice': voice,
      if (language?.trim().isNotEmpty == true) 'language': language,
      'format': 'wav',
      'sampleRate': 24000,
    });
    await _admit();
    final response = await _httpClient.send(request);
    final bytes = await response.stream.toBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        final error = jsonDecode(utf8.decode(bytes));
        if (error is Map &&
            error['code'] is String &&
            (error['code'] as String).startsWith('PRIVACY_')) {
          throw PrivacyException(error['code'] as String);
        }
      } on FormatException {
        /* The normal proxy error below covers non-JSON. */
      }
      throw StateError(
        'Maaso proxy TTS failed: HTTP ${response.statusCode} ${utf8.decode(bytes, allowMalformed: true)}',
      );
    }
    return PcmWavStreamNormalizer.normalize(Uint8List.fromList(bytes));
  }

  @override
  Future<TtsSession> openSession({
    required String turnId,
    String? language,
    String? voice,
  }) async {
    await _admit();
    final session = await MaasoStreamingTtsSession.open(
      baseUri: _baseUri,
      accessTokenProvider: _accessTokenProvider,
      turnId: turnId,
      voice: voice,
      language: language,
      connector: _socketConnector,
      beforeDispatch: _admit,
      privacyRevocations: _privacyRevocations,
    );
    if (_closed) {
      await session.cancel('account_closed');
      throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
    }
    _sessions.add(session);
    session.audioFrames.listen(
      (_) {},
      onError: (Object _, StackTrace _) {},
      onDone: () => _sessions.remove(session),
    );
    return session;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final session in _sessions) {
      unawaited(session.cancel('account_closed').catchError((Object _) {}));
    }
    _sessions.clear();
    if (_ownsClient) _httpClient.close();
  }

  static Uri _normalizeBase(Uri uri) {
    final text = uri.toString();
    return text.endsWith('/') ? uri : Uri.parse('$text/');
  }
}
