import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:maaso/src/features/auth/presentation/login_page.dart';

void main() {
  test('login avatar viewport keeps head below top crop on phone screens', () {
    final safeArea = LoginAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );

    expect(safeArea.top, inInclusiveRange(0.15, 0.17));
    expect(safeArea.bottom, inInclusiveRange(0.12, 0.14));
    expect(1 - safeArea.top - safeArea.bottom, inInclusiveRange(0.70, 0.72));
  });

  test('login avatar viewport is stable when keyboard is open', () {
    final closedSafeArea = LoginAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );
    final openSafeArea = LoginAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: const EdgeInsets.only(bottom: 320),
    );

    expect(openSafeArea.top, closedSafeArea.top);
    expect(openSafeArea.bottom, closedSafeArea.bottom);
  });

  test('login avatar viewport matches home avatar viewport', () {
    final homeSafeArea = HomeAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );
    final loginSafeArea = LoginAvatarViewportPolicy.safeAreaFor(
      size: const Size(393, 852),
      padding: const EdgeInsets.only(top: 59, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );

    expect(loginSafeArea.top, homeSafeArea.top);
    expect(loginSafeArea.bottom, homeSafeArea.bottom);
  });
}
