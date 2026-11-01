import 'dart:convert';

import 'package:maaso/src/features/agent/application/intent/creation_intent.dart';
import 'package:maaso/src/features/agent/application/intent/lookup_intent.dart';

enum AgentActionScope {
  chat,
  proactivePresence,
  notificationInteraction;

  bool allowsActionType(String type) => switch (this) {
    AgentActionScope.chat => true,
    AgentActionScope.proactivePresence =>
      type == 'emotion.set' || type == 'avatar.act' || type == 'avatar.react',
    AgentActionScope.notificationInteraction =>
      type == 'emotion.set' || type == 'voice.speak',
  };
}

class AgentActionProtocolException implements Exception {
  const AgentActionProtocolException(
    this.code, {
    this.params = const <String, Object?>{},
    this.debugCause,
  });

  /// Stable machine-readable reason. Never expose provider/parser details.
  final String code;
  final Map<String, Object?> params;
  final Object? debugCause;

  /// Compatibility getter for log-only callers. This is intentionally the
  /// stable code rather than localized or parser-provided prose.
  String get message => code;

  String get debugDescription => debugCause == null
      ? code
      : '$code (${debugCause.runtimeType}: $debugCause)';

  @override
  String toString() => 'AgentActionProtocolException: $code';
}

class AgentActionEnvelope {
  const AgentActionEnvelope({
    required this.reply,
    required this.actions,
    this.scope = AgentActionScope.chat,
  });

  final String reply;
  final List<AgentAction> actions;
  final AgentActionScope scope;

