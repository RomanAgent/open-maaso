import 'conversation_style_context.dart';

/// Cheap host checks over complete output units. This is deliberately not a
/// semantic judge of humor, truthfulness or the user's emotional state.
final class ConversationTextGate {
  ConversationTextGate(this.style);

  final ConversationStyleSnapshot? style;
  final Set<String> _delivered = {};

  bool get isCurrent => style?.isCurrent ?? true;

  bool allows(String text) {
    if (!isCurrent) return false;
    for (final address in style?.forbiddenAddresses ?? const <String>[]) {
      final escaped = RegExp.escape(address);
      // Latin names match words, not substrings such as "Al" in "also".
      final latin = RegExp(r'^[a-zA-Z0-9 _-]+$').hasMatch(address);
      final pattern = latin
          ? '(?<![a-zA-Z0-9])$escaped(?![a-zA-Z0-9])'
          : escaped;
      if (RegExp(pattern, caseSensitive: false).hasMatch(text)) return false;
    }
    return true;
  }

  /// Call once per prospective visible unit; TTS for that unit uses [allows]
  /// again so speaking the same displayed sentence is not a duplicate.
  bool admit(String text) {
    if (!allows(text)) return false;
    final key = text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    return key.isNotEmpty && _delivered.add(key);
  }
}

/// Keeps token fragments private until a whole sentence can be checked. Never
/// flushes a size-limited prefix, which could split a forbidden address.
final class ConversationSegmentBuffer {
  ConversationSegmentBuffer(this.gate);

  final ConversationTextGate gate;
  String _pending = '';
  bool blocked = false;
  static const maxPendingCharacters = 4096;

  List<String> add(String delta) {
    if (blocked) return const [];
    _pending += delta;
    if (_pending.length > maxPendingCharacters || !gate.isCurrent) {
      blocked = true;
      _pending = '';
      return const [];
    }
    final output = <String>[];
    while (true) {
      final end = _pending.indexOf(RegExp(r'[。！？!?\n]|\.(?=\s|$)'));
      if (end < 0) break;
      final unit = _pending.substring(0, end + 1);
      _pending = _pending.substring(end + 1);
      if (unit.trim().isEmpty) continue;
      if (!gate.admit(unit)) {
        blocked = true;
        _pending = '';
        break;
      }
      output.add(unit);
    }
    return output;
  }

  List<String> finish() {
    final tail = _pending;
    _pending = '';
    if (blocked || tail.trim().isEmpty) return const [];
    if (!gate.admit(tail)) {
      blocked = true;
      return const [];
    }
    return [tail];
  }
}
