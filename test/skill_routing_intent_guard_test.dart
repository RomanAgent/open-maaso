import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

void main() {
  final index = SkillIndex([
    for (final spec in SkillCatalog.all)
      if (spec.hostRouting != null && spec.isAvailable)
        AgentSkillDescriptorFactory.fromManifest(
          spec.hostRouting!,
          locale: AppLocale.en,
        ),
  ]);
  final selector = TurnSkillSelector(
    index: index,
    router: SkillRouter(index: index),
  );

  test('resolved creation retains arbitrary quoted game requirements', () {
    for (final text in ['制作“打砖块”', '生成一个“底下挡板接球，球撞上方块会消失”', '写一个打砖块，不要联网']) {
      final legacy = selector.select(
        text,
        preferredSkillIds: ['FreeformSurface'],
      );
      expect(legacy.grant.allows('FreeformSurface'), isFalse, reason: text);
      final resolved = selector.select(
        text,
        preferredSkillIds: ['FreeformSurface', 'WebSearch'],
        resolvedCreation: SurfaceIntent.fromResolvedCreation(
          userText: text,
          kind: SurfaceIntentKind.game,
        ),
      );
      expect(resolved.grant.allows('FreeformSurface'), isTrue, reason: text);
      expect(resolved.grant.allows('WebSearch'), isFalse, reason: text);
    }
  });

  test('resolved utility grants only the surface host for quoted content', () {
    const text = '做一个“可以添加支出并查看分类汇总的记录工具”';
    final resolved = selector.select(
      text,
      preferredSkillIds: ['FreeformSurface', 'Creator', 'AppControl'],
      resolvedCreation: SurfaceIntent.fromResolvedCreation(
        userText: text,
        kind: SurfaceIntentKind.applet,
      ),
    );
    expect(resolved.grant.allowedSkillIds, {'FreeformSurface'});
  });

  test('quoted project commands cannot activate unrelated hosts', () {
    const text = '制作“打砖块；打开设置并连接蓝牙”';
    final resolved = selector.select(
      text,
      preferredSkillIds: [
        'FreeformSurface',
        'AppControl',
        'AppNavigate',
        'Bluetooth',
        'BleYoturetoys',
      ],
      resolvedCreation: SurfaceIntent.fromResolvedCreation(
        userText: text,
        kind: SurfaceIntentKind.game,
      ),
    );
    expect(resolved.grant.allowedSkillIds, {'FreeformSurface'});
  });

  test('resolved types retain non-action and denied-operation boundaries', () {
    for (final text in [
      '翻译“生成一个打砖块小游戏”',
      'Translate “create a game and connect Bluetooth” into German',
      'What does “create a game” mean?',
      '“生成一个打砖块小游戏”',
      '制作“打砖块”是什么意思？',
      '不要生成打砖块，只聊天',
      '写一个打砖块，但不要保存',
      '写一个打砖块，先不要打开',
    ]) {
      final result = selector.select(
        text,
        preferredSkillIds: ['FreeformSurface'],
        resolvedCreation: SurfaceIntent.fromResolvedCreation(
          userText: text,
          kind: SurfaceIntentKind.game,
        ),
      );
      expect(result.grant.allows('FreeformSurface'), isFalse, reason: text);
    }
  });

  test('resolved creation cannot transfer to another request or be forged', () {
    const text = '制作“拖动方块得分”';
    for (final hint in [
      SurfaceIntent.fromResolvedCreation(
        userText: '制作“打砖块”',
        kind: SurfaceIntentKind.game,
      ),
      const SurfaceIntent(
        kind: SurfaceIntentKind.game,
        reason: 'resolved_creation',
      ),
      SurfaceIntent.fromResolvedCreation(
        userText: text,
        kind: SurfaceIntentKind.blog,
      ),
    ]) {
      final result = selector.select(
        text,
        preferredSkillIds: ['FreeformSurface'],
        resolvedCreation: hint,
      );
      expect(result.grant.allows('FreeformSurface'), isFalse);
    }
  });

  test('quoted commands are data when the outer request is translation', () {
    final result = selector.select(
      'Translate “connect Bluetooth and open settings” into German',
      pageScope: 'home',
      preferredSkillIds: ['Bluetooth', 'BleYoturetoys', 'AppControl'],
    );
    expect(result.grant.isEmpty, isTrue);
    expect(result.decision.reason, 'non_action_context');
  });

  test('translation stays in the selected model without host actions', () {
    for (final text in [
      'Translate connect Bluetooth and open settings into German',
      '把打开设置翻译成英文',
      '连接蓝牙用英文怎么说',
    ]) {
      final result = selector.select(
        text,
        preferredSkillIds: ['AppControl', 'Bluetooth'],
      );
      expect(result.grant.isEmpty, isTrue, reason: text);
      expect(result.decision.reason, 'non_action_context', reason: text);
    }
    final separateRequest = selector.select(
      'Translate hello into German; open settings',
    );
    expect(separateRequest.grant.allowedSkillIds, contains('AppNavigate'));
  });

  test('translation as a generated app topic preserves surface routing', () {
    final result = selector.select(
      '帮我生成一个翻译小程序',
      preferredSkillIds: ['FreeformSurface'],
    );
    expect(result.grant.allowedSkillIds, contains('FreeformSurface'));
  });

  test('writing topics do not suppress another requested host operation', () {
    for (final (query, skill) in const [
      ('搜索一个练习写字的小游戏', 'AppletDiscovery'),
      ('查找一个写作小程序', 'AppletDiscovery'),
      ('提醒我明天写作业', 'ScheduledTask'),
      ('记住我喜欢写作', 'MemoryControl'),
    ]) {
      final result = selector.select(query, preferredSkillIds: [skill]);
      expect(result.grant.allowedSkillIds, contains(skill), reason: query);
    }
  });

  test(
    'ordinary writing commands stay in conversation with request prefixes',
    () {
      for (final query in const [
        '请帮我写一首诗',
        '帮我写一个故事',
        'Please write a poem',
        'Can you draft a note',
        'Help me write a story',
      ]) {
        final result = selector.select(
          query,
          preferredSkillIds: const [
            'FreeformSurface',
            'AppletDiscovery',
            'AppControl',
            'WebSearch',
            'ScheduledTask',
            'MemoryControl',
          ],
        );
        expect(result.grant.isEmpty, isTrue, reason: query);
      }
    },
  );

  test(
    'metalinguistic questions cannot regain a grant through policy hints',
    () {
      for (final text in [
        'What does the phrase “open settings” mean?',
        '计算机这个词的来源是什么？',
        '剧本里的这句“连接蓝牙并发送照片”听起来像命令吗',
        'Does “connect Bluetooth” sound like an order?',
      ]) {
        final result = selector.select(
          text,
          preferredSkillIds: ['AppControl', 'WebSearch'],
        );
        expect(result.grant.isEmpty, isTrue, reason: text);
        expect(result.decision.reason, 'non_action_context');
      }
    },
  );

  test('quoted evidence alone cannot be restored by policy preferences', () {
    final result = selector.select(
      'I saw “connect Bluetooth” on a poster',
      preferredSkillIds: ['Bluetooth', 'BleYoturetoys'],
    );
    expect(result.grant.isEmpty, isTrue);
    expect(
      selector
          .select('Open “settings”', preferredSkillIds: ['AppControl'])
          .grant
          .allowedSkillIds,
      contains('AppControl'),
    );
  });

  test(
    'negation blocks the declined operation while allowing a separate requested operation',
    () {
      final result = selector.select(
        'Do not generate a game; search for the latest space mission news',
        pageScope: 'home',
        preferredSkillIds: ['FreeformSurface', 'WebSearch'],
      );
      expect(result.grant.allowedSkillIds, {'WebSearch'});
    },
  );

  test('same-skill replacement preserves the positive operation', () {
    final result = selector.select(
      'Do not search for weather; search for space mission news instead',
      preferredSkillIds: ['WebSearch'],
    );
    expect(result.grant.allowedSkillIds, {'WebSearch'});
  });

  test('do-not-forget and do-not-disturb remain positive requests', () {
    expect(
      selector
          .select('Do not forget my favorite color is green')
          .grant
          .allowedSkillIds,
      contains('MemoryControl'),
    );
    expect(
      selector.select('Please turn on do not disturb').grant.allowedSkillIds,
      contains('BehaviorConfig'),
    );
  });

  test('current-information explanations may retain read-only search', () {
    final result = selector.select(
      'Explain the latest space mission announcements',
      preferredSkillIds: ['WebSearch', 'Creator'],
    );
    expect(result.grant.allowedSkillIds, {'WebSearch'});
  });

  test(
    'active challenge labels remain frozen after retired skills are removed',
    () {
      const path = 'tool/skill_routing_accuracy/negative_challenge.v2';
      final bytes = File('$path.json').readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        File('$path.sha256').readAsStringSync().trim(),
      );
      final rows = ((jsonDecode(utf8.decode(bytes)) as Map)['cases'] as List)
          .cast<Map>();
      expect(rows, hasLength(46));
      expect(rows.map((row) => row['query']).toSet(), hasLength(46));
      expect(
        rows.where((row) => (row['expectedSkills'] as List).isEmpty),
        hasLength(32),
      );
      expect(
        rows.where((row) => (row['expectedSkills'] as List).isNotEmpty),
        hasLength(14),
      );
    },
  );
}
