import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/controllers/agent_card_controller.dart';
import 'package:maaso/src/core/widgets/agent_cards.dart';

/// Lets the cloud (and on-device) brain push a *floating confirmation card*
/// above the chat input. These are **transient user-interaction surfaces**:
/// API-key setup, parameter
/// confirmation, short forms.  Once the user taps a footer button (back / skip
/// / next / confirm) the card disappears.
///
/// Use this whenever the agent needs structured input from the user without
/// hijacking the chat thread with awkward "please reply with key=…" prompts.
class ShowCardSkill extends AgentSkill {
  ShowCardSkill({this.agentId});

  final String? agentId;

  @override
  String get skillName => 'ShowCard';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Push a floating confirmation / setup card above the chat input. '
      'Use this when you need the user to confirm a value, fill in a key, '
      'or pick from a short list of options — anything that would feel '
      'clunky as plain chat text. Cards disappear after the user taps a '
      'footer button.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'showSetupCard': _show,
  };

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => {
    'showSetupCard': {
      'type': 'object',
      'properties': {
        'type': {
          'type': 'string',
          'enum': ['set_api_key'],
          'description': 'Card type to render.',
        },
        'props': {
          'type': 'object',
          'description':
              'Optional card props such as prefilled_key, base_url, and model.',
        },
      },
      'required': ['type'],
    },
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'showSetupCard':
        'Show a setup or confirmation card above chat; currently supports type "set_api_key".',
  };

  dynamic _show(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_args"}';
    if (!appServices.isRegistered<AgentCardController>()) {
      return '{"error":"no_controller"}';
    }
    try {
      final raw = args[0];
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return '{"error":"expected_object"}';
      final type = decoded['type']?.toString().trim() ?? '';
      if (type.isEmpty) return '{"error":"missing_type"}';
      final props = (decoded['props'] is Map)
          ? Map<String, dynamic>.from(decoded['props'])
          : <String, dynamic>{};

      final card = AgentCards.fromType(type, props);
      if (card == null) {
        Log.w('🪪 [ShowCard] unknown card type: $type');
        return '{"error":"unknown_type","type":"$type"}';
      }
      appServices.find<AgentCardController>().push(card);
      Log.i('🪪 [ShowCard] pushed $type (id=${card.id})');
      return jsonEncode({'status': 'ok', 'cardId': card.id, 'type': type});
    } catch (error) {
      Log.w('[ShowCard] failed: $error');
      return jsonEncode({'error': 'execution_failed'});
    }
  }
}
