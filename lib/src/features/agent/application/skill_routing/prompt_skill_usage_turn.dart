import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';

/// One natural user turn, including any model retries or continuations.
/// Selection and rendering alone never count as use: the complete fragment
/// must be present in the system text of a request entering the HTTP client.
final class PromptSkillUsageTurn {
  PromptSkillUsageTurn({
    required SkillUsageService service,
    required bool Function() isCurrent,
  }) : _service = service,
       _isCurrent = isCurrent;

  final SkillUsageService _service;
  final bool Function() _isCurrent;
  final Set<String> _recorded = {};
  List<PromptSkillEntry> _selected = const [];
  bool Function()? _snapshotIsCurrent;

  void select({
    required PromptSkillSnapshot snapshot,
    required TurnSkillGrant grant,
    required bool Function() snapshotIsCurrent,
  }) {
    _selected = [
      for (final id in grant.allowedSkillIds)
        if (snapshot.entryById(id) case final entry?)
          if (entry.promptFragment.trim().isNotEmpty) entry,
    ];
    _snapshotIsCurrent = snapshotIsCurrent;
  }

  void onDispatch(http.BaseRequest request) {
    if (_selected.isEmpty ||
        !_service.isCurrent ||
        !_isCurrent() ||
        _snapshotIsCurrent?.call() != true ||
        request is! http.Request) {
      return;
    }
    final Object? payload;
    try {
      payload = jsonDecode(request.body);
    } on FormatException {
      return;
    }
    if (payload is! Map) return;
    final systemTexts = <String>[];
    final messages = payload['messages'];
    if (messages is List) {
      for (final message in messages) {
        if (message is Map &&
            message['role'] == 'system' &&
            message['content'] is String) {
          systemTexts.add(message['content'] as String);
        }
      }
    }
    // Same boundary supports Gemini's role-preserving system instruction.
    final system = payload['systemInstruction'];
    final parts = system is Map ? system['parts'] : null;
    if (parts is List) {
      for (final part in parts) {
        if (part is Map && part['text'] is String) {
          systemTexts.add(part['text'] as String);
        }
      }
    }
    if (systemTexts.isEmpty) return;
    for (final entry in _selected) {
      final id = entry.descriptor.id;
      if (_recorded.contains(id) ||
          !systemTexts.any((text) => text.contains(entry.promptFragment))) {
        continue;
      }
      final key = promptSkillUsageKey(id);
      if (key == null) continue;
      final attempt = _service.start(
        skillName: key,
        method: 'applyPrompt',
        channel: SkillUsageChannel.prompt,
      );
      if (attempt == null) continue;
      _recorded.add(id);
      // Success means the instruction was applied to a dispatched request,
      // never that the model's answer or the user's wider goal succeeded.
      unawaited(attempt.finish(succeeded: true));
    }
  }
}
