import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// Topics that can be considered by the foreground proactive-companion loop.
///
/// Relationship facts are deliberately represented by event-shaped topics.
/// Rolling counters such as `daysKnown` and `streak` are not inputs to this
/// policy, so they cannot accidentally become a recurring fallback topic.
enum ProactiveTopicKind {
  quietPresence,
  timeOfDay,
  recentAffect,
  relationshipMilestone,
  relationshipStage,
  anniversary,
  environmentObservation,
}

enum ProactiveDecisionKind { reserve, accept, silence }

enum ProactiveSilenceReason {
  none,
  quietHours,
  dailyBudgetExhausted,
  globalGap,
  duplicateSourceEvent,
  duplicateEvidence,
  topicCooldown,
  unsupportedRelationshipCandidate,
  missingRelationshipEvidence,
  noFreshCandidate,
  emptyDraft,
  duplicateText,
  nearDuplicateText,
  waitingForReply,
  authorizationChanged,
  authorizationExpired,
  topicUnavailable,
}

/// All product tuning for proactive foreground speech lives here.
class ProactivePolicyConfig {
  const ProactivePolicyConfig({
    this.foregroundDailyLimit = 3,
    this.minimumGlobalGap = const Duration(minutes: 20),
    this.maximumDeterministicJitter = const Duration(minutes: 25),
    this.genericTopicCooldown = const Duration(hours: 24),
    this.fingerprintRetentionCount = 32,
    this.fingerprintRetention = const Duration(days: 30),
    this.nearDuplicateThreshold = 0.78,
    this.quietStartMinutes = 23 * 60,
    this.quietEndMinutes = 7 * 60,
    this.authorizationRevision,
    this.authorizationGeneration,
    this.authorizedUntil,
    this.lastUserReturnAt,
    this.agreementChangedAt,
  }) : assert(foregroundDailyLimit >= 0),
       assert(fingerprintRetentionCount >= 0),
       assert(nearDuplicateThreshold >= 0 && nearDuplicateThreshold <= 1),
       assert(quietStartMinutes >= 0 && quietStartMinutes < 24 * 60),
       assert(quietEndMinutes >= 0 && quietEndMinutes < 24 * 60);

  final int foregroundDailyLimit;
  final Duration minimumGlobalGap;
  final Duration maximumDeterministicJitter;
  final Duration genericTopicCooldown;
  final int fingerprintRetentionCount;
  final Duration fingerprintRetention;
  final double nearDuplicateThreshold;
  final int quietStartMinutes;
  final int quietEndMinutes;
  final int? authorizationRevision;
  final int? authorizationGeneration;
  final DateTime? authorizedUntil;
  final DateTime? lastUserReturnAt;
  final DateTime? agreementChangedAt;

  bool isQuietAt(DateTime value) {
    if (quietStartMinutes == quietEndMinutes) return false;
    final local = value.toLocal();
    final minute = local.hour * 60 + local.minute;
    if (quietStartMinutes < quietEndMinutes) {
      return minute >= quietStartMinutes && minute < quietEndMinutes;
    }
    return minute >= quietStartMinutes || minute < quietEndMinutes;
  }
}

/// A typed topic proposed by Presence or another trusted host source.
class ProactiveTopicCandidate {
  const ProactiveTopicCandidate({
    required this.kind,
    required this.topicKey,
    this.sourceEventId,
    this.evidenceKey,
    this.textSeed = '',
    this.priority = 0,
  });

  final ProactiveTopicKind kind;
  final String topicKey;
  final String? sourceEventId;
  final String? evidenceKey;
  final String textSeed;
  final int priority;

  bool get isRelationshipEvidence =>
      kind == ProactiveTopicKind.relationshipMilestone ||
      kind == ProactiveTopicKind.relationshipStage;
}

/// Privacy-safe historical input consumed by the pure policy.
///
/// Callers persist hashes and similarity features, never normalized or raw
/// proactive text. Exact source/evidence markers may be retained longer than
/// text fingerprints so one-shot events remain one-shot.
class ProactiveOutreachHistoryEntry {
  const ProactiveOutreachHistoryEntry({
    required this.topicKey,
    required this.occurredAt,
    required this.consumesSourceEvent,
    required this.consumesEvidence,
    this.sourceEventId,
    this.evidenceKey,
    this.normalizedTextHash,
    this.similarityFeatures = const <String>{},
    this.countsTowardForegroundBudget = true,
    this.countsTowardGlobalGap = true,
  });

