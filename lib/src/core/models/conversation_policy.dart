import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/episode.dart';

enum RelationshipExpressionStage {
  newlyMet('new'),
  familiar('familiar'),
  close('close');

  const RelationshipExpressionStage(this.key);
  final String key;
}

enum ConversationFactKind {
  preferredAddress,
  forbiddenAddress,
  banterBoundary,
  restriction,
  sharedContext,
  repair,
}

enum BanterDisposition { unknown, accepted, forbidden }

enum ConversationRestriction { noTeasing, noUnsolicitedAdvice, serious }

enum ConversationEvidenceKind {
  confirmedContinuation,
  sharedPhraseReuse,
  preferenceRespected,
}

enum ConversationRepairStatus { open, boundaryApplied, resolved }

/// A single semantic claim. Authority and source provenance are supplied by
/// MemoryWriteCoordinator, never by this payload or a model response.
final class ConversationFactDraft {
  ConversationFactDraft._(this.kind, Map<String, Object?> payload)
    : payload = Map.unmodifiable(payload) {
    _validate();
  }

  factory ConversationFactDraft.preferredAddress(String address) =>
      ConversationFactDraft._(ConversationFactKind.preferredAddress, {
        'address': address,
      });

  factory ConversationFactDraft.forbiddenAddress(
    String address, {
    bool forbidden = true,
  }) => ConversationFactDraft._(ConversationFactKind.forbiddenAddress, {
    'address': address,
    'forbidden': forbidden,
  });

  factory ConversationFactDraft.banter({
    required String topicKey,
    required BanterDisposition disposition,
  }) => ConversationFactDraft._(ConversationFactKind.banterBoundary, {
    'topicKey': topicKey,
    'disposition': disposition.name,
    'maxIntensity': disposition == BanterDisposition.accepted
        ? 'light'
        : 'none',
  });

  factory ConversationFactDraft.restriction({
    required ConversationRestriction restriction,
    required bool restricted,
  }) => ConversationFactDraft._(ConversationFactKind.restriction, {
    'restriction': restriction.name,
    'restricted': restricted,
  });

  factory ConversationFactDraft.sharedContext({
    required String contextKey,
    required String label,
    required ConversationEvidenceKind evidenceKind,
    String? preferenceSlot,
  }) => ConversationFactDraft._(ConversationFactKind.sharedContext, {
    'contextKey': contextKey,
    'label': label,
    'evidenceKind': evidenceKind.name,
    'preferenceSlot': ?preferenceSlot,
  });

  factory ConversationFactDraft.repair({
    required String targetSlot,
    required ConversationRepairStatus status,
  }) => ConversationFactDraft._(ConversationFactKind.repair, {
    'targetSlot': targetSlot,
    'status': status.name,
  });

  final ConversationFactKind kind;
  final Map<String, Object?> payload;
  String? get address => payload['address'] as String?;
  bool? get forbidden => payload['forbidden'] as bool?;
  String? get topicKey => payload['topicKey'] as String?;
  BanterDisposition? get disposition =>
      _enumOrNull(BanterDisposition.values, payload['disposition']);
  ConversationRestriction? get restriction =>
      _enumOrNull(ConversationRestriction.values, payload['restriction']);
  bool? get restricted => payload['restricted'] as bool?;
  String? get contextKey => payload['contextKey'] as String?;
  String? get label => payload['label'] as String?;
  ConversationEvidenceKind? get evidenceKind =>
      _enumOrNull(ConversationEvidenceKind.values, payload['evidenceKind']);
  String? get preferenceSlot => payload['preferenceSlot'] as String?;
  String? get targetSlot => payload['targetSlot'] as String?;
  ConversationRepairStatus? get repairStatus =>
      _enumOrNull(ConversationRepairStatus.values, payload['status']);

