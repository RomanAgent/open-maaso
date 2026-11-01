import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

void main() {
  test(
    'an independent creation clause follows a leading question or preference',
    () {
      for (final request in const [
        '你喜欢玩什么游戏，帮我做一个出来',
        '你喜欢什么游戏？帮我做一个触屏小游戏',
        '我想试试你推荐的玩法，生成一个可以用手指控制的小程序',
        'What game would you recommend? Please create a playable mini game',
        'I enjoy space themes, build a useful mini app',
        'If you have time, please create a playable mini game',
        '如果你方便，帮我做一个触屏小游戏',
      ]) {
        expect(
          SurfaceCreationAuthority.canResolveCreation(request),
          isTrue,
          reason: request,
        );
      }
      expect(_typeFor('你喜欢什么游戏？帮我做一个触屏小游戏'), SurfaceExperienceType.game);
      expect(
        _typeFor(
          'What game would you recommend? Please create a playable mini game',
        ),
        SurfaceExperienceType.game,
      );
      expect(
        _typeFor('I enjoy space themes, build a useful mini app'),
        SurfaceExperienceType.utility,
      );
    },
  );

  test(
    'mixed-message commands never come from quotes, examples or refusals',
    () {
      for (final request in const [
        '你喜欢什么游戏，只讨论一下',
        '你喜欢什么游戏，帮我做一个小游戏需要多久？',
        '你喜欢什么游戏，帮我做一个小游戏还是玩现成的更好？',
        '你喜欢什么游戏，帮我做一个小游戏的方案',
        '你喜欢什么游戏，帮我做一个出来，只给方案',
        '你喜欢什么游戏，帮我做一个小游戏，但不要保存',
        '你喜欢什么游戏，帮我做一个小游戏，先别展示',
        '你喜欢什么游戏，不要帮我做一个小游戏',
        '翻译这句话：你喜欢什么游戏，帮我做一个出来',
        '他说，你喜欢什么游戏，帮我做一个出来',
        '例如：你喜欢什么游戏，帮我做一个出来',
        '如果用户说，帮我做一个小游戏，应该怎么回复？',
        '假如我说，帮我做一个小游戏，你会怎么处理',
        '如果有人要求，帮我做一个小游戏，应该收费多少？',
        '只讨论实现方案，帮我做一个小游戏',
        '你喜欢什么游戏，帮我写一篇关于这个游戏的文章',
        '你喜欢什么游戏，“帮我做一个小游戏”',
        '“你喜欢什么游戏，帮我做一个小游戏”',
        '你喜欢什么游戏，「帮我做一个小游戏」',
        '你喜欢什么游戏，`帮我做一个小游戏`',
        '你喜欢什么游戏，“没结束的引号，帮我做一个小游戏',
        r'"引用中有转义\"，帮我做一个小游戏"',
        r'{"content":"你喜欢什么游戏，帮我做一个小游戏"}',
        'Translate this sentence: what do you prefer, please build a mini game',
        'For example, please build a mini game',
        'If a user says, please build a mini game, how should you respond?',
        'When someone asks, create a mini game, what would it cost?',
        'What game do you prefer? Write a tutorial about it',
        'What does this phrase mean, please build a mini game',
        'What game do you like? "Please make a mini game"',
        "What game do you like? 'Please make a mini game'",
        'What game do you like? `Please make a mini game`',
        'What game do you like? Please make a mini game, only give me a plan',
        "What game do you like? Please make a mini game but don't open it",
      ]) {
        expect(
          SurfaceCreationAuthority.canResolveCreation(request),
          isFalse,
          reason: request,
        );
        final type = SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.game,
        );
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: request,
            interactiveHint: true,
            surfaceIntent: type,
          ),
          isNull,
          reason: request,
        );
      }
    },
  );

  test('explicit applet and game creation produce a typed authority', () {
    expect(_typeFor('创建一个能玩的五子棋小游戏'), SurfaceExperienceType.game);
    expect(_typeFor('生成五子棋小游戏'), SurfaceExperienceType.game);
    expect(_typeFor('新建并生成一个俄罗斯方块小游戏'), SurfaceExperienceType.game);
    expect(_typeFor('build a useful mini app'), SurfaceExperienceType.utility);
    expect(
      _typeFor('please create a travel planning mini app'),
      SurfaceExperienceType.utility,
    );
    expect(_typeFor('帮我生成一个京都旅行规划小程序'), SurfaceExperienceType.utility);
    expect(_typeFor('生成一个有用的旅行小程序'), SurfaceExperienceType.utility);
  });

  test('ordinary utility content never authorizes new mini app creation', () {
    for (final request in const <String>[
      '帮我做个京都旅行攻略',
      '写一篇关于京都的文章',
      'show me a stats dashboard',
      'build me a floating canvas animation',
      'visualize this data as a chart',
      'show me a travel mini app',
      'present a travel mini app',
      'create an itinerary using a travel mini app',
      'write an article about this mini app',
      '生成一个行程，使用旅行小程序',
      '创建一个计划用现有旅行小程序',
    ]) {
      expect(_typeFor(request), isNull, reason: request);
    }
  });

  test('hint-only content nouns and an open-surface hint grant nothing', () {
    for (final request in const <String>[
      '什么是小游戏',
      '告诉我博客是什么',
      'explain dashboards',
      'What makes a good dashboard?',
      'How do I write an article?',
      'Can you explain how to make a dashboard?',
      'Tell me how to create a mini app',
      '告诉我怎么设计一个看板',
      '写一篇文章要多久？',
      '制作这个小游戏需要注意什么？',
      '写一篇文章的步骤是什么？',
      '制作小游戏的成本是多少？',
      '写一篇文章用什么软件？',
      '制作小游戏从哪里开始？',
      '设计看板难不难？',
      'Build a mini app or a website—which is cheaper?',
      'Create a dashboard or use a spreadsheet—which is better?',
      'Could you create a dashboard or use a spreadsheet—which is better?',
      '请帮我创建一个看板还是用表格更好？',
      'Could you create a dashboard or use a spreadsheet—which is better',
      '请帮我创建一个看板还是用表格更好',
      'tell me a joke',
    ]) {
      expect(_typeFor(request), isNull, reason: request);
    }
  });

  test('negated creation never becomes authority despite card cues', () {
    for (final request in const <String>[
      '不要生成小程序，只解释概念',
      '别做一个小游戏，说说规则',
      "don't generate a mini app; explain it",
      'do not make me a dashboard',
      "Create a dashboard but don't save it",
      '生成一个小游戏，但不要保存',
      "Create a dashboard but don't show it",
      "Build a mini app but don't open it",
      '创建一个看板，但不要展示',
      '生成一个小游戏，先别打开',
    ]) {
      expect(_typeFor(request), isNull, reason: request);
    }
  });

  test('a non-interactive policy hint cannot authorize creation', () {
    expect(
      SurfaceCreationAuthority.experienceTypeFor(
        text: 'build a stats dashboard',
        interactiveHint: false,
        surfaceIntent: SurfaceIntent.classify('build a stats dashboard'),
      ),
      isNull,
    );
  });

  test('polite explicit requests remain authorized', () {
    expect(_typeFor('Could you build me a stats dashboard?'), isNull);
    expect(
      _typeFor('Can you create a playable mini game?'),
      SurfaceExperienceType.game,
    );
    expect(_typeFor('可以帮我创建一个看板吗？'), isNull);
    expect(_typeFor('可以创建一个看板吗'), isNull);
    expect(_typeFor('可以帮我创建一个旅行小程序吗？'), SurfaceExperienceType.utility);
    expect(_typeFor('能不能创建小游戏'), SurfaceExperienceType.game);
    expect(_typeFor('可以创建小游戏吗'), SurfaceExperienceType.game);
  });
}

SurfaceExperienceType? _typeFor(String text) =>
    SurfaceCreationAuthority.experienceTypeFor(
      text: text,
      interactiveHint: true,
      surfaceIntent: SurfaceIntent.classify(text),
    );