  factory ProactiveOutreachHistoryEntry.fromText({
    required ProactiveCompanionPolicy policy,
    required String topicKey,
    required DateTime occurredAt,
    required String text,
    String? sourceEventId,
    String? evidenceKey,
    bool countsTowardForegroundBudget = true,
    bool countsTowardGlobalGap = true,
    bool consumesSourceEvent = true,
    bool consumesEvidence = true,
  }) {
    final signature = policy.signatureFor(text);
    return ProactiveOutreachHistoryEntry(
      topicKey: topicKey,
      occurredAt: occurredAt,
      consumesSourceEvent: consumesSourceEvent,
      consumesEvidence: consumesEvidence,
      sourceEventId: sourceEventId,
      evidenceKey: evidenceKey,
      normalizedTextHash: signature.fingerprint,
      similarityFeatures: signature.similarityFeatures,
      countsTowardForegroundBudget: countsTowardForegroundBudget,
      countsTowardGlobalGap: countsTowardGlobalGap,
    );
  }

  final String topicKey;
  final DateTime occurredAt;
  final bool consumesSourceEvent;
  final bool consumesEvidence;
  final String? sourceEventId;
  final String? evidenceKey;
  final String? normalizedTextHash;
  final Set<String> similarityFeatures;
  final bool countsTowardForegroundBudget;
  final bool countsTowardGlobalGap;
}

class ProactiveTextSignature {
  const ProactiveTextSignature({
    required this.normalizedText,
    required this.fingerprint,
    required this.similarityFeatures,
  });

  /// Ephemeral canonical text. Persist [fingerprint] and
  /// [similarityFeatures], not this value.
  final String normalizedText;
  final String fingerprint;
  final Set<String> similarityFeatures;
}

class ProactiveNoveltyDecision {
  const ProactiveNoveltyDecision._({
    required this.kind,
    required this.reason,
    this.candidate,
    this.nextEligibleAt,
    this.textSignature,
    this.similarityScore,
  });

  factory ProactiveNoveltyDecision.reserve(ProactiveTopicCandidate candidate) =>
      ProactiveNoveltyDecision._(
        kind: ProactiveDecisionKind.reserve,
        reason: ProactiveSilenceReason.none,
        candidate: candidate,
      );

  factory ProactiveNoveltyDecision.accept({
    required ProactiveTopicCandidate candidate,
    required ProactiveTextSignature signature,
  }) => ProactiveNoveltyDecision._(
    kind: ProactiveDecisionKind.accept,
    reason: ProactiveSilenceReason.none,
    candidate: candidate,
    textSignature: signature,
  );

  factory ProactiveNoveltyDecision.silence(
    ProactiveSilenceReason reason, {
    ProactiveTopicCandidate? candidate,
    DateTime? nextEligibleAt,
    ProactiveTextSignature? textSignature,
    double? similarityScore,
  }) => ProactiveNoveltyDecision._(
    kind: ProactiveDecisionKind.silence,
    reason: reason,
    candidate: candidate,
    nextEligibleAt: nextEligibleAt,
    textSignature: textSignature,
    similarityScore: similarityScore,
  );

  final ProactiveDecisionKind kind;
  final ProactiveSilenceReason reason;
  final ProactiveTopicCandidate? candidate;
  final DateTime? nextEligibleAt;
  final ProactiveTextSignature? textSignature;
  final double? similarityScore;

  bool get shouldReserve => kind == ProactiveDecisionKind.reserve;
  bool get isAccepted => kind == ProactiveDecisionKind.accept;
  bool get shouldStaySilent => kind == ProactiveDecisionKind.silence;
}

/// Deterministic selection and novelty policy for proactive companion speech.
///
/// This class is intentionally synchronous and contains no model, embedding,
/// persistence, clock, random or network dependency.
class ProactiveCompanionPolicy {
  const ProactiveCompanionPolicy({this.config = const ProactivePolicyConfig()});

