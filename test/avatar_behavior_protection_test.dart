import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_protection.dart';

void main() {
  tearDown(appServices.reset);

  test(
    'successful expression protects only its agent until its duration ends',
    () {
      var now = DateTime(2026, 9, 2, 12);
      final protection = AvatarBehaviorProtection(now: () => now);
      final hold = protection.begin('self', const Duration(seconds: 2));
      hold.complete(applied: true);

      expect(protection.isProtected('self'), isTrue);
      expect(protection.isProtected('peer'), isFalse);
      now = now.add(const Duration(milliseconds: 1999));
      expect(protection.isProtected('self'), isTrue);
      now = now.add(const Duration(milliseconds: 1));
      expect(protection.isProtected('self'), isFalse);
    },
  );

  test('failed older expression cannot release a newer expression', () {
    final protection = AvatarBehaviorProtection();
    final failed = protection.begin('self', const Duration(seconds: 2));
    final current = protection.begin('self', const Duration(seconds: 1));
    current.complete(applied: true);
    failed.complete(applied: false);

    expect(protection.isProtected('self'), isTrue);
  });

  test('failed expressions immediately release their own protection', () {
    final protection = AvatarBehaviorProtection();
    protection
        .begin('self', const Duration(seconds: 2))
        .complete(applied: false);

    expect(protection.isProtected('self'), isFalse);
  });

  test('hung or oversized expressions cannot permanently block ambience', () {
    var now = DateTime(2026, 9, 2, 12);
    final protection = AvatarBehaviorProtection(now: () => now);
    protection.begin('hung', const Duration(seconds: 1));
    protection
        .begin('oversized', const Duration(hours: 1))
        .complete(applied: true);

    now = now.add(const Duration(seconds: 5));
    expect(protection.isProtected('hung'), isFalse);
    expect(protection.isProtected('oversized'), isFalse);
  });

  test('account close clears protection and ignores late completion', () async {
    final protection = appServices.put(AvatarBehaviorProtection());
    final hold = protection.begin('self', const Duration(seconds: 2));
    await appServices.reset();
    hold.complete(applied: true);

    expect(protection.isProtected('self'), isFalse);
  });

  test('late completion cannot revive an unpruned expired pending hold', () {
    var now = DateTime(2026, 9, 2, 12);
    final protection = AvatarBehaviorProtection(now: () => now);
    final hold = protection.begin('self', const Duration(seconds: 2));
    now = now.add(const Duration(seconds: 5));
    hold.complete(applied: true);
    expect(protection.isProtected('self'), isFalse);
  });

  test('old ambient continuation stays invalid after expression failure', () {
    final protection = AvatarBehaviorProtection();
    final revision = protection.revisionFor('self');
    expect(protection.allowsAmbient('self', revision), isTrue);
    protection
        .begin('self', const Duration(seconds: 1))
        .complete(applied: false);
    expect(protection.isProtected('self'), isFalse);
    expect(protection.allowsAmbient('self', revision), isFalse);
    expect(
      protection.allowsAmbient('self', protection.revisionFor('self')),
      isTrue,
    );
  });
}