  String get slotKey => switch (kind) {
    ConversationFactKind.preferredAddress => 'address.preferred',
    ConversationFactKind.forbiddenAddress =>
      'address.forbidden.${conversationContextKey(address!)}',
    ConversationFactKind.banterBoundary => 'banter.$topicKey',
    ConversationFactKind.restriction => 'restriction.${restriction!.name}',
    ConversationFactKind.sharedContext =>
      'context.${evidenceKind!.name}.$contextKey'
          '${preferenceSlot == null ? '' : '.${conversationContextKey(preferenceSlot!)}'}',
    ConversationFactKind.repair =>
      'repair.${conversationContextKey(targetSlot!)}',
  };

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'kind': kind.name,
    'payload': payload,
  };

  factory ConversationFactDraft.fromJson(Map<String, Object?> json) {
    if (!_exactKeys(json, {'schemaVersion', 'kind', 'payload'}) ||
        json['schemaVersion'] != 1 ||
        json['payload'] is! Map) {
      throw const FormatException('invalid conversation fact');
    }
    final kind = _enumOrNull(ConversationFactKind.values, json['kind']);
    if (kind == null) {
      throw const FormatException('invalid conversation fact kind');
    }
    try {
      return ConversationFactDraft._(
        kind,
        Map<String, Object?>.from(json['payload']! as Map),
      );
    } on Object {
      throw const FormatException('invalid conversation fact payload');
    }
  }

  void _validate() {
    final keys = switch (kind) {
      ConversationFactKind.preferredAddress => {'address'},
      ConversationFactKind.forbiddenAddress => {'address', 'forbidden'},
      ConversationFactKind.banterBoundary => {
        'topicKey',
        'disposition',
        'maxIntensity',
      },
      ConversationFactKind.restriction => {'restriction', 'restricted'},
      ConversationFactKind.sharedContext => {
        'contextKey',
        'label',
        'evidenceKind',
        if (payload.containsKey('preferenceSlot')) 'preferenceSlot',
      },
      ConversationFactKind.repair => {'targetSlot', 'status'},
    };
    if (!_exactKeys(payload, keys)) {
      throw const FormatException('unknown fact field');
    }
    switch (kind) {
      case ConversationFactKind.preferredAddress:
      case ConversationFactKind.forbiddenAddress:
        if (normalizeConversationAddress(address) != address ||
            address == null ||
            (kind == ConversationFactKind.forbiddenAddress &&
                forbidden == null)) {
          throw const FormatException('invalid address');
        }
      case ConversationFactKind.banterBoundary:
        if (!conversationBanterTopics.contains(topicKey) ||
            disposition == null ||
            (disposition == BanterDisposition.accepted &&
                !conversationLightBanterTopics.contains(topicKey)) ||
            payload['maxIntensity'] !=
                (disposition == BanterDisposition.accepted
                    ? 'light'
                    : 'none')) {
          throw const FormatException('invalid banter boundary');
        }
      case ConversationFactKind.restriction:
        if (restriction == null || restricted == null) {
          throw const FormatException('invalid restriction');
        }
      case ConversationFactKind.sharedContext:
        if (!_identifier(contextKey) ||
            !_literal(label, 96) ||
            evidenceKind == null ||
            (evidenceKind == ConversationEvidenceKind.preferenceRespected) !=
                (preferenceSlot != null) ||
            (preferenceSlot != null && !_identifier(preferenceSlot))) {
          throw const FormatException('invalid shared context');
        }
      case ConversationFactKind.repair:
        if (!_identifier(targetSlot) || repairStatus == null) {
          throw const FormatException('invalid repair');
        }
    }
  }
}

const conversationLightBanterTopics = {
  'gaming',
  'work',
  'study',
  'cooking',
  'procrastination',
  'daily_mixups',
};
const conversationBanterTopics = {
  ...conversationLightBanterTopics,
  'general',
  'appearance',
  'health',
  'family',
  'relationships',
  'finances',
  'identity',
  'trauma',
};

