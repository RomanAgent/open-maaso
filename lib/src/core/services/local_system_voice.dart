import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Android's selected engine may have both embedded and network voices.
/// Merely setting a language or preferring offline synthesis is insufficient.
Map<String, String>? embeddedAndroidVoice(Object? voices, String locale) {
  if (voices is! List) return null;
  final requested = locale.replaceAll('_', '-').toLowerCase();
  for (final voice in voices) {
    if (voice is! Map ||
        voice['name'] is! String ||
        voice['locale'] is! String ||
        voice['network_required'] != '0') {
      continue;
    }
    final name = voice['name'] as String, language = voice['locale'] as String;
    if (name.isEmpty ||
        language.replaceAll('_', '-').toLowerCase() != requested ||
        voice['features'] is! String ||
        (voice['features'] as String).split('\t').contains('notInstalled')) {
      continue;
    }
    return {'name': name, 'locale': language};
  }
  return null;
}

Future<bool> prepareLocalSystemVoice(FlutterTts tts, String locale) async {
  // The web plugin omits SpeechSynthesisVoice.localService, so it cannot prove
  // embedded synthesis. Local Sherpa and text remain independent fallbacks.
  if (kIsWeb) return false;
  if (defaultTargetPlatform != TargetPlatform.android) {
    // Apple AVSpeechSynthesizer generates speech on device; desktop system
    // paths use the platform's installed synthesizer rather than cloud APIs.
    return true;
  }
  final voice = embeddedAndroidVoice(await tts.getVoices, locale);
  if (voice == null) return false;
  return await tts.setVoice(voice) == 1;
}
