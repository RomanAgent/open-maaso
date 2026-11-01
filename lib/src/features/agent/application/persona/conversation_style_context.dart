import 'dart:convert';

import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';

/// Host-owned style context for one response. Address values are bounded data,
/// never prompt instructions. No field grants permission for greater intimacy.
final class ConversationStyleSnapshot {
  ConversationStyleSnapshot({
    required this.isPrivate,
    RelationshipStage? relationshipStage,
    bool noTeasing = false,
    bool noUnsolicitedAdvice = false,
    bool serious = false,
    Iterable<String> forbiddenAddresses = const [],
    RelationshipExpressionStage? expressionStage,
    String? preferredAddress,
    Map<String, BanterDisposition> banterBoundaries = const {},
    Iterable<ConversationFact> sharedContexts = const [],
    bool repairRequired = false,
    bool neutralAddressOnly = false,
    int policyVersion = 0,
    this.deliveryGuard,
    this.validUntil,
    String? contactGuidance,
  }) : relationshipStage = isPrivate
           ? relationshipStage ?? RelationshipStage.stranger
           : null,
       noTeasing = isPrivate && noTeasing,
       noUnsolicitedAdvice = isPrivate && noUnsolicitedAdvice,
       serious = isPrivate && serious,
       expressionStage = isPrivate
           ? expressionStage ?? RelationshipExpressionStage.newlyMet
           : RelationshipExpressionStage.newlyMet,
       preferredAddress =
           isPrivate &&
               !neutralAddressOnly &&
               forbiddenAddresses.length <=
                   ConversationStyleSession.maxForbiddenAddresses &&
               !forbiddenAddresses
                   .map(_boundedAddress)
                   .contains(_boundedAddress(preferredAddress))
           ? _boundedAddress(preferredAddress)
           : null,
       banterBoundaries = Map.unmodifiable(
         isPrivate ? banterBoundaries : <String, BanterDisposition>{},
       ),
       sharedContexts = List.unmodifiable(
         isPrivate ? sharedContexts.take(3) : <ConversationFact>[],
       ),
       repairRequired = isPrivate && repairRequired,
       neutralAddressOnly =
           isPrivate &&
           (neutralAddressOnly ||
               forbiddenAddresses.length >
                   ConversationStyleSession.maxForbiddenAddresses),
       policyVersion = isPrivate ? policyVersion : 0,
       contactGuidance = isPrivate ? contactGuidance : null,
       forbiddenAddresses = List<String>.unmodifiable(
         isPrivate
             ? forbiddenAddresses
                   .map(_boundedAddress)
                   .whereType<String>()
                   .toSet()
                   .take(ConversationStyleSession.maxForbiddenAddresses)
             : const <String>[],
       );

  final bool isPrivate;
  final RelationshipStage? relationshipStage;
  final bool noTeasing;
  final bool noUnsolicitedAdvice;
  final bool serious;
  final List<String> forbiddenAddresses;
  final RelationshipExpressionStage expressionStage;
  final String? preferredAddress;
  final Map<String, BanterDisposition> banterBoundaries;
  final List<ConversationFact> sharedContexts;
  final bool repairRequired;
  final bool neutralAddressOnly;
  final int policyVersion;

  /// Host-only validity check, excluded from model-visible prompt data.
  final bool Function()? deliveryGuard;
  final DateTime? validUntil;

  /// Constant host outcome from a verified contact agreement operation.
  final String? contactGuidance;
  bool get isCurrent =>
      (validUntil == null || DateTime.now().isBefore(validUntil!)) &&
      (deliveryGuard?.call() ?? true);
}

/// One original human message and its separately verified source identity.
final class ConversationStyleInput {
  const ConversationStyleInput(this.text, {this.sourceId});
  final String text;
  final String? sourceId;
}

/// Immediate, in-memory restrictions for a single private runtime session.
///
/// The caller supplies [currentUserText] only for an authenticated human turn;
/// public, tool, background and synthetic text must never be passed as user
/// evidence. This class performs no persistence and does not authorize memory
/// writes. Recreate or [clear] it at the runtime/account/session boundary.
final class ConversationStyleSession {
  static const int maxForbiddenAddresses = 16;