final class ConversationFact {
  ConversationFact({
    required this.draft,
    required this.episodeId,
    required this.revision,
    required List<EpisodeSourceRef> sourceRefs,
  }) : sourceRefs = List.unmodifiable(sourceRefs) {
    if (episodeId < 1 ||
        revision < 1 ||
        sourceRefs.isEmpty ||
        sourceRefs.length > 8 ||
        !sourceRefs.any(
          (source) => source.origin == EpisodeSourceOrigin.user,
        )) {
      throw const FormatException(
        'conversation fact requires human provenance',
      );
    }
  }
  final ConversationFactDraft draft;
  final int episodeId;
  final int revision;
  final List<EpisodeSourceRef> sourceRefs;
  String get currentUserSourceId => sourceRefs
      .firstWhere((source) => source.origin == EpisodeSourceOrigin.user)
      .sourceId;
}

/// A read model of accepted, source-live facts, supplied by the account-owned
/// governed service. Neither message counts nor legacy bond scores enter it.
final class ConversationPolicy {
  ConversationPolicy.fromFacts(
    Iterable<ConversationFact> input, {
    required this.policyVersion,
  }) {
    final bySlot = <String, ConversationFact>{};
    for (final fact in input) {
      final old = bySlot[fact.draft.slotKey];
      if (old == null ||
          fact.revision > old.revision ||
          (fact.revision == old.revision && fact.episodeId > old.episodeId)) {
        bySlot[fact.draft.slotKey] = fact;
      }
    }
    facts = List.unmodifiable(bySlot.values);
    preferredAddress = bySlot['address.preferred']?.draft.address;
    forbiddenAddresses = List.unmodifiable(
      facts
          .where(
            (fact) =>
                fact.draft.kind == ConversationFactKind.forbiddenAddress &&
                fact.draft.forbidden == true,
          )
          .map((fact) => fact.draft.address!),
    );
    banterBoundaries = Map.unmodifiable({
      for (final fact in facts)
        if (fact.draft.kind == ConversationFactKind.banterBoundary)
          fact.draft.topicKey!: fact.draft.disposition!,
    });
    sharedContexts = List.unmodifiable(
      facts.where(
        (fact) => fact.draft.kind == ConversationFactKind.sharedContext,
      ),
    );
    repairs = List.unmodifiable(
      facts.where((fact) => fact.draft.kind == ConversationFactKind.repair),
    );
    expressionStage = _deriveStage();
  }
  final int policyVersion;
  late final List<ConversationFact> facts;
  late final String? preferredAddress;
  late final List<String> forbiddenAddresses;
  late final Map<String, BanterDisposition> banterBoundaries;
  late final List<ConversationFact> sharedContexts;
  late final List<ConversationFact> repairs;
  late final RelationshipExpressionStage expressionStage;

  bool restricted(ConversationRestriction restriction) => facts.any(
    (fact) =>
        fact.draft.kind == ConversationFactKind.restriction &&
        fact.draft.restriction == restriction &&
        fact.draft.restricted == true,
  );
  bool get hasUnresolvedRepair => repairs.any(
    (fact) => fact.draft.repairStatus != ConversationRepairStatus.resolved,
  );

