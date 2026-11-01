import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Home keeps legacy proactive delivery and adds a committed stream', () {
    final source = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        'StreamSubscription<AgentInitiatedResponse>? '
        '_committedProactiveSub;',
      ),
    );
    expect(source, contains('_runtime!.onProactiveResponse.listen'));
    expect(source, contains('_runtime!.onCommittedProactiveResponse.listen'));
    expect(source, contains('_committedProactiveSub?.cancel()'));
  });

  test('committed proactive response is account-gated and render-only', () {
    final source = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();
    final wrapperStart = source.indexOf(
      'Future<void> _onCommittedProactive(AgentInitiatedResponse response)',
    );
    final activeStart = source.indexOf(
      'Future<void> _onCommittedProactiveActive(',
      wrapperStart,
    );
    final activeEnd = source.indexOf('\n  @override', activeStart);

    expect(wrapperStart, greaterThanOrEqualTo(0));
    expect(activeStart, greaterThan(wrapperStart));
    expect(activeEnd, greaterThan(activeStart));

    final wrapper = source.substring(wrapperStart, activeStart);
    final active = source.substring(activeStart, activeEnd);
    expect(wrapper, contains('_registry.runAccountOperation'));
    expect(
      active,
      contains(
        '_setLatestBubble(response.text, outreachId: response.outreachId)',
      ),
    );
    expect(active, contains('await _loadDockActive()'));
    expect(active, isNot(contains('saveChatMessage')));
    expect(active, isNot(contains('ChatMessage(')));
    expect(active, isNot(contains('presentStandaloneReply')));
  });

  test('latest reply dismissal preserves exact proactive provenance', () {
    final home = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();
    final stack = File(
      'lib/src/core/widgets/agent_card_stack.dart',
    ).readAsStringSync();

    expect(RegExp(r'latestBubble\.value\s*=').allMatches(home), hasLength(1));
    expect(home, contains('void _setLatestBubble('));
    expect(home, contains('String? _latestBubbleOutreachId;'));
    expect(home, contains('void dismissLatestReply()'));
    expect(home, contains('final outreachId = _latestBubbleOutreachId;'));
    expect(home, contains('_setLatestBubble(null);'));
    expect(home, contains('_registry.runAccountOperation'));
    expect(home, contains('collector.recordDismissed('));
    expect(stack, contains('onTap: controller.dismissLatestReply'));
    expect(stack, isNot(contains('controller.latestBubble.value = null')));
  });
}