  final Map<_StyleRestriction, _RestrictionLease> _restrictions = {};
  final Map<String, _RestrictionLease> _addresses = {};
  DateTime? _teasingRelaxedUntil;
  final Map<_StyleRestriction, _RestrictionLease> _released = {};
  final Map<String, _FactOverride> _factOverrides = {};
  ConversationPreferenceSnapshot? _previousExplicitPreferences;

  ConversationStyleSnapshot snapshot({
    required bool isPrivate,
    RelationshipStage? relationshipStage,
    String? currentUserText,
    DateTime? now,
    ConversationPolicy? persistentPolicy,
    String? currentSourceId,
    List<ConversationStyleInput>? currentUserInputs,
    ConversationPreferenceSnapshot? explicitPreferences,
    String? contactGuidance,
    bool Function()? deliveryGuard,
  }) {
    // Even expiry cleanup is skipped: public turns neither read nor mutate
    // the owner's private conversational preferences.
    if (!isPrivate) return ConversationStyleSnapshot(isPrivate: false);
    final previous = _previousExplicitPreferences;
    if (previous != null &&
        explicitPreferences != null &&
        previous.revision != explicitPreferences.revision) {
      if (previous.preferredAddress != explicitPreferences.preferredAddress ||
          explicitPreferences.forbiddenAddresses.contains(
            _factOverrides['address.preferred']?.draft.address,
          )) {
        _factOverrides.remove('address.preferred');
      }
      if (previous.humorStyle != explicitPreferences.humorStyle ||
          previous.noTeasing != explicitPreferences.noTeasing ||
          previous.humorStyleExplicit !=
              explicitPreferences.humorStyleExplicit) {
        _released.remove(_StyleRestriction.teasing);
        _teasingRelaxedUntil = null;
        _factOverrides.removeWhere(
          (_, value) =>
              value.draft.kind == ConversationFactKind.banterBoundary &&
              value.draft.disposition == BanterDisposition.accepted,
        );
      }
      for (final topic in conversationBanterTopics) {
        if (previous.banterBoundaries[topic] !=
            explicitPreferences.banterBoundaries[topic]) {
          _factOverrides.remove('banter.$topic');
        }
      }
    }
    _previousExplicitPreferences = explicitPreferences;
    final clock = now ?? DateTime.now();
    void expire<T>(Map<T, _RestrictionLease> leases) {
      for (final entry in leases.entries.toList()) {
        final remaining = entry.value.activeAt(clock);
        if (remaining == null) {
          leases.remove(entry.key);
        } else {
          leases[entry.key] = remaining;
        }
      }
    }

    expire(_restrictions);
    expire(_addresses);
    expire(_released);
    for (final entry in _factOverrides.entries.toList()) {
      final remaining = entry.value.lease.activeAt(clock);
      if (remaining == null) {
        _factOverrides.remove(entry.key);
      } else {
        _factOverrides[entry.key] = _FactOverride(entry.value.draft, remaining);
      }
    }
    if (_teasingRelaxedUntil != null &&
        !clock.isBefore(_teasingRelaxedUntil!)) {
      _teasingRelaxedUntil = null;
    }
    final turnOverrides = <_StyleRestriction, bool>{};
    final turnAddresses = <String>{};

    final turnFacts = <String, _FactOverride>{};
    final inputs =
        currentUserInputs ??
        [
          if (currentUserText != null)
            ConversationStyleInput(currentUserText, sourceId: currentSourceId),
        ];
    for (final input in inputs) {
      final currentUserText = input.text;
      final currentSourceId = input.sourceId;
      for (final command in _directStyleCommands(currentUserText)) {
        final restriction = command.restriction;
        final address = command.address;
        if (restriction != null) {
          if (command.scope == _BoundaryScope.turn) {
            turnOverrides[restriction] = command.restricted;
          } else if (!command.restricted) {
            // Release is deliberately limited to teasing. It does not grant
            // topic permissions or release seriousness, advice or addresses.
            if (command.scope == _BoundaryScope.today) {
              _teasingRelaxedUntil = _calendarDayEnd(clock);
            } else {
              _teasingRelaxedUntil = null;
            }
            _released[restriction] = _RestrictionLease(
              _scopeUntil(command.scope, clock),
              sourceId: currentSourceId,
            );
            turnOverrides[restriction] = false;
          } else {
            _released.remove(restriction);
            if (restriction == _StyleRestriction.teasing) {
              _teasingRelaxedUntil = null;
            }
            _remember(
              _restrictions,
              restriction,
              command.scope,
              clock,
              sourceId: currentSourceId,
            );
            turnOverrides.remove(restriction);
          }
        } else if (address != null) {
          if (command.scope == _BoundaryScope.turn) {
            if (!turnAddresses.contains(address) &&
                turnAddresses.length == maxForbiddenAddresses) {
              turnAddresses.remove(turnAddresses.first);
            }
            turnAddresses.add(address);
          } else {
            if (!_addresses.containsKey(address) &&
                _addresses.length == maxForbiddenAddresses) {
              _addresses.remove(_addresses.keys.first);
            }
            _remember(
              _addresses,
              address,
              command.scope,
              clock,
              sourceId: currentSourceId,
            );
          }
          if (turnFacts['address.preferred']?.draft.address == address) {
            turnFacts.remove('address.preferred');
          }
          final chosen = _factOverrides['address.preferred'];
          if (chosen?.draft.address == address) {
            _factOverrides.remove('address.preferred');
          }
        }
      }

      final admittedFacts = parseConversationPreferences(
        currentUserText,
      ).map((draft) => jsonEncode(draft.toJson())).toSet();
      final clauses = _directClauses(currentUserText);
      for (var index = 0; index < clauses.length; index++) {
        final clause = clauses[index];
        final scope = _directFactScope(clause);
        for (final draft in parseConversationPreferences(clause)) {
          if (!admittedFacts.contains(jsonEncode(draft.toJson()))) continue;
          if (draft.kind == ConversationFactKind.restriction ||
              draft.kind == ConversationFactKind.forbiddenAddress) {
            continue;
          }
          final value = _FactOverride(
            draft,
            _RestrictionLease(
              _scopeUntil(scope, clock),
              sourceId: currentSourceId,
            ),
          );
          if (draft.kind == ConversationFactKind.preferredAddress) {
            final laterBan = clauses
                .skip(index + 1)
                .any((later) => _styleCommand(later)?.address == draft.address);
            if (laterBan) continue;
          }
          if (scope == _BoundaryScope.turn) {
            turnFacts[draft.slotKey] = value;
          } else {
            final previous = _factOverrides[draft.slotKey];
            _factOverrides[draft.slotKey] =
                previous != null &&
                    jsonEncode(previous.draft.toJson()) ==
                        jsonEncode(draft.toJson())
                ? _FactOverride(draft, previous.lease.merged(value.lease))
                : value;
          }
        }
      }
    }
    final overrides = {..._factOverrides, ...turnFacts};
    final chosenAddress = overrides['address.preferred']?.draft.address;
    final addresses = <String>{
      ...turnAddresses,
      ..._addresses.keys,
      ...?persistentPolicy?.forbiddenAddresses,
      ...?explicitPreferences?.forbiddenAddresses,
    };
    if (chosenAddress != null) addresses.remove(chosenAddress);
    final banter = <String, BanterDisposition>{
      for (final entry
          in persistentPolicy?.banterBoundaries.entries ??
              const <MapEntry<String, BanterDisposition>>[])
        if (!(explicitPreferences?.humorStyleExplicit == true &&
            explicitPreferences?.humorStyle !=
                ConversationHumorStyle.lightBanter &&
            entry.value == BanterDisposition.accepted))
          entry.key: entry.value,
      ...?explicitPreferences?.banterBoundaries,
    };
    for (final override in overrides.values) {
      if (override.draft.kind == ConversationFactKind.banterBoundary) {
        banter[override.draft.topicKey!] = override.draft.disposition!;
      }
    }
    final repairs = <String, ConversationRepairStatus>{
      for (final fact in persistentPolicy?.repairs ?? <ConversationFact>[])
        fact.draft.targetSlot!: fact.draft.repairStatus!,
      for (final override in overrides.values)
        if (override.draft.kind == ConversationFactKind.repair)
          override.draft.targetSlot!: override.draft.repairStatus!,
    };

    bool active(_StyleRestriction kind) =>
        turnOverrides[kind] ??
        (kind == _StyleRestriction.teasing && _teasingRelaxedUntil != null
            ? false
            : _released.containsKey(kind)
            ? false
            : (kind == _StyleRestriction.teasing &&
                      explicitPreferences?.noTeasing == true) ||
                  _restrictions.containsKey(kind) ||
                  (persistentPolicy?.restricted(switch (kind) {
                        _StyleRestriction.teasing =>
                          ConversationRestriction.noTeasing,
                        _StyleRestriction.advice =>
                          ConversationRestriction.noUnsolicitedAdvice,
                        _StyleRestriction.serious =>
                          ConversationRestriction.serious,
                      }) ??
                      false));
    final expiries = <DateTime?>[
      _teasingRelaxedUntil,
      for (final lease in _released.values) lease.until,
      for (final fact in _factOverrides.values) fact.lease.until,
    ].whereType<DateTime>().toList()..sort();
    return ConversationStyleSnapshot(
      isPrivate: true,
      relationshipStage: relationshipStage,
      noTeasing: active(_StyleRestriction.teasing),
      noUnsolicitedAdvice: active(_StyleRestriction.advice),
      serious: active(_StyleRestriction.serious),
      forbiddenAddresses: addresses,
      preferredAddress:
          chosenAddress ??
          explicitPreferences?.preferredAddress ??
          persistentPolicy?.preferredAddress,
      expressionStage: persistentPolicy?.expressionStage,
      banterBoundaries: banter,
      sharedContexts: persistentPolicy?.sharedContexts ?? const [],
      repairRequired: repairs.values.any(
        (status) => status != ConversationRepairStatus.resolved,
      ),
      policyVersion: persistentPolicy?.policyVersion ?? 0,
      deliveryGuard: deliveryGuard,
      validUntil: expiries.isEmpty ? null : expiries.first,
      contactGuidance: contactGuidance,
    );
  }

