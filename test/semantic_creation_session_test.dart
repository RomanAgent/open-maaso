import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/intent/creation_intent.dart';
import 'package:maaso/src/features/agent/application/intent/semantic_creation_session.dart';

const _scope = 'account-a|staging|self|session-a';
const _opaqueId = 'Host_Proposal:AbC-01/part.2';

CreationIntent _proposal(String requirements, {String kind = 'game'}) =>
    CreationIntent.fromJson({
      'type': 'creation.intent',
      'mode': 'propose',
      'kind': kind,
      'requirements': requirements,
    });

CreationIntent _confirmation(String id, {String? additionalRequirements}) =>
    CreationIntent.fromJson({
      'type': 'creation.intent',
      'mode': 'confirm',
      'proposalId': id,
      'requirements': ?additionalRequirements,
    });

void main() {
  late DateTime now;
  late SemanticCreationSession session;
  setUp(() {
    now = DateTime.utc(2026, 10, 13, 8);
    session = SemanticCreationSession(now: () => now, newId: () => _opaqueId);
  });

  CreationProposal offer({String requirements = '声音改变重力，收集光点打开下一关。'}) =>
      session.propose(
        _proposal(requirements),
        scopeKey: _scope,
        sourceTurnId: 'human-turn-a',
      );

  test('host proposal retains owner, source turn and default expiry', () {
    final proposed = offer();
    expect(proposed.id, _opaqueId);
    expect(proposed.scopeKey, _scope);
    expect(proposed.sourceTurnId, 'human-turn-a');
    expect(proposed.kind, CreationIntentKind.game);
    expect(proposed.expiresAt, now.add(const Duration(minutes: 5)));
    expect(session.current(_scope), same(proposed));
    expect(proposed.toPromptData(), {
      'id': _opaqueId,
      'kind': 'game',
      'requirements': proposed.requirements,
    });
    final callerData = proposed.toPromptData();
    callerData['requirements'] = 'Caller-modified data';
    expect(session.current(_scope)!.requirements, proposed.requirements);
  });

  test('matching opaque ID consumes exactly once', () {
    final proposed = offer();
    final decision = _confirmation(_opaqueId);
    expect(session.consume(decision, _scope), same(proposed));
    expect(session.current(_scope), isNull);
    expect(session.consume(decision, _scope), isNull);
  });

  test('ID comparison is exact and does not normalize case or punctuation', () {
    final proposed = offer();
    for (final wrong in [
      _opaqueId.toLowerCase(),
      _opaqueId.replaceAll(':', '-'),
      _opaqueId.replaceAll('/', '.'),
      '$_opaqueId-extra',
      'some-other-host-id',
    ]) {
      expect(session.consume(_confirmation(wrong), _scope), isNull);
      expect(session.current(_scope), same(proposed));
    }
    expect(session.consume(_confirmation(_opaqueId), _scope), same(proposed));
  });

  test('proposal is still valid immediately before expiry', () {
    final proposed = offer();
    now = proposed.expiresAt.subtract(const Duration(microseconds: 1));
    expect(session.current(_scope), same(proposed));
    expect(session.consume(_confirmation(_opaqueId), _scope), same(proposed));
  });

  for (final afterExpiry in [Duration.zero, const Duration(minutes: 1)]) {
    test('expiry boundary plus $afterExpiry clears and cannot be consumed', () {
      final proposed = offer();
      now = proposed.expiresAt.add(afterExpiry);
      expect(session.current(_scope), isNull);
      expect(session.consume(_confirmation(_opaqueId), _scope), isNull);
      now = now.subtract(const Duration(days: 1));
      expect(session.current(_scope), isNull);
    });
  }

  test('consume checks expiry without a preceding current-context read', () {
    final proposed = offer();
    now = proposed.expiresAt;
    expect(session.consume(_confirmation(_opaqueId), _scope), isNull);
    expect(session.current(_scope), isNull);
  });

  test('custom TTL is respected without changing proposal data', () {
    session = SemanticCreationSession(
      ttl: const Duration(seconds: 17),
      now: () => now,
      newId: () => _opaqueId,
    );
    final proposed = offer();
    expect(proposed.expiresAt, now.add(const Duration(seconds: 17)));
    now = now.add(const Duration(seconds: 17));
    expect(session.consume(_confirmation(_opaqueId), _scope), isNull);
  });

  for (final nextScope in [
    'account-b|staging|self|session-a',
    'account-a|production|self|session-a',
    'account-a|staging|other-agent|session-a',
    'account-a|staging|self|session-b',
    ' $_scope ',
  ]) {
    test('scope transition to $nextScope revokes the original proposal', () {
      offer();
      expect(session.current(nextScope), isNull);
      expect(session.current(_scope), isNull);
      expect(session.consume(_confirmation(_opaqueId), _scope), isNull);
    });
  }

  test('consume also fences account changes before reading context', () {
    offer();
    expect(
      session.consume(_confirmation(_opaqueId), 'different-account'),
      isNull,
    );
    expect(session.current(_scope), isNull);
  });

  test('a newer host proposal replaces the old ID and complete brief', () {
    var sequence = 0;
    session = SemanticCreationSession(
      now: () => now,
      newId: () => 'host-proposal-${++sequence}',
    );
    final first = offer(requirements: '重力随声音变化。');
    final next = session.propose(
      _proposal(
        'Track stars, retain notes and browse the calendar.',
        kind: 'utility',
      ),
      scopeKey: _scope,
      sourceTurnId: 'human-turn-b',
    );
    expect(first.id, isNot(next.id));
    expect(session.consume(_confirmation(first.id), _scope), isNull);
    expect(session.current(_scope), same(next));
    expect(session.consume(_confirmation(next.id), _scope), same(next));
    expect(next.kind, CreationIntentKind.utility);
    expect(next.sourceTurnId, 'human-turn-b');
  });

  for (final item in [
    ('game', '拖动月亮改变重力，光点会分裂；支持暂停、触屏、键盘、关卡和“帮助”页面。'),
    (
      'game',
      'Whispers change gravity; stars split, pause works, and portals open nested scenes.',
    ),
    ('utility', '按日期记录星空观察，支持修改、取消提醒、分类汇总、自动翻译和二级详情页面。'),
    (
      'utility',
      'Track expenses with categories, edit records, cancel reminders, translate notes and open detail pages.',
    ),
    ('game', '任意新玩法\n${'Moon🌕 星星改变重力\n' * 1500}最后一条完整需求'),
  ]) {
    test(
      '${item.$1} arbitrary complete requirements remain literal project data',
      () {
        final proposed = session.propose(
          _proposal(item.$2, kind: item.$1),
          scopeKey: _scope,
          sourceTurnId: 'human-turn-a',
        );
        expect(proposed.requirements, item.$2);
        expect(proposed.toPromptData()['requirements'], item.$2);
        final accepted = session.consume(_confirmation(_opaqueId), _scope)!;
        expect(accepted.requirements, item.$2);
        expect(accepted.kind.name, item.$1);
      },
    );
  }

  test('confirmation additions remain separate from the accepted proposal', () {
    final proposed = offer();
    const additions = '加入“暂停”按钮；translate help and keep the original controls.';
    final decision = _confirmation(
      _opaqueId,
      additionalRequirements: additions,
    );
    final accepted = session.consume(decision, _scope)!;
    expect(accepted, same(proposed));
    expect(accepted.requirements, proposed.requirements);
    expect(decision.requirements, additions);
  });

  for (final action in <Map<String, Object?>>[
    {'type': 'creation.intent', 'mode': 'none'},
    {
      'type': 'creation.intent',
      'mode': 'create',
      'kind': 'game',
      'requirements': 'An arbitrary playable output.',
    },
    {
      'type': 'creation.intent',
      'mode': 'propose',
      'kind': 'utility',
      'requirements': 'An arbitrary runnable output.',
    },
    {
      'type': 'creation.intent',
      'mode': 'edit',
      'projectId': 'host-project-1',
      'requirements': 'Preserve controls and add details.',
    },
    {'type': 'creation.intent', 'mode': 'cancel', 'taskId': 'host-task-1'},
    {'type': 'creation.intent', 'mode': 'retry', 'taskId': 'host-task-1'},
    {'type': 'creation.intent', 'mode': 'status', 'taskId': 'host-task-1'},
  ]) {
    test('${action['mode']} does not consume a proposal as confirmation', () {
      final proposed = offer();
      expect(session.consume(CreationIntent.fromJson(action), _scope), isNull);
      expect(session.current(_scope), same(proposed));
    });
  }

  test('clear and a new session cannot inherit a pending host proposal', () {
    offer();
    session.clear();
    expect(session.current(_scope), isNull);
    expect(session.consume(_confirmation(_opaqueId), _scope), isNull);
    offer();
    final another = SemanticCreationSession(
      now: () => now,
      newId: () => _opaqueId,
    );
    expect(another.current(_scope), isNull);
    expect(another.consume(_confirmation(_opaqueId), _scope), isNull);
  });

  test(
    'only typed proposal decisions with explicit owner/source can register',
    () {
      expect(
        () => session.propose(
          CreationIntent.fromJson({'type': 'creation.intent', 'mode': 'none'}),
          scopeKey: _scope,
          sourceTurnId: 'human-turn-a',
        ),
        throwsFormatException,
      );
      expect(
        () => session.propose(
          _proposal('星星改变重力。'),
          scopeKey: '',
          sourceTurnId: 'human-turn-a',
        ),
        throwsFormatException,
      );
      expect(
        () => session.propose(
          _proposal('星星改变重力。'),
          scopeKey: _scope,
          sourceTurnId: '',
        ),
        throwsFormatException,
      );
      expect(session.current(_scope), isNull);
    },
  );
}
