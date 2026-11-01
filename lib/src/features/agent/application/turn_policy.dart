import 'package:maaso/src/features/agent/data/utils/logger.dart';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/utils/explicit_creation_question_guard.dart';
import 'package:maaso/src/features/agent/application/app_control_intent.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart'
    show RoutingDecision, LocalIntent, RouteComplexity;
import 'package:maaso/src/features/agent/application/projector_intent.dart';
import 'package:maaso/src/features/agent/application/projector_media_session.dart';
import 'package:maaso/src/features/agent/application/response_track_plan.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/applets/domain/applet_request_intent.dart';
import 'package:maaso/src/core/services/locale_config_service.dart'
    show AppLocale;

/// Which kind of generated surface/setup UI (if any) this turn wants.
enum CardIntent {
  none,
  setup, // ShowCard — short form / confirm / setting / choice
  interactive, // FreeformSurface — rich/generated UI surface
}

/// Immutable per-turn decision produced by [TurnPolicyEngine].
///
/// Hint-only: skill invocations use native tools or validated JSON actions.
/// This object decides *what kind of turn this is* once, so
/// prompt shaping, path selection, and the Phase-2 acknowledgement all read a
/// single source of truth instead of re-deriving it.
class TurnPolicy {
  final bool shouldSearch;
  final bool shouldSearchApplets;
  final CardIntent card;
  final bool shouldAskClarifying;
  final bool preferMultiStep;
  final bool preferNativeTools;
  final List<String> preferredSkills;
  final ProjectorMediaResolution projectorMedia;
  final SurfaceIntent surface;
  final ResponseTrackPlan tracks;

  /// i18n key for the Phase-2 thought-bubble line (resolved with `.tr` at the
  /// push site so this object stays pure). Null = no acknowledgement.
  final String? acknowledgement;

  /// Comma-joined trail of which rules fired, for TurnTrace / logs.
  final String reason;

  const TurnPolicy({
    this.shouldSearch = false,
    this.shouldSearchApplets = false,
    this.card = CardIntent.none,
    this.shouldAskClarifying = false,
    this.preferMultiStep = false,
    this.preferNativeTools = false,
    this.preferredSkills = const [],
    this.projectorMedia = ProjectorMediaResolution.none,
    this.surface = SurfaceIntent.none,
    this.tracks = ResponseTrackPlan.none,
    this.acknowledgement,
    this.reason = '',
  });

  /// Safe default — behaviourally equivalent to a plain chat turn today.
  static const neutral = TurnPolicy();

  /// Short, turn-scoped directive prepended to the per-turn preamble (NOT the
  /// cached system prompt). Empty when neutral so the prompt never grows for a
  /// plain turn.
  String get promptBlock => promptBlockFor(AgentPromptCatalog.currentLocale);

  String promptBlockFor(AppLocale locale) {
    final parts = <String>[];
    if (shouldSearch) {
      parts.add(
        AgentPromptCatalog.text('runtime.policy.search', locale: locale),
      );
    }
    if (shouldSearchApplets) {
      parts.add(
        AgentPromptCatalog.text(
          'runtime.policy.applet_discovery',
          locale: locale,
        ),
      );
    }
    if (card == CardIntent.interactive) {
      if (surface.kind == SurfaceIntentKind.applet ||
          surface.kind == SurfaceIntentKind.game) {
        parts.add(
          AgentPromptCatalog.text(
            'runtime.policy.applet_build',
            locale: locale,
          ),
        );
      }
      if (surface.kind == SurfaceIntentKind.game) {
        parts.add(
          AgentPromptCatalog.text(
            'runtime.policy.surface_game',
            locale: locale,
          ),
        );
      } else if (surface.kind != SurfaceIntentKind.applet) {
        parts.add(
          AgentPromptCatalog.text(
            'runtime.policy.surface_utility',
            locale: locale,
          ),
        );
      }
    } else if (card == CardIntent.setup) {
      parts.add(
        AgentPromptCatalog.text('runtime.policy.show_card', locale: locale),
      );
    }
    if (shouldAskClarifying) {
      parts.add(
        AgentPromptCatalog.text('runtime.policy.clarify', locale: locale),
      );
    }
    final projectorPrompt = projectorMedia.promptBlockFor(locale);
    if (projectorPrompt.isNotEmpty) {
      parts.add(projectorPrompt);
    }
    final tracksPrompt = tracks.promptDirectiveFor(locale);
    if (tracksPrompt.isNotEmpty) {
      if (card == CardIntent.interactive) {
        parts.add(
          AgentPromptCatalog.text(
            'runtime.policy.surface_tracks',
            locale: locale,
          ),
        );
      } else {
        parts.add(tracksPrompt);
      }
    }
    if (parts.isEmpty) return '';
    return AgentPromptCatalog.text(
      'runtime.policy.wrapper',
      locale: locale,
      params: {'parts': parts.join('; ')},
    );
  }
}

