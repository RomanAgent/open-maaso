import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/features/applets/domain/applet_request_intent.dart';

void main() {
  test('creation type follows the requested product, not feature keywords', () {
    for (final entry in const <String, AppletContentType>{
      '生成一个记录游戏分数的小程序，这个页面可以清空记录并返回首页': AppletContentType.applet,
      '可以帮我做一个记录游戏分数的小程序吗': AppletContentType.applet,
      '生成一个小程序，包含小游戏页面和记录页': AppletContentType.applet,
      'Create a game-score tracking mini app': AppletContentType.applet,
      'Build a mini app with game scores and settings':
          AppletContentType.applet,
      '生成一个小程序里可玩的小游戏': AppletContentType.game,
      '生成一个小游戏，里面有小程序式设置页': AppletContentType.game,
      'Create a mini game with applet-style settings': AppletContentType.game,
    }.entries) {
      final intent = AppletRequestIntent.classify(entry.key);
      expect(intent.kind, AppletRequestKind.create, reason: entry.key);
      expect(intent.contentType, entry.value, reason: entry.key);
      final surface = SurfaceIntent.classify(entry.key);
      expect(
        SurfaceCreationAuthority.experienceTypeFor(
          text: entry.key,
          interactiveHint: true,
          surfaceIntent: surface,
        ),
        entry.value == AppletContentType.game
            ? SurfaceExperienceType.game
            : SurfaceExperienceType.utility,
        reason: entry.key,
      );
    }
  });

  test('explicit build language creates an Applet production intent', () {
    final game = AppletRequestIntent.classify('跟 Agent 说我要生成一个跑酷小游戏');
    final applet = AppletRequestIntent.classify('帮我做一个旅行记账小程序');

    expect(game.kind, AppletRequestKind.create);
    expect(game.contentType, AppletContentType.game);
    expect(applet.kind, AppletRequestKind.create);
    expect(applet.contentType, AppletContentType.applet);
    expect(
      SurfaceIntent.classify('跟 Agent 说我要生成一个跑酷小游戏').kind,
      SurfaceIntentKind.game,
    );
  });

  test('named game creation keeps one typed intent across routing', () {
    for (final text in const <String>[
      '生成五子棋小游戏',
      '创建俄罗斯方块游戏',
      '制作贪吃蛇小游戏',
      '开发数独小游戏',
    ]) {
      final intent = AppletRequestIntent.classify(text);

      expect(intent.kind, AppletRequestKind.create, reason: text);
      expect(intent.contentType, AppletContentType.game, reason: text);
      expect(SurfaceIntent.classify(text).kind, SurfaceIntentKind.game);
    }

    final applet = AppletRequestIntent.classify('生成一个旅行记账小程序');
    expect(applet.kind, AppletRequestKind.create);
    expect(applet.contentType, AppletContentType.applet);
    expect(
      SurfaceIntent.classify('生成一个旅行记账小程序').kind,
      SurfaceIntentKind.applet,
    );
  });

  test(
    'arbitrary game names retain explicit creation through intent, policy and authority',
    () {
      for (final text in const [
        '生成魂斗罗小游戏',
        '帮我写一个魂斗罗小游戏',
        '写一个原创小游戏',
        '做魂斗罗小游戏',
        'Create a Contra game with a tutorial',
        'Write a game with a tutorial about the game',
        'Write a game with instructions for the game',
        '生成一个魂斗罗小游戏带说明',
        '制作一个魂斗罗小游戏带新手教程',
        '生成一个魂斗罗小游戏有完整说明',
        '制作一个魂斗罗小游戏要包含操作说明',
        '创建植物大战僵尸小游戏',
        '制作水下遗迹探索游戏',
        '开发赛博朋克横版闯关小游戏',
        '请生成一款公司经营小游戏',
        '生成《魂斗罗》小游戏',
        '生成网页跑酷小游戏，支持重开和触屏',
        '生成太空沙盒小游戏需要支持多个关卡',
        'Generate Contra game',
        'Create Space defenders game',
        'Build Stardew-inspired mini-game',
        'Could you generate an underwater adventure game?',
      ]) {
        final intent = AppletRequestIntent.classify(text);
        expect(intent.kind, AppletRequestKind.create, reason: text);
        expect(intent.contentType, AppletContentType.game, reason: text);
        final surface = SurfaceIntent.classify(text);
        expect(surface.kind, SurfaceIntentKind.game, reason: text);
        final policy = TurnPolicyEngine(
          agentId: 'self',
        ).decide(TurnContext(userText: text));
        expect(policy.card, CardIntent.interactive, reason: text);
        expect(
          policy.preferredSkills,
          contains('FreeformSurface'),
          reason: text,
        );
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: text,
            interactiveHint: true,
            surfaceIntent: surface,
          ),
          SurfaceExperienceType.game,
          reason: text,
        );
      }
    },
  );

  test(
    'arbitrary names do not convert negation, quotations, descriptions or questions into creation authority',
    () {
      for (final text in const [
        '不要生成魂斗罗小游戏',
        '别创建植物大战僵尸小游戏',
        '生成魂斗罗小游戏但不要保存',
        '写一个魂斗罗游戏攻略',
        '帮我写一个魂斗罗游戏文章',
        '做一个魂斗罗游戏教程',
        'Write a Contra game guide',
        'Write a guide to Contra game',
        'Write an article about Contra game',
        'Please write a tutorial for Contra game',
        'Help me write a guide to Contra game',
        'I want you to write an article about Contra game',
        'Can you write game documentation?',
        'Write a plan for Contra game',
        'Write a manual for Contra game',
        'Write a walkthrough for Contra game',
        'Generate a review of a game-score tracking mini app',
        'Create a tutorial about a game-score tracking mini app',
        'Build a plan for an applet about games',
        '写一份关于魂斗罗小游戏的攻略',
        '设计魂斗罗小游戏，但不要设计，先只讨论',
        'Design a Contra game, but do not design it yet; just discuss',
        '如何生成魂斗罗小游戏？',
        '生成魂斗罗小游戏需要多久？',
        '生成魂斗罗小游戏还是直接玩哪个更好？',
        '生成器支持魂斗罗小游戏',
        '开发团队正在制作植物大战僵尸小游戏',
        '创建工具支持魂斗罗游戏',
        '制作公司演示太空跑酷小游戏',
        '生成模型输出的魂斗罗小游戏',
        '创建模式包含潜水探险游戏',
        '制作完成的云端植物小游戏',
        '他说“生成魂斗罗小游戏”',
        '“生成魂斗罗小游戏”',
        'Explain how to create Contra game',
        "don't generate Contra game",
        'Generate model outputs of Contra game',
        'Create mode includes Contra game',
      ]) {
        expect(
          AppletRequestIntent.classify(text),
          AppletRequestIntent.none,
          reason: text,
        );
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: text,
            interactiveHint: true,
            surfaceIntent: SurfaceIntent.classify(text),
          ),
          isNull,
          reason: text,
        );
      }
    },
  );

  test('negated Applet creation language fails closed', () {
    for (final text in <String>[
      '不要生成一个五子棋游戏，只告诉我规则',
      '别做一个五子棋游戏',
      "don't generate a Gomoku game",
      "don't make me a Gomoku game",
      '生成一个小游戏，但不要保存',
      '创建一个看板，但不要展示',
      "Create a mini game but don't save it",
      "Build a mini app but don't show it",
    ]) {
      expect(AppletRequestIntent.classify(text), AppletRequestIntent.none);
      expect(SurfaceIntent.classify(text), SurfaceIntent.none);
    }
  });

  test('positive English Applet creation remains explicit', () {
    final intent = AppletRequestIntent.classify(
      'Generate a playable Gomoku game',
    );
    final politeQuestion = AppletRequestIntent.classify(
      'Can you create a playable mini game?',
    );
    final politeChineseQuestion = AppletRequestIntent.classify('可以帮我做一个小游戏？');

    expect(intent.kind, AppletRequestKind.create);
    expect(intent.contentType, AppletContentType.game);
    expect(politeQuestion.kind, AppletRequestKind.create);
    expect(politeChineseQuestion.kind, AppletRequestKind.create);
    expect(
      SurfaceIntent.classify('Generate a playable Gomoku game').kind,
      SurfaceIntentKind.game,
    );
  });

  test('play and find language searches before generation', () {
    for (final text in <String>[
      '我想玩一个塔防小游戏',
      '找一个能练口算的小游戏',
      'show me a puzzle mini-game',
      'recommend an expense tracker applet',
    ]) {
      final intent = AppletRequestIntent.classify(text);
      expect(intent.kind, AppletRequestKind.discover, reason: text);
      expect(SurfaceIntent.classify(text).kind, SurfaceIntentKind.none);
    }
  });

  test('bare nouns do not silently search or generate', () {
    expect(AppletRequestIntent.classify('小游戏'), AppletRequestIntent.none);
    expect(AppletRequestIntent.classify('小程序'), AppletRequestIntent.none);
  });

  test('quality adjectives remain explicit Applet creation requests', () {
    for (final entry in const <(String, AppletContentType)>[
      ('帮我创建一个更好的小游戏', AppletContentType.game),
      ('做一个比较好玩的小游戏', AppletContentType.game),
      ('创建一个更适合儿童的小程序', AppletContentType.applet),
      ('Create a better mini game than the old one', AppletContentType.game),
      ('Build a safer mini app for my family', AppletContentType.applet),
    ]) {
      final intent = AppletRequestIntent.classify(entry.$1);

      expect(intent.kind, AppletRequestKind.create, reason: entry.$1);
      expect(intent.contentType, entry.$2, reason: entry.$1);
    }
  });

  test('informational and comparative Applet questions fail closed', () {
    for (final text in const <String>[
      'How do I create a mini game?',
      'Can you explain how to create a mini game?',
      'Tell me how to create a mini game.',
      'Is it better to make a mini app or a website?',
      'Could you create a mini game or play chess—which is better',
      'Is a mini game better than a mini app',
      '如何做一个小游戏？',
      '你能解释一下如何创建小游戏吗？',
      '告诉我怎么做一个小游戏。',
      '做一个小游戏还是做一个小程序更好？',
      '做一个小游戏还是小程序更好',
      '小游戏和小程序哪个更适合儿童',
      '做小游戏或者小程序怎么选',
      '做一个小游戏要多久？',
      '做一个小游戏需要注意什么？',
      '生成五子棋小游戏需要多久？',
      '生成五子棋小游戏还是直接玩哪个更好？',
      '开发者如何生成五子棋小游戏',
      '生成过的五子棋小游戏在哪里',
      '生成。你喜欢五子棋小游戏吗？',
      '生成器支持五子棋小游戏',
      '开发团队正在制作五子棋小游戏',
      '创建工具支持俄罗斯方块游戏',
      '制作公司演示贪吃蛇小游戏',
      '生成模型输出的五子棋小游戏',
      '创建模式包含俄罗斯方块游戏',
      '制作完成的贪吃蛇小游戏',
    ]) {
      expect(
        AppletRequestIntent.classify(text),
        AppletRequestIntent.none,
        reason: text,
      );
    }
  });

  test('turn policy selects AppletDiscovery for play intent', () {
    final policy = TurnPolicyEngine(
      agentId: 'self',
    ).decide(const TurnContext(userText: '我想玩一个合成类小游戏'));

    expect(policy.shouldSearchApplets, isTrue);
    expect(policy.card, CardIntent.none);
    expect(policy.preferredSkills, contains('AppletDiscovery'));
    expect(policy.preferredSkills, isNot(contains('FreeformSurface')));
    expect(policy.acknowledgement, 'policy.ack_applet_search');
    expect(policy.promptBlock, contains('AppletDiscovery'));
  });

  test('Applet discovery suppresses unrelated web-search cues', () {
    final policy = TurnPolicyEngine(
      agentId: 'self',
    ).decide(const TurnContext(userText: '找一个 AI 新闻小游戏'));

    expect(policy.shouldSearchApplets, isTrue);
    expect(policy.shouldSearch, isFalse);
    expect(policy.preferredSkills, contains('AppletDiscovery'));
    expect(policy.preferredSkills, isNot(contains('WebSearch')));
  });

  test('turn policy keeps explicit generation on guided FreeformSurface', () {
    final policy = TurnPolicyEngine(
      agentId: 'self',
    ).decide(const TurnContext(userText: '帮我生成一个太空跑酷小游戏'));

    expect(policy.shouldSearchApplets, isFalse);
    expect(policy.card, CardIntent.interactive);
    expect(policy.surface.kind, SurfaceIntentKind.game);
    expect(policy.preferredSkills, contains('FreeformSurface'));
    expect(policy.promptBlock, contains('name'));
    expect(policy.promptBlock, contains('goal/content'));
  });
}