  void clear() {
    _previousExplicitPreferences = null;
    _restrictions.clear();
    _addresses.clear();
    _teasingRelaxedUntil = null;
    _released.clear();
    _factOverrides.clear();
  }

  /// Source revocation removes only that source's transient overlays. It never
  /// copies durable facts into session state or revives a deleted projection.
  void invalidateSources(Set<String> sourceIds) {
    void prune<T>(Map<T, _RestrictionLease> leases) {
      for (final entry in leases.entries.toList()) {
        final remaining = entry.value.withoutSources(sourceIds);
        if (remaining == null) {
          leases.remove(entry.key);
        } else {
          leases[entry.key] = remaining;
        }
      }
    }

    prune(_restrictions);
    prune(_addresses);
    prune(_released);
    for (final entry in _factOverrides.entries.toList()) {
      final remaining = entry.value.lease.withoutSources(sourceIds);
      if (remaining == null) {
        _factOverrides.remove(entry.key);
      } else {
        _factOverrides[entry.key] = _FactOverride(entry.value.draft, remaining);
      }
    }
    if (!_released.containsKey(_StyleRestriction.teasing)) {
      _teasingRelaxedUntil = null;
    }
  }

  /// Deleting one governed fact revokes only its matching source contribution.
  /// Other preferences expressed in that same human message remain effective.
  void invalidateFacts(Map<String, Set<String>> invalidatedFactSources) {
    void prune<T>(Map<T, _RestrictionLease> values, T key, String slot) {
      final revoked = invalidatedFactSources[slot];
      final existing = values[key];
      if (revoked == null || existing == null) return;
      final remaining = existing.withoutSources(revoked);
      if (remaining == null) {
        values.remove(key);
      } else {
        values[key] = remaining;
      }
    }

    for (final kind in _StyleRestriction.values) {
      final domain = switch (kind) {
        _StyleRestriction.teasing => ConversationRestriction.noTeasing,
        _StyleRestriction.advice => ConversationRestriction.noUnsolicitedAdvice,
        _StyleRestriction.serious => ConversationRestriction.serious,
      };
      final slot = ConversationFactDraft.restriction(
        restriction: domain,
        restricted: true,
      ).slotKey;
      prune(_restrictions, kind, slot);
      prune(_released, kind, slot);
    }
    for (final address in _addresses.keys.toList()) {
      prune(
        _addresses,
        address,
        ConversationFactDraft.forbiddenAddress(address).slotKey,
      );
    }
    for (final entry in _factOverrides.entries.toList()) {
      final revoked = invalidatedFactSources[entry.key];
      if (revoked == null) continue;
      final remaining = entry.value.lease.withoutSources(revoked);
      if (remaining == null) {
        _factOverrides.remove(entry.key);
      } else {
        _factOverrides[entry.key] = _FactOverride(entry.value.draft, remaining);
      }
    }
    if (!_released.containsKey(_StyleRestriction.teasing)) {
      _teasingRelaxedUntil = null;
    }
  }

