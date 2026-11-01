import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart'
    show InvalidToolArgumentsException;
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';

class DelayedChoiceExecutor extends AppService {
  final RxList<DelayedToolBranch> pending = <DelayedToolBranch>[].obs;
  final RxList<DelayedToolEvent> recentEvents = <DelayedToolEvent>[].obs;
  final Map<String, int> _commitAttempts = <String, int>{};
  int _discardGeneration = 0;

  Future<DelayedChoiceRunResult> run({
    required LLMClient client,
    required SkillManager skillManager,
    required List<Message> messages,
    Duration? timeout,
    int maxRounds = 6,
    bool Function()? shouldCancel,
    AppLocale? locale,
  }) async {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    final convo = List<Message>.from(messages);
    final tools = skillManager.toNativeTools(
      format: NativeToolFormat.openai,
      locale: turnLocale,
    );
    final rounds = <DelayedChoiceRound>[];
    String lastContent = '';

    for (var round = 0; round < maxRounds; round++) {
      if (shouldCancel?.call() == true) {
        return DelayedChoiceRunResult(
          content: lastContent,
          rounds: rounds,
          stoppedReason: 'cancelled',
        );
      }

      final turn = await client.chatWithTools(convo, tools, timeout: timeout);
      lastContent = turn.content;
      rounds.add(
        DelayedChoiceRound(
          toolCalls: turn.toolCalls.length,
          hadContent: turn.content.isNotEmpty,
        ),
      );
      _record('round', 'round=$round toolCalls=${turn.toolCalls.length}');

      if (!turn.hasToolCalls) {
        return DelayedChoiceRunResult(
          content: turn.content,
          rounds: rounds,
          stoppedReason: 'text_only',
        );
      }

      convo.add(
        Message.assistantToolCalls(turn.toolCalls, content: turn.content),
      );

      for (final call in turn.toolCalls) {
        final result = await _runOne(call, skillManager, turnLocale);
        convo.add(Message.tool(toolCallId: call.id, content: result));
      }
    }

    return DelayedChoiceRunResult(
      content: lastContent,
      rounds: rounds,
      stoppedReason: 'max_rounds',
    );
  }

  Future<String> commitLatest(
    SkillManager skillManager, {
    AppLocale? locale,
  }) async {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    if (pending.isEmpty) {
      return jsonEncode({
        'status': 'empty',
        'message': AgentPromptCatalog.text(
          'app.delayed_choice.no_pending',
          locale: turnLocale,
        ),
      });
    }
    return commit(pending.last.id, skillManager, locale: turnLocale);
  }

  Future<String> commit(
    String branchId,
    SkillManager skillManager, {
    AppLocale? locale,
  }) async {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    final branch = pending.firstWhereOrNull((b) => b.id == branchId);
    if (branch == null) {
      return jsonEncode({'status': 'missing', 'branchId': branchId});
    }
    try {
      skillManager.validateToolArguments(branch.toolName, branch.args);
    } on InvalidToolArgumentsException catch (e) {
      Log.w(
        '🛠️ [DelayedChoice] ${e.code} while committing ${branch.toolName}',
      );
      return jsonEncode({
        'status': 'error',
        'branchId': branchId,
        'error': 'bad_arguments',
      });
    } catch (e, st) {
      Log.e('❌ [DelayedChoice] commit preflight failed: $e\n$st');
      return jsonEncode({
        'status': 'error',
        'branchId': branchId,
        'error': 'execution_failed',
      });
    }

    // Claim synchronously before the first await. Concurrent commits now see a
    // missing branch instead of invoking the same effect twice. Legacy paths
    // may restore a failed claim, but an enforced contract result consumes it
    // permanently because the callback may already have produced an effect.
    final claimedIndex = pending.indexWhere((item) => item.id == branchId);
    if (claimedIndex < 0) {
      return jsonEncode({'status': 'missing', 'branchId': branchId});
    }
    final claimed = pending.removeAt(claimedIndex);
    final claimDiscardGeneration = _discardGeneration;
    final attempt = (_commitAttempts[branchId] ?? 0) + 1;
    _commitAttempts[branchId] = attempt;
    try {
      final execution = await skillManager.invokeToolWithContract(
        claimed.toolName,
        claimed.args,
        locale: turnLocale,
        callId: 'delayed-${claimed.id}-$attempt',
        channel: ActionContractChannel.delayedTool,
      );
      final result = execution.output == null
          ? '{}'
          : execution.output.toString();
      if (!execution.isLegacy && !_typedContractSucceeded(result)) {
        _commitAttempts.remove(branchId);
        return jsonEncode({
          'status': 'error',
          'branchId': branchId,
          'error': _typedContractFailureCode(result),
        });
      }
      _commitAttempts.remove(branchId);
      _record('commit', '${claimed.toolName} branch=$branchId');
      return jsonEncode({
        'status': 'committed',
        'branchId': branchId,
        'tool': claimed.toolName,
        'result': _tryJson(result),
      });
    } on InvalidToolArgumentsException catch (e) {
      _restoreClaim(claimed, claimedIndex, claimDiscardGeneration);
      Log.w(
        '🛠️ [DelayedChoice] ${e.code} while committing ${claimed.toolName}',
      );
      return jsonEncode({
        'status': 'error',
        'branchId': branchId,
        'error': 'bad_arguments',
      });
    } catch (e, st) {
      _restoreClaim(claimed, claimedIndex, claimDiscardGeneration);
      Log.e('❌ [DelayedChoice] commit failed: $e\n$st');
      return jsonEncode({
        'status': 'error',
        'branchId': branchId,
        'error': 'execution_failed',
      });
    }
  }

