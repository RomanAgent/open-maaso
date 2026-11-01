import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/agent/presentation/companion/embedded_avatar_presentation_policy.dart';

void main() {
  test('only macOS and Windows native windows suppress embedded Avatar UI', () {
    expect(
      EmbeddedAvatarPresentationPolicy.shouldEmbed(
        isWeb: false,
        platform: TargetPlatform.macOS,
      ),
      isFalse,
    );
    expect(
      EmbeddedAvatarPresentationPolicy.shouldEmbed(
        isWeb: false,
        platform: TargetPlatform.windows,
      ),
      isFalse,
    );

    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(
        EmbeddedAvatarPresentationPolicy.shouldEmbed(
          isWeb: false,
          platform: platform,
        ),
        isTrue,
        reason: platform.name,
      );
    }

    expect(
      EmbeddedAvatarPresentationPolicy.shouldEmbed(
        isWeb: true,
        platform: TargetPlatform.macOS,
      ),
      isTrue,
    );
    expect(
      EmbeddedAvatarPresentationPolicy.shouldEmbed(
        isWeb: true,
        platform: TargetPlatform.windows,
      ),
      isTrue,
    );
  });

  test('native desktop Home keeps persistent chat without a room exception', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final history = File(
      'lib/src/features/home/presentation/widgets/home_chat_history.dart',
    ).readAsStringSync();

    expect(source, contains('EmbeddedAvatarPresentationPolicy.shouldEmbed()'));
    expect(source, isNot(contains('macHomeScene')));
    expect(source, isNot(contains('AvatarPortalScope.maybeOf(context)')));
    expect(source, contains('if (embedAvatar)'));
    expect(
      source,
      matches(
        RegExp(
          r'if\s*\(embedAvatar\)\s*(?:const\s+)?'
          r'Positioned\.fill\(\s*child:\s*(?:const\s+)?'
          r'_HomeWorldBackdrop\(',
        ),
      ),
    );
    expect(source, contains('GlassBackdropKind.flutter'));
    expect(source, contains('const _DesktopHomeBackdrop()'));
    final desktopBackdrop = source.substring(
      source.indexOf('class _DesktopHomeBackdrop'),
      source.indexOf('class _HomeWorldBackdrop'),
    );
    expect(desktopBackdrop, contains('ColoredBox('));
    expect(
      desktopBackdrop,
      contains('color: Theme.of(context).scaffoldBackgroundColor'),
    );
    expect(desktopBackdrop, isNot(contains('LinearGradient')));
    expect(
      AppTheme.build(
        AppPalette.of(Brightness.light, AppAccent.blue),
      ).scaffoldBackgroundColor,
      Colors.white,
    );
    expect(
      source,
      contains(
        'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart',
      ),
    );
    expect(source, contains('child: HomeChatHistory('));
    expect(history, contains('getMessagesInRange('));
    expect(history, contains('from: day.start,'));
    expect(history, contains('before: day.end,'));
    expect(history, contains('final message = _messages[index]'));
    expect(history, contains('row = MessageBubble('));
    expect(history, contains('message: message,'));
    expect(source, contains('showLatestReply: false'));
    expect(source, contains('onSend: c.send'));
    expect(source, isNot(contains('U2aChatController')));
    expect(history, isNot(contains('U2aChatController')));
  });

  test('latest reply overlay is optional while action cards stay mounted', () {
    final source = File(
      'lib/src/core/widgets/agent_card_stack.dart',
    ).readAsStringSync();

    expect(source, contains('this.showLatestReply = true'));
    expect(source, contains('if (showLatestReply) const _LatestReplyBubble()'));
    expect(source, contains('const AgentLoadingCards()'));
    expect(source, contains('final card = controller.current'));
  });
}