  void _remember<T>(
    Map<T, _RestrictionLease> target,
    T key,
    _BoundaryScope scope,
    DateTime now, {
    String? sourceId,
  }) {
    final next = _RestrictionLease(
      scope == _BoundaryScope.today ? _calendarDayEnd(now) : null,
      sourceId: sourceId,
    );
    // Preserve each independent source and its own expiry. Deleting an older
    // request cannot erase a newer reiteration or lengthen its narrower scope.
    target[key] = target[key]?.merged(next) ?? next;
  }
}

DateTime _calendarDayEnd(DateTime now) => now.isUtc
    ? DateTime.utc(now.year, now.month, now.day + 1)
    : DateTime(now.year, now.month, now.day + 1);

enum _StyleRestriction { teasing, advice, serious }

enum _BoundaryScope { turn, today, session }

final class _RestrictionLease {
  _RestrictionLease(DateTime? until, {String? sourceId})
    : _sources = {sourceId: until};
  _RestrictionLease._(Map<String?, DateTime?> sources)
    : _sources = Map.unmodifiable(sources);
  final Map<String?, DateTime?> _sources;

  DateTime? get until {
    if (_sources.values.any((value) => value == null)) return null;
    return _sources.values.cast<DateTime>().reduce(
      (a, b) => a.isAfter(b) ? a : b,
    );
  }

