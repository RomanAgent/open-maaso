import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/app_invocation_chat_reference.dart';
import 'package:maaso/src/features/chat/presentation/widgets/app_invocation_chat_card.dart';

import 'support/app_invocation_recovery_fixture.dart';

void main() {
  late InvocationRecoveryFixture f;
  Future<void> create(WidgetTester tester) async {
    final created = (await tester.runAsync(InvocationRecoveryFixture.create))!;
    f = created;
    addTearDown(() async => tester.runAsync(created.close));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  Widget card({
    AppInvocationChatReference? reference,
    Future<void> Function(AppInvocationChatReference)? onRecover,
    Future<void> Function(AppInvocationChatReference)? onRestore,
    bool enabled = true,
    double scale = 1,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 240,
            child: AppInvocationChatCard(
              reference: reference ?? f.reference,
              sessionId: 'self',
              service: f.recovery,
              enabled: enabled,
              onRecover: onRecover,
              onRestore: onRestore,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'unverified imported metadata never shows its claimed source or controls',
    (tester) async {
      await create(tester);
      await tester.pumpWidget(
        card(
          reference: f.altered({'sourceTitle': 'Forged trusted work'}),
          onRecover: (_) async {},
          onRestore: (_) async {},
        ),
      );
      await settle(tester);
      expect(find.text('Forged trusted work'), findsNothing);
      expect(find.text('Action record unavailable'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'verified controls recheck the journal and prevent duplicate taps',
    (tester) async {
      await create(tester);
      final finish = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        card(
          onRecover: (reference) async {
            calls++;
            expect(reference.invocationId, f.run.invocationId);
            await finish.future;
          },
          onRestore: (_) async {},
        ),
      );
      await settle(tester);
      expect(find.text('Flexible work'), findsOneWidget);
      expect(find.text('Finished; result ready to retrieve'), findsOneWidget);
      await tester.tap(find.text('Retrieve result'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tap(find.text('Retrieve result'));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('Working…'), findsOneWidget);
      finish.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scope change removes controls and never calls an old owner', (
    tester,
  ) async {
    await create(tester);
    var calls = 0;
    await tester.pumpWidget(card(onRecover: (_) async => calls++));
    await settle(tester);
    f.current = false;
    await tester.tap(find.text('Retrieve result'));
    await settle(tester);
    expect(calls, 0);
    await tester.pumpWidget(card(onRecover: (_) async => calls++));
    await settle(tester);
    expect(find.text('Flexible work'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets(
    'narrow large text wraps and callback-free hosts stay read-only',
    (tester) async {
      await create(tester);
      await tester.pumpWidget(
        card(scale: 2, onRecover: (_) async {}, onRestore: (_) async {}),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Restore draft'), findsOneWidget);
      await tester.pumpWidget(card());
      await settle(tester);
      expect(find.text('Flexible work'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    },
  );
}