  RelationshipExpressionStage _deriveStage() {
    if (hasUnresolvedRepair) return RelationshipExpressionStage.newlyMet;
    final confirmed = sharedContexts
        .where(
          (fact) =>
              fact.draft.evidenceKind ==
              ConversationEvidenceKind.confirmedContinuation,
        )
        .toList();
    if (confirmed.map((fact) => fact.draft.contextKey).toSet().length < 2 ||
        confirmed.map((fact) => fact.currentUserSourceId).toSet().length < 2) {
      return RelationshipExpressionStage.newlyMet;
    }
    final reused = sharedContexts
        .where(
          (fact) =>
              fact.draft.evidenceKind ==
              ConversationEvidenceKind.sharedPhraseReuse,
        )
        .toList();
    final respected = sharedContexts.any((evidence) {
      if (evidence.draft.evidenceKind !=
          ConversationEvidenceKind.preferenceRespected) {
        return false;
      }
      if (evidence.sourceRefs
              .where((ref) => ref.origin == EpisodeSourceOrigin.agent)
              .map((ref) => ref.sourceId)
              .toSet()
              .length <
          2) {
        return false;
      }
      return facts.any(
        (preference) =>
            preference.draft.slotKey == evidence.draft.preferenceSlot &&
            preference.currentUserSourceId != evidence.currentUserSourceId &&
            evidence.sourceRefs.any(
              (ref) => preference.sourceRefs.any(
                (source) =>
                    source.sourceId == ref.sourceId &&
                    source.contentHash == ref.contentHash,
              ),
            ),
      );
    });
    final ordinaryCloseness =
        confirmed.map((fact) => fact.draft.contextKey).toSet().length >= 3 &&
        confirmed.map((fact) => fact.currentUserSourceId).toSet().length >= 3;
    final sharedCloseness =
        reused.map((fact) => fact.draft.contextKey).toSet().length >= 2 &&
        reused.map((fact) => fact.currentUserSourceId).toSet().length >= 2;
    if (respected && (ordinaryCloseness || sharedCloseness)) {
      return RelationshipExpressionStage.close;
    }
    return RelationshipExpressionStage.familiar;
  }
}

final class ConversationEvidenceMessage {
  const ConversationEvidenceMessage({
    required this.text,
    required this.isUser,
    required this.source,
    this.turnId,
  });
  final String text;
  final bool isUser;
  final EpisodeSourceRef source;
  final String? turnId;
}

final class ConversationFactProposal {
  ConversationFactProposal({
    required this.draft,
    List<EpisodeSourceRef> supportingSources = const [],
  }) : supportingSources = List.unmodifiable(supportingSources);
  final ConversationFactDraft draft;
  final List<EpisodeSourceRef> supportingSources;
}

