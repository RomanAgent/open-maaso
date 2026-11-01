import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/unity_webgl_avatar_host.dart';

void main() {
  testWidgets('non-Web build keeps the supplied avatar fallback', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: UnityWebGLAvatarHost(
          viewportActive: true,
          fallback: Text('avatar fallback'),
        ),
      ),
    );

    expect(find.text('avatar fallback'), findsOneWidget);
  });
}
