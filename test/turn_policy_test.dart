import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/projector_media_session.dart';
import 'package:maaso/src/features/agent/application/response_track_plan.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';

void main() {
  group('TurnPolicy value object', () {
    test('neutral has no actions and an empty promptBlock', () {
      const p = TurnPolicy.neutral;
      expect(p.shouldSearch, isFalse);
      expect(p.card, CardIntent.none);
      expect(p.preferMultiStep, isFalse);
      expect(p.preferNativeTools, isFalse);
      expect(p.acknowledgement, isNull);
      expect(p.promptBlock, isEmpty);
    });

    test('promptBlock summarizes only the active dimensions', () {
      const search = TurnPolicy(shouldSearch: true);
      expect(search.promptBlockFor(AppLocale.en), contains('WebSearch'));

      const surface = TurnPolicy(card: CardIntent.interactive);
      expect(surface.promptBlockFor(AppLocale.en), contains('FreeformSurface'));

      const game = TurnPolicy(
        card: CardIntent.interactive,
        surface: SurfaceIntent(kind: SurfaceIntentKind.game),
      );
      final gamePromptEn = game.promptBlockFor(AppLocale.en);
      final gamePromptZh = game.promptBlockFor(AppLocale.zh);
      expect(gamePromptEn, contains('fullscreen'));
      expect(gamePromptEn, contains('webApp'));
      expect(
        gamePromptEn,
        contains(
          'external assets, libraries and network dependencies are permitted',
        ),
      );
      expect(gamePromptEn, contains('menus, intros and secondary views'));
      expect(gamePromptEn, contains('workerCanvas'));
      expect(gamePromptEn, contains('Game.define'));
      expect(
        gamePromptEn,
        isNot(contains('first screen immediately playable')),
      );
      expect(gamePromptEn, isNot(contains('public-safe webApp')));
      expect(gamePromptZh, contains('fullscreen'));
      expect(gamePromptZh, contains('webApp'));
      expect(gamePromptZh, contains('外部资源、库和网络依赖'));
      expect(gamePromptZh, contains('菜单、剧情开场和二级页面'));
      expect(gamePromptZh, contains('workerCanvas'));
      expect(gamePromptZh, contains('Game.define'));
      expect(gamePromptZh, isNot(contains('首屏必须直接可玩')));

      const setup = TurnPolicy(card: CardIntent.setup);
      expect(setup.promptBlockFor(AppLocale.en), contains('ShowCard'));

      const tracked = TurnPolicy(
        tracks: ResponseTrackPlan(expression: true, voice: true, skill: true),
      );
      expect(
        tracked.promptBlockFor(AppLocale.en),
        contains('tracks=expression,voice,skill'),
      );
    });

    test('promptBlock uses one explicit locale without mixed fixed prose', () {
      const policy = TurnPolicy(
        shouldSearch: true,
        card: CardIntent.setup,
        shouldAskClarifying: true,
      );

      final zh = policy.promptBlockFor(AppLocale.zh);
      expect(zh, contains('需要核实当前事实'));
      expect(zh, contains('澄清问题'));
      expect(zh, isNot(contains('Verify current facts')));
      expect(zh, contains('不得猜测位置'));
      final en = policy.promptBlockFor(AppLocale.en);
      expect(en, contains('Verify current facts'));
      expect(en, contains('never invent location access'));
      expect(en, isNot(contains('需要核实当前事实')));
    });
  });

  group('TurnPolicyEngine.decide', () {
    final engine = TurnPolicyEngine(agentId: 'self');

    RoutingDecision routing({
      LocalIntent intent = LocalIntent.knowledge,
      RouteComplexity complexity = RouteComplexity.medium,
      List<String> tools = const [],
    }) => RoutingDecision(
      intent: intent,
      confidence: 0.8,
      emotionPreemit: 'neutral',
      complexity: complexity,
      needsTools: tools,
    );

    test('web_search hint → shouldSearch + ack_search when online', () {
      final p = engine.decide(
        TurnContext(
          userText: 'who won the game',
          routing: routing(tools: ['web_search']),
          online: true,
        ),
      );
      expect(p.shouldSearch, isTrue);
      expect(p.acknowledgement, 'policy.ack_search');
      expect(p.preferredSkills, contains('WebSearch'));
    });

    test('recency keyword triggers search even with null routing', () {
      final p = engine.decide(const TurnContext(userText: '北京今天天气怎么样'));
      expect(p.shouldSearch, isTrue);
    });

    test('offline suppresses search and yields ack_offline', () {
      final p = engine.decide(
        TurnContext(
          userText: 'latest news on the election',
          routing: routing(tools: ['web_search']),
          online: false,
        ),
      );
      expect(p.shouldSearch, isFalse);
      expect(p.acknowledgement, 'policy.ack_offline');
    });

    test('explicit "do not search" disables search', () {
      final p = engine.decide(
        const TurnContext(userText: '别联网，就用你知道的告诉我最新情况', online: true),
      );
      expect(p.shouldSearch, isFalse);
    });

    test('plain emotional turn does not search or open a surface', () {
      final p = engine.decide(
        TurnContext(
          userText: '我今天好累，心情不好',
          routing: routing(
            intent: LocalIntent.chitchat,
            complexity: RouteComplexity.simple,
          ),
        ),
      );
      expect(p.shouldSearch, isFalse);
      expect(p.card, CardIntent.none);
      expect(p.acknowledgement, isNull);
      expect(p.promptBlock, isEmpty);
    });

    test(
      'explicit page-control requests deterministically prefer AppControl',
      () {
        for (final prompt in <String>['打开设置页面']) {
          final policy = engine.decide(TurnContext(userText: prompt));
          expect(
            policy.preferredSkills,
            contains('AppControl'),
            reason: prompt,
          );
          expect(policy.reason, contains('app_control'), reason: prompt);
        }
      },
    );

    test('ordinary writing stays in conversation after Creator retirement', () {
      for (final prompt in <String>[
        '帮我写一篇关于 AI Agent 的文章',
        '帮我起标题、列大纲并写正文',
        '写一篇A股分析并放进创作页面',
        '帮我写一篇公众号文章',
      ]) {
        final policy = engine.decide(TurnContext(userText: prompt));
        expect(
          policy.preferredSkills,
          isNot(contains('Creator')),
          reason: prompt,
        );
        expect(
          policy.preferredSkills,
          isNot(contains('AppControl')),
          reason: prompt,
        );
        expect(
          policy.preferredSkills,
          isNot(contains('FreeformSurface')),
          reason: prompt,
        );
        expect(policy.surface, SurfaceIntent.none, reason: prompt);
        expect(
          policy.reason,
          isNot(contains('creator_editorial')),
          reason: prompt,
        );
      }
    });

    test('informational writing questions do not trigger page control', () {
      for (final prompt in <String>[
        '写一篇文章要多久？',
        '写一篇文章的步骤是什么？',
        '写一篇文章用什么软件？',
      ]) {
        final policy = engine.decide(TurnContext(userText: prompt));
        expect(
          policy.preferredSkills,
          isNot(contains('Creator')),
          reason: prompt,
        );
        expect(
          policy.preferredSkills,
          isNot(contains('AppControl')),
          reason: prompt,
        );
        expect(
          policy.preferredSkills,
          isNot(contains('FreeformSurface')),
          reason: prompt,
        );
        expect(policy.surface, SurfaceIntent.none, reason: prompt);
      }
    });

    test(
      'freeform hint without explicit mini app request grants no creation',
      () {
        final p = engine.decide(
          TurnContext(
            userText: 'make this into a list',
            routing: routing(tools: ['freeform_surface']),
          ),
        );
        expect(p.card, CardIntent.none);
        expect(p.acknowledgement, isNull);
        expect(p.preferredSkills, isNot(contains('FreeformSurface')));
        expect(p.preferredSkills, isNot(contains('CardControl')));
      },
    );

    test('setup words route to ShowCard, not FreeformSurface', () {
      final p = engine.decide(
        const TurnContext(userText: 'let me set my api key'),
      );
      expect(p.card, CardIntent.setup);
      expect(p.preferredSkills, contains('ShowCard'));
      expect(p.preferredSkills, isNot(contains('FreeformSurface')));
    });

    test('an open surface biases an interactive turn to editing it', () {
      final p = engine.decide(
        const TurnContext(userText: '再加一行', hasOpenSurface: true),
      );
      expect(p.card, CardIntent.interactive);
      expect(p.preferredSkills, contains('FreeformSurface'));
    });

    test(
      'projector connect bypasses open surfaces and waits for async skills',
      () {
        final p = engine.decide(
          TurnContext(
            userText: 'connect projector',
            routing: routing(tools: ['freeform_surface']),
            hasOpenSurface: true,
            autoPlanEnabled: false,
          ),
        );

        expect(p.card, CardIntent.none);
        expect(p.preferMultiStep, isTrue);
        expect(p.preferredSkills, containsAll(['BleYoturetoys', 'Bluetooth']));
        expect(p.preferredSkills, isNot(contains('FreeformSurface')));
        expect(p.preferredSkills, isNot(contains('CardControl')));
      },
    );

    test('projector gallery follow-up suppresses surface routing', () {
      const recentConversation = '''
USER: connect projector
AGENT: Connected. Want to use a photo from your gallery or find one online to project?
''';
      final p = engine.decide(
        TurnContext(
          userText: 'photo from gallery',
          routing: routing(tools: ['freeform_surface']),
          recentConversation: recentConversation,
        ),
      );

      expect(p.card, CardIntent.none);
      expect(p.preferredSkills, containsAll(['BleYoturetoys', 'Bluetooth']));
      expect(p.preferredSkills, isNot(contains('FreeformSurface')));
      expect(p.preferredSkills, isNot(contains('CardControl')));
    });

    test('projector online image follow-up searches and projects', () {
      const recentConversation = '''
USER: 连接投影仪
AGENT: 已连接。你想从相册选择照片，还是让我从网上找一张图片投影？
''';
      final p = engine.decide(
        TurnContext(
          userText: '帮我找一张小狗的图片',
          routing: routing(tools: ['freeform_surface']),
          recentConversation: recentConversation,
          online: true,
        ),
      );

      expect(p.card, CardIntent.none);
      expect(p.shouldSearch, isTrue);
      expect(
        p.preferredSkills,
        containsAll(['WebSearch', 'BleYoturetoys', 'Bluetooth']),
      );
      expect(p.acknowledgement, 'policy.ack_search');
    });

    test('projector bare subject follow-up searches instead of chatting', () {
      const recentConversation = '''
USER: connect projector
AGENT: Got it, the projector's connected! Do you want to use a photo from your gallery, or should I find one online to project?
''';
      final p = engine.decide(
        TurnContext(
          userText: 'silly cat',
          routing: routing(intent: LocalIntent.chitchat),
          recentConversation: recentConversation,
          online: true,
        ),
      );

      expect(p.card, CardIntent.none);
      expect(p.shouldSearch, isTrue);
      expect(
        p.preferredSkills,
        containsAll(['WebSearch', 'BleYoturetoys', 'Bluetooth']),
      );
      expect(p.reason, contains('projector_image_subject'));
    });

    test('projector question does not steal an ordinary speech command', () {
      const recentConversation = '''
USER: connect projector
AGENT: Connected. Want a photo from your gallery or should I find one online?
''';
      final p = engine.decide(
        TurnContext(
          userText: 'say hello',
          routing: routing(intent: LocalIntent.chitchat),
          recentConversation: recentConversation,
          online: true,
        ),
      );

      expect(p.shouldSearch, isFalse);
      expect(p.preferredSkills, isNot(contains('WebSearch')));
      expect(p.preferredSkills, isNot(contains('BleYoturetoys')));
      expect(p.reason, isNot(contains('projector')));
    });

    test('older projector question cannot contaminate a later topic', () {
      const recentConversation = '''
USER: connect projector
AGENT: Connected. Want a photo from your gallery or should I find one online?
USER: tell me a joke
AGENT: Why did the robot cross the road? To recharge on the other side.
''';
      final p = engine.decide(
        TurnContext(
          userText: 'silly cat',
          routing: routing(intent: LocalIntent.chitchat),
          recentConversation: recentConversation,
          online: true,
        ),
      );

      expect(p.shouldSearch, isFalse);
      expect(p.preferredSkills, isNot(contains('BleYoturetoys')));
      expect(p.reason, isNot(contains('projector')));
    });

    test(
      'projector media session routes bare subject without conversation',
      () {
        final p = engine.decide(
          TurnContext(
            userText: 'silly cat',
            routing: routing(intent: LocalIntent.chitchat),
            online: true,
            projectorMedia: const ProjectorMediaResolution(
              kind: ProjectorMediaResolutionKind.onlineImage,
              imageQuery: 'silly cat',
              reason: 'bare_subject',
            ),
          ),
        );

        expect(p.card, CardIntent.none);
        expect(p.shouldSearch, isTrue);
        expect(p.preferredSkills, containsAll(['WebSearch', 'BleYoturetoys']));
        expect(p.projectorMedia.imageQuery, 'silly cat');
        expect(p.tracks.skill, isTrue);
        expect(p.tracks.surface, isFalse);
        expect(
          p.promptBlock,
          contains('skill_bleyoturetoys_projectortransferimage'),
        );
      },
    );

    test(
      'travel planning searches reusable mini apps instead of creating one',
      () {
        final p = engine.decide(
          TurnContext(
            userText: 'make me a Kyoto travel guide',
            routing: routing(
              intent: LocalIntent.task,
              tools: ['freeform_surface'],
            ),
            online: true,
          ),
        );

        expect(p.surface.kind, SurfaceIntentKind.none);
        expect(p.card, CardIntent.none);
        expect(p.shouldSearchApplets, isTrue);
        expect(p.preferredSkills, contains('AppletDiscovery'));
        expect(p.preferredSkills, isNot(contains('FreeformSurface')));
        expect(p.tracks.skill, isTrue);
        expect(p.tracks.surface, isFalse);
        expect(p.reason, contains('applet_search'));
        expect(p.promptBlock, contains('AppletDiscovery'));
      },
    );

    test('game intent uses FreeformSurface instead of legacy PlayableGame', () {
      final p = engine.decide(
        TurnContext(
          userText: 'make me an Aippy-like mini game',
          routing: routing(
            intent: LocalIntent.task,
            tools: ['freeform_surface'],
          ),
          online: true,
        ),
      );

      expect(p.surface.kind, SurfaceIntentKind.game);
      expect(p.card, CardIntent.interactive);
      expect(p.preferredSkills, contains('FreeformSurface'));
      expect(p.preferredSkills, isNot(contains('Artifact')));
      expect(p.preferredSkills, isNot(contains('PlayableGame')));
      expect(p.preferredSkills, isNot(contains('CardControl')));
      expect(p.tracks.skill, isTrue);
      expect(p.tracks.surface, isTrue);
    });

    test('freeform game rules do not become navigation or setup tasks', () {
      for (final prompt in const <String>[
        '生成一个底下有个杠，球会掉下来然后弹上去的小游戏',
        '生成一个可触摸的弹球小游戏，需要设置球的速度',
        '生成一个小游戏，确认后可以开始，失败后返回菜单',
        '生成一个小游戏，敌人被击中后删除，回到起点重新开始',
        '生成一个小游戏，点击按钮能切换到第二关和设置页面',
        'Create an arbitrary bouncing ball game with a bottom paddle',
      ]) {
        final p = engine.decide(TurnContext(userText: prompt));
        expect(p.card, CardIntent.interactive, reason: prompt);
        expect(p.surface.kind, SurfaceIntentKind.game, reason: prompt);
        expect(p.preferredSkills, contains('FreeformSurface'), reason: prompt);
        expect(
          p.preferredSkills,
          isNot(contains('AppControl')),
          reason: prompt,
        );
        expect(p.preferredSkills, isNot(contains('ShowCard')), reason: prompt);
        expect(p.tracks.surface, isTrue, reason: prompt);
      }
    });

    test('arbitrary applet secondary navigation is generated content', () {
      for (final prompt in const <String>[
        '生成一个有二级导航的小程序，点击设置可以进入设置页并返回首页',
        '生成一个小程序，球会掉下来然后弹上去',
        '创建一个带二级详情的小程序，返回菜单时保留用户填写的内容',
      ]) {
        final p = engine.decide(TurnContext(userText: prompt));
        expect(p.card, CardIntent.interactive, reason: prompt);
        expect(p.surface.kind, SurfaceIntentKind.applet, reason: prompt);
        expect(p.preferredSkills, contains('FreeformSurface'), reason: prompt);
        expect(
          p.preferredSkills,
          isNot(contains('AppControl')),
          reason: prompt,
        );
        expect(p.preferredSkills, isNot(contains('ShowCard')), reason: prompt);
      }
    });

    test('navigation discussion and rejected creation have no new surface', () {
      for (final prompt in const <String>[
        '去小游戏频道',
        '不要生成小游戏，回到home页面',
        '解释如何做一个小游戏',
        '制作这个小游戏需要注意什么？',
        '生成一个小游戏，但不要保存',
        '帮我发帖介绍这个小游戏',
        'let me set my api key',
      ]) {
        final p = engine.decide(TurnContext(userText: prompt));
        expect(p.card, isNot(CardIntent.interactive), reason: prompt);
        expect(p.surface.kind, SurfaceIntentKind.none, reason: prompt);
        expect(
          p.preferredSkills,
          isNot(contains('FreeformSurface')),
          reason: prompt,
        );
      }
    });

    test('preferMultiStep needs positive non-trivial evidence + autoPlan', () {
      expect(
        engine
            .decide(
              TurnContext(
                userText: 'plan my move to a new city',
                routing: routing(
                  intent: LocalIntent.task,
                  complexity: RouteComplexity.complex,
                ),
                autoPlanEnabled: true,
              ),
            )
            .preferMultiStep,
        isTrue,
      );
      // chitchat never escalates
      expect(
        engine
            .decide(
              TurnContext(
                userText: 'hi there',
                routing: routing(
                  intent: LocalIntent.chitchat,
                  complexity: RouteComplexity.simple,
                ),
                autoPlanEnabled: true,
              ),
            )
            .preferMultiStep,
        isFalse,
      );
      // autoPlan off → no multi-step unless forced
      expect(
        engine
            .decide(
              TurnContext(
                userText: 'plan my move',
                routing: routing(
                  intent: LocalIntent.task,
                  complexity: RouteComplexity.complex,
                ),
                autoPlanEnabled: false,
              ),
            )
            .preferMultiStep,
        isFalse,
      );
      // forcedPlan overrides
      expect(
        engine
            .decide(
              const TurnContext(userText: '[PLAN MODE] x', forcedPlan: true),
            )
            .preferMultiStep,
        isTrue,
      );
    });

    test(
      'preferNativeTools only when enabled, not multi-step, brain supports it',
      () {
        final p = engine.decide(
          TurnContext(
            userText: 'what is the capital of France',
            routing: routing(
              intent: LocalIntent.knowledge,
              complexity: RouteComplexity.simple,
            ),
            nativeToolsEnabled: true,
            brainHasNativeTools: true,
            autoPlanEnabled: true, // simple → not multi-step
          ),
        );
        expect(p.preferNativeTools, isTrue);
      },
    );

    test('a surface turn does not escalate to multi-step unless forced', () {
      // Non-trivial task that is ALSO a generated surface stays single-shot.
      final surfaceTurn = engine.decide(
        TurnContext(
          userText: 'make me a mini app with a blog about my cat',
          routing: routing(
            intent: LocalIntent.task,
            complexity: RouteComplexity.complex,
            tools: ['freeform_surface'],
          ),
          autoPlanEnabled: true,
        ),
      );
      expect(surfaceTurn.card, CardIntent.interactive);
      expect(surfaceTurn.preferredSkills, contains('FreeformSurface'));
      expect(
        surfaceTurn.preferMultiStep,
        isFalse,
        reason: 'building one surface is not a think-act-observe task',
      );

      // Explicit plan mode still forces multi-step, even for a surface.
      final forcedSurface = engine.decide(
        TurnContext(
          userText: '[PLAN MODE] make me a blog',
          routing: routing(tools: ['freeform_surface']),
          forcedPlan: true,
        ),
      );
      expect(forcedSurface.preferMultiStep, isTrue);
    });
  });
}
