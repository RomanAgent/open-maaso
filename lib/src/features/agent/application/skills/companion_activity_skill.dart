import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_service.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_surface_factory.dart';

typedef CompanionActivitySkillClock = DateTime Function();

/// Minimal built-in bridge for account-scoped Companion Activities.
///
/// All mutations are deliberately not agent-invocable here. They remain behind
/// trusted host/UI boundaries in [CompanionActivityService].
final class CompanionActivitySkill extends AgentSkill {
  CompanionActivitySkill({
    CompanionActivityService? service,
    CompanionActivitySurfaceFactory surfaceFactory =
        const CompanionActivitySurfaceFactory(),
    CompanionActivitySkillClock? clock,
    this.agentId = 'self',
  }) : _serviceOverride = service,
       _surfaceFactory = surfaceFactory,
       _clock = clock ?? DateTime.now;

  final CompanionActivityService? _serviceOverride;
  final CompanionActivitySurfaceFactory _surfaceFactory;
  final CompanionActivitySkillClock _clock;
  final String agentId;

  CompanionActivityService get _service =>
      _serviceOverride ?? appServices.find<CompanionActivityService>();

  @override
  String get skillName => 'CompanionActivity';

  @override
  String get description =>
      'Read account-scoped companion activities or build a fully offline '
      'read-only activity dashboard. This skill cannot create occurrences, '
      'approve evidence, award points, redeem rewards, or promise physical '
      'rewards.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'activitySummary': _summary,
        'activityBuildSurface': _buildSurface,
      };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas =>
      <String, Map<String, dynamic>>{
        'activitySummary': _dateSchema,
        'activityBuildSurface': _dateSchema,
      };

  @override
  Map<String, String> get nativeMethodDescriptions => const <String, String>{
    'activitySummary':
        'Read tasks, virtual points, and streak without changing state.',
    'activityBuildSurface':
        'Build a self-contained offline dashboard and a persistable surface widget snapshot.',
  };

  Future<String> _summary(List<dynamic> args) async {
    try {
      final input = _decode(args, const <String>{'asOf'});
      final asOf = ActivityLocalDate.parse(_requiredString(input, 'asOf'));
      final snapshot = await _service.snapshot();
      final streak = await _service.streak(asOf: asOf);
      final tasks = snapshot.tasks.toList(growable: false)
        ..sort((left, right) => right.availableAt.compareTo(left.availableAt));
      return jsonEncode(<String, Object?>{
        'status': 'ok',
        'balance': snapshot.ledger.balance,
        'streak': streak.current,
        'longestStreak': streak.longest,
        'tasks': tasks
            .take(CompanionActivitySurfaceFactory.maxVisibleTasks)
            .map(
              (task) => <String, Object?>{
                'id': task.id,
                'templateId': task.templateId,
                'title': task.title,
                'state': task.state.name,
                'cadence': task.cadence.name,
                'awardPoints': task.awardPoints,
                'availableAt': task.availableAt.toUtc().toIso8601String(),
                'dueAt': task.dueAt.toUtc().toIso8601String(),
              },
            )
            .toList(growable: false),
      });
    } on FormatException catch (error) {
      return _error('invalid_arguments', error.message);
    } on ArgumentError {
      return _error('invalid_arguments');
    } on StateError {
      return _error('activity_unavailable');
    } on Object {
      return _error('execution_failed');
    }
  }

  Future<String> _buildSurface(List<dynamic> args) async {
    try {
      final input = _decode(args, const <String>{'asOf'});
      final asOf = ActivityLocalDate.parse(_requiredString(input, 'asOf'));
      final snapshot = await _service.snapshot();
      final streak = await _service.streak(asOf: asOf);
      final bundle = _surfaceFactory.build(
        snapshot: snapshot,
        streak: streak,
        accountId: _service.scope.accountId,
        facadeGeneration: _service.scope.facadeGeneration,
        agentId: agentId,
        generatedAt: _clock(),
      );
      return jsonEncode(<String, Object?>{
        'status': 'ok',
        'surface': bundle.project.toJson(),
        'widget': bundle.widget.toJson(),
      });
    } on FormatException catch (error) {
      return _error('invalid_arguments', error.message);
    } on ArgumentError {
      return _error('invalid_arguments');
    } on StateError {
      return _error('activity_unavailable');
    } on Object {
      return _error('execution_failed');
    }
  }

  static Map<String, Object?> _decode(
    List<dynamic> args,
    Set<String> allowedKeys,
  ) {
    if (args.length != 1) {
      throw const FormatException('expected exactly one argument object');
    }
    final raw = args.first;
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) throw const FormatException('expected object');
    final input = Map<String, Object?>.from(decoded);
    if (input.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('unexpected argument field');
    }
    return input;
  }

  static String _requiredString(Map<String, Object?> input, String field) {
    final value = input[field];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field is required');
    }
    return value.trim();
  }

  static String _error(String code, [String? message]) =>
      jsonEncode(<String, Object?>{
        'error': code,
        if (message != null && message.isNotEmpty) 'message': message,
      });

  static const Map<String, dynamic> _dateSchema = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'asOf': <String, dynamic>{
        'type': 'string',
        'description': 'Current local date in YYYY-MM-DD form.',
      },
    },
    'required': <String>['asOf'],
    'additionalProperties': false,
  };
}
