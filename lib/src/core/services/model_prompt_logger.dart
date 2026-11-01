import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// Dumps the exact prompt/messages sent to a model.
///
/// Prompts can be much longer than a single platform log line, so each message
/// is chunked while preserving role/order metadata.
class ModelPromptLogger {
  static const int _chunkSize = 2500;

  static void logMessages(
    String label,
    Iterable<({String role, String content})> messages, {
    String? meta,
  }) {
    final list = messages.toList(growable: false);
    Log.i(
      '🧾 [ModelPrompt/$label] BEGIN messages=${list.length}'
      '${meta == null || meta.isEmpty ? "" : " $meta"}',
    );
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      _logChunked(
        label,
        'message ${i + 1}/${list.length} role=${m.role} chars=${m.content.length}',
        m.content,
      );
    }
    Log.i('🧾 [ModelPrompt/$label] END');
  }

  static void logPrompt(String label, String prompt, {String? meta}) {
    Log.i(
      '🧾 [ModelPrompt/$label] BEGIN promptChars=${prompt.length}'
      '${meta == null || meta.isEmpty ? "" : " $meta"}',
    );
    _logChunked(label, 'prompt chars=${prompt.length}', prompt);
    Log.i('🧾 [ModelPrompt/$label] END');
  }

  static void _logChunked(String label, String header, String text) {
    if (text.isEmpty) {
      Log.i('🧾 [ModelPrompt/$label] $header <empty>');
      return;
    }
    final chunks = (text.length / _chunkSize).ceil();
    for (
      var start = 0, part = 1;
      start < text.length;
      start += _chunkSize, part++
    ) {
      final next = start + _chunkSize;
      final end = next > text.length ? text.length : next;
      Log.i(
        '🧾 [ModelPrompt/$label] $header chunk=$part/$chunks\n'
        '${text.substring(start, end)}',
      );
    }
  }
}
