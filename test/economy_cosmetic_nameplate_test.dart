import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/domain/cosmetic_appearance.dart';
import 'package:maaso/src/features/economy/presentation/cosmetic_nameplate.dart';

void main() {
  test(
    'public cosmetic parser rejects unknown renderers and mismatched slots',
    () {
      final frame = {
        'kind': 'frame',
        'renderId': 'aurora',
        'nameEn': 'Aurora',
        'nameZh': '极光',
      };
      expect(
        CosmeticAppearance.fromJson({'frame': frame}).frame!.renderId,
        'aurora',
      );
      expect(
        () => CosmeticAppearance.fromJson({'title': frame}),
        throwsFormatException,
      );
      expect(
        () => CosmeticStyle.fromJson({
          ...frame,
          'renderId': 'https://remote/script',
        }),
        throwsFormatException,
      );
      expect(CosmeticAppearance.fromJson(null).isEmpty, true);
    },
  );
  testWidgets('frame and localized title preserve the original identity role', (
    tester,
  ) async {
    final appearance = CosmeticAppearance.fromJson({
      'frame': {
        'kind': 'frame',
        'renderId': 'aurora',
        'nameEn': 'Aurora',
        'nameZh': '极光',
      },
      'title': {
        'kind': 'title',
        'renderId': 'ribbon',
        'nameEn': 'Stargazer',
        'nameZh': '观星者',
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CosmeticNameplate(
            appearance: appearance,
            chinese: true,
            child: const Text('Luna (Native)'),
          ),
        ),
      ),
    );
    expect(find.text('Luna (Native)'), findsOneWidget);
    expect(find.text('观星者'), findsOneWidget);
    expect(tester.takeException(), null);
  });
}