/// Everything [TurnPolicyEngine.decide] needs. All fields are cheap to gather
/// inside `AgentRuntime.chat()`.
class TurnContext {
  final String userText;
  final RoutingDecision? routing;
  final String recentConversation;
  final bool hasOpenSurface; // SurfaceRuntime.isVisible
  final bool online; // ConnectivityService.isOnline
  final bool cloudAvailable; // LLMConfigController.cloudUsable
  final AppLocale locale; // LocaleConfigService.resolvedAppLocale (reserved)
  final bool autoPlanEnabled; // AgentBehaviorConfig.multiStepEnabled
  final bool nativeToolsEnabled; // AgentBehaviorConfig.useNativeTools
  final bool brainHasNativeTools; // AgentRuntime.hasNativeTools
  final bool forcedPlan; // text contains "[PLAN MODE"
  final ProjectorMediaResolution projectorMedia;
  final SurfaceIntent resolvedSurfaceIntent;

  const TurnContext({
    required this.userText,
    this.routing,
    this.recentConversation = '',
    bool hasOpenSurface = false,
    @Deprecated('Use hasOpenSurface') bool hasOpenCard = false,
    this.online = true,
    this.cloudAvailable = false,
    this.locale = AppLocale.en,
    this.autoPlanEnabled = false,
    this.nativeToolsEnabled = false,
    this.brainHasNativeTools = false,
    this.forcedPlan = false,
    this.projectorMedia = ProjectorMediaResolution.none,
    this.resolvedSurfaceIntent = SurfaceIntent.none,
  }) : hasOpenSurface = hasOpenSurface || hasOpenCard;
}

/// Stateless, deterministic per-turn decision. One per agent, like ReflexEngine.
class TurnPolicyEngine {
  TurnPolicyEngine({required this.agentId});
  final String agentId;

  // Recency / volatility / source-request cues that EXTEND the local brain's
  // web_search bank (zh + en, lowercased). Deliberately specific — generic
  // words like 今天/today/最近 are excluded so "我今天好累" never triggers search.
  static const _searchCues = <String>[
    '最新',
    '价格',
    '多少钱',
    '排名',
    '股价',
    '汇率',
    '天气',
    '预报',
    '新闻',
    '版本',
    '政策',
    '出处',
    '来源',
    '引用',
    'latest',
    'price',
    'how much',
    'ranking',
    'stock',
    'exchange rate',
    'weather',
    'forecast',
    'news',
    'version',
    'citation',
  ];
  static const _noSearchCues = <String>[
    '别联网',
    '不要联网',
    '别上网',
    '不用搜',
    '不要搜',
    "don't search",
    'do not search',
    'no internet',
    'without searching',
  ];
  // Strong, unambiguous "wants a setup card" phrases — these can ENTER the
  // card branch on their own.
  static const _setupEntryCues = <String>['api key', 'apikey', 'api-key'];

  TurnPolicy decide(TurnContext ctx) {
    try {
      return _decide(ctx);
    } catch (e) {
      Log.w(
        '🧭 [TurnPolicy/$agentId] decide threw, falling back to neutral: $e',
      );
      return TurnPolicy.neutral;
    }
  }

