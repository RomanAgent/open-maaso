import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_window_placement.dart';

void main() {
  const primary = DesktopWindowBounds(
    left: 0,
    top: 24,
    width: 1440,
    height: 876,
  );

  test('pet stays on the display containing the current window', () {
    const secondary = DesktopWindowBounds(
      left: 1440,
      top: 0,
      width: 1920,
      height: 1080,
    );
    final result = DesktopWindowPlacement.petBounds(
      current: const DesktopWindowBounds(
        left: 2800,
        top: 900,
        width: 500,
        height: 760,
      ),
      visibleDisplays: const <DesktopWindowBounds>[primary, secondary],
      primaryDisplay: primary,
    );

    expect(result.width, DesktopWindowPlacement.petWidth);
    expect(result.height, DesktopWindowPlacement.petHeight);
    expect(result.left, lessThanOrEqualTo(3028));
    expect(result.top, lessThanOrEqualTo(648));
  });

  test('off-screen app bounds are recovered onto the primary display', () {
    final result = DesktopWindowPlacement.appBounds(
      requested: const DesktopWindowBounds(
        left: 5000,
        top: 5000,
        width: 1000,
        height: 700,
      ),
      primaryDisplay: primary,
    );

    expect(result.left, 220);
    expect(result.top, 112);
    expect(result.width, 1000);
    expect(result.height, 700);
  });

  test('restored app bounds are clamped to the visible area', () {
    final result = DesktopWindowPlacement.appBounds(
      requested: const DesktopWindowBounds(
        left: -120,
        top: -80,
        width: 1200,
        height: 800,
      ),
      primaryDisplay: primary,
    );

    expect(result.left, 0);
    expect(result.top, 24);
    expect(result.width, 1200);
    expect(result.height, 800);
  });
}
