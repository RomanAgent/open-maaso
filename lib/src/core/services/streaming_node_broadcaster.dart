import 'package:maaso/src/features/agent/data/utils/logger.dart';

class StreamingNodeBroadcaster {
  final Set<String> _spoken = {};
  final List<String> _pending = [];

  List<String> drainPending() {
    if (_pending.isEmpty) return const [];
    final out = List<String>.from(_pending);
    _spoken.addAll(_pending);
    _pending.clear();
    return out;
  }

  void onThinking(String thought) {
    if (thought.trim().isEmpty) return;
    if (_spoken.contains(thought)) return;
    _pending.add(thought);
    Log.i(
      '📢 [Broadcaster] queued thought: ${thought.length > 60 ? '${thought.substring(0, 60)}…' : thought}',
    );
  }

  void interrupt() {
    _pending.clear();
    _spoken.clear();
  }

  void reset() {
    _pending.clear();
    _spoken.clear();
  }
}
