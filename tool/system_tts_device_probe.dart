// Release-only verification entrypoint. The normal app uses lib/main.dart.
// It never reads a user's API key or database; its model endpoint is a local
// deterministic fixture, while phone synthesis and playback are real.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/system_tts_engine.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final status = ValueNotifier('Checking installed phone speech…');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: status,
            builder: (_, value, _) => Text(value, textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
  final report = <String, Object?>{
    'kind': 'Release phone system-TTS and native audio playback',
    'model_endpoint': 'in-process loopback fixture; not a real cloud account',
    'uses_user_credentials': false,
    'samples': <Object?>[],
  };
  HttpServer? server;
  MaasoTtsPlugin? speech;
  LLMProxyService? proxy;
  final subscriptions = <StreamSubscription<dynamic>>[];
  try {
    appServices.testMode = true;
    final storage = appServices.put<SecureStorageService>(_MemoryStorage());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    var reply = '';
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      if (request.uri.path != '/v1/chat/completions' ||
          request.headers.value('authorization') != 'Bearer fixture-key') {
        request.response.statusCode = 400;
      } else {
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': jsonEncode({'reply': reply, 'actions': []}),
                },
                'finish_reason': 'stop',
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    await storage.write(
      LLMDirectCloudConfig.storageKey,
      LLMDirectCloudConfig(
        apiKey: 'fixture-key',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'device-probe',
        enabled: false,
      ).encode(),
    );
    proxy = appServices.put(LLMProxyService(localEdition: true));
    final channel = _ProbeChannel();
    TTSEngineRegistry.current = SystemTtsEngine(channel: channel);
    await MaasoTtsPlugin.loadSoundPreference();
    report['app_sound_enabled'] = MaasoTtsPlugin.soundEnabled.value;
    speech = MaasoTtsPlugin(agentId: 'device-system-tts-probe');
    var mouths = 0;
    subscriptions.add(
      EventBus().on<LipSyncVisemeTrackEvent>().listen((_) => mouths++),
    );
    for (final item in [
      ('en', 'The phone is using its installed local voice.'),
      ('zh', '手机本地语音测试通过。'),
    ]) {
      status.value = 'Testing ${item.$1} system voice…';
      reply = item.$2;
      final client = await proxy.ensureClient();
      if (client == null) {
        throw StateError('fixture_model_configuration_unavailable');
      }
      final response = await chatJsonObjectWithPrivacyAdmission(client, [
        Message.user('Test the configured model API.'),
      ], onAdmitted: () {});
      final text = (jsonDecode(response) as Map)['reply'] as String;
      final turn = speech.openTurn(turnId: 'probe-${item.$1}', text: text);
      final utterance = turn.speak(
        utteranceId: 'probe-${item.$1}:0',
        text: text,
      );
      final started = await utterance.started.timeout(
        const Duration(seconds: 40),
      );
      final terminal = await utterance.terminal.timeout(
        const Duration(seconds: 40),
      );
      await turn.drained;
      (report['samples'] as List).add({
        'language': item.$1,
        'started': started,
        'terminal': terminal.name,
        'native_audio': channel.lastAudio,
      });
      if (!started || terminal != SpeechTerminal.completed) {
        throw StateError('native_playback_not_completed');
      }
    }
    report['fixture_api_requests'] = requests;
    report['mouth_track_events'] = mouths;
    report['passed'] = requests == 2 && mouths >= 2;
    status.value = 'Local voice verification completed.';
  } catch (error) {
    report['passed'] = false;
    report['error_type'] = error.runtimeType.toString();
    if (error is PlatformException) report['error_code'] = error.code;
    status.value = 'Local voice verification failed; evidence saved.';
  } finally {
    await MaasoTtsPlugin.stopAll();
    await speech?.dispose();
    await proxy?.deactivateAccountAndDrain();
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    await server?.close(force: true);
    final directory = await getApplicationDocumentsDirectory();
    await File(
      '${directory.path}/open-maaso-system-tts-probe.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
  }
}

class _ProbeChannel extends MethodChannel {
  _ProbeChannel() : super('maaso/system_tts');
  Map<String, Object?>? lastAudio;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final result = await super.invokeMethod<T>(method, arguments);
    if (method == 'synthesize' && result is Uint8List && result.length > 44) {
      final view = ByteData.sublistView(result);
      var sum = 0.0;
      var peak = 0;
      for (var i = 44; i + 1 < result.length; i += 2) {
        final sample = view.getInt16(i, Endian.little);
        sum += sample * sample;
        peak = math.max(peak, sample.abs());
      }
      lastAudio = {
        'bytes': result.length,
        'sample_rate': view.getUint32(24, Endian.little),
        'rms': math.sqrt(sum / ((result.length - 44) / 2)) / 32768,
        'peak': peak,
      };
      if (peak == 0) throw StateError('native_audio_is_silent');
    }
    return result;
  }
}

class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    value == null ? values.remove(key) : values[key] = value;
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
