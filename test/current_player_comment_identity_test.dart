import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/presentation/current_player_identity_badge.dart';
import 'identity_test_support.dart';

void main() {
  setUp(() => appServices.reset());
  tearDown(() => appServices.reset());
  testWidgets('confirmed rename stays visible while local projection drains', (
    tester,
  ) async {
    final pendingProjection = Completer<void>();
    final identity = IdentityService(
      gateway: FakeIdentityGateway(initial: identityFixture(player: 'Sky')),
      projectProfile: (profile) async {
        if (profile.version == 2) await pendingProjection.future;
      },
    );
    await identity.load();
    appServices.put<IdentityService>(identity);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: CurrentPlayerIdentityBadge())),
      ),
    );
    expect(find.text('Sky (Alien)', findRichText: true), findsOneWidget);
    final saving = identity.save(playerName: 'New Sky', agentName: 'Wheat');
    await tester.pump();
    expect(identity.completed, isFalse);
    expect(find.text('New Sky (Alien)', findRichText: true), findsOneWidget);
    pendingProjection.complete();
    await saving;
    await tester.pump();
    expect(identity.completed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'missing public identity never substitutes a private or Agent name',
    (tester) async {
      final identity = IdentityService(gateway: FakeIdentityGateway());
      await identity.load();
      appServices.put<IdentityService>(identity);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: CurrentPlayerIdentityBadge()),
          ),
        ),
      );
      expect(find.byType(RichText), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
