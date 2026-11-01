import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/intent/freeform_creation_resolver.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const request =
    '生成一个底下有条杠，球会掉下来然后杠必须要接住，上面有很多小方块，球接触小方块小方块就会消失掉，全部小方块消失掉即可进入下一关，小方块消掉的时候会掉下道具，可以让球分裂开来';

void main() {
  test(
    'accepted unnamed proposal supplies type data but cannot supply authority',
    () async {
      const authority = '制作一个可运行的互动作品，按照我刚刚确认的提案完整实现。';
      const brief = '我给你写一个底下挡板接球、消除上面方块的作品。用户确认：就做你说的那个。';
      final client = _Model('{"kind":"game"}');
      final result = await FreeformCreationResolver(client).resolve(
        authority,
        isCurrent: () => true,
        confirmedProjectRequirements: brief,
      );
      expect(result.kind, SurfaceIntentKind.game);
      expect(result.matchesResolvedRequest(authority), isTrue);
      expect(jsonDecode(client.calls.single.last.content), {
        'request': authority,
        'confirmedProjectRequirements': brief,
      });
      final ordinary = _Model('{"kind":"game"}');
      final denied = await FreeformCreationResolver(ordinary).resolve(
        '今天的天气如何',
        isCurrent: () => true,
        confirmedProjectRequirements: brief,
      );
      expect(denied.kind, SurfaceIntentKind.none);
      expect(ordinary.calls, isEmpty);
    },
  );
  test(
    'mixed freeform requests reach the model as the complete human brief',
    () async {
      for (final entry in const {
        '你喜欢玩什么游戏，帮我做一个出来': 'game',
        '你觉得怎样记账方便，帮我做一个可以添加支出、按分类汇总并删除记录的工具': 'utility',
        'What kind of game do you prefer? Please build one with touch controls':
            'game',
        'I keep losing track of bills, make a tool that groups expenses by month':
            'utility',
      }.entries) {
        expect(
          FreeformCreationResolver.needsResolution(entry.key),
          isTrue,
          reason: entry.key,
        );
        final client = _Model('{"kind":"${entry.value}"}');
        final result = await FreeformCreationResolver(
          client,
        ).resolve(entry.key, isCurrent: () => true);
        expect(
          result.kind,
          entry.value == 'game'
              ? SurfaceIntentKind.game
              : SurfaceIntentKind.applet,
        );
        expect(result.matchesResolvedRequest(entry.key), isTrue);
        expect(jsonDecode(client.calls.single.last.content), {
          'request': entry.key,
        });
      }
    },
  );

  test(
    'product instructions and game-score tools reach semantic resolution unchanged',
    () async {
      for (final entry in const {
        '生成一个球接杠的作品，附一段说明如何操作': 'game',
        'Build a draggable puzzle and include instructions that explain how to restart':
            'game',
        '生成一个记录游戏分数的工具，支持添加、修改和删除成绩': 'utility',
        'Build a score tracker for games with add, edit and delete controls':
            'utility',
      }.entries) {
        final client = _Model('{"kind":"${entry.value}"}');
        expect(
          FreeformCreationResolver.needsResolution(entry.key),
          isTrue,
          reason: entry.key,
        );
        final result = await FreeformCreationResolver(
          client,
        ).resolve(entry.key, isCurrent: () => true);
        expect(
          result.kind,
          entry.value == 'game'
              ? SurfaceIntentKind.game
              : SurfaceIntentKind.applet,
        );
        expect(jsonDecode(client.calls.single.last.content), {
          'request': entry.key,
        });
      }
    },
  );
  test(
    'freeform mechanics resolve without a product keyword or altered input',
    () async {
      final client = _Model('{"kind":"game"}');
      final result = await FreeformCreationResolver(
        client,
      ).resolve(request, isCurrent: () => true);
      expect(result.kind, SurfaceIntentKind.game);
      expect(result.matchesResolvedRequest(request), isTrue);
      expect(result.matchesResolvedRequest('生成另一个不同的作品'), isFalse);
      expect(client.calls, hasLength(1));
      expect(client.calls.single.map((m) => m.role), ['system', 'user']);
      expect(jsonDecode(client.calls.single.last.content), {
        'request': request,
      });
      expect(
        SurfaceCreationAuthority.experienceTypeFor(
          text: request,
          interactiveHint: true,
          surfaceIntent: result,
        )?.name,
        'game',
      );
    },
  );

  test('unnamed utility resolves without inventing a game name', () async {
    const text = '帮我做一个可以输入支出、记录分类和按月汇总的工具';
    final result = await FreeformCreationResolver(
      _Model('{"kind":"utility"}'),
    ).resolve(text, isCurrent: () => true);
    expect(result.kind, SurfaceIntentKind.applet);
    expect(result.matchesResolvedRequest(text), isTrue);
  });

  for (final text in [
    '重新生成一个新的',
    '再生成一次',
    '重试一下',
    'generate another version',
    '生成一个打砖块小游戏',
    '不要生成一个球接杠的作品',
    '如何生成一个球接杠的作品？',
    '生成一个球接杠的设计方案',
    '帮我翻译“生成一个球接杠的作品”',
    '他说生成一个球接杠的作品',
    '生成一个球接杠的作品，但不要保存',
    '生成一个球接杠的作品，先别展示',
    '聊一聊球接杠是什么',
  ]) {
    test(
      'no extra classification for explicit or non-creation request: $text',
      () async {
        final client = _Model('{"kind":"game"}');
        final result = await FreeformCreationResolver(
          client,
        ).resolve(text, isCurrent: () => true);
        expect(result.kind, SurfaceIntentKind.none);
        expect(client.calls, isEmpty);
      },
    );
  }

  for (final raw in [
    '{"kind":"none"}',
    '{"kind":"game","actions":[]}',
    '{"kind":"game","kind":"utility"}',
    '{"kind":"game","request":"other"}',
    '{"kind":true}',
    '{"kind":"unknown"}',
    'I will make a game',
    '```json\n{"kind":"game"}\n```',
    '{"kind":"game"',
  ]) {
    test(
      'malformed or noninteractive type gives no creation authority: $raw',
      () async {
        final client = _Model(raw);
        final result = await FreeformCreationResolver(
          client,
        ).resolve(request, isCurrent: () => true);
        expect(result.kind, SurfaceIntentKind.none);
        expect(client.calls, hasLength(1));
      },
    );
  }

  test(
    'cancelled resolution cannot reuse its answer in a newer turn',
    () async {
      final pending = Completer<String>();
      final client = _Model('')..pending = pending.future;
      var current = true;
      final result = FreeformCreationResolver(
        client,
      ).resolve(request, isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete('{"kind":"game"}');
      expect((await result).kind, SurfaceIntentKind.none);
      expect(client.calls, hasLength(1));
      expect(
        (await FreeformCreationResolver(
          client,
        ).resolve(request, isCurrent: () => false)).kind,
        SurfaceIntentKind.none,
      );
      expect(client.calls, hasLength(1));
    },
  );

  test('provider failure never dispatches a paid fallback request', () async {
    final client = _Model('')..failure = StateError('provider_unavailable');
    expect(
      (await FreeformCreationResolver(
        client,
      ).resolve(request, isCurrent: () => true)).kind,
      SurfaceIntentKind.none,
    );
    expect(client.calls, hasLength(1));
  });
}

class _Model extends LLMClient {
  _Model(this.response);
  final String response;
  final calls = <List<Message>>[];
  Future<String>? pending;
  Object? failure;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    calls.add(List.unmodifiable(messages));
    if (failure != null) return Future.error(failure!);
    return pending ?? Future.value(response);
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected secondary request');
}