  factory AgentActionEnvelope.parse(
    String raw, {
    AgentActionScope scope = AgentActionScope.chat,
  }) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const AgentActionProtocolException('empty_response');
    }
    final jsonText = _extractJsonObject(text);
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (error) {
      throw AgentActionProtocolException('invalid_json', debugCause: error);
    }
    if (decoded is! Map) {
      throw const AgentActionProtocolException('top_level_not_object');
    }

    final reply = (decoded['reply'] ?? '').toString().trim();
    final rawActions = decoded['actions'];
    if (rawActions is! List) {
      throw const AgentActionProtocolException('actions_not_list');
    }
    final actions = rawActions
        .whereType<Map>()
        .map((json) => AgentAction.fromJson(json))
        .toList(growable: false);
    if (reply.isEmpty && actions.isEmpty) {
      throw const AgentActionProtocolException('missing_reply_or_actions');
    }
    if (rawActions.length != actions.length) {
      throw const AgentActionProtocolException('action_not_object');
    }
    final envelope = AgentActionEnvelope(
      reply: reply,
      actions: actions,
      scope: scope,
    );
    envelope.validateCreationIntentActions();
    envelope.validateLookupIntentActions();
    switch (scope) {
      case AgentActionScope.chat:
        break;
      case AgentActionScope.proactivePresence:
        _validateProactivePresenceResponse(actions);
      case AgentActionScope.notificationInteraction:
        _validateNotificationInteractionResponse(actions);
    }
    return envelope;
  }

  /// Validates semantic project data even when a caller constructed the
  /// envelope directly. This does not grant or execute the intent.
  CreationIntent? validateCreationIntentActions() {
    if (actions.where((action) => action.type == 'creation.intent').length >
        1) {
      throw const AgentActionProtocolException('creation_intent_duplicate');
    }
    CreationIntent? intent;
    for (var index = 0; index < actions.length; index += 1) {
      final action = actions[index];
      if (action.type != 'creation.intent') continue;
      if (intent != null) {
        throw const AgentActionProtocolException('creation_intent_duplicate');
      }
      try {
        intent = CreationIntent.fromJson(action.data);
      } on FormatException catch (error) {
        throw AgentActionProtocolException(
          'creation_intent_invalid',
          debugCause: error,
        );
      }
      if (index != actions.length - 1) {
        throw const AgentActionProtocolException(
          'creation_intent_not_terminal',
        );
      }
    }
    return intent;
  }

  /// Validates optional lookup data without granting or executing a tool.
  LookupIntent? validateLookupIntentActions() {
    final lookups = actions.where((action) => action.type == 'lookup.intent');
    if (lookups.isEmpty) return null;
    if (scope != AgentActionScope.chat) {
      throw const AgentActionProtocolException(
        'lookup_intent_scope_not_allowed',
      );
    }
    if (lookups.length != 1) {
      throw const AgentActionProtocolException('lookup_intent_duplicate');
    }
    final action = lookups.single;
    final LookupIntent intent;
    try {
      intent = LookupIntent.fromJson(action.data);
    } on FormatException catch (error) {
      throw AgentActionProtocolException(
        'lookup_intent_invalid',
        debugCause: error,
      );
    }
    final index = actions.indexOf(action);
    if (index != actions.length - 1 &&
        !(index == actions.length - 2 &&
            actions.last.type == 'creation.intent')) {
      throw const AgentActionProtocolException('lookup_intent_not_terminal');
    }
    final creation = validateCreationIntentActions();
    if (creation != null && creation.mode != CreationIntentMode.none) {
      throw const AgentActionProtocolException('conflicting_semantic_intents');
    }
    return intent;
  }

  Map<String, Object?> toJson() => {
    'reply': reply,
    'actions': actions.map((action) => action.toJson()).toList(),
  };

  static bool _looksLikeLegacyScript(String text) {
    final legacyNamespace = String.fromCharCodes([67, 108, 97, 119, 46]);
    if (text.contains(legacyNamespace)) return true;
    return RegExp(
      r'```(?:javascript|js)\b',
      caseSensitive: false,
    ).hasMatch(text);
  }

  static String _extractJsonObject(String text) {
    // JSON string values are data. Generated JavaScript and documentation may
    // contain legacy names or Markdown examples without becoming host scripts.
    // Decode the complete object before considering any external wrapper.
    if (text.startsWith('{')) return text;

    final fence = RegExp(
      r'^```(?:json)?\s*([\s\S]*)```$',
      caseSensitive: false,
    ).firstMatch(text);
    final candidate = (fence?.group(1) ?? text).trim();
    if (candidate.startsWith('{')) return candidate;

    // Never extract an object from prose, an executable wrapper, or a mixed
    // response. That would silently discard instructions outside the contract.
    if (_looksLikeLegacyScript(text)) {
      throw const AgentActionProtocolException('legacy_script');
    }
    throw const AgentActionProtocolException('no_json_object');
  }

  static void _validateNotificationInteractionResponse(
    List<AgentAction> actions,
  ) {
    for (final action in actions) {
      if (!AgentActionScope.notificationInteraction.allowsActionType(
        action.type,
      )) {
        throw AgentActionProtocolException(
          'notification_action_not_allowed',
          params: <String, Object?>{'type': action.type},
        );
      }
    }
  }

  static void _validateProactivePresenceResponse(List<AgentAction> actions) {
    for (final action in actions) {
      if (!AgentActionScope.proactivePresence.allowsActionType(action.type)) {
        throw AgentActionProtocolException(
          'proactive_action_not_allowed',
          params: <String, Object?>{'type': action.type},
        );
      }
    }
  }
}

class AgentAction {
  const AgentAction({required this.type, required this.data});

  final String type;
  final Map<String, Object?> data;

  factory AgentAction.fromJson(Map<dynamic, dynamic> json) {
    final type = (json['type'] ?? '').toString().trim();
    if (type.isEmpty) {
      throw const AgentActionProtocolException('action_missing_type');
    }
    final data = _stringKeyed(json);
    if (type == 'lookup.intent') {
      try {
        final intent = LookupIntent.fromJson(data);
        return AgentAction(
          type: type,
          data: Map<String, Object?>.unmodifiable(intent.toJson()),
        );
      } on FormatException catch (error) {
        throw AgentActionProtocolException(
          'lookup_intent_invalid',
          debugCause: error,
        );
      }
    }
    if (type == 'creation.intent') {
      try {
        final intent = CreationIntent.fromJson(data);
        return AgentAction(
          type: type,
          data: Map<String, Object?>.unmodifiable(intent.toJson()),
        );
      } on FormatException catch (error) {
        throw AgentActionProtocolException(
          'creation_intent_invalid',
          debugCause: error,
        );
      }
    }
    return AgentAction(type: type, data: data);
  }

  Object? operator [](String key) => data[key];

  Map<String, Object?> toJson() => data;

  static Map<String, Object?> _stringKeyed(Map<dynamic, dynamic> raw) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
}
