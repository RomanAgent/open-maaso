import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_project_build_edit_banner.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() => appServices.reset());
  for (final brightness in Brightness.values) {
    testWidgets(
      'edit banner reserves its actual scaled height at 320px and 2x in $brightness',
      (tester) async {
        AppLocalization.updateLocale(const Locale('zh', 'CN'));
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 240);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var clears = 0;
        double? reserved;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 240),
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: Builder(
                  builder: (context) {
                    reserved = HomeProjectBuildEditBanner.heightFor(context);
                    return Align(
                      alignment: Alignment.topCenter,
                      child: HomeProjectBuildEditBanner(
                        title: '一份名称很长但仍然保留当前版本的露营物资清单',
                        onClear: () => clears++,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final banner = tester.getRect(
          find.byKey(const ValueKey('project-build-edit-banner')),
        );
        final label = tester.getRect(
          find.byKey(const ValueKey('project-build-edit-reference')),
        );
        expect(banner.height, reserved);
        expect(label.bottom, lessThanOrEqualTo(banner.bottom));
        expect(label.left, greaterThanOrEqualTo(banner.left));
        expect(label.right, lessThanOrEqualTo(banner.right));
        final button = tester.getSize(
          find.byKey(const ValueKey('project-build-edit-clear')),
        );
        expect(button.width, greaterThanOrEqualTo(48));
        expect(button.height, greaterThanOrEqualTo(48));
        expect(find.byType(BackdropFilter), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('project-build-edit-clear')),
        );
        expect(clears, 1);
      },
    );
  }
  testWidgets(
    'disabled edit clear keeps its semantic control and does not run',
    (tester) async {
      AppLocalization.updateLocale(const Locale('en', 'US'));
      var clears = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeProjectBuildEditBanner(
              title: 'Checklist',
              enabled: false,
              onClear: () => clears++,
            ),
          ),
        ),
      );
      expect(find.text('Editing: Checklist'), findsOneWidget);
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('project-build-edit-clear')),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, 'Stop editing this project');
      await tester.tap(find.byKey(const ValueKey('project-build-edit-clear')));
      expect(clears, 0);
    },
  );
}
