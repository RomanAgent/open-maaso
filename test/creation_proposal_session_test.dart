import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/intent/creation_proposal_session.dart';

const _screenshotProposal =
    '我比较喜欢轻松但有点操作感的小游戏，比如弹球打砖块。'
    '那我给你做一个触屏控制的打砖块吧，做好直接打开玩。';
const _scope = 'account-a|staging|self|conversation-a';

void main() {
  late DateTime now;
  late CreationProposalSession session;
  setUp(() {
    now = DateTime.utc(2026, 10, 12, 10);
    session = CreationProposalSession(now: () => now);
  });

  test('the screenshot confirmation binds the actual proposal, once', () {
    expect(
      session.observeAssistantReply(_screenshotProposal, scopeKey: _scope),
      isTrue,
    );
    final brief = session.takeConfirmation('好就按你的来做', scopeKey: _scope);
    expect(brief, isNotNull);
    expect(brief!.kind, CreationProposalKind.game);
    expect(brief.proposalText, _screenshotProposal);
    expect(brief.confirmationText, '好就按你的来做');
    expect(session.takeConfirmation('好就按你的来做', scopeKey: _scope), isNull);
  });

  for (final text in [
    '就做你说的那个',
    '好，就按你的来做',
    '好，就按你的来做，加入分裂道具和音效',
    '好就按你的来做，叫它“弹球”',
    '好，就做你说的那个，加入“重力反转”效果',
    '好就按你的来做，支持自动翻译',
    '好就按你的来做，增加新手教程解释怎么重新开始',
    '好就按你的来做，教程里提示“怎么重新开始？”',
    '好就按你的来做，新手帮助页解释怎么重新开始？',
    'Okay, make the one you suggested, name it "Moon Jump"',
    '按照你建议的方案来制作',
    '就照你说的写吧',
    '做你选的那个，加入声音反馈',
    'make the one you suggested',
    'Sure, build the game you proposed',
    'Okay, make the one you suggested',
    'Okay, make the one you suggested, add touch controls',
    'Please create it your way',
    'write the app you recommended',
  ]) {
    test('explicit adjacent creation confirmation: $text', () {
      session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
      final brief = session.takeConfirmation(text, scopeKey: _scope);
      expect(brief, isNotNull);
      expect(brief!.confirmationText, text);
    });
  }

  for (final proposal in [
    '我给你做个声音能改变重力的小游戏，每次失误会改变地形。',
    '我可以写一个可玩的作品，收集光点改变周围环境。',
    '我来制作一款互动作品，让手指拖动月亮改变重力。',
    'I will build a playable experience where whispers change gravity.',
    '我给你做一个拖月亮改变重力的小游戏，页面上也有操作说明。',
    '如果你愿意，我给你做一个小游戏。',
    '假如你想要的话，我会给你写个互动作品。',
    'If you like, I can make a game where whispers change gravity.',
    '我给你做一个小游戏，支持暂停和重新开始。',
    '我给你做一个带玩法说明的小游戏。',
    '我给你做一个有新手教程的小游戏。',
    'I can make a game with a tutorial and a pause button.',
  ]) {
    test(
      'arbitrary gameplay does not depend on a known game name: $proposal',
      () {
        expect(
          session.observeAssistantReply(proposal, scopeKey: _scope),
          isTrue,
        );
        final brief = session.takeConfirmation('就做你说的那个', scopeKey: _scope);
        expect(brief!.kind, CreationProposalKind.game);
        expect(brief.proposalText, proposal);
      },
    );
  }

  for (final proposal in [
    '我给你做一个小程序，可以随时添加支出、查看分类汇总并修改记录。',
    'I can make a mini app to track the stars you observe.',
    'I will build a score tracker for your games.',
    '我给你做个待办小程序，可以添加、修改和取消提醒。',
  ]) {
    test('runnable utility offers bind as utility: $proposal', () {
      expect(session.observeAssistantReply(proposal, scopeKey: _scope), isTrue);
      final brief = session.takeConfirmation('按你的方案来做', scopeKey: _scope);
      expect(brief!.kind, CreationProposalKind.utility);
    });
  }

  for (final proposal in [
    '我给你写一个底下挡板接球的作品。',
    '我来做个声音改变重力、星星会分裂的东西。',
    '我给你做个可以添加支出并按日期汇总的东西。',
    'I can build something where whispers change gravity.',
    '我来写一个支持多页面导航的小游戏。',
    '我来写个记录游戏分数的工具，支持分类汇总。',
    'I can build a game with several web pages and navigation.',
  ]) {
    test(
      'unnamed proposals await the model type after confirmation: $proposal',
      () {
        expect(
          session.observeAssistantReply(proposal, scopeKey: _scope),
          isTrue,
        );
        final brief = session.takeConfirmation('就做你说的那个', scopeKey: _scope);
        expect(brief!.kind, CreationProposalKind.unresolved);
        expect(brief.proposalText, proposal);
      },
    );
  }

  for (final confirmation in [
    '好就按你的来做，加入暂停按钮',
    '好就按你的来做，加入取消提醒按钮',
    'Okay, make the one you suggested, include a stop button',
    '好就按你的来做，按钮文字是“取消”',
  ]) {
    test('product pause and cancellation controls are data: $confirmation', () {
      session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
      final brief = session.takeConfirmation(confirmation, scopeKey: _scope);
      expect(brief, isNotNull);
      expect(brief!.confirmationText, confirmation);
    });
  }

  for (final text in [
    '好',
    '好的',
    '继续',
    '你看着办',
    'yes',
    'Okay, continue',
    'go ahead',
    '今天吃什么',
    '好就按你的来做，但是先别开始',
    '好，就按你的来做，但是先别开始',
    '就做你说的那个，不过不要保存',
    '按你的来做，但是不要展示',
    '别做你说的那个',
    '算了',
    '取消',
    '停止',
    '暂停生成',
    '取消制作',
    '好就按你的来做，但取消制作',
    '好就按你的来做，不过暂停生成',
    'Okay, make the one you suggested, but stop this generation',
    '先只讲方案',
    '翻译“好就按你的来做”',
    '“就做你说的那个”',
    '"make the one you suggested"',
    '解释这句话：好就按你的来做',
    '翻译“好就按你的来做”，支持自动翻译',
    '就做你说的那个？增加新手教程',
    '按照你说的做需要多久？',
    '就做你说的那个？',
    'Make the one you suggested, but do not save it',
    'Only explain the plan',
  ]) {
    test('no creation authority, and adjacency is consumed: $text', () {
      session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
      expect(session.takeConfirmation(text, scopeKey: _scope), isNull);
      expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
    });
  }

  for (final proposal in [
    '我比较喜欢有操作感的小游戏。',
    '你可以做一个小游戏。',
    '“我给你做个小游戏吧”',
    '例如这样说：我给你做一个小游戏。',
    '我不会做一个小游戏，现在先只讲方案。',
    '我给你写一篇小游戏故事。',
    '我来做一个小游戏开发教程。',
    '我来制作游戏的代码示例。',
    '我给你写一个游戏教程。',
    '我给你做一份游戏说明。',
    '我给你做。',
    'I can write a story about a game.',
    'I will only explain how to build a game.',
    '他说，我给你做一个小游戏。',
    '她说我会写一个小程序。',
    '假设角色说：我给你做一个小游戏。',
    'I said yesterday that I can make a game.',
    'For example, I can build a game.',
    'Suppose I will make a mini app.',
    '假如用户说：我给你做一个小游戏。',
    '如果你愿意，假设角色说：我给你做一个小游戏。',
  ]) {
    test(
      'discussion, quoted or non-runnable output is not a proposal: $proposal',
      () {
        expect(
          session.observeAssistantReply(proposal, scopeKey: _scope),
          isFalse,
        );
        expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
      },
    );
  }

  test('an ordinary newer assistant reply replaces the old proposal', () {
    session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
    expect(session.observeAssistantReply('晚饭吃了吗？', scopeKey: _scope), isFalse);
    expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
  });

  test(
    'quoted product features and later in-game reported speech are data',
    () {
      const proposal = '我来写一个小游戏，附带“操作说明”，角色说：欢迎来到月球。';
      expect(session.observeAssistantReply(proposal, scopeKey: _scope), isTrue);
      final brief = session.takeConfirmation(
        '好就按你的来做，叫它“弹球”',
        scopeKey: _scope,
      );
      expect(brief, isNotNull);
      expect(brief!.proposalText, proposal);
      expect(brief.confirmationText, '好就按你的来做，叫它“弹球”');
    },
  );

  test('scope switch drops the offer and cannot restore it', () {
    for (final nextScope in [
      'account-b|staging|self|conversation-a',
      'account-a|production|self|conversation-a',
      'account-a|staging|other-agent|conversation-a',
      'account-a|staging|self|conversation-b',
    ]) {
      session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
      expect(session.takeConfirmation('就做你说的那个', scopeKey: nextScope), isNull);
      expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
    }
  });

  test('expired offers and exact expiry boundary are unavailable', () {
    session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
    now = now.add(const Duration(minutes: 5));
    expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
    session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
    now = now.add(const Duration(minutes: 6));
    expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
  });

  test('clear and a different session cannot inherit a proposal', () {
    session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
    session.clear();
    expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
    session.observeAssistantReply(_screenshotProposal, scopeKey: _scope);
    final another = CreationProposalSession(now: () => now);
    expect(another.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
  });

  test('empty owner or invalid TTL cannot register', () {
    expect(
      session.observeAssistantReply(_screenshotProposal, scopeKey: ''),
      isFalse,
    );
    expect(session.takeConfirmation('就做你说的那个', scopeKey: _scope), isNull);
    expect(
      () => CreationProposalSession(ttl: Duration.zero),
      throwsArgumentError,
    );
  });
}
