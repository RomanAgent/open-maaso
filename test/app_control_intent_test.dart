import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/app_control_intent.dart';

void main() {
  group('classifyAppOperationIntent', () {
    test('freeform creation features are not existing page commands', () {
      for (final prompt in const <String>[
        '生成一个底下有个杠，球会掉下来然后弹上去的小游戏',
        '生成一个可触摸的弹球小游戏，需要设置球的速度',
        '生成一个小游戏，确认后可以开始，失败后返回菜单',
        '生成一个小游戏，敌人被击中后删除，回到起点重新开始',
        '生成一个有二级导航的小程序，点击设置可以进入设置页并返回首页',
        'Create an arbitrary bouncing ball game with a bottom paddle',
      ]) {
        expect(
          classifyAppOperationIntent(prompt),
          AppOperationIntentKind.none,
          reason: prompt,
        );
        expect(looksLikeAppControlIntent(prompt), isFalse, reason: prompt);
      }
    });

    test('existing page navigation remains an app operation', () {
      for (final prompt in const <String>[
        '去小游戏频道',
        '打开小程序频道',
        '不要生成小游戏，回到home页面',
      ]) {
        expect(
          classifyAppOperationIntent(prompt),
          AppOperationIntentKind.navigation,
          reason: prompt,
        );
      }
    });

    test('separates natural writing, community posts, and writing advice', () {
      expect(
        classifyAppOperationIntent('帮我写一篇关于 AI Agent 的文章'),
        AppOperationIntentKind.editorialWriting,
      );
      expect(
        classifyAppOperationIntent('打开 Agent Feed 的讨论社区帮我写一篇A股的帖子。'),
        AppOperationIntentKind.editorialWriting,
      );
      expect(
        classifyAppOperationIntent('写一篇文章的步骤是什么？'),
        AppOperationIntentKind.informationalWriting,
      );
    });
  });

  group('looksLikeAppControlIntent', () {
    test('retired community requests do not trigger app controls', () {
      expect(
        looksLikeAppControlIntent('打开 Agent Feed 的讨论社区帮我写一篇A股的帖子。'),
        isFalse,
      );
    });

    test('recognizes destination navigation and visible page actions', () {
      expect(looksLikeAppControlIntent('打开设置页面'), isTrue);
      expect(looksLikeAppControlIntent('让agent帮我发个帖子'), isFalse);
      expect(looksLikeAppControlIntent('navigate to the skills page'), isTrue);
    });

    test('does not claim ordinary editorial writing or conversation', () {
      for (final prompt in <String>[
        '帮我写一篇关于 AI Agent 的文章',
        '帮我起标题、列大纲并写正文',
        '写一篇A股分析并放进创作页面',
        '调用 Creator.prepareEditorialWriting，打开 Creator Studio 并填写',
      ]) {
        expect(looksLikeAppControlIntent(prompt), isFalse, reason: prompt);
      }
      expect(looksLikeAppControlIntent('帮我写一个排序算法'), isFalse);
      expect(looksLikeAppControlIntent('聊聊今天的心情'), isFalse);
    });
  });
}
