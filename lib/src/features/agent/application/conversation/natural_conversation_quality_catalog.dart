/// Locale used by the natural-conversation quality corpus.
enum NaturalConversationQualityLocale { zh, en }

/// The same category appears once per locale so language results are comparable.
enum NaturalConversationQualityCategory {
  everydayChoice,
  contextDependentOpinion,
  hesitantDecision,
  correctedPreference,
  understatedDisappointment,
  clearCelebration,
  dryHumor,
  shortAcknowledgement,
  listeningBoundary,
  rememberedPreference,
  correctedName,
  conversationClosure,
}

/// Observable quality dimensions exercised without putting action commands in
/// the user's mouth. One scenario may cover several dimensions.
enum NaturalConversationQualityFocus {
  naturalReply,
  contextInference,
  multiUtteranceRhythm,
  emotionalAttunement,
  hesitationAndPause,
  repetitionRestraint,
  autonomousBodyCue,
  speechIdleIsolation,
}

/// Strength of the emotion evidence supplied by the user, not a diagnosis.
enum NaturalConversationEmotionEvidence { none, ambiguous, explicit }

enum NaturalConversationHistoryRole { user, assistant }

class NaturalConversationHistoryTurn {
  const NaturalConversationHistoryTurn({
    required this.role,
    required this.text,
  });

  final NaturalConversationHistoryRole role;
  final String text;
}

class NaturalConversationQualityScenario {
  const NaturalConversationQualityScenario({
    required this.id,
    required this.locale,
    required this.category,
    required this.userText,
    required this.emotionEvidence,
    this.history = const <NaturalConversationHistoryTurn>[],
    this.potentialStaleMarkers = const <String>[],
  });

  final String id;
  final NaturalConversationQualityLocale locale;
  final NaturalConversationQualityCategory category;
  final List<NaturalConversationHistoryTurn> history;
  final String userText;

  /// Used only to decide whether a human must review emotion inference.
  final NaturalConversationEmotionEvidence emotionEvidence;

  /// A match is a review flag, not an automatic failure. A natural reply may
  /// mention superseded content while acknowledging the user's correction.
  final List<String> potentialStaleMarkers;

  Set<NaturalConversationQualityFocus> get focuses =>
      naturalConversationQualityFocusByCategory[category] ?? const {};
}

const naturalConversationQualityFocusByCategory =
    <NaturalConversationQualityCategory, Set<NaturalConversationQualityFocus>>{
      NaturalConversationQualityCategory.everydayChoice: {
        NaturalConversationQualityFocus.naturalReply,
        NaturalConversationQualityFocus.multiUtteranceRhythm,
        NaturalConversationQualityFocus.hesitationAndPause,
        NaturalConversationQualityFocus.autonomousBodyCue,
      },
      NaturalConversationQualityCategory.contextDependentOpinion: {
        NaturalConversationQualityFocus.contextInference,
        NaturalConversationQualityFocus.naturalReply,
      },
      NaturalConversationQualityCategory.hesitantDecision: {
        NaturalConversationQualityFocus.emotionalAttunement,
        NaturalConversationQualityFocus.hesitationAndPause,
        NaturalConversationQualityFocus.multiUtteranceRhythm,
        NaturalConversationQualityFocus.autonomousBodyCue,
      },
      NaturalConversationQualityCategory.correctedPreference: {
        NaturalConversationQualityFocus.contextInference,
        NaturalConversationQualityFocus.repetitionRestraint,
      },
      NaturalConversationQualityCategory.understatedDisappointment: {
        NaturalConversationQualityFocus.emotionalAttunement,
        NaturalConversationQualityFocus.autonomousBodyCue,
      },
      NaturalConversationQualityCategory.clearCelebration: {
        NaturalConversationQualityFocus.emotionalAttunement,
        NaturalConversationQualityFocus.autonomousBodyCue,
      },
      NaturalConversationQualityCategory.dryHumor: {
        NaturalConversationQualityFocus.emotionalAttunement,
        NaturalConversationQualityFocus.repetitionRestraint,
      },
      NaturalConversationQualityCategory.shortAcknowledgement: {
        NaturalConversationQualityFocus.naturalReply,
        NaturalConversationQualityFocus.repetitionRestraint,
        NaturalConversationQualityFocus.speechIdleIsolation,
      },
      NaturalConversationQualityCategory.listeningBoundary: {
        NaturalConversationQualityFocus.contextInference,
        NaturalConversationQualityFocus.emotionalAttunement,
        NaturalConversationQualityFocus.speechIdleIsolation,
      },
      NaturalConversationQualityCategory.rememberedPreference: {
        NaturalConversationQualityFocus.contextInference,
        NaturalConversationQualityFocus.naturalReply,
      },
      NaturalConversationQualityCategory.correctedName: {
        NaturalConversationQualityFocus.contextInference,
        NaturalConversationQualityFocus.repetitionRestraint,
      },
      NaturalConversationQualityCategory.conversationClosure: {
        NaturalConversationQualityFocus.emotionalAttunement,
        NaturalConversationQualityFocus.repetitionRestraint,
        NaturalConversationQualityFocus.speechIdleIsolation,
      },
    };

const naturalConversationQualityCatalogVersion = 1;

