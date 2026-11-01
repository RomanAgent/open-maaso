import 'dart:convert';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/persona/agent_persona_spec.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/soul_service.dart';

/// Lets the agent persist what it has just learned about itself into
/// `soul.md`. The Agent name comes from app setup; this skill can record
/// other facts later when the master tells the agent to update them.
///
/// All fields are optional — pass only the ones you're updating this turn,
/// so a single skill call can save partial answers as they arrive instead
/// of forcing the agent to collect every field before writing.
///
/// Also syncs [AgentProfile.nickname] when `name` changes, so the chat
/// header / avatar label refresh without a separate save.
class SetSoulSkill extends AgentSkill {
  SetSoulSkill();

  SoulService get _soul => appServices.find<SoulService>();
  AgentCoreController get _core => appServices.find<AgentCoreController>();

  @override
  String get skillName => 'SetSoul';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Save what you learned about yourself into soul.md (your identity file). '
      'The Agent name is the name chosen during app setup; do not rename it here. '
      'Use this to record the age or gender the master assigns you. Later, call again '
      'whenever those facts change, or use notesAppend to remember other things about '
      'yourself. Use professionTitle and specialties only when the master explicitly sets '
      'or changes them. Pass only the fields you are updating this turn — partial saves are fine.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setSoul': _setSoul,
    'getSoul': _getSoul,
  };

  Future<dynamic> _setSoul(List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(args[0].toString()) as Map<String, dynamic>;
    } catch (_) {
      return '{"error":"invalid_json"}';
    }

    final name = payload['name']?.toString().trim();
    final identity = appServices.maybeFind<IdentityService>();
    if (identity != null &&
        (name?.isNotEmpty ?? false) &&
        (!identity.onboardingCompleted || name != identity.setupAgentName)) {
      final status = identity.onboardingCompleted
          ? 'agent_name_from_setup'
          : 'agent_setup_required';
      return jsonEncode({
        'status': status,
        if (!identity.onboardingCompleted) 'route': AppRouteCatalog.onboarding,
        if (identity.onboardingCompleted) 'agentName': identity.setupAgentName,
        'message': AgentPromptCatalog.text('skill.result.set_soul.$status'),
      });
    }
    final ageRaw = payload['age'];
    int? age;
    if (ageRaw is num) {
      age = ageRaw.toInt();
    } else if (ageRaw is String && ageRaw.trim().isNotEmpty) {
      age = int.tryParse(ageRaw.trim());
    }
    final gender = payload['gender']?.toString().trim();
    final notesAppend = payload['notesAppend']?.toString();
    final notesReplace = payload['notesReplace']?.toString();
    final updatesProfession = payload.containsKey('professionTitle');
    final updatesSpecialties = payload.containsKey('specialties');
    final professionTitle = updatesProfession
        ? _optionalText(payload['professionTitle'])
        : null;
    final specialties = updatesSpecialties
        ? _specialties(payload['specialties'])
        : const <String>[];

    await _soul.update(
      name: (name?.isEmpty ?? true) ? null : name,
      age: age,
      gender: (gender?.isEmpty ?? true) ? null : gender,
      notesAppend: notesAppend,
      notesReplace: notesReplace,
    );

    // Keep public identity metadata on AgentProfile so UI and prompt readers
    // observe one atomic profile update. copyWith preserves every unrelated
    // profile field, including theme/UI settings and future optional persona
    // values.
    final currentProfile = _core.profile.value;
    if (currentProfile != null) {
      final updatesPersona = updatesProfession || updatesSpecialties;
      final currentPersona = currentProfile.persona;
      final nextPersona = updatesPersona
          ? AgentPersonaSpec.fromJson(<String, Object?>{
              'schemaVersion': AgentPersonaSpec.currentSchemaVersion,
              'professionTitle': updatesProfession
                  ? professionTitle
                  : currentPersona.professionTitle,
              'specialties': updatesSpecialties
                  ? specialties
                  : currentPersona.specialties,
              'interests': currentPersona.interests,
              'socialStyle': currentPersona.socialStyle.toJson(),
              'avoidTopics': currentPersona.avoidTopics,
            })
          : currentPersona;
      final nextName = (name?.isNotEmpty ?? false)
          ? name!
          : currentProfile.nickname;
      if (nextName != currentProfile.nickname || updatesPersona) {
        await _core.updateProfile(
          currentProfile.copyWith(nickname: nextName, persona: nextPersona),
        );
      }
    }

    return jsonEncode({
      'status': 'ok',
      'configured': _soul.configured,
      'soul': {
        'name': _soul.name.value,
        'age': _soul.age.value,
        'gender': _soul.gender.value,
      },
      if (_core.profile.value case final profile?)
        'persona': profile.persona.toJson(),
    });
  }

  dynamic _getSoul(List<dynamic> _) => jsonEncode({
    'name': _soul.name.value,
    'age': _soul.age.value,
    'gender': _soul.gender.value,
    'notes': _soul.notes.value,
    'configured': _soul.configured,
  });

  static String? _optionalText(Object? value) {
    if (value is! String) return null;
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.isEmpty ? null : normalized;
  }

  static List<String> _specialties(Object? value) {
    final values = switch (value) {
      List<dynamic> items => items.whereType<String>(),
      String text => text.split(RegExp(r'[,，;；\n]')),
      _ => const <String>[],
    };
    return values.toList(growable: false);
  }
}