  TurnPolicy _decide(TurnContext ctx) {
    final lower = ctx.userText.toLowerCase();
    final classifiedSurface = SurfaceCreationAuthority.resolveSurfaceIntent(
      text: ctx.userText,
      resolvedSurfaceIntent: ctx.resolvedSurfaceIntent,
    );
    final explicitCreation =
        SurfaceCreationAuthority.experienceTypeFor(
          text: ctx.userText,
          interactiveHint: true,
          surfaceIntent: classifiedSurface,
        ) !=
        null;
    final appOperationIntent = classifyAppOperationIntent(ctx.userText);
    final wantsAppControl =
        !explicitCreation && appOperationIntent.usesAppControl;
    final suppressesGeneratedSurface =
        !explicitCreation && appOperationIntent.suppressesGeneratedSurface;
    final appletRequest = AppletRequestIntent.classify(ctx.userText);
    final reusableUtilityRequest =
        !ctx.hasOpenSurface &&
        !explicitCreation &&
        !suppressesGeneratedSurface &&
        !ExplicitCreationQuestionGuard.blocks(lower) &&
        RegExp(
          r'帮|想|计划|规划|安排|制定|去|做|生成|创建|\b(?:help|plan|organize|create|build|make|need|want)\b',
        ).hasMatch(lower) &&
        (_any(lower, const [
              '旅行',
              '旅游',
              '行程',
              '攻略',
              'trip',
              'travel',
              'itinerary',
            ]) ||
            classifiedSurface.kind == SurfaceIntentKind.dashboard);
    final wantsAppletDiscovery =
        appletRequest.isDiscovery || reusableUtilityRequest;
    final shouldSearchApplets = wantsAppletDiscovery && ctx.online;
    final tools = ctx.routing?.needsTools ?? const <String>[];
    final projectorSessionFollowUp = ctx.projectorMedia.isProjectorFollowUp;
    final projectorFollowUp =
        projectorSessionFollowUp ||
        isProjectorMediaFollowUp(ctx.userText, ctx.recentConversation);
    final projectorTurn =
        !explicitCreation &&
        (textContainsAny(lower, projectorTerms) || projectorFollowUp);
    final projectorOnlineImageFollowUp =
        ctx.projectorMedia.shouldSearch ||
        isProjectorOnlineImageFollowUp(ctx.userText, ctx.recentConversation);
    final projectorImageSubjectFollowUp =
        ctx.projectorMedia.reason == 'bare_subject' ||
        isProjectorImageSubjectFollowUp(ctx.userText, ctx.recentConversation);
    final projectorOnlineImageRequest =
        projectorTurn && isProjectorOnlineImageChoiceText(ctx.userText);
    final surface =
        projectorTurn || wantsAppletDiscovery || suppressesGeneratedSurface
        ? SurfaceIntent.none
        : explicitCreation
        ? classifiedSurface
        : SurfaceIntent.none;

    // ── search: only when facts can change ──
    final saidNoSearch = _any(lower, _noSearchCues);
    final searchHinted = tools.contains('web_search');
    final searchKw = _any(lower, _searchCues);
    final wouldSearch =
        !wantsAppletDiscovery &&
        !saidNoSearch &&
        (searchHinted ||
            searchKw ||
            projectorOnlineImageFollowUp ||
            projectorOnlineImageRequest);
    final shouldSearch = wouldSearch && ctx.online;

    // ── generated surface: only when text isn't the best interface ──
    final setupStrong = _any(lower, _setupEntryCues);
    var card = CardIntent.none;
    final surfaceHinted =
        !wantsAppletDiscovery &&
        !suppressesGeneratedSurface &&
        explicitCreation;
    if (!projectorTurn && (surfaceHinted || setupStrong)) {
      // Settings/confirmation controls are ordinary product requirements.
      // Only a host setup request selects ShowCard; creation keeps its grant.
      card = surfaceHinted ? CardIntent.interactive : CardIntent.setup;
    }
    if (ctx.hasOpenSurface &&
        card != CardIntent.setup &&
        !projectorTurn &&
        !wantsAppletDiscovery &&
        !suppressesGeneratedSurface) {
      card = CardIntent.interactive; // editing the open surface
    }

    // ── multi-step / native: moved verbatim from chat() ──
    final routing = ctx.routing;
    final nonTrivial =
        routing != null &&
        routing.intent != LocalIntent.chitchat &&
        routing.intent != LocalIntent.unknown &&
        routing.complexity != RouteComplexity.simple &&
        routing.complexity != RouteComplexity.unknown;
    // A generated surface is one visual object to build, not a think-act-observe task —
    // keep it single-shot (streaming) instead of the multi-step loop, which
    // resends the whole system prompt per step and blocks on each. Explicit
    // [PLAN MODE] (forcedPlan) still wins.
    final requiresAwaitedSkillResult =
        projectorTurn || shouldSearch || shouldSearchApplets;
    final preferMultiStep =
        ctx.forcedPlan ||
        requiresAwaitedSkillResult ||
        (ctx.autoPlanEnabled && nonTrivial && card == CardIntent.none);
    final preferNativeTools =
        ctx.nativeToolsEnabled && !preferMultiStep && ctx.brainHasNativeTools;

    final skills = <String>[
      if (wantsAppControl) 'AppControl',
      if (shouldSearch) 'WebSearch',
      if (shouldSearchApplets) 'AppletDiscovery',
      if (projectorTurn) ...['BleYoturetoys', 'Bluetooth'],
      if (card == CardIntent.interactive) 'FreeformSurface',
      if (card == CardIntent.setup) 'ShowCard',
    ];
    final hasTrackWork =
        shouldSearch ||
        shouldSearchApplets ||
        projectorTurn ||
        card != CardIntent.none ||
        surface.isSurface ||
        skills.isNotEmpty;
    final tracks = hasTrackWork
        ? ResponseTrackPlan.forTurn(
            hasSkillWork: skills.isNotEmpty || shouldSearch || projectorTurn,
            surface: surface,
          )
        : ResponseTrackPlan.none;

    // ── Phase-2 acknowledgement (i18n key; null = none) ──
    String? ack;
    if ((wouldSearch || wantsAppletDiscovery) && !ctx.online) {
      ack = 'policy.ack_offline';
    } else if (shouldSearch) {
      ack = 'policy.ack_search';
    } else if (shouldSearchApplets) {
      ack = 'policy.ack_applet_search';
    } else if (card == CardIntent.interactive) {
      ack = 'policy.ack_card';
    }

    final reason = <String>[
      if (saidNoSearch) 'no_search',
      if (searchHinted) 'search_hint',
      if (searchKw) 'search_kw',
      if (wantsAppletDiscovery && !ctx.online) 'applet_search_offline',
      if (shouldSearchApplets) 'applet_search',
      if (wouldSearch && !ctx.online) 'offline',
      if (projectorTurn) 'projector',
      if (projectorSessionFollowUp) 'projector_session',
      if (projectorFollowUp) 'projector_followup',
      if (projectorOnlineImageFollowUp || projectorOnlineImageRequest)
        'projector_online_image',
      if (projectorImageSubjectFollowUp) 'projector_image_subject',
      if (appOperationIntent == AppOperationIntentKind.informationalWriting)
        'writing_advice',
      if (wantsAppControl) 'app_control',
      if (surface.isSurface) 'surface=${surface.kind.name}',
      if (card != CardIntent.none) 'card=${card.name}',
      if (requiresAwaitedSkillResult) 'awaited_skill',
      if (preferMultiStep) 'multistep',
      if (preferNativeTools) 'native',
    ].join(',');

    return TurnPolicy(
      shouldSearch: shouldSearch,
      shouldSearchApplets: shouldSearchApplets,
      card: card,
      shouldAskClarifying: false, // v1 conservative
      preferMultiStep: preferMultiStep,
      preferNativeTools: preferNativeTools,
      preferredSkills: skills,
      projectorMedia: ctx.projectorMedia,
      surface: surface,
      tracks: tracks,
      acknowledgement: ack,
      reason: reason,
    );
  }

  static bool _any(String haystack, List<String> needles) {
    for (final n in needles) {
      if (haystack.contains(n)) return true;
    }
    return false;
  }
}
