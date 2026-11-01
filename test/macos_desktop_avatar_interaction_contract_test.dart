import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'macos/Runner/MacOSUnityAvatarPortal.swift',
  ).readAsStringSync();

  test('macOS emits the exact avatarInteraction v1 tap payload', () {
    final callbacks = RegExp(
      r'"avatarInteraction",\s*arguments:\s*\[(.*?)\]\)',
      dotAll: true,
    ).allMatches(source).toList();

    expect(callbacks, hasLength(1));
    final keys = RegExp(r'"([A-Za-z][A-Za-z0-9]*)"\s*:')
        .allMatches(callbacks.single.group(1)!)
        .map((match) => match.group(1))
        .toList();
    expect(keys, <String>[
      'version',
      'type',
      'normalizedX',
      'normalizedY',
      'region',
      'generation',
      'timestampMs',
    ]);
    expect(callbacks.single.group(1), contains('"version": 1'));
    expect(callbacks.single.group(1), contains('"type": "tap"'));
  });

  test('show accepts one authoritative bounded interaction generation', () {
    final showBranch = source.substring(
      source.indexOf('case "show":'),
      source.indexOf('case "hide":'),
    );

    expect(
      showBranch,
      contains('Set(arguments.keys) == ["interactionGeneration"]'),
    );
    expect(
      showBranch,
      contains('CFGetTypeID(generationNumber) != CFBooleanGetTypeID()'),
    );
    expect(showBranch, contains('!CFNumberIsFloatType(generationNumber)'));
    expect(showBranch, contains('generationNumber.int64Value >= 1'));
    expect(
      showBranch,
      contains('generationNumber.int64Value <= Int64(Int32.max)'),
    );
    expect(
      showBranch,
      contains(
        'showPanel(\n        interactionGeneration: '
        'Int(generationNumber.int64Value))',
      ),
    );
    expect(source, contains('visibilityGeneration = interactionGeneration'));
    expect(source, isNot(contains('visibilityGeneration + 1')));
  });

  test('semantic coordinates are top-down and regions are closed', () {
    final enumBody = RegExp(
      r'private enum MacOSDesktopAvatarTapRegion: String \{(.*?)\}',
      dotAll: true,
    ).firstMatch(source)!.group(1)!;
    final regions = RegExp(
      r'\bcase\s+([A-Za-z]+)',
    ).allMatches(enumBody).map((match) => match.group(1)).toList();

    expect(regions, <String>[
      'head',
      'torso',
      'leftSide',
      'rightSide',
      'feet',
      'avatar',
    ]);
    expect(source, contains('(avatar.maxY - point.y) / avatar.height'));
    expect(source, isNot(contains('(point.y - avatar.minY) / avatar.height')));
    expect(source, contains('guard avatar.contains(point) else'));
    expect(source, contains('return (normalizedX, normalizedY, .avatar)'));
    expect(source, contains('if normalizedY <= 0.28'));
    expect(source, contains('if normalizedY >= 0.82'));
    expect(source, contains('if normalizedX <= 0.32'));
    expect(source, contains('if normalizedX >= 0.68'));
  });

  test('short tap and drag are mutually exclusive native gestures', () {
    final dragBody = source.substring(
      source.indexOf('func continueDragging()'),
      source.indexOf('func endDragging(with event: NSEvent)'),
    );
    final endBody = source.substring(
      source.indexOf('func endDragging(with event: NSEvent)'),
      source.indexOf('func cancelPointerGesture()'),
    );
    final rightClickBody = source.substring(
      source.indexOf('override func rightMouseDown(with event: NSEvent)'),
      source.indexOf('override func cancelOperation(_ sender: Any?)'),
    );
    final hideBody = source.substring(
      source.indexOf('func hidePanel()'),
      source.indexOf('func dispose()'),
    );

    expect(
      source,
      contains('private static let maximumTapDuration: TimeInterval = 0.5'),
    );
    expect(
      source,
      contains('private static let baseDragThreshold: CGFloat = 6'),
    );
    expect(
      source,
      contains(
        'Self.baseDragThreshold * presentationConfiguration.visualScale',
      ),
    );
    expect(
      dragBody,
      contains('guard movement > dragThreshold else { return }'),
    );
    expect(
      dragBody.indexOf('guard movement > dragThreshold'),
      lessThan(dragBody.indexOf('performDrag(')),
    );
    expect(endBody, contains('if didDrag {'));
    expect(endBody, contains('duration <= Self.maximumTapDuration'));
    expect(endBody, contains('movement <= dragThreshold'));
    expect(
      endBody.indexOf('if didDrag {'),
      lessThan(endBody.indexOf('onAvatarInteraction(')),
    );
    expect(rightClickBody, contains('presentContextMenu'));
    expect(rightClickBody, isNot(contains('onAvatarInteraction')));
    expect(source, contains('override func cancelOperation(_ sender: Any?)'));
    expect(hideBody, contains('cancelPointerGesture()'));
    expect(
      hideBody.indexOf('cancelPointerGesture()'),
      lessThan(hideBody.indexOf('orderOut(nil)')),
    );
  });

  test('tap timestamp uses bounded monotonic uptime milliseconds', () {
    expect(source, contains('ProcessInfo.processInfo.systemUptime * 1_000'));
    expect(
      source,
      contains(
        'private static let maximumTimestampMs = 9_007_199_254_740_991.0',
      ),
    );
    expect(source, contains('.clamped(to: 0 ... maximumTimestampMs)'));
    expect(source, contains('timestampMs: Self.monotonicTimestampMs()'));
  });

  test('hit test, gesture start, menu and semantic tap share current alpha', () {
    final begin = source.substring(
      source.indexOf('func beginDragging(with event: NSEvent)'),
      source.indexOf('func continueDragging()'),
    );
    final hitTest = source.substring(
      source.indexOf('override func hitTest(_ point: NSPoint)'),
      source.indexOf('override func acceptsFirstMouse'),
    );
    final rightClick = source.substring(
      source.indexOf('override func rightMouseDown(with event: NSEvent)'),
      source.indexOf('override func cancelOperation'),
    );
    final semantic = source.substring(
      source.indexOf('fileprivate func semanticTap('),
      source.indexOf(
        'func setAvatarImage',
        source.indexOf('fileprivate func semanticTap('),
      ),
    );
    expect(
      begin,
      contains(
        'guard petContentView.containsVisibleAvatar(at: point) else { return }',
      ),
    );
    expect(
      begin.indexOf('containsVisibleAvatar'),
      lessThan(begin.indexOf('pointerGesture = PointerGesture')),
    );
    expect(hitTest, contains('convert(point, from: superview)'));
    expect(
      hitTest,
      contains('containsVisibleAvatar(at: localPoint) ? self : nil'),
    );
    expect(
      rightClick,
      contains('guard containsVisibleAvatar(at: point) else { return }'),
    );
    expect(
      rightClick.indexOf('containsVisibleAvatar'),
      lessThan(rightClick.indexOf('presentContextMenu')),
    );
    expect(semantic, contains('guard containsVisibleAvatar(at: point),'));
  });

  test(
    'captured drag keeps events through transparent frames until up or cancel',
    () {
      final passthrough = source.substring(
        source.indexOf('private func updateMousePassthrough()'),
        source.indexOf('@objc private func screenParametersDidChange'),
      );
      final captureGuard = RegExp(
        r'guard pointerGesture == nil else \{\s*ignoresMouseEvents = false\s*return\s*\}',
      );
      expect(captureGuard.hasMatch(passthrough), isTrue);
      expect(
        passthrough.indexOf('guard pointerGesture == nil'),
        lessThan(passthrough.indexOf('containsVisibleAvatar')),
      );
      expect(
        source,
        contains('pointerGesture = nil\n    updateMousePassthrough()'),
      );
      expect(source, contains('endDragging(with: event)'));
      expect(source, contains('cancelPointerGesture()'));
    },
  );
}