  final ProactivePolicyConfig config;

  /// Runs one commit boundary against a stable policy configuration.
  ///
  /// Static policies execute immediately. Account-backed adapters override
  /// this to linearize a preference mutation either before or after the
  /// database transaction, never inside it.
  Future<T> runWithStableConfig<T>(
    Future<T> Function(ProactivePolicyConfig config) operation,
  ) => operation(config);

  /// Selects one fresh topic or explicitly returns a silence decision.
  ProactiveNoveltyDecision evaluate({
    required DateTime now,
    required Iterable<ProactiveTopicCandidate> candidates,
    Iterable<ProactiveOutreachHistoryEntry> history = const [],
    DateTime? lastUserActivityAt,
    required String deterministicJitterKey,
    bool respectQuietHours = true,
  }) {
    final jitterKey = deterministicJitterKey.trim();
    if (jitterKey.isEmpty) {
      throw ArgumentError.value(
        deterministicJitterKey,
        'deterministicJitterKey',
        'must contain a stable account/date key',
      );
    }
    final historyList = history.toList(growable: false);
    final rankedCandidates = candidates.toList(growable: false)
      ..sort((a, b) {
        final priority = b.priority.compareTo(a.priority);
        if (priority != 0) return priority;
        final topic = a.topicKey.compareTo(b.topicKey);
        if (topic != 0) return topic;
        final kind = a.kind.index.compareTo(b.kind.index);
        if (kind != 0) return kind;
        final source = (a.sourceEventId ?? '').compareTo(b.sourceEventId ?? '');
        if (source != 0) return source;
        final evidence = (a.evidenceKey ?? '').compareTo(b.evidenceKey ?? '');
        if (evidence != 0) return evidence;
        return a.textSeed.compareTo(b.textSeed);
      });

    if (respectQuietHours && config.isQuietAt(now)) {
      return ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.quietHours,
      );
    }