/// Restrictive deterministic producer. Callers supply only the current durable
/// human message and source-validated, already-published history. No model
/// metadata, delivery count, sentiment or elapsed time is evidence.
List<ConversationFactProposal> extractConversationFacts({
  required String userText,
  List<ConversationEvidenceMessage> history = const [],
  List<ConversationFact> acceptedFacts = const [],
}) {
  final output = <ConversationFactProposal>[
    for (final draft in parseConversationPreferences(
      userText,
      forPersistence: true,
    ))
      ConversationFactProposal(draft: draft),
  ];
  if (_quotedOrExplanatory(userText)) return output;
  final text = userText.trim();
  final confirmation =
      RegExp(
        r'^(?:你记对了|你还记得|对，就是上次(?:聊过|说过|讨论过)的)[，,:：\s]*[“「"]([^”」"\n]{2,64})[”」"][，,：:\s]+(.{4,160})[。.!！]?$',
      ).firstMatch(text) ??
      RegExp(
        r'^(?:you remembered correctly|yes, that is what we discussed)[,:\s]+"([^"\n]{2,64})"[,.:\s]+(.{4,160})[.!]?$',
        caseSensitive: false,
      ).firstMatch(text);
  if (confirmation != null && !_emptyAcknowledgment(confirmation.group(2)!)) {
    final label = confirmation.group(1)!.trim();
    // A successful continuation needs both the original user topic and a
    // later assistant continuation from a different turn.
    for (var index = history.length - 1; index >= 0; index--) {
      final assistant = history[index];
      if (assistant.isUser || !assistant.text.contains(label)) continue;
      final priorUsers = history
          .take(index)
          .where(
            (message) =>
                message.isUser &&
                message.text.contains(label) &&
                (message.turnId == null ||
                    assistant.turnId == null ||
                    message.turnId != assistant.turnId),
          );
      if (priorUsers.isEmpty) continue;
      output.add(
        ConversationFactProposal(
          draft: ConversationFactDraft.sharedContext(
            contextKey: conversationContextKey(label),
            label: label,
            evidenceKind: ConversationEvidenceKind.confirmedContinuation,
          ),
          supportingSources: [priorUsers.last.source, assistant.source],
        ),
      );
      break;
    }
  }
  final reuse =
      RegExp(
        r'^(?:还是我们说的|又到了我们说的|继续我们(?:上次)?说的)[“「"]([^”」"\n]{2,64})[”」"][，,：:\s]+(.{4,160})[。.!！]?$',
      ).firstMatch(text) ??
      RegExp(
        r'^(?:back to our|as we called it)[,:\s]+"([^"\n]{2,64})"[,.:\s]+(.{4,160})[.!]?$',
        caseSensitive: false,
      ).firstMatch(text);
  if (reuse != null && !_emptyAcknowledgment(reuse.group(2)!)) {
    final label = reuse.group(1)!.trim();
    final previous = history
        .where((message) => message.text.contains(label))
        .toList();
    final users = previous.where((message) => message.isUser).toList();
    final assistants = previous.where((message) => !message.isUser).toList();
    if (users.isNotEmpty &&
        assistants.isNotEmpty &&
        users.last.source.sourceId != assistants.last.source.sourceId) {
      output.add(
        ConversationFactProposal(
          draft: ConversationFactDraft.sharedContext(
            contextKey: conversationContextKey(label),
            label: label,
            evidenceKind: ConversationEvidenceKind.sharedPhraseReuse,
          ),
          supportingSources: [users.last.source, assistants.last.source],
        ),
      );
    }
  }
  final forbiddenRespected =
      RegExp(
        r'^你这次(?:确实)?(?:没有再叫我|没再叫我)[“「"]([^”」"\n]{1,32})[”」"][，,：:\s]*(?:这样很好|这样舒服多了|谢谢你记住了)[。.!！]?$',
      ).firstMatch(text) ??
      RegExp(
        r'^you did not call me "([^"\n]{1,32})" this time[,.:\s]+(?:thank you for remembering|that feels better)[.!]?$',
        caseSensitive: false,
      ).firstMatch(text);
  final preferredRespected =
      RegExp(
        r'^你这次(?:确实)?叫我[“「"]([^”」"\n]{1,32})[”」"][，,：:\s]*(?:这样很好|这样舒服多了|谢谢你记住了)[。.!！]?$',
      ).firstMatch(text) ??
      RegExp(
        r'^you called me "([^"\n]{1,32})" this time[,.:\s]+(?:thank you for remembering|that feels better)[.!]?$',
        caseSensitive: false,
      ).firstMatch(text);
  final restrictionRespected =
      RegExp(
        r'^这几次你都(?:没|没有)(给建议|开玩笑)[，,：:\s]*(?:这样舒服多了|这样很好|谢谢你记住了)[。.!！]?$',
      ).firstMatch(text) ??
      RegExp(
        r'^you have not (given advice|made jokes) these last few times[,.:\s]+(?:that feels better|thank you for remembering)[.!]?$',
        caseSensitive: false,
      ).firstMatch(text);
  if (forbiddenRespected != null ||
      preferredRespected != null ||
      restrictionRespected != null) {
    final address = normalizeConversationAddress(
      (forbiddenRespected ?? preferredRespected)?.group(1),
    );
    final restriction = restrictionRespected == null
        ? null
        : const [
            '给建议',
            'given advice',
          ].contains(restrictionRespected.group(1)!.toLowerCase())
        ? ConversationRestriction.noUnsolicitedAdvice
        : ConversationRestriction.noTeasing;
    final preference = acceptedFacts.where((fact) {
      final draft = fact.draft;
      if (restriction != null) {
        return draft.kind == ConversationFactKind.restriction &&
            draft.restriction == restriction &&
            draft.restricted == true;
      }
      return address != null &&
          draft.address == address &&
          (preferredRespected != null
              ? draft.kind == ConversationFactKind.preferredAddress
              : draft.kind == ConversationFactKind.forbiddenAddress &&
                    draft.forbidden == true);
    }).lastOrNull;
    // The service validates these as published turns. A user's substantive
    // confirmation is still a reviewable proposal, never an automatic score.
    final preferenceIndex = preference == null
        ? -1
        : history.indexWhere(
            (message) =>
                message.source.sourceId == preference.currentUserSourceId,
          );
    final assistantTurns = <String, List<ConversationEvidenceMessage>>{};
    for (final message
        in history
            .skip(preferenceIndex + 1)
            .where((message) => !message.isUser)) {
      (assistantTurns[message.turnId ?? message.source.sourceId] ??= []).add(
        message,
      );
    }
    final delivered = assistantTurns.values.toList().reversed.take(2).toList();
    if (preference != null && preferenceIndex >= 0 && delivered.length == 2) {
      final addressMatches =
          address == null ||
          delivered.every(
            (turn) => preferredRespected != null
                ? turn.any((message) => message.text.contains(address))
                : turn.every((message) => !message.text.contains(address)),
          );
      final sources = <String, EpisodeSourceRef>{
        for (final source in preference.sourceRefs) source.sourceId: source,
        for (final turn in delivered)
          for (final message in turn) message.source.sourceId: message.source,
      }.values.toList();
      // Absence of humor/advice is confirmed by the explicit human statement;
      // it is not inferred from a keyword or a model's self-assessment.
      if (addressMatches && sources.length <= 7) {
        output.add(
          ConversationFactProposal(
            draft: ConversationFactDraft.sharedContext(
              contextKey: conversationContextKey(preference.draft.slotKey),
              label: address == null ? '交流偏好' : '称呼:$address',
              evidenceKind: ConversationEvidenceKind.preferenceRespected,
              preferenceSlot: preference.draft.slotKey,
            ),
            supportingSources: sources,
          ),
        );
      }
    }
  }
  return List.unmodifiable(output);
}

