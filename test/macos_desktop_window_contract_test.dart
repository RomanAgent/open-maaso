import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pet mode reverses the macOS frameless opaque-window side effect', () {
    final source = File(
      'lib/src/desktop/infrastructure/'
      'window_manager_desktop_window_gateway.dart',
    ).readAsStringSync();

    final frameless = source.indexOf('windowManager.setAsFrameless()');
    final macOSGuard = source.indexOf('if (Platform.isMacOS)', frameless);
    final hiddenTitleBar = source.indexOf(
      'windowManager.setTitleBarStyle(',
      macOSGuard,
    );
    final hiddenTitleBarStyle = source.indexOf(
      'TitleBarStyle.hidden',
      hiddenTitleBar,
    );
    final hiddenWindowButtons = source.indexOf(
      'windowButtonVisibility: false',
      hiddenTitleBarStyle,
    );
    final clearBackground = source.indexOf(
      'windowManager.setBackgroundColor(const Color(0x00000000))',
      hiddenWindowButtons,
    );

    expect(frameless, greaterThanOrEqualTo(0));
    expect(macOSGuard, greaterThan(frameless));
    expect(hiddenTitleBar, greaterThan(macOSGuard));
    expect(hiddenTitleBarStyle, greaterThan(hiddenTitleBar));
    expect(hiddenWindowButtons, greaterThan(hiddenTitleBarStyle));
    expect(clearBackground, greaterThan(hiddenWindowButtons));
  });

  test('app mode restores native buttons and the white app background', () {
    final source = File(
      'lib/src/desktop/infrastructure/'
      'window_manager_desktop_window_gateway.dart',
    ).readAsStringSync();

    final enterAppMode = source.indexOf('Future<void> enterAppMode(');
    final normalTitleBar = source.indexOf(
      'windowManager.setTitleBarStyle(',
      enterAppMode,
    );
    final normalTitleBarStyle = source.indexOf(
      'TitleBarStyle.normal',
      normalTitleBar,
    );
    final visibleWindowButtons = source.indexOf(
      'windowButtonVisibility: true',
      normalTitleBarStyle,
    );
    final appBackground = source.indexOf(
      'windowManager.setBackgroundColor(ColorConstant.backgroundColor)',
      visibleWindowButtons,
    );

    expect(enterAppMode, greaterThanOrEqualTo(0));
    expect(normalTitleBar, greaterThan(enterAppMode));
    expect(normalTitleBarStyle, greaterThan(normalTitleBar));
    expect(visibleWindowButtons, greaterThan(normalTitleBarStyle));
    expect(appBackground, greaterThan(visibleWindowButtons));
    final appMode = source.substring(
      enterAppMode,
      source.indexOf('Future<void> startDragging()', enterAppMode),
    );
    expect(appMode, isNot(contains('Color(0x00000000)')));
  });

  test('native macOS titlebar shares the white app window background', () {
    final source = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();

    expect(source, contains('self.backgroundColor = NSColor.white'));
    expect(
      source,
      contains('flutterViewController.backgroundColor = NSColor.clear'),
    );
    expect(source, contains('titlebarAppearsTransparent = true'));
    expect(source, contains('titlebarSeparatorStyle = .none'));

    final nib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(
      nib,
      contains(
        '<windowStyleMask key="styleMask" titled="YES" closable="YES" '
        'miniaturizable="YES" resizable="YES"/>',
      ),
    );
    expect(source, isNot(contains('styleMask')));
    expect(source, isNot(contains('standardWindowButton')));
    expect(source, isNot(contains('titleVisibility')));
  });

  test(
    'native titlebar styling is restored before app mode becomes visible',
    () {
      final source = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final showStart = source.indexOf('override func setIsVisible(');
      final focusStart = source.indexOf('override func makeKeyAndOrderFront(');
      final appearanceStart = source.indexOf(
        'private func applyUnifiedTitlebarAppearance()',
      );
      expect(showStart, greaterThanOrEqualTo(0));
      expect(focusStart, greaterThan(showStart));
      expect(appearanceStart, greaterThan(focusStart));

      final show = source.substring(showStart, focusStart);
      final focus = source.substring(focusStart, appearanceStart);
      expect(show, contains('if flag {'));
      expect(show, contains('applyUnifiedTitlebarAppearance()'));
      expect(show, contains('super.setIsVisible(flag)'));
      expect(focus, contains('applyUnifiedTitlebarAppearance()'));
      expect(focus, contains('super.makeKeyAndOrderFront(sender)'));
      expect(
        show.indexOf('applyUnifiedTitlebarAppearance()'),
        lessThan(show.indexOf('super.setIsVisible(flag)')),
      );
      expect(
        focus.indexOf('applyUnifiedTitlebarAppearance()'),
        lessThan(focus.indexOf('super.makeKeyAndOrderFront(sender)')),
      );

      // The existing background/brightness channel can still control the color;
      // restoring native chrome must not force light appearance on every show.
      final appearance = source.substring(
        appearanceStart,
        source.indexOf('override func close()', appearanceStart),
      );
      expect(appearance, isNot(contains('backgroundColor =')));
      expect(appearance, isNot(contains('appearance =')));
    },
  );

  test('closing the main window keeps the desktop companion process alive', () {
    final source = File('macos/Runner/AppDelegate.swift').readAsStringSync();

    expect(source, contains('applicationShouldTerminateAfterLastWindowClosed'));
    expect(source, contains('return false'));
  });

  test(
    'desktop pet portal activation waits until the first frame completes',
    () {
      final source = File(
        'lib/src/desktop/presentation/desktop_pet_stage.dart',
      ).readAsStringSync();

      expect(source, contains('WidgetsBinding.instance.addPostFrameCallback'));
      expect(source, contains('nextPortal.summon()'));
      expect(source, contains('SchedulerPhase.persistentCallbacks'));
    },
  );
}