    if (_foregroundCountOn(historyList, now) >= config.foregroundDailyLimit) {
      return ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.dailyBudgetExhausted,
      );
    }

    if (rankedCandidates.isEmpty) {
      return ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.noFreshCandidate,
      );
    }

    final latestTouch = _latestGlobalTouch(
      historyList,
      now: now,
      lastUserActivityAt: lastUserActivityAt,
    );
    if (latestTouch != null) {
      final nextEligibleAt = latestTouch.add(
        config.minimumGlobalGap + deterministicJitterFor(jitterKey),
      );
      if (now.isBefore(nextEligibleAt)) {
        return ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.globalGap,
          nextEligibleAt: nextEligibleAt,
        );
      }
    }

    ProactiveNoveltyDecision? firstSuppression;
    for (final candidate in rankedCandidates) {
      final suppression = _candidateSuppression(
        now: now,
        candidate: candidate,
        history: historyList,
      );
      if (suppression == null) {
        return ProactiveNoveltyDecision.reserve(candidate);
      }
      firstSuppression ??= ProactiveNoveltyDecision.silence(
        suppression,
        candidate: candidate,
      );
    }
    return firstSuppression ??
        ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.noFreshCandidate,
        );
  }

  /// Applies exact and near-duplicate gates to a fully buffered draft.
  ProactiveNoveltyDecision evaluateDraft({
    required DateTime now,
    required ProactiveTopicCandidate candidate,
    required String draft,
    Iterable<ProactiveOutreachHistoryEntry> history = const [],
  }) {
    final signature = signatureFor(draft);
    if (signature.normalizedText.isEmpty) {
      return ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.emptyDraft,
        candidate: candidate,
        textSignature: signature,
      );
    }

    final recentFingerprints = _retainedFingerprintHistory(now, history);
    for (final entry in recentFingerprints) {
      if (entry.normalizedTextHash == signature.fingerprint) {
        return ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.duplicateText,
          candidate: candidate,
          textSignature: signature,
          similarityScore: 1,
        );
      }
    }

    if (_hasFreshRelationshipEvidence(candidate, history)) {
      return ProactiveNoveltyDecision.accept(
        candidate: candidate,
        signature: signature,
      );
    }

    for (final entry in recentFingerprints) {
      if (entry.similarityFeatures.isEmpty) continue;
      final score = similarityScore(
        signature.similarityFeatures,
        entry.similarityFeatures,
      );
      if (score >= config.nearDuplicateThreshold) {
        return ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.nearDuplicateText,
          candidate: candidate,
          textSignature: signature,
          similarityScore: score,
        );
      }
    }

    return ProactiveNoveltyDecision.accept(
      candidate: candidate,
      signature: signature,
    );
  }

  /// A stable per-key jitter. No mutable RNG is involved, so retries and
  /// restarts calculate the same eligibility boundary.
  Duration deterministicJitterFor(String key) {
    final maximumMilliseconds =
        config.maximumDeterministicJitter.inMilliseconds;
    if (maximumMilliseconds <= 0) return Duration.zero;
    final bytes = sha256.convert(utf8.encode(key)).bytes;
    final seed =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    return Duration(milliseconds: seed % (maximumMilliseconds + 1));
  }

  ProactiveTextSignature signatureFor(String text) {
    final normalized = normalizeText(text);
    final canonical = _canonicalFingerprintText(normalized);
    return ProactiveTextSignature(
      normalizedText: normalized,
      fingerprint: sha256.convert(utf8.encode(canonical)).toString(),
      similarityFeatures: _similarityFeatures(normalized),
    );
  }

  /// Compatibility-folds common NFKC forms, lowercases, removes punctuation,
  /// and canonicalizes whitespace without requiring a platform normalizer.
  String normalizeText(String text) {
    final folded = _compatibilityFold(text).toLowerCase();
    final output = StringBuffer();
    var pendingSpace = false;
    for (final rune in folded.runes) {
      if (_isCombiningMark(rune)) continue;
      if (_isWordRune(rune)) {
        if (pendingSpace && output.isNotEmpty) output.write(' ');
        output.writeCharCode(rune);
        pendingSpace = false;
      } else {
        pendingSpace = output.isNotEmpty;
      }
    }
    return output.toString().trim();
  }

  /// Returns the strongest Dice/Jaccard overlap across language feature bands.
  double similarityScore(Set<String> left, Set<String> right) {
    if (left.isEmpty || right.isEmpty) return 0;
    final scores = <double>[];
    _addSimilarityScores(scores, left, right);
    for (final prefix in const <String>['c2:', 'c3:', 'e:']) {
      final a = left.where((item) => item.startsWith(prefix)).toSet();
      final b = right.where((item) => item.startsWith(prefix)).toSet();
      if (a.isEmpty || b.isEmpty) continue;
      _addSimilarityScores(scores, a, b);
    }
    final strongest = scores.reduce(math.max);

    // A changed number or Latin entity embedded in otherwise identical CJK is
    // semantically meaningful ("7 天" vs "30 天", Alice vs Bob). Never let a
    // CJK-only band erase that slot change and trip the near-duplicate gate.
    final leftHasCjk = left.any(_isCjkFeature);
    final rightHasCjk = right.any(_isCjkFeature);
    final leftSlots = left.where(_isLexicalSlotFeature).toSet();
    final rightSlots = right.where(_isLexicalSlotFeature).toSet();
    if (leftHasCjk &&
        rightHasCjk &&
        (leftSlots.isNotEmpty || rightSlots.isNotEmpty) &&
        !_sameSet(leftSlots, rightSlots)) {
      return math.min(
        strongest,
        math.max(0, config.nearDuplicateThreshold - 0.000001),
      );
    }
    return strongest;
  }

  ProactiveSilenceReason? _candidateSuppression({
    required DateTime now,
    required ProactiveTopicCandidate candidate,
    required List<ProactiveOutreachHistoryEntry> history,
  }) {
    final topicKey = candidate.topicKey.trim();
    if (topicKey.isEmpty) return ProactiveSilenceReason.noFreshCandidate;

    if (candidate.kind == ProactiveTopicKind.anniversary) {
      return ProactiveSilenceReason.unsupportedRelationshipCandidate;
    }
    if (candidate.isRelationshipEvidence && !_hasValue(candidate.evidenceKey)) {
      return ProactiveSilenceReason.missingRelationshipEvidence;
    }

    final sourceEventId = candidate.sourceEventId?.trim();
    if (_hasValue(sourceEventId) &&
        history.any(
          (entry) =>
              entry.consumesSourceEvent &&
              entry.sourceEventId?.trim() == sourceEventId,
        )) {
      return ProactiveSilenceReason.duplicateSourceEvent;
    }

    final evidenceKey = candidate.evidenceKey?.trim();
    if (_hasValue(evidenceKey) &&
        history.any(
          (entry) =>
              entry.consumesEvidence &&
              entry.evidenceKey?.trim() == evidenceKey,
        )) {
      return ProactiveSilenceReason.duplicateEvidence;
    }

    if (!candidate.isRelationshipEvidence) {
      final latestTopic = _latestWhere(
        history,
        (entry) =>
            !entry.occurredAt.isAfter(now) && entry.topicKey.trim() == topicKey,
      );
      if (latestTopic != null &&
          now.difference(latestTopic).compareTo(config.genericTopicCooldown) <
              0) {
        return ProactiveSilenceReason.topicCooldown;
      }
    }
    return null;
  }

  int _foregroundCountOn(
    Iterable<ProactiveOutreachHistoryEntry> history,
    DateTime now,
  ) {
    final localNow = now.toLocal();
    return history.where((entry) {
      if (!entry.countsTowardForegroundBudget) return false;
      final local = entry.occurredAt.toLocal();
      return local.year == localNow.year &&
          local.month == localNow.month &&
          local.day == localNow.day;
    }).length;
  }

  DateTime? _latestGlobalTouch(
    Iterable<ProactiveOutreachHistoryEntry> history, {
    required DateTime now,
    DateTime? lastUserActivityAt,
  }) {
    DateTime? latest =
        lastUserActivityAt != null && !lastUserActivityAt.isAfter(now)
        ? lastUserActivityAt
        : null;
    for (final entry in history) {
      if (!entry.countsTowardGlobalGap || entry.occurredAt.isAfter(now)) {
        continue;
      }
      if (latest == null || entry.occurredAt.isAfter(latest)) {
        latest = entry.occurredAt;
      }
    }
    return latest;
  }

  DateTime? _latestWhere(
    Iterable<ProactiveOutreachHistoryEntry> history,
    bool Function(ProactiveOutreachHistoryEntry entry) predicate,
  ) {
    DateTime? latest;
    for (final entry in history) {
      if (!predicate(entry)) continue;
      if (latest == null || entry.occurredAt.isAfter(latest)) {
        latest = entry.occurredAt;
      }
    }
    return latest;
  }

  List<ProactiveOutreachHistoryEntry> _retainedFingerprintHistory(
    DateTime now,
    Iterable<ProactiveOutreachHistoryEntry> history,
  ) {
    final cutoff = now.subtract(config.fingerprintRetention);
    final retained =
        history
            .where(
              (entry) =>
                  !entry.occurredAt.isBefore(cutoff) &&
                  (entry.normalizedTextHash != null ||
                      entry.similarityFeatures.isNotEmpty),
            )
            .toList()
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    if (retained.length <= config.fingerprintRetentionCount) return retained;
    return retained.take(config.fingerprintRetentionCount).toList();
  }

  bool _hasFreshRelationshipEvidence(
    ProactiveTopicCandidate candidate,
    Iterable<ProactiveOutreachHistoryEntry> history,
  ) {
    if (!candidate.isRelationshipEvidence) return false;
    final evidence = candidate.evidenceKey?.trim();
    if (!_hasValue(evidence)) return false;
    return !history.any(
      (entry) =>
          entry.consumesEvidence && entry.evidenceKey?.trim() == evidence,
    );
  }
}

bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

Set<String> _similarityFeatures(String normalized) {
  final features = <String>{};
  final cjk = normalized.runes.where(_isCjk).toList(growable: false);
  _addRuneGrams(features, cjk, 2, 'c2:');
  _addRuneGrams(features, cjk, 3, 'c3:');

  final englishTokens = _lexicalTokens(normalized);
  features.addAll(englishTokens.map((token) => 's:$token'));
  for (var size = 1; size <= math.min(3, englishTokens.length); size++) {
    for (var index = 0; index <= englishTokens.length - size; index++) {
      features.add('e:${englishTokens.sublist(index, index + size).join('_')}');
    }
  }
  return Set<String>.unmodifiable(features);
}

void _addRuneGrams(
  Set<String> output,
  List<int> runes,
  int size,
  String prefix,
) {
  if (runes.length < size) return;
  for (var index = 0; index <= runes.length - size; index++) {
    output.add(
      '$prefix${String.fromCharCodes(runes.sublist(index, index + size))}',
    );
  }
}

double _dice(Set<String> left, Set<String> right) {
  final intersection = left.intersection(right).length;
  return (2 * intersection) / (left.length + right.length);
}

double _jaccard(Set<String> left, Set<String> right) {
  final union = left.union(right).length;
  if (union == 0) return 0;
  return left.intersection(right).length / union;
}

