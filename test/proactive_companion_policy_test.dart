import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';

void main() {
  const daytime = ProactivePolicyConfig(
    quietStartMinutes: 0,
    quietEndMinutes: 0,
  );
  const policy = ProactiveCompanionPolicy(config: daytime);
  const jitterKey = 'account:test:2026-08-26';
  final now = DateTime(2026, 8, 26, 15);

  const quietCandidate = ProactiveTopicCandidate(
    kind: ProactiveTopicKind.quietPresence,
    topicKey: 'quiet-presence',
    sourceEventId: 'presence:quiet:1',
  );

  group('configuration', () {
    test('uses the initial product defaults', () {
      const config = ProactivePolicyConfig();

      expect(config.foregroundDailyLimit, 3);
      expect(config.minimumGlobalGap, const Duration(minutes: 20));
      expect(config.maximumDeterministicJitter, const Duration(minutes: 25));
      expect(config.genericTopicCooldown, const Duration(hours: 24));
      expect(config.fingerprintRetentionCount, 32);
      expect(config.fingerprintRetention, const Duration(days: 30));
      expect(config.nearDuplicateThreshold, 0.78);
    });
  });

  group('topic selection', () {
    test('same relationship evidence is one-shot', () {
      const candidate = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.relationshipMilestone,
        topicKey: 'relationship-milestone',
        sourceEventId: 'relationship:event:1',
        evidenceKey: 'milestone:first-shared-project',
      );
      final decision = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[candidate],
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry(
            topicKey: 'relationship-milestone',
            evidenceKey: 'milestone:first-shared-project',
            occurredAt: now.subtract(const Duration(days: 4)),
            consumesSourceEvent: true,
            consumesEvidence: true,
            countsTowardGlobalGap: false,
          ),
        ],
      );

      expect(decision.shouldStaySilent, isTrue);
      expect(decision.reason, ProactiveSilenceReason.duplicateEvidence);
    });

    test('new milestone or stage signature is allowed once', () {
      final history = <ProactiveOutreachHistoryEntry>[
        ProactiveOutreachHistoryEntry(
          topicKey: 'relationship-stage',
          evidenceKey: 'stage:new-friend',
          occurredAt: now.subtract(const Duration(days: 2)),
          consumesSourceEvent: true,
          consumesEvidence: true,
          countsTowardGlobalGap: false,
        ),
      ];
      const candidate = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.relationshipStage,
        topicKey: 'relationship-stage',
        sourceEventId: 'relationship:stage:trusted',
        evidenceKey: 'stage:trusted-companion',
      );

      final first = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[candidate],
        history: history,
      );
      final replay = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[candidate],
        history: <ProactiveOutreachHistoryEntry>[
          ...history,
          ProactiveOutreachHistoryEntry(
            topicKey: candidate.topicKey,
            sourceEventId: candidate.sourceEventId,
            evidenceKey: candidate.evidenceKey,
            occurredAt: now,
            consumesSourceEvent: true,
            consumesEvidence: true,
            countsTowardGlobalGap: false,
          ),
        ],
      );

      expect(first.shouldReserve, isTrue);
      expect(replay.shouldStaySilent, isTrue);
      expect(replay.reason, ProactiveSilenceReason.duplicateSourceEvent);
    });

    test('rolling day counts cannot become a relationship fallback', () {
      final dayThree = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[],
      );
      final dayFour = policy.evaluate(
        now: now.add(const Duration(days: 1)),
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[],
      );

      expect(dayThree.reason, ProactiveSilenceReason.noFreshCandidate);
      expect(dayFour.reason, ProactiveSilenceReason.noFreshCandidate);
    });

    test('anniversary is dormant until a product evidence contract exists', () {
      const candidate = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.anniversary,
        topicKey: 'relationship-anniversary',
        evidenceKey: 'anniversary:7',
      );

      final decision = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[candidate],
      );

      expect(
        decision.reason,
        ProactiveSilenceReason.unsupportedRelationshipCandidate,
      );
    });

    test('source event replay is rejected exactly', () {
      final decision = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry(
            topicKey: 'another-topic',
            sourceEventId: quietCandidate.sourceEventId,
            occurredAt: now.subtract(const Duration(days: 40)),
            consumesSourceEvent: true,
            consumesEvidence: true,
            countsTowardForegroundBudget: false,
            countsTowardGlobalGap: false,
          ),
        ],
      );

      expect(decision.reason, ProactiveSilenceReason.duplicateSourceEvent);
    });

    test('an uncommitted attempt does not consume source or evidence', () {
      const candidate = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.relationshipMilestone,
        topicKey: 'relationship-milestone',
        sourceEventId: 'relationship:event:retryable',
        evidenceKey: 'milestone:retryable',
      );
      final decision = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[candidate],
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry(
            topicKey: candidate.topicKey,
            occurredAt: now.subtract(const Duration(minutes: 1)),
            consumesSourceEvent: false,
            consumesEvidence: false,
            sourceEventId: candidate.sourceEventId,
            evidenceKey: candidate.evidenceKey,
            countsTowardForegroundBudget: false,
            countsTowardGlobalGap: false,
          ),
        ],
      );

      expect(decision.shouldReserve, isTrue);
    });
  });

  group('eligibility gates', () {
    test('quiet hours are a first-class silence decision', () {
      const quietPolicy = ProactiveCompanionPolicy();
      final decision = quietPolicy.evaluate(
        now: DateTime(2026, 8, 26, 23, 30),
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
      );

      expect(decision.reason, ProactiveSilenceReason.quietHours);
    });

    test('daily foreground budget is enforced', () {
      final history = List<ProactiveOutreachHistoryEntry>.generate(
        3,
        (index) => ProactiveOutreachHistoryEntry(
          topicKey: 'topic-$index',
          occurredAt: now.subtract(Duration(hours: index + 1)),
          consumesSourceEvent: true,
          consumesEvidence: true,
          countsTowardGlobalGap: false,
        ),
      );

      final decision = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
        history: history,
      );

      expect(decision.reason, ProactiveSilenceReason.dailyBudgetExhausted);
    });

    test('global gap includes deterministic jitter and user activity', () {
      final first = policy.evaluate(
        now: now,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
        lastUserActivityAt: now.subtract(const Duration(minutes: 20)),
        deterministicJitterKey: 'account-hash:2026-08-26',
      );
      final second = policy.evaluate(
        now: now,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
        lastUserActivityAt: now.subtract(const Duration(minutes: 20)),
        deterministicJitterKey: 'account-hash:2026-08-26',
      );

      expect(first.reason, ProactiveSilenceReason.globalGap);
      expect(first.nextEligibleAt, second.nextEligibleAt);
      expect(first.nextEligibleAt, isNotNull);
      expect(first.nextEligibleAt!.isAfter(now), isTrue);
    });

    test('generic topic cooldown does not mask a different topic', () {
      final history = <ProactiveOutreachHistoryEntry>[
        ProactiveOutreachHistoryEntry(
          topicKey: quietCandidate.topicKey,
          occurredAt: now.subtract(const Duration(hours: 2)),
          consumesSourceEvent: true,
          consumesEvidence: true,
          countsTowardGlobalGap: false,
        ),
      ];
      const alternative = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.environmentObservation,
        topicKey: 'weather-cleared',
        sourceEventId: 'environment:weather:2',
        priority: -1,
      );

      final sameOnly = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
        history: history,
      );
      final withAlternative = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[
          quietCandidate,
          alternative,
        ],
        history: history,
      );

      expect(sameOnly.reason, ProactiveSilenceReason.topicCooldown);
      expect(withAlternative.shouldReserve, isTrue);
      expect(withAlternative.candidate?.topicKey, alternative.topicKey);
    });

    test('future history and future user activity do not extend cooldowns', () {
      final future = now.add(const Duration(days: 30));
      final decision = policy.evaluate(
        now: now,
        deterministicJitterKey: jitterKey,
        candidates: const <ProactiveTopicCandidate>[quietCandidate],
        lastUserActivityAt: future,
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry(
            topicKey: quietCandidate.topicKey,
            occurredAt: future,
            consumesSourceEvent: false,
            consumesEvidence: false,
            countsTowardForegroundBudget: false,
            countsTowardGlobalGap: true,
          ),
        ],
      );

      expect(decision.shouldReserve, isTrue);
      expect(decision.nextEligibleAt, isNull);
    });

    test(
      'stable caller key keeps jitter independent of candidate ordering',
      () {
        const firstCandidate = ProactiveTopicCandidate(
          kind: ProactiveTopicKind.environmentObservation,
          topicKey: 'same-topic',
          sourceEventId: 'same-source',
          evidenceKey: 'evidence:a',
          textSeed: 'seed:b',
        );
        const secondCandidate = ProactiveTopicCandidate(
          kind: ProactiveTopicKind.environmentObservation,
          topicKey: 'same-topic',
          sourceEventId: 'same-source',
          evidenceKey: 'evidence:b',
          textSeed: 'seed:a',
        );
        final touch = now.subtract(const Duration(minutes: 10));
        final ordered = policy.evaluate(
          now: now,
          deterministicJitterKey: jitterKey,
          lastUserActivityAt: touch,
          candidates: const <ProactiveTopicCandidate>[
            firstCandidate,
            secondCandidate,
          ],
        );
        final reversed = policy.evaluate(
          now: now,
          deterministicJitterKey: jitterKey,
          lastUserActivityAt: touch,
          candidates: const <ProactiveTopicCandidate>[
            secondCandidate,
            firstCandidate,
          ],
        );

        expect(ordered.nextEligibleAt, reversed.nextEligibleAt);
        expect(ordered.reason, ProactiveSilenceReason.globalGap);
        expect(reversed.reason, ProactiveSilenceReason.globalGap);

        final eligibleAt = ordered.nextEligibleAt!;
        final selected = policy.evaluate(
          now: eligibleAt,
          deterministicJitterKey: jitterKey,
          lastUserActivityAt: touch,
          candidates: const <ProactiveTopicCandidate>[
            secondCandidate,
            firstCandidate,
          ],
        );
        expect(selected.candidate?.evidenceKey, 'evidence:a');
      },
    );

    test('blank deterministic jitter keys fail fast', () {
      expect(
        () => policy.evaluate(
          now: now,
          deterministicJitterKey: '  ',
          candidates: const <ProactiveTopicCandidate>[quietCandidate],
        ),
        throwsArgumentError,
      );
    });
  });

  group('buffered text novelty', () {
    test(
      'NFKC-style width, case, punctuation and whitespace variants match',
      () {
        final history = <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'quiet-presence',
            occurredAt: now.subtract(const Duration(days: 1)),
            text: 'Ｈｅｌｌｏ，  世界！',
          ),
        ];

        final decision = policy.evaluateDraft(
          now: now,
          candidate: quietCandidate,
          draft: 'hello 世界',
          history: history,
        );

        expect(decision.reason, ProactiveSilenceReason.duplicateText);
      },
    );

    test('Chinese 2/3-grams reject a lightly rephrased repeated thought', () {
      const previous = '三天了，时间悄悄溜走，却留下一点暖意。';
      const repeated = '三天了，时间悄悄流走，却留下一点暖意。';
      final decision = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: repeated,
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'relationship-stage',
            occurredAt: now.subtract(const Duration(hours: 2)),
            text: previous,
          ),
        ],
      );

      expect(decision.reason, ProactiveSilenceReason.nearDuplicateText);
      expect(decision.similarityScore, greaterThanOrEqualTo(0.78));
    });

    test('English token shingles reject near-duplicate wording', () {
      const previous =
          'Three days already, time quietly passes and leaves a little warmth.';
      const repeated =
          'Three days already, time quietly passed and leaves a little warmth.';
      final decision = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: repeated,
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'relationship-stage',
            occurredAt: now.subtract(const Duration(hours: 2)),
            text: previous,
          ),
        ],
      );

      expect(decision.reason, ProactiveSilenceReason.nearDuplicateText);
      expect(decision.similarityScore, greaterThanOrEqualTo(0.78));
    });

    test('low-overlap text on a different topic is accepted', () {
      final decision = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: '窗外的雨停了，空气看起来很清爽。',
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'relationship-stage',
            occurredAt: now.subtract(const Duration(hours: 2)),
            text: '我们完成了第一个共同项目，值得记住。',
          ),
        ],
      );

      expect(decision.isAccepted, isTrue);
      expect(decision.textSignature?.fingerprint, hasLength(64));
    });

    test('new relationship evidence bypasses only approximate similarity', () {
      const candidate = ProactiveTopicCandidate(
        kind: ProactiveTopicKind.relationshipMilestone,
        topicKey: 'relationship-milestone',
        evidenceKey: 'milestone:30-days',
      );
      final history = <ProactiveOutreachHistoryEntry>[
        ProactiveOutreachHistoryEntry.fromText(
          policy: policy,
          topicKey: candidate.topicKey,
          evidenceKey: 'milestone:7-days',
          occurredAt: now.subtract(const Duration(days: 23)),
          text: '我们认识7天了，这段陪伴值得记住。',
        ),
      ];

      final fresh = policy.evaluateDraft(
        now: now,
        candidate: candidate,
        draft: '我们认识30天了，这段陪伴值得记住。',
        history: history,
      );
      final exact = policy.evaluateDraft(
        now: now,
        candidate: candidate,
        draft: '我们认识7天了，这段陪伴值得记住。',
        history: history,
      );

      expect(fresh.isAccepted, isTrue);
      expect(exact.reason, ProactiveSilenceReason.duplicateText);
    });

    test('changed numeric and Latin slots survive an identical CJK frame', () {
      final numeric = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: '我们认识30天了，这段陪伴值得记住。',
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'earlier',
            occurredAt: now.subtract(const Duration(days: 1)),
            text: '我们认识7天了，这段陪伴值得记住。',
          ),
        ],
      );
      final entity = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: 'Bob今天带来了一个好消息。',
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'earlier',
            occurredAt: now.subtract(const Duration(days: 1)),
            text: 'Alice今天带来了一个好消息。',
          ),
        ],
      );

      expect(numeric.isAccepted, isTrue);
      expect(entity.isAccepted, isTrue);
    });

    test(
      'fingerprints preserve English boundaries and compact CJK separators',
      () {
        expect(
          policy.signatureFor('now here').fingerprint,
          isNot(policy.signatureFor('nowhere').fingerprint),
        );
        expect(
          policy.signatureFor('你好，世界！').fingerprint,
          policy.signatureFor('你好世界').fingerprint,
        );
        expect(
          policy.signatureFor('Ｃａｆé').fingerprint,
          policy.signatureFor('cafe\u0301').fingerprint,
        );
      },
    );

    test('non-Latin scripts normalize to meaningful non-empty text', () {
      expect(policy.normalizeText('Привет, мир!'), isNotEmpty);
      expect(policy.normalizeText('مرحبا، بالعالم!'), isNotEmpty);
      expect(
        policy
            .evaluateDraft(
              now: now,
              candidate: quietCandidate,
              draft: 'Привет, мир!',
            )
            .isAccepted,
        isTrue,
      );
    });

    test('containment catches a repeated template with a long new tail', () {
      const previous = '三天了，时间悄悄溜走，却留下一点暖意。';
      final decision = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: '$previous窗外的风也很轻，希望你今天过得顺利。',
        history: <ProactiveOutreachHistoryEntry>[
          ProactiveOutreachHistoryEntry.fromText(
            policy: policy,
            topicKey: 'earlier',
            occurredAt: now.subtract(const Duration(hours: 1)),
            text: previous,
          ),
        ],
      );

      expect(decision.reason, ProactiveSilenceReason.nearDuplicateText);
      expect(decision.similarityScore, 1);
    });

    test('fingerprint retention is bounded by age and count', () {
      const retentionPolicy = ProactiveCompanionPolicy(
        config: ProactivePolicyConfig(
          quietStartMinutes: 0,
          quietEndMinutes: 0,
          fingerprintRetentionCount: 1,
          fingerprintRetention: Duration(days: 30),
        ),
      );
      final old = ProactiveOutreachHistoryEntry.fromText(
        policy: retentionPolicy,
        topicKey: 'old',
        occurredAt: now.subtract(const Duration(days: 31)),
        text: '不会再参与文本比较',
      );
      final newer = ProactiveOutreachHistoryEntry.fromText(
        policy: retentionPolicy,
        topicKey: 'newer',
        occurredAt: now.subtract(const Duration(days: 1)),
        text: '最近保留的一句话',
      );
      final secondNewest = ProactiveOutreachHistoryEntry.fromText(
        policy: retentionPolicy,
        topicKey: 'second-newest',
        occurredAt: now.subtract(const Duration(days: 2)),
        text: '第二新的重复句子',
      );

      expect(
        retentionPolicy
            .evaluateDraft(
              now: now,
              candidate: quietCandidate,
              draft: old.normalizedTextHash == null ? '' : '不会再参与文本比较',
              history: <ProactiveOutreachHistoryEntry>[old, newer],
            )
            .isAccepted,
        isTrue,
      );
      expect(
        retentionPolicy
            .evaluateDraft(
              now: now,
              candidate: quietCandidate,
              draft: '第二新的重复句子',
              history: <ProactiveOutreachHistoryEntry>[newer, secondNewest],
            )
            .isAccepted,
        isTrue,
      );
    });

    test('result is deterministic and has no embedding or network input', () {
      final history = <ProactiveOutreachHistoryEntry>[
        ProactiveOutreachHistoryEntry.fromText(
          policy: policy,
          topicKey: 'earlier',
          occurredAt: now.subtract(const Duration(hours: 4)),
          text: 'Earlier unrelated sentence.',
        ),
      ];

      final first = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: 'A deterministic local-only sentence.',
        history: history,
      );
      final second = policy.evaluateDraft(
        now: now,
        candidate: quietCandidate,
        draft: 'A deterministic local-only sentence.',
        history: history,
      );

      expect(first.kind, second.kind);
      expect(
        first.textSignature?.fingerprint,
        second.textSignature?.fingerprint,
      );
      expect(
        first.textSignature?.similarityFeatures,
        second.textSignature?.similarityFeatures,
      );
    });
  });
}
