import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/features/identity/data/companion_profile_store.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'companion persistence fences wrong or retired account contexts',
    () async {
      final db = await databaseFactoryMemory.openDatabase('companion-scope');
      addTearDown(db.close);
      var active = true;
      final owner = SembastCompanionProfileStore(
        database: db,
        contextKey: 'prod|owner',
        isCurrent: () => active,
      );
      final profile = CompanionProfile(
        version: 2,
        avatarPreset: 'star',
        agentGender: 'female',
        onboardingVersion: 1,
      );
      await owner.write(profile);
      final wrong = SembastCompanionProfileStore(
        database: db,
        contextKey: 'prod|other',
        isCurrent: () => true,
      );
      await expectLater(
        wrong.read(),
        throwsA(isA<CompanionProfileException>()),
      );
      await expectLater(
        wrong.write(profile.copyWith(avatarPreset: 'leaf')),
        throwsA(isA<CompanionProfileException>()),
      );
      expect((await owner.read())!.avatarPreset, 'star');
      active = false;
      await expectLater(
        owner.read(),
        throwsA(isA<CompanionProfileException>()),
      );
      await expectLater(
        owner.write(profile),
        throwsA(isA<CompanionProfileException>()),
      );
    },
  );

  test(
    'explicit setup gender preserves local notes and ordinary gender lock',
    () async {
      final dir = await Directory.systemTemp.createTemp('companion-soul-');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, (_) async => dir.path);
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(paths, null);
        await dir.delete(recursive: true);
      });
      final scope = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner',
      ).agent('self');
      final soul = await SoulService().init(scope: scope);
      await soul.update(
        name: 'Tina',
        age: 24,
        gender: 'female',
        notesReplace: 'An existing private memory\nKeep this unchanged.',
      );
      soul.lockGender();
      await soul.update(gender: 'male');
      expect(soul.gender.value, 'female');
      await soul.applyCompanionSetupGender('nonbinary');
      final restored = await SoulService().init(scope: scope);
      expect(restored.gender.value, 'nonbinary');
      expect(restored.genderLocked.value, isTrue);
      expect(restored.name.value, 'Tina');
      expect(restored.age.value, 24);
      expect(
        restored.notes.value,
        'An existing private memory\nKeep this unchanged.',
      );
      await expectLater(
        restored.applyCompanionSetupGender('invalid'),
        throwsA(isA<FormatException>()),
      );
      expect(restored.gender.value, 'nonbinary');
      final other = await SoulService().init(
        scope: AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'other',
        ).agent('self'),
      );
      expect(other.notes.value, isEmpty);
      expect(other.gender.value, isNull);
    },
  );
}