/// Curated conversational inputs. They never ask for an animation or name an
/// expected answer; semantic correctness is deliberately left to human review.
const naturalConversationQualityScenarios = <NaturalConversationQualityScenario>[
  NaturalConversationQualityScenario(
    id: 'zh.everyday_choice',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.everydayChoice,
    userText: '今天吃啥好呢？',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.context_dependent_opinion',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.contextDependentOpinion,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: '我把确认按钮挪到页面底部了，单手比较容易点到。',
      ),
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: '这样操作路径会短一些。',
      ),
    ],
    userText: '你觉得这样对吗？',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.hesitant_decision',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.hesitantDecision,
    userText: '我有点想换工作，但又怕选错。',
    emotionEvidence: NaturalConversationEmotionEvidence.explicit,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.corrected_preference',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.correctedPreference,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: '我今天想吃点辣的。',
      ),
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: '那去吃麻辣烫？',
      ),
    ],
    userText: '算了，胃有点不舒服，还是清淡一点吧。',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
    potentialStaleMarkers: <String>['麻辣烫'],
  ),
  NaturalConversationQualityScenario(
    id: 'zh.understated_disappointment',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.understatedDisappointment,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: '面试结果出来了吗？',
      ),
    ],
    userText: '嗯，没过。也正常。',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.clear_celebration',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.clearCelebration,
    userText: '我拿到 offer 了！等了好久！',
    emotionEvidence: NaturalConversationEmotionEvidence.explicit,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.dry_humor',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.dryHumor,
    userText: '哈哈，反正倒霉的总是我。',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.short_acknowledgement',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.shortAcknowledgement,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: '明早会降温，出门记得带件外套。',
      ),
    ],
    userText: '嗯。',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.listening_boundary',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.listeningBoundary,
    userText: '我现在只想吐槽一下，先别给我建议。',
    emotionEvidence: NaturalConversationEmotionEvidence.explicit,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.remembered_preference',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.rememberedPreference,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: '我喝东西不喜欢太甜。',
      ),
    ],
    userText: '那下午喝点什么？',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
  ),
  NaturalConversationQualityScenario(
    id: 'zh.corrected_name',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.correctedName,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: '以后叫我小北吧。',
      ),
    ],
    userText: '对了，别叫小北了，叫我阿岚吧。',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
    potentialStaleMarkers: <String>['小北'],
  ),
  NaturalConversationQualityScenario(
    id: 'zh.conversation_closure',
    locale: NaturalConversationQualityLocale.zh,
    category: NaturalConversationQualityCategory.conversationClosure,
    userText: '算了，今天先不聊这个了。',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'en.everyday_choice',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.everydayChoice,
    userText: 'What should I eat today?',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
  ),
  NaturalConversationQualityScenario(
    id: 'en.context_dependent_opinion',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.contextDependentOpinion,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text:
            'I moved the confirm button to the bottom so it is easier to reach one-handed.',
      ),
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: 'That makes the interaction path shorter.',
      ),
    ],
    userText: 'Do you think that is right?',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'en.hesitant_decision',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.hesitantDecision,
    userText:
        'I kind of want to change jobs, but I am worried I will choose wrong.',
    emotionEvidence: NaturalConversationEmotionEvidence.explicit,
  ),
  NaturalConversationQualityScenario(
    id: 'en.corrected_preference',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.correctedPreference,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: 'I feel like having something spicy today.',
      ),
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: 'How about spicy ramen?',
      ),
    ],
    userText:
        'Actually, my stomach feels off. I would rather have something light.',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
    potentialStaleMarkers: <String>['spicy ramen'],
  ),
  NaturalConversationQualityScenario(
    id: 'en.understated_disappointment',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.understatedDisappointment,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: 'Did you hear back after the interview?',
      ),
    ],
    userText: 'Yeah, I did not get it. Fair enough, I guess.',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'en.clear_celebration',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.clearCelebration,
    userText: 'I got the offer! I have been waiting forever!',
    emotionEvidence: NaturalConversationEmotionEvidence.explicit,
  ),
  NaturalConversationQualityScenario(
    id: 'en.dry_humor',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.dryHumor,
    userText: 'Ha, of course I am always the lucky one.',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
  NaturalConversationQualityScenario(
    id: 'en.short_acknowledgement',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.shortAcknowledgement,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.assistant,
        text: 'It will be colder tomorrow morning, so bring a jacket.',
      ),
    ],
    userText: 'Mm.',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
  ),
  NaturalConversationQualityScenario(
    id: 'en.listening_boundary',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.listeningBoundary,
    userText:
        'I just want to vent right now. Please do not give me advice yet.',
    emotionEvidence: NaturalConversationEmotionEvidence.explicit,
  ),
  NaturalConversationQualityScenario(
    id: 'en.remembered_preference',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.rememberedPreference,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: 'I do not like drinks that are too sweet.',
      ),
    ],
    userText: 'What should I get this afternoon?',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
  ),
  NaturalConversationQualityScenario(
    id: 'en.corrected_name',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.correctedName,
    history: <NaturalConversationHistoryTurn>[
      NaturalConversationHistoryTurn(
        role: NaturalConversationHistoryRole.user,
        text: 'Call me North from now on.',
      ),
    ],
    userText: 'Actually, do not call me North anymore. Call me Aria.',
    emotionEvidence: NaturalConversationEmotionEvidence.none,
    potentialStaleMarkers: <String>['North'],
  ),
  NaturalConversationQualityScenario(
    id: 'en.conversation_closure',
    locale: NaturalConversationQualityLocale.en,
    category: NaturalConversationQualityCategory.conversationClosure,
    userText: 'Never mind. I do not want to talk about this today.',
    emotionEvidence: NaturalConversationEmotionEvidence.ambiguous,
  ),
];