/// Current explicit choices can immediately change expression; the same draft
/// is only a proposal for durable storage. Explicit today/turn scopes are never
/// offered as durable claims.
List<ConversationFactDraft> parseConversationPreferences(
  String raw, {
  bool forPersistence = false,
}) {
  if (_quotedOrExplanatory(raw)) return const [];
  final output = <ConversationFactDraft>[];
  for (var clause in _preferenceClauses(raw)) {
    if (RegExp(
      r'^(?:你好|嗨|谢谢|hi|hey|hello|thanks)$',
      caseSensitive: false,
    ).hasMatch(clause)) {
      continue;
    }
    final temporary = RegExp(
      r'^(?:今天|今日|这轮|这一轮|这次回答|这次|(?:for )?today|(?:for )?this (?:turn|reply|response))\s*|\s+(?:today|this turn|this reply|this response)$',
      caseSensitive: false,
    );
    final isTemporary = temporary.hasMatch(clause);
    clause = clause.replaceAll(temporary, '').trim();
    clause = clause.replaceFirst(
      RegExp(
        r'^(?:请记住[：:\s]*|记住[：:\s]*|remember[,:\s]+)',
        caseSensitive: false,
      ),
      '',
    );
    clause = clause
        .replaceFirst(
          RegExp(r'^(?:请|以后|之后|please\s+)', caseSensitive: false),
          '',
        )
        .trim();
    ConversationFactDraft? draft;
    final forbidden = RegExp(
      r'^(?:(?:不要|别)(?:再)?叫我\s*|(?:do not|don\x27t|stop) (?:call|calling) me\s+)(.+?)(?:了|吧)?$',
      caseSensitive: false,
    ).firstMatch(clause);
    final preferred = RegExp(
      r'^(?:(?:你可以)?叫我\s*|(?:you can )?call me\s+)(.+?)(?:吧)?$',
      caseSensitive: false,
    ).firstMatch(clause);
    final address = normalizeConversationAddress(
      (forbidden ?? preferred)?.group(1),
    );
    if (address != null) {
      draft = forbidden != null
          ? ConversationFactDraft.forbiddenAddress(address)
          : ConversationFactDraft.preferredAddress(address);
    }
    final topicBan =
        RegExp(
          r'^(?:不要|别)(?:再)?拿(.{1,24})(?:开玩笑|调侃)(?:了)?$',
        ).firstMatch(clause) ??
        RegExp(
          r'^(?:do not|don\x27t) (?:joke|tease) about (.{1,24})$',
          caseSensitive: false,
        ).firstMatch(clause);
    final topicAllow =
        RegExp(
          r'^(?:可以|允许你)(?:轻轻|轻微)?(?:拿|调侃)(.{1,24}?)(?:开玩笑|调侃)?$',
        ).firstMatch(clause) ??
        RegExp(
          r'^you can lightly (?:joke|tease) about (.{1,24})$',
          caseSensitive: false,
        ).firstMatch(clause);
    final topic = _topicKey((topicBan ?? topicAllow)?.group(1));
    if (topic != null &&
        (topicBan != null || conversationLightBanterTopics.contains(topic))) {
      draft = ConversationFactDraft.banter(
        topicKey: topic,
        disposition: topicBan != null
            ? BanterDisposition.forbidden
            : BanterDisposition.accepted,
      );
    }
    if (RegExp(
      r'^(?:(?:不要|别)(?:再)?(?:开玩笑|调侃我|拿我开玩笑|玩梗)(?:了)?|no (?:jokes|teasing)|(?:do not|don\x27t|stop) (?:joke|joking|tease me|teasing me))$',
      caseSensitive: false,
    ).hasMatch(clause)) {
      draft = ConversationFactDraft.restriction(
        restriction: ConversationRestriction.noTeasing,
        restricted: true,
      );
    }
    if (RegExp(
      r'^(?:(?:不要|别)(?:再)?(?:给我)?(?:建议|出主意)(?:了)?|我只想吐槽|no (?:unsolicited )?advice|just listen|(?:do not|don\x27t) give me advice)$',
      caseSensitive: false,
    ).hasMatch(clause)) {
      draft = ConversationFactDraft.restriction(
        restriction: ConversationRestriction.noUnsolicitedAdvice,
        restricted: true,
      );
    }
    if (RegExp(
      r'^(?:认真点|认真回答|严肃点|be serious|answer seriously)$',
      caseSensitive: false,
    ).hasMatch(clause)) {
      draft = ConversationFactDraft.restriction(
        restriction: ConversationRestriction.serious,
        restricted: true,
      );
    }
    if (RegExp(
      r'^(?:现在可以开玩笑了|可以开玩笑了|you can joke again|jokes are okay now)$',
      caseSensitive: false,
    ).hasMatch(clause)) {
      draft = ConversationFactDraft.restriction(
        restriction: ConversationRestriction.noTeasing,
        restricted: false,
      );
    }
    final repair = RegExp(r'^刚才拿(.{1,24})开玩笑(?:过分了|过了)$').firstMatch(clause);
    final repaired = RegExp(r'^关于(.{1,24})的玩笑问题已经解决了?$').firstMatch(clause);
    final repairTopic = _topicKey((repair ?? repaired)?.group(1));
    if (repairTopic != null) {
      draft = ConversationFactDraft.repair(
        targetSlot: 'banter.$repairTopic',
        status: repair != null
            ? ConversationRepairStatus.open
            : ConversationRepairStatus.resolved,
      );
    }
    if (draft == null) break;
    if (!forPersistence || !isTemporary) output.add(draft);
  }
  return List.unmodifiable(output);
}