  _RestrictionLease merged(_RestrictionLease other) {
    final combined = {..._sources};
    for (final entry in other._sources.entries) {
      final previous = combined[entry.key];
      if (!combined.containsKey(entry.key) ||
          (previous != null &&
              (entry.value == null || entry.value!.isAfter(previous)))) {
        combined[entry.key] = entry.value;
      }
    }
    return _RestrictionLease._(combined);
  }

  _RestrictionLease? withoutSources(Set<String> revoked) {
    final remaining = {..._sources}
      ..removeWhere((source, _) => source != null && revoked.contains(source));
    return remaining.isEmpty ? null : _RestrictionLease._(remaining);
  }

  bool expiredAt(DateTime now) => until != null && !now.isBefore(until!);

  _RestrictionLease? activeAt(DateTime now) {
    final active = {..._sources}
      ..removeWhere((_, until) => until != null && !now.isBefore(until));
    return active.isEmpty ? null : _RestrictionLease._(active);
  }
}

final class _FactOverride {
  const _FactOverride(this.draft, this.lease);
  final ConversationFactDraft draft;
  final _RestrictionLease lease;
}

DateTime? _scopeUntil(_BoundaryScope scope, DateTime now) =>
    scope == _BoundaryScope.today ? _calendarDayEnd(now) : null;

_BoundaryScope _directFactScope(String text) {
  if (RegExp(
    r'^(?:今天|今日|(?:for )?today)\s*|\s+today$',
    caseSensitive: false,
  ).hasMatch(text.trim())) {
    return _BoundaryScope.today;
  }
  if (RegExp(
    r'^(?:这轮|这一轮|这次回答|这次|(?:for )?this (?:turn|reply|response))\s*|\s+this (?:turn|reply|response)$',
    caseSensitive: false,
  ).hasMatch(text.trim())) {
    return _BoundaryScope.turn;
  }
  return _BoundaryScope.session;
}

final class _StyleCommand {
  const _StyleCommand({
    this.restriction,
    this.address,
    this.restricted = true,
    this.scope = _BoundaryScope.session,
  });

  final _StyleRestriction? restriction;
  final String? address;
  final bool restricted;
  final _BoundaryScope scope;
}

Iterable<_StyleCommand> _directStyleCommands(String text) sync* {
  if (_isLanguageExample(text)) return;
  final clauses = _directClauses(text);
  for (final clause in clauses) {
    final command = _styleCommand(clause);
    // Do not reinterpret later clauses of a quotation, explanation or story
    // as commands. Only greetings and direct self-introductions may precede
    // the first style command.
    if (command == null) {
      if (_isGreetingOrCourtesy(clause) ||
          _preferredNameFromClause(clause) != null ||
          parseConversationPreferences(clause).isNotEmpty) {
        continue;
      }
      break;
    }
    yield command;
  }
}

