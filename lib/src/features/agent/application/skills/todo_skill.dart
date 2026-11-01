import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/todo_service.dart';

/// Lets the agent maintain a working checklist for multi-step tasks —
/// mirrors what Claude Code does with TodoWrite.  The user sees the list
/// as a corner card on the home page, ticked off as the agent finishes
/// each item.  Encourage usage when the task obviously has ≥2 steps.
class TodoSkill extends AgentSkill
    implements StructuredActionPromptSchemaProvider {
  TodoSkill({this.agentId});

  final String? agentId;

  TodoService get _svc => appServices.find<TodoService>();

  @override
  String get skillName => 'Todo';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Progress checklist for the current task. Any request with more than two steps should first be listed via todo_addMany([...]), '
      'then tick off each item with todo_complete(id) as you finish it. The user can see your progress in real time on screen.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'todo_add': _add,
    'todo_addMany': _addMany,
    'todo_complete': _complete,
    'todo_completeIndex': _completeIndex,
    'todo_list': _list,
    'todo_clear': _clear,
  };

  static final _promptSchemas = StructuredActionPromptSchemas({
    'todo_add': {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'minLength': 1,
          'maxLength': 256,
          'pattern': r'\S',
        },
      },
      'required': ['text'],
      'additionalProperties': false,
    },
    'todo_addMany': {
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'items': {
            'type': 'string',
            'minLength': 1,
            'maxLength': 256,
            'pattern': r'\S',
          },
          'minItems': 1,
          'maxItems': 20,
        },
      },
      'required': ['items'],
      'additionalProperties': false,
    },
    'todo_complete': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'pattern': r'^t[1-9]\d*$'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
    'todo_completeIndex': {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer', 'minimum': 1},
      },
      'required': ['index'],
      'additionalProperties': false,
    },
    'todo_list': {
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    },
    'todo_clear': {
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    },
  });

  @override
  StructuredActionPromptSchemas get structuredActionPromptSchemas =>
      _promptSchemas;

  Object? _argumentValue(List<dynamic> args, String key) {
    if (args.isEmpty) return null;
    final raw = args.first;
    if (raw is! String) return raw is Map ? raw[key] : raw;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded[key] : decoded;
    } catch (_) {
      return raw; // Legacy positional invocation.
    }
  }

  dynamic _add(List<dynamic> args) {
    final text = _argumentValue(args, 'text');
    if (text is! String || text.trim().isEmpty) {
      return '{"error":"missing_text"}';
    }
    final id = _svc.add(text.trim());
    return jsonEncode({'status': 'ok', 'id': id});
  }

  dynamic _addMany(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_items"}';
    try {
      final raw = args[0];
      final decoded = raw is String ? jsonDecode(raw) : raw;
      final items = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['items']
          : null;
      if (items is! List ||
          items.isEmpty ||
          items.length > 20 ||
          items.any(
            (item) =>
                item is! String || item.trim().isEmpty || item.length > 256,
          )) {
        return '{"error":"expected_nonempty_string_array"}';
      }
      final ids = <String>[];
      for (final v in items) {
        ids.add(_svc.add((v as String).trim()));
      }
      return jsonEncode({'status': 'ok', 'ids': ids});
    } catch (_) {
      return '{"error":"invalid_json"}';
    }
  }

  dynamic _complete(List<dynamic> args) {
    final id = _argumentValue(args, 'id');
    if (id is! String || id.trim().isEmpty) return '{"error":"missing_id"}';
    final ok = _svc.complete(id.trim());
    return jsonEncode({'status': ok ? 'ok' : 'not_found'});
  }

  dynamic _completeIndex(List<dynamic> args) {
    final index = _argumentValue(args, 'index');
    if (index == null) return '{"error":"missing_index"}';
    final idx = index is int ? index : int.tryParse(index.toString()) ?? 0;
    if (idx < 1 || idx > _svc.items.length) {
      return '{"error":"index_out_of_range"}';
    }
    _svc.complete(_svc.items[idx - 1].id);
    return '{"status":"ok"}';
  }

  dynamic _list(List<dynamic> _) => jsonEncode(_svc.snapshot());

  dynamic _clear(List<dynamic> _) {
    _svc.clear();
    return '{"status":"ok"}';
  }
}