String? _topicKey(String? raw) {
  if (raw == null) return null;
  return const <String, String>{
    '游戏': 'gaming',
    '打游戏': 'gaming',
    'gaming': 'gaming',
    '工作': 'work',
    'work': 'work',
    '学习': 'study',
    'study': 'study',
    '做饭': 'cooking',
    '厨艺': 'cooking',
    'cooking': 'cooking',
    '拖延': 'procrastination',
    'procrastination': 'procrastination',
    '日常小失误': 'daily_mixups',
    'daily mixups': 'daily_mixups',
    '外貌': 'appearance',
    'appearance': 'appearance',
    '健康': 'health',
    'health': 'health',
    '家人': 'family',
    'family': 'family',
    '感情': 'relationships',
    'relationships': 'relationships',
    '收入': 'finances',
    'finances': 'finances',
    '身份': 'identity',
    'identity': 'identity',
    '创伤': 'trauma',
    'trauma': 'trauma',
  }[raw.trim().toLowerCase()];
}

bool _quotedOrExplanatory(String raw) => RegExp(
  r'(?:^[\s]*[“「"‘]|[<>`]|这(?:句|段|句话|个表达)|什么意思|怎么翻译|翻译成|举个?例子|只是举例|不是对你的要求|(?:他说|她说|朋友说)|\b(?:translate|translation|what does|phrase|sentence|quotation|quoted|for example)\b)',
  caseSensitive: false,
).hasMatch(raw);