_StyleCommand? _styleCommand(String raw) {
  var clause = raw.trim().replaceAll('’', "'").replaceAll(RegExp(r'\s+'), ' ');
  var scope = _BoundaryScope.session;
  final turnPrefix = RegExp(
    r'^(?:这(?:一轮|轮|次回复|个回复|次回答|次)|(?:for )?this (?:reply|response|turn))\s*',
    caseSensitive: false,
  );
  final todayPrefix = RegExp(
    r'^(?:今天|今日|(?:for )?today)\s*',
    caseSensitive: false,
  );
  clause = _stripCourtesy(clause);
  if (turnPrefix.hasMatch(clause)) {
    scope = _BoundaryScope.turn;
    clause = clause.replaceFirst(turnPrefix, '');
  } else if (todayPrefix.hasMatch(clause)) {
    scope = _BoundaryScope.today;
    clause = clause.replaceFirst(todayPrefix, '');
  }
  final suffix = RegExp(
    r'\s+(?:(?:for )?(today|this reply|this response|this turn))$',
    caseSensitive: false,
  );
  final suffixMatch = suffix.firstMatch(clause);
  if (suffixMatch != null) {
    scope = suffixMatch.group(1)!.toLowerCase() == 'today'
        ? _BoundaryScope.today
        : _BoundaryScope.turn;
    clause = clause.substring(0, suffixMatch.start).trim();
  }
  clause = _stripCourtesy(clause);

  if (RegExp(
    r'^(?:(?:先|现在|以后|之后)?(?:请)?(?:不要|别|别再|不要再)(?:再)?(?:跟我|和我|对我)?(?:开玩笑|调侃我?|拿我开玩笑|贫了|贫嘴|损我|讲梗|玩梗)(?:了|吧)?|(?:please )?(?:no (?:jokes|teasing)|(?:do not|don\x27t|stop) (?:joke|joking|(?:tease|teasing)(?: me)?|(?:make|making) jokes)))$',
    caseSensitive: false,
  ).hasMatch(clause)) {
    return _StyleCommand(restriction: _StyleRestriction.teasing, scope: scope);
  }
  if (RegExp(
    r'^(?:(?:现在)?(?:可以|能)开玩笑了|(?:you can|it\x27s (?:okay|ok) to) (?:joke|make jokes)(?: again| now)?|jokes are (?:okay|ok)(?: again| now)?)$',
    caseSensitive: false,
  ).hasMatch(clause)) {
    return _StyleCommand(
      restriction: _StyleRestriction.teasing,
      restricted: false,
      scope: scope,
    );
  }
  if (RegExp(
    r'^(?:(?:先|现在|以后|之后)?(?:不要|别)(?:再)?(?:主动)?(?:给我?|提供)?(?:建议|出主意)(?:了|吧)?|(?:我)?(?:现在|暂时)?不想听建议|(?:我)?(?:现在|先)?只想吐槽|(?:please )?(?:no (?:unsolicited )?advice|(?:do not|don\x27t|stop) (?:give|giving|offer|offering)(?: me)? (?:unsolicited )?advice|just listen|i (?:do not|don\x27t) (?:want|need) advice(?: right now)?))$',
    caseSensitive: false,
  ).hasMatch(clause)) {
    return _StyleCommand(restriction: _StyleRestriction.advice, scope: scope);
  }
  if (RegExp(
    r'^(?:(?:先|现在|请)?(?:认真点|认真一点|认真回答|严肃一点|严肃点)|(?:please )?(?:be serious|take this seriously|answer seriously))$',
    caseSensitive: false,
  ).hasMatch(clause)) {
    return _StyleCommand(restriction: _StyleRestriction.serious, scope: scope);
  }
  final address = RegExp(
    r'^(?:(?:先|现在|以后|之后)?(?:不要|别)(?:再)?叫我\s*|(?:please )?(?:do not|don\x27t|stop) (?:call|calling) me\s+)(.+)$',
    caseSensitive: false,
  ).firstMatch(clause);
  final value = _boundedAddress(
    address?.group(1)?.replaceFirst(RegExp(r'(?:了|吧)$'), ''),
  );
  if (value != null) return _StyleCommand(address: value, scope: scope);
  return null;
}