  void _restoreClaim(
    DelayedToolBranch branch,
    int previousIndex,
    int claimDiscardGeneration,
  ) {
    if (claimDiscardGeneration != _discardGeneration) return;
    if (pending.any((item) => item.id == branch.id)) return;
    final restoredIndex = previousIndex < 0
        ? 0
        : previousIndex > pending.length
        ? pending.length
        : previousIndex;
    pending.insert(restoredIndex, branch);
  }

  int discardAll() {
    final count = pending.length;
    _discardGeneration += 1;
    pending.clear();
    _commitAttempts.clear();
    _record('discard', 'discarded=$count');
    return count;
  }

  Map<String, dynamic> toDebugMap() {
    return {
      'pendingCount': pending.length,
      'pending': [
        for (final b in pending.take(4))
          {
            'id': b.id,
            'tool': b.toolName,
            'risk': b.risk,
            'summary': b.summary,
          },
      ],
      'events': [
        for (final e in recentEvents.take(6))
          {'kind': e.kind, 'detail': e.detail},
      ],
    };
  }

  Future<String> _runOne(
    ToolCall call,
    SkillManager skillManager,
    AppLocale locale,
  ) async {
    Map<String, dynamic> args;
    try {
      final decoded = call.argumentsJson.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(call.argumentsJson);
      if (decoded is! Map) {
        return jsonEncode({'error': 'bad_arguments'});
      }
      args = Map<String, dynamic>.from(decoded);
    } catch (e) {
      Log.w('🛠️ [DelayedChoice] bad args for ${call.name}: $e');
      return jsonEncode({'error': 'bad_arguments'});
    }

    try {
      skillManager.validateToolArguments(call.name, args);
    } on InvalidToolArgumentsException catch (e) {
      Log.w('🛠️ [DelayedChoice] ${e.code} for ${call.name}');
      return jsonEncode({'error': 'bad_arguments'});
    } on StateError catch (e) {
      Log.w('🛠️ [DelayedChoice] ${e.message}');
      return jsonEncode({'error': 'unknown_tool', 'name': call.name});
    } catch (e, st) {
      Log.e('❌ [DelayedChoice] ${call.name} preflight failed: $e\n$st');
      return jsonEncode({'error': 'execution_failed'});
    }

    final policy = DelayedChoicePolicy.classify(
      call.name,
      args,
      locale: locale,
    );
    if (policy.requiresCommit) {
      final branch = DelayedToolBranch(
        id: _newBranchId(),
        toolName: call.name,
        args: _deepFreezeArguments(args),
        risk: policy.risk,
        summary: policy.summary,
        createdAt: DateTime.now(),
      );
      pending.add(branch);
      _record('propose', '${call.name} branch=${branch.id}');
      return jsonEncode({
        'status': 'commit_required',
        'branchId': branch.id,
        'tool': call.name,
        'risk': policy.risk,
        'summary': policy.summary,
        'message': AgentPromptCatalog.text(
          'app.delayed_choice.confirmation',
          locale: locale,
        ),
      });
    }

    try {
      _record('execute', call.name);
      return await skillManager.invokeTool(
        call.name,
        args,
        locale: locale,
        callId: call.id,
        channel: ActionContractChannel.delayedTool,
      );
    } on InvalidToolArgumentsException catch (e) {
      Log.w('🛠️ [DelayedChoice] ${e.code} for ${call.name}');
      return jsonEncode({'error': 'bad_arguments'});
    } on StateError catch (e) {
      Log.w('🛠️ [DelayedChoice] ${e.message}');
      return jsonEncode({'error': 'unknown_tool', 'name': call.name});
    } catch (e, st) {
      Log.e('❌ [DelayedChoice] ${call.name} threw: $e\n$st');
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  static Map<String, dynamic> _deepFreezeArguments(Map<String, dynamic> args) =>
      Map<String, dynamic>.unmodifiable(<String, dynamic>{
        for (final entry in args.entries)
          entry.key: _deepFreezeJson(entry.value),
      });

  static Object? _deepFreezeJson(Object? value) {
    if (value is Map) {
      final frozen = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw StateError('Tool arguments contain a non-string object key');
        }
        frozen[key] = _deepFreezeJson(entry.value);
      }
      return Map<String, dynamic>.unmodifiable(frozen);
    }
    if (value is List) {
      return List<dynamic>.unmodifiable(value.map(_deepFreezeJson));
    }
    return value;
  }