double _containment(Set<String> left, Set<String> right) {
  final shorter = math.min(left.length, right.length);
  if (shorter < 4) return 0;
  return left.intersection(right).length / shorter;
}

void _addSimilarityScores(
  List<double> output,
  Set<String> left,
  Set<String> right,
) {
  output
    ..add(_jaccard(left, right))
    ..add(_dice(left, right));
  final containment = _containment(left, right);
  if (containment > 0) output.add(containment);
}

bool _isCjkFeature(String value) =>
    value.startsWith('c2:') || value.startsWith('c3:');

bool _isLexicalSlotFeature(String value) => value.startsWith('s:');

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

List<String> _lexicalTokens(String normalized) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    tokens.add(buffer.toString());
    buffer.clear();
  }

  for (final rune in normalized.runes) {
    if (_isAsciiWord(rune) || _isLatinLetter(rune)) {
      buffer.writeCharCode(rune);
    } else {
      flush();
    }
  }
  flush();
  return tokens;
}

String _canonicalFingerprintText(String normalized) {
  final tokens = normalized
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) return '';
  final output = StringBuffer(tokens.first);
  var previousLast = tokens.first.runes.last;
  for (final token in tokens.skip(1)) {
    final nextFirst = token.runes.first;
    if (!_isCjk(previousLast) && !_isCjk(nextFirst)) output.write(' ');
    output.write(token);
    previousLast = token.runes.last;
  }
  return output.toString();
}

String _compatibilityFold(String value) {
  final output = StringBuffer();
  for (final rune in value.runes) {
    final latinBase = _latinBaseFold[rune];
    if (latinBase != null) {
      output.write(latinBase);
    } else if (rune == 0x3000 || rune == 0x00a0) {
      output.write(' ');
    } else if (rune >= 0xff01 && rune <= 0xff5e) {
      output.writeCharCode(rune - 0xfee0);
    } else if (rune >= 0x2460 && rune <= 0x2473) {
      output.write('${rune - 0x245f}');
    } else {
      final ligature = _compatibilityLigatures[rune];
      if (ligature != null) {
        output.write(ligature);
      } else {
        output.writeCharCode(rune);
      }
    }
  }
  return output.toString();
}

