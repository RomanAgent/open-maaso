import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/economy/application/membership_page_adapter.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/presentation/membership_page.dart';
import 'profile_membership_test_support.dart';
import 'economy_store_purchase_test.dart' show storeNow;

Widget membershipPage(
  StorePurchaseService service, {
  AgentUiControlService? control,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) => ProviderScope(
  child: MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
    home: MembershipPage(
      route: '/membership',
      service: service,
      uiControl: control,
    ),
  ),
);

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  (MembershipGatewayFake, MembershipNativeFake, StorePurchaseService) fixture({
    bool noPrice = false,
  }) {
    final gateway = MembershipGatewayFake();
    final native = MembershipNativeFake()..missingPrice = noPrice;
    final service = StorePurchaseService(
      gateway: gateway,
      native: native,
      now: () => storeNow,
    );
    addTearDown(() async {
      service.onClose();
      await native.updates.close();
    });
    return (gateway, native, service);
  }

  testWidgets(
    'new tiers show genuine localized prices and selection does not charge',
    (tester) async {
      final (g, n, s) = fixture();
      await tester.pumpWidget(membershipPage(s));
      await tester.pumpAndSettle();
      for (final tier in ['free', 'basic', 'plus', 'pro_v2']) {
        expect(find.byKey(ValueKey('membership-select-$tier')), findsOneWidget);
      }
      for (final tier in ['pro', 'max', 'ultra']) {
        expect(find.byKey(ValueKey('membership-select-$tier')), findsNothing);
      }
      expect(find.text('Current: Free'), findsOneWidget);
      expect(find.text('Wallet and coin passes'), findsNothing);
      expect(find.text('钱包与币兑通行证'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('membership-select-basic')));
      await tester.pumpAndSettle();
      expect(find.text(r'Continue · LOCAL $9.90 / month'), findsOneWidget);
      expect(n.buys, 0);
      expect(g.calls, isNot(contains('checkout')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('purchase verifies full terms and waits for human confirmation', (
    tester,
  ) async {
    final (g, n, s) = fixture();
    await tester.pumpWidget(membershipPage(s));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('membership-select-basic')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('membership-purchase')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(g.membershipReads, 1);
    expect(find.textContaining('Verified Basic'), findsOneWidget);
    expect(n.buys, 0);
    await tester.tap(find.byKey(const ValueKey('membership-human-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(n.buys, 1);
    expect(g.calls, contains('checkout'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('membership-purchase')),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'unavailable terms or missing store prices cannot start payment',
    (tester) async {
      final (g, n, s) = fixture();
      g.unavailable = true;
      await tester.pumpWidget(membershipPage(s));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-select-plus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-purchase')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(n.buys, 0);
      expect(find.byType(AlertDialog), findsNothing);
      final (_, n2, s2) = fixture(noPrice: true);
      await tester.pumpWidget(membershipPage(s2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-select-basic')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('membership-purchase')),
            )
            .onPressed,
        isNull,
      );
      expect(n2.buys, 0);
    },
  );
  testWidgets(
    'retired account disables already-reviewed purchase and hides old status',
    (tester) async {
      final (_, n, s) = fixture();
      await tester.pumpWidget(membershipPage(s));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-select-basic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-purchase')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      s.onClose();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('membership-human-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('Verified Basic'), findsNothing);
      expect(n.buys, 0);
    },
  );
  testWidgets(
    'restore uses the account-owned native store and never creates a purchase',
    (tester) async {
      final (_, n, s) = fixture();
      await tester.pumpWidget(membershipPage(s));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-restore')));
      await tester.pumpAndSettle();
      expect(n.restores, 1);
      expect(n.buys, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'AppControl prepares selection without payment and is detached on exit',
    (tester) async {
      final (g, n, s) = fixture();
      final control = AgentUiControlService();
      addTearDown(control.onClose);
      await tester.pumpWidget(membershipPage(s, control: control));
      await tester.pumpAndSettle();
      final lease = control.coordinator
          .begin(
            sessionId: 'membership-test',
            purpose: 'Select plan',
            targetRoute: '/membership',
          )
          .value!;
      final adapter = control.adapters
          .resolve<MembershipPageAdapter>(route: '/membership', lease: lease)
          .value!;
      final execution = AppControlActionExecutionContext.host(
        requiresCommit: false,
        authorityIsCurrent: () => true,
        staleCode: 'stale',
      );
      expect(adapter.actionById('buy'), isNull);
      expect(adapter.actionById('restore'), isNull);
      expect(adapter.actionById('confirm'), isNull);
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: MembershipPageAdapter.prepareAction,
          arguments: {'tier': 'pro_v2'},
          executionContext: execution,
        )).value,
        {'prepared': true, 'charged': false},
      );
      await tester.pump();
      expect(n.buys, 0);
      expect(g.membershipReads, 0);
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: MembershipPageAdapter.prepareAction,
          arguments: {'tier': 'pro'},
          executionContext: execution,
        )).isSuccess,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('membership-select-basic')));
      await tester.pump();
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: MembershipPageAdapter.prepareAction,
          arguments: {'tier': 'plus'},
          executionContext: execution,
        )).isSuccess,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: MembershipPageAdapter.prepareAction,
          arguments: {'tier': 'basic'},
          executionContext: execution,
        )).isSuccess,
        isFalse,
      );
    },
  );
  for (final spec in [
    (const Size(320, 700), 2.0, Brightness.light),
    (const Size(812, 375), 2.0, Brightness.dark),
    (const Size(1024, 768), 1.0, Brightness.light),
  ]) {
    testWidgets('membership responsive ${spec.$1} scale ${spec.$2}', (
      tester,
    ) async {
      tester.view.physicalSize = spec.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (_, _, service) = fixture();
      await tester.pumpWidget(
        membershipPage(service, scale: spec.$2, brightness: spec.$3),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('membership-select-pro_v2')),
        250,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('membership-plans-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tapAt(
        tester.getTopLeft(
              find.byKey(const ValueKey('membership-select-pro_v2')),
            ) +
            const Offset(24, 24),
      );
      await tester.pumpAndSettle();
      if (spec.$1.height < 500) {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('membership-purchase')),
          200,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('membership-plans-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
      } else {
        await tester.ensureVisible(
          find.byKey(const ValueKey('membership-purchase')),
        );
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