  void _record(String kind, String detail) {
    recentEvents.insert(
      0,
      DelayedToolEvent(kind: kind, detail: detail, at: DateTime.now()),
    );
    if (recentEvents.length > 20) {
      recentEvents.removeRange(20, recentEvents.length);
    }
  }

  static Object? _tryJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  static bool _typedContractSucceeded(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['status'] == 'ok';
    } on Object {
      return false;
    }
  }

  static String _typedContractFailureCode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final code = decoded is Map ? decoded['code']?.toString() : null;
      if (code != null &&
          code.isNotEmpty &&
          code.length <= 64 &&
          RegExp(r'^[a-z0-9._-]+$').hasMatch(code)) {
        return code;
      }
    } on Object {
      // Use a fixed value-redacting fallback below.
    }
    return 'execution_failed';
  }

  static String _newBranchId() => 'dc_${DateTime.now().microsecondsSinceEpoch}';
}

class DelayedChoicePolicy {
  const DelayedChoicePolicy({
    required this.requiresCommit,
    required this.risk,
    required this.summary,
  });

  final bool requiresCommit;
  final String risk;
  final String summary;

  static DelayedChoicePolicy classify(
    String toolName,
    Map<String, dynamic> args, {
    AppLocale? locale,
  }) {
    final name = toolName.toLowerCase();
    final sideEffect = RegExp(
      r'(post|put|patch|delete|create|update|save|send|write|set|log)',
    ).hasMatch(name);
    if (!sideEffect) {
      return DelayedChoicePolicy(
        requiresCommit: false,
        risk: 'read_only',
        summary: AgentPromptCatalog.text(
          'app.delayed_choice.summary.read_only',
          locale: locale,
        ),
      );
    }

    final url = args['url']?.toString();
    final target = url == null || url.isEmpty ? toolName : url;
    return DelayedChoicePolicy(
      requiresCommit: true,
      risk: name.contains('delete') ? 'destructive' : 'side_effect',
      summary: AgentPromptCatalog.text(
        'app.delayed_choice.summary.execute',
        locale: locale,
        params: <String, Object?>{'tool': toolName, 'target': target},
      ),
    );
  }
}

class DelayedToolBranch {
  const DelayedToolBranch({
    required this.id,
    required this.toolName,
    required this.args,
    required this.risk,
    required this.summary,
    required this.createdAt,
  });

  final String id;
  final String toolName;
  final Map<String, dynamic> args;
  final String risk;
  final String summary;
  final DateTime createdAt;
}

class DelayedToolEvent {
  const DelayedToolEvent({
    required this.kind,
    required this.detail,
    required this.at,
  });

  final String kind;
  final String detail;
  final DateTime at;
}

class DelayedChoiceRound {
  const DelayedChoiceRound({required this.toolCalls, required this.hadContent});

  final int toolCalls;
  final bool hadContent;
}

class DelayedChoiceRunResult {
  const DelayedChoiceRunResult({
    required this.content,
    required this.rounds,
    required this.stoppedReason,
  });

  final String content;
  final List<DelayedChoiceRound> rounds;
  final String stoppedReason;

  int get totalToolCalls => rounds.fold(0, (s, r) => s + r.toolCalls);
}
