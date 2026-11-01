import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

void main() {
  testWidgets(
    'secondary content frame caps wide layouts and fills narrow ones',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1400, 800));

      await tester.pumpWidget(
        const MaterialApp(
          home: AppSecondaryScaffold(
            contentMaxWidth: 960,
            header: SizedBox(height: 44),
            body: ColoredBox(color: Colors.red),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(AppSecondaryScaffold.contentFrameKey)).width,
        960,
      );

      await tester.binding.setSurfaceSize(const Size(600, 800));
      await tester.pump();

      expect(
        tester.getSize(find.byKey(AppSecondaryScaffold.contentFrameKey)).width,
        600,
      );
    },
  );

  testWidgets('secondary content frame remains opt-in', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppSecondaryScaffold(
          header: SizedBox(height: 44),
          body: SizedBox.expand(),
        ),
      ),
    );

    expect(find.byKey(AppSecondaryScaffold.contentFrameKey), findsNothing);
  });
}