/// Only direct, affirmative self-introductions or address requests qualify.
/// Existing profile capture remains responsible for governed persistence.
String? extractDirectPreferredName(String text) {
  if (_isLanguageExample(text)) return null;
  for (final rawClause in _directClauses(text)) {
    if (_isGreetingOrCourtesy(rawClause)) continue;
    final name = _preferredNameFromClause(rawClause);
    if (name != null) return name;
    if (_styleCommand(rawClause) == null) return null;
  }
  return null;
}

String? _preferredNameFromClause(String rawClause) {
  final clause = _stripCourtesy(rawClause.trim());
  final match = RegExp(
    r'^(?:(?:我叫|我的名字(?:是|叫)?|(?:以后|之后)?(?:你可以)?叫我)\s*|(?:my name is|(?:you can )?call me)\s+)(.+)$',
    caseSensitive: false,
  ).firstMatch(clause);
  if (match == null) return null;
  final candidate = match
      .group(1)!
      .replaceFirst(
        RegExp(r'\s+(?:and|but|because)\s+.*$', caseSensitive: false),
        '',
      )
      .replaceFirst(RegExp(r'吧$'), '')
      .trim();
  return _boundedAddress(candidate);
}

String _stripCourtesy(String text) => text
    .replaceFirst(RegExp(r'^(?:请|麻烦你|麻烦|拜托)\s*'), '')
    .replaceFirst(RegExp(r'^please\s+', caseSensitive: false), '')
    .replaceFirst(RegExp(r'\s+please$', caseSensitive: false), '')
    .replaceFirst(RegExp(r'(?:好吗|好么|行吗|行么|可以吗)$'), '')
    .trim();

bool _isGreetingOrCourtesy(String text) => RegExp(
  r'^(?:你好|嗨|您好|谢谢|谢谢你|好|hi|hey|hello|please|thanks|thank you)$',
  caseSensitive: false,
).hasMatch(text.trim());

bool _isLanguageExample(String text) => RegExp(
  r'(?:这(?:句|段|句话|个表达)|是什么意思|什么意思|怎么翻译|如何翻译|翻译成|用(?:中文|英文|英语|汉语)怎么说|(?:我|他|她|别人|朋友)说的|举个?例子|只是举例|不是对你的要求|\b(?:translate|translation|what does|what do you mean|phrase|sentence|quotation|quoted|in (?:english|chinese|french|spanish))\b)',
  caseSensitive: false,
).hasMatch(text);

String? _boundedAddress(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  const quotes = {'"': '"', "'": "'", '“': '”', '‘': '’', '「': '」', '『': '』'};
  final close = value.isEmpty ? null : quotes[value[0]];
  if (close != null && value.endsWith(close) && value.length >= 2) {
    value = value.substring(1, value.length - 1).trim();
  }
  if (value.isEmpty || value.runes.length > 32) return null;
  if (!RegExp(
    r'^[\u4e00-\u9fffA-Za-z][\u4e00-\u9fffA-Za-z0-9 _-]*$',
  ).hasMatch(value)) {
    return null;
  }
  if (RegExp(
    r'(?:不是|不要|别叫|不能|不可以|的时候|的话|的人|只是|而是|会怎样|会怎么样|怎么|如何|为什么|是否|让我|让你|告诉|他说|她说|朋友说|[吗么]$|\b(?:not|don\x27t|never|said|says|should|would|could|means|instead)\b)',
    caseSensitive: false,
  ).hasMatch(value)) {
    return null;
  }
  return value;
}

/// Splits only outside quotes. A quoted nickname can contain punctuation,
/// while an entire quoted instruction keeps its opening quote and cannot match.
List<String> _directClauses(String text) {
  final clauses = <String>[];
  var buffer = StringBuffer();
  String? closingQuote;
  const quotes = {'"': '"', '“': '”', '‘': '’', '「': '」', '『': '』'};
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (closingQuote != null) {
      buffer.write(char);
      if (char == closingQuote) closingQuote = null;
      continue;
    }
    final quoteEnd = quotes[char];
    if (quoteEnd != null) {
      closingQuote = quoteEnd;
      buffer.write(char);
    } else if (RegExp(r'[,，;；。.!！?？\n\r]').hasMatch(char)) {
      final clause = buffer.toString().trim();
      if (clause.isNotEmpty) clauses.add(clause);
      buffer = StringBuffer();
    } else {
      buffer.write(char);
    }
  }
  final last = buffer.toString().trim();
  if (last.isNotEmpty) clauses.add(last);
  return clauses;
}