bool _emptyAcknowledgment(String raw) => RegExp(
  r'^(?:嗯|好|好的|哈哈|谢谢|对|yes|okay|ok|thanks|haha|[\s，,。.!！])+$',
  caseSensitive: false,
).hasMatch(raw.trim());

List<String> _preferenceClauses(String raw) {
  final result = <String>[];
  var buffer = StringBuffer();
  String? closing;
  const quotes = {'“': '”', '「': '」', '"': '"', '‘': '’'};
  for (final rune in raw.runes) {
    final char = String.fromCharCode(rune);
    if (closing != null) {
      buffer.write(char);
      if (char == closing) closing = null;
    } else if (quotes.containsKey(char)) {
      closing = quotes[char];
      buffer.write(char);
    } else if (RegExp(r'[,，;；。.!！?？\n\r]').hasMatch(char)) {
      if (buffer.toString().trim().isNotEmpty) {
        result.add(buffer.toString().trim());
      }
      buffer = StringBuffer();
    } else {
      buffer.write(char);
    }
  }
  if (buffer.toString().trim().isNotEmpty) result.add(buffer.toString().trim());
  return result;
}

String conversationContextKey(String text) => sha256
    .convert(
      utf8.encode(text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')),
    )
    .toString()
    .substring(0, 24);

String? normalizeConversationAddress(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  const quotes = {'"': '"', "'": "'", '“': '”', '‘': '’', '「': '」', '『': '』'};
  final closing = value.isEmpty ? null : quotes[value[0]];
  if (closing != null && value.endsWith(closing) && value.length >= 2) {
    value = value.substring(1, value.length - 1).trim();
  }
  if (value.isEmpty ||
      value.runes.length > 32 ||
      !RegExp(
        r'^[\u4e00-\u9fffA-Za-z][\u4e00-\u9fffA-Za-z0-9 _-]*$',
      ).hasMatch(value) ||
      RegExp(
        r'(?:不是|不要|别叫|不能|不可以|的时候|的话|的人|只是|而是|会怎样|会怎么样|怎么|如何|为什么|是否|让我|让你|告诉|他说|她说|朋友说|[吗么]$|\b(?:not|don\x27t|never|said|says|should|would|could|means|instead)\b)',
        caseSensitive: false,
      ).hasMatch(value)) {
    return null;
  }
  return value;
}

bool _literal(String? text, int max) =>
    text != null &&
    text.trim() == text &&
    text.runes.length >= 2 &&
    text.runes.length <= max &&
    !RegExp(r'[\x00-\x1f<>\u2028\u2029]').hasMatch(text);
bool _identifier(String? text) =>
    text != null && RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$').hasMatch(text);
bool _exactKeys(Map<String, Object?> value, Set<String> keys) =>
    value.length == keys.length && value.keys.every(keys.contains);
T? _enumOrNull<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
