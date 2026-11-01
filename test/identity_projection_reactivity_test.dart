import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

import 'identity_test_support.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  Widget status(IdentityService identity) => MaterialApp(
    home: AppReactiveBuilder(
      () => Text(identity.completed ? 'ready' : 'awaiting identity'),
    ),
  );

  testWidgets('public controls react after delayed identity projection', (
    tester,
  ) async {
    final projection = Completer<void>();
    final identity = IdentityService(
      gateway: FakeIdentityGateway(initial: identityFixture()),
      projectProfile: (_) => projection.future,
    );
    await tester.pumpWidget(status(identity));
    final loading = identity.load();
    await tester.pump();
    expect(identity.profile?.completed, isTrue);
    expect(identity.completed, isFalse);
    expect(find.text('awaiting identity'), findsOneWidget);
    projection.complete();
    await loading;
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    identity.onClose();
  });

  testWidgets('failed projection stays closed and retry notifies controls', (
    tester,
  ) async {
    var fail = true;
    final gateway = FakeIdentityGateway(initial: identityFixture());
    final identity = IdentityService(
      gateway: gateway,
      projectProfile: (_) async {
        if (fail) throw StateError('projection_failed');
      },
    );
    await tester.pumpWidget(status(identity));
    await expectLater(identity.load(), throwsA(isA<StateError>()));
    await tester.pump();
    expect(find.text('awaiting identity'), findsOneWidget);
    fail = false;
    await identity.save(playerName: 'Star', agentName: 'Wheat');
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(gateway.writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    identity.onClose();
  });

  testWidgets('retiring during projection never enables public controls', (
    tester,
  ) async {
    final projection = Completer<void>();
    final identity = IdentityService(
      gateway: FakeIdentityGateway(initial: identityFixture()),
      projectProfile: (_) => projection.future,
    );
    await tester.pumpWidget(status(identity));
    final loading = identity.load();
    final assertion = expectLater(
      loading,
      throwsA(
        isA<IdentityException>().having(
          (error) => error.failure,
          'failure',
          IdentityFailure.contextChanged,
        ),
      ),
    );
    await tester.pump();
    identity.onClose();
    projection.complete();
    await assertion;
    await tester.pump();
    expect(find.text('awaiting identity'), findsOneWidget);
    expect(find.text('ready'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
