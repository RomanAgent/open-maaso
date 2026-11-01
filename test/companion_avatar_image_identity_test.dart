import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/identity/domain/companion_profile.dart';
import 'package:maaso/src/features/identity/presentation/companion_avatar.dart';

CompanionProfile _photoProfile(int red) {
  final pixels = image.Image(width: 4, height: 4);
  image.fill(pixels, color: image.ColorRgb8(red, 80, 120));
  return CompanionProfile(avatarJpeg: base64Encode(image.encodeJpg(pixels)));
}

Widget _avatarHost(CompanionProfile? profile, {int rebuild = 0}) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        Text('rebuild $rebuild'),
        CompanionAvatar(
          key: const ValueKey('header-avatar'),
          profile: profile,
          size: 40,
        ),
        CompanionAvatar(
          key: const ValueKey('profile-avatar'),
          profile: profile,
          size: 80,
        ),
      ],
    ),
  ),
);

MemoryImage _photoProvider(WidgetTester tester, String key) {
  final avatarImage = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(Image),
  );
  return tester.widget<Image>(avatarImage).image as MemoryImage;
}

void main() {
  test('one profile keeps the same immutable decoded photo', () {
    final profile = _photoProfile(30);
    final bytes = profile.avatarBytes!;
    final original = List<int>.of(bytes);

    for (var read = 0; read < 20; read++) {
      expect(profile.avatarBytes, same(bytes));
    }
    expect(() => bytes[0] = 0, throwsUnsupportedError);
    expect(() => bytes.setRange(0, 2, [0, 0]), throwsUnsupportedError);
    expect(profile.avatarBytes, orderedEquals(original));
    expect(profile.toJson()['avatarJpeg'], base64Encode(original));
  });

  test(
    'separate profiles and photo changes do not share mutable image data',
    () {
      final first = _photoProfile(30);
      final restored = CompanionProfile.fromJson(first.toJson());
      final changed = first.copyWith(avatarJpeg: _photoProfile(220).avatarJpeg);

      expect(restored.avatarBytes, orderedEquals(first.avatarBytes!));
      expect(restored.avatarBytes, isNot(same(first.avatarBytes)));
      expect(changed.avatarBytes, isNot(orderedEquals(first.avatarBytes!)));
      expect(first.avatarBytes, orderedEquals(base64Decode(first.avatarJpeg)));
      expect(CompanionProfile().avatarBytes, isNull);
      expect(CompanionProfile(avatarPreset: 'moon').avatarBytes, isNull);
    },
  );

  testWidgets(
    'header and profile photo cache keys survive unrelated widget rebuilds',
    (tester) async {
      final profile = _photoProfile(30);
      await tester.pumpWidget(_avatarHost(profile));
      final original = await _photoProvider(
        tester,
        'header-avatar',
      ).obtainKey(ImageConfiguration.empty);

      for (var rebuild = 1; rebuild <= 20; rebuild++) {
        await tester.pumpWidget(_avatarHost(profile, rebuild: rebuild));
        final header = await _photoProvider(
          tester,
          'header-avatar',
        ).obtainKey(ImageConfiguration.empty);
        final detail = await _photoProvider(
          tester,
          'profile-avatar',
        ).obtainKey(ImageConfiguration.empty);
        expect(header, equals(original));
        expect(detail, equals(original));
        expect(header.hashCode, original.hashCode);
        expect(detail.hashCode, original.hashCode);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new photos and empty profiles replace the old image providers', (
    tester,
  ) async {
    final first = _photoProfile(30);
    final second = _photoProfile(220);
    await tester.pumpWidget(_avatarHost(first));
    final oldKey = await _photoProvider(
      tester,
      'header-avatar',
    ).obtainKey(ImageConfiguration.empty);

    await tester.pumpWidget(_avatarHost(second));
    for (final key in ['header-avatar', 'profile-avatar']) {
      final provider = _photoProvider(tester, key);
      expect(await provider.obtainKey(ImageConfiguration.empty), isNot(oldKey));
      expect(provider.bytes, orderedEquals(base64Decode(second.avatarJpeg)));
    }

    await tester.pumpWidget(
      _avatarHost(CompanionProfile(avatarPreset: 'moon')),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.nightlight_round), findsNWidgets(2));

    await tester.pumpWidget(_avatarHost(first));
    expect(find.byType(Image), findsNWidgets(2));
    await tester.pumpWidget(_avatarHost(null));
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.public_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
