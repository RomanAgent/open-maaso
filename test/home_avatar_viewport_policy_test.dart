import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';

void main() {
  test('phone avatar viewport stays full body above composer', () {
    final safeArea = HomeAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );

    expect(safeArea.top, inInclusiveRange(0.16, 0.19));
    expect(safeArea.bottom, inInclusiveRange(0.10, 0.14));
    expect(safeArea.top, greaterThan(safeArea.bottom));
    expect(1 - safeArea.top - safeArea.bottom, greaterThanOrEqualTo(0.68));
  });

  test('home avatar viewport keeps head below hud while staying enlarged', () {
    final safeArea = HomeAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );

    final visibleBand = 1 - safeArea.top - safeArea.bottom;
    expect(safeArea.top, greaterThanOrEqualTo(0.16));
    expect(safeArea.bottom, inInclusiveRange(0.10, 0.14));
    expect(visibleBand, inInclusiveRange(0.68, 0.74));
  });

  test('keyboard does not resize or shift home avatar viewport', () {
    final closedSafeArea = HomeAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );
    final openSafeArea = HomeAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: const EdgeInsets.only(bottom: 320),
    );

    expect(openSafeArea.top, closedSafeArea.top);
    expect(openSafeArea.bottom, closedSafeArea.bottom);
  });

  test(
    'keyboard animation and narrow screens keep the original Home camera',
    () {
      const padding = EdgeInsets.only(top: 59, bottom: 34);
      for (final size in [const Size(393, 852), const Size(320, 800)]) {
        final resting = HomeAvatarViewportPolicy.safeAreaFor(
          size: size,
          padding: padding,
          viewInsets: EdgeInsets.zero,
        );
        for (final inset in [10.0, 34.0, 100.0, 320.0, 380.0]) {
          expect(
            HomeAvatarViewportPolicy.safeAreaFor(
              size: size,
              padding: padding,
              viewInsets: EdgeInsets.only(bottom: inset),
            ),
            resting,
          );
        }
      }
    },
  );

  test('composer bottom never dips below resting safe-area position', () {
    final resting = HomeAvatarViewportPolicy.composerBottomFor(
      padding: const EdgeInsets.only(bottom: 34),
      viewInsets: EdgeInsets.zero,
    );
    final keyboardAlmostClosed = HomeAvatarViewportPolicy.composerBottomFor(
      padding: const EdgeInsets.only(bottom: 34),
      viewInsets: const EdgeInsets.only(bottom: 10),
    );
    final keyboardOpen = HomeAvatarViewportPolicy.composerBottomFor(
      padding: const EdgeInsets.only(bottom: 34),
      viewInsets: const EdgeInsets.only(bottom: 320),
    );

    expect(resting, 42);
    expect(keyboardAlmostClosed, resting);
    expect(keyboardOpen, 328);
  });
}