const Map<int, String> _latinBaseFold = <int, String>{
  0x00c0: 'A',
  0x00c1: 'A',
  0x00c2: 'A',
  0x00c3: 'A',
  0x00c4: 'A',
  0x00c5: 'A',
  0x00e0: 'a',
  0x00e1: 'a',
  0x00e2: 'a',
  0x00e3: 'a',
  0x00e4: 'a',
  0x00e5: 'a',
  0x0100: 'A',
  0x0101: 'a',
  0x0102: 'A',
  0x0103: 'a',
  0x0104: 'A',
  0x0105: 'a',
  0x01cd: 'A',
  0x01ce: 'a',
  0x00c7: 'C',
  0x00e7: 'c',
  0x0106: 'C',
  0x0107: 'c',
  0x010c: 'C',
  0x010d: 'c',
  0x00c8: 'E',
  0x00c9: 'E',
  0x00ca: 'E',
  0x00cb: 'E',
  0x00e8: 'e',
  0x00e9: 'e',
  0x00ea: 'e',
  0x00eb: 'e',
  0x0112: 'E',
  0x0113: 'e',
  0x0116: 'E',
  0x0117: 'e',
  0x0118: 'E',
  0x0119: 'e',
  0x011a: 'E',
  0x011b: 'e',
  0x00cc: 'I',
  0x00cd: 'I',
  0x00ce: 'I',
  0x00cf: 'I',
  0x00ec: 'i',
  0x00ed: 'i',
  0x00ee: 'i',
  0x00ef: 'i',
  0x012a: 'I',
  0x012b: 'i',
  0x012e: 'I',
  0x012f: 'i',
  0x00d1: 'N',
  0x00f1: 'n',
  0x0143: 'N',
  0x0144: 'n',
  0x0147: 'N',
  0x0148: 'n',
  0x00d2: 'O',
  0x00d3: 'O',
  0x00d4: 'O',
  0x00d5: 'O',
  0x00d6: 'O',
  0x00f2: 'o',
  0x00f3: 'o',
  0x00f4: 'o',
  0x00f5: 'o',
  0x00f6: 'o',
  0x014c: 'O',
  0x014d: 'o',
  0x0150: 'O',
  0x0151: 'o',
  0x01d1: 'O',
  0x01d2: 'o',
  0x00d9: 'U',
  0x00da: 'U',
  0x00db: 'U',
  0x00dc: 'U',
  0x00f9: 'u',
  0x00fa: 'u',
  0x00fb: 'u',
  0x00fc: 'u',
  0x016a: 'U',
  0x016b: 'u',
  0x016e: 'U',
  0x016f: 'u',
  0x0170: 'U',
  0x0171: 'u',
  0x0172: 'U',
  0x0173: 'u',
  0x01d3: 'U',
  0x01d4: 'u',
  0x00dd: 'Y',
  0x00fd: 'y',
  0x00ff: 'y',
  0x0178: 'Y',
};

const Map<int, String> _compatibilityLigatures = <int, String>{
  0xfb00: 'ff',
  0xfb01: 'fi',
  0xfb02: 'fl',
  0xfb03: 'ffi',
  0xfb04: 'ffl',
  0xfb05: 'st',
  0xfb06: 'st',
};

bool _isAsciiWord(int rune) =>
    (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7a);

bool _isLatinLetter(int rune) =>
    (rune >= 0x00c0 && rune <= 0x02af) || (rune >= 0x1e00 && rune <= 0x1eff);

bool _isWordRune(int rune) =>
    _isAsciiWord(rune) ||
    _isLatinLetter(rune) ||
    _isCjk(rune) ||
    _isAdditionalScriptRune(rune);

bool _isCombiningMark(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0x1ab0 && rune <= 0x1aff) ||
    (rune >= 0x1dc0 && rune <= 0x1dff) ||
    (rune >= 0x20d0 && rune <= 0x20ff) ||
    (rune >= 0xfe20 && rune <= 0xfe2f);

bool _isAdditionalScriptRune(int rune) =>
    (rune >= 0x0370 && rune <= 0x052f) || // Greek, Coptic, Cyrillic
    (rune >= 0x0531 && rune <= 0x0587) || // Armenian letters
    (rune >= 0x0591 && rune <= 0x05f2) || // Hebrew letters and marks
    (rune >= 0x0610 && rune <= 0x06ed) || // Arabic letters, marks, digits
    (rune >= 0x0710 && rune <= 0x074a) || // Syriac
    (rune >= 0x0780 && rune <= 0x07b1) || // Thaana
    (rune >= 0x0900 && rune <= 0x0dff) || // Indic scripts
    (rune >= 0x0e01 && rune <= 0x0eff) || // Thai and Lao
    (rune >= 0x10a0 && rune <= 0x10ff) || // Georgian
    (rune >= 0x1200 && rune <= 0x167f) || // Ethiopic, Cherokee, Canadian
    (rune >= 0x1780 && rune <= 0x17ff) || // Khmer
    (rune >= 0x2c00 && rune <= 0x2dff) ||
    (rune >= 0xa640 && rune <= 0xa7ff);

bool _isCjk(int rune) =>
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0x20000 && rune <= 0x2ebef) ||
    (rune >= 0x3040 && rune <= 0x30ff) ||
    (rune >= 0xac00 && rune <= 0xd7af);
