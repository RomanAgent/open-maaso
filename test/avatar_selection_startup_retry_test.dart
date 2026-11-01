import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_startup_retry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Home retry joins the account-bound startup pass already in flight',
    () async {
      final config = AvatarConfigService();
      addTearDown(config.onClose);
      final retry = AvatarSelectionStartupRetry.forConfig(config);
      var ownerCurrent = true;
      var passes = 0;
      final release = Completer<void>();
      void requireOwner() {
        if (!ownerCurrent) throw StateError('account mount replaced');
      }

      final first = retry.run(
        reconcile: () async {
          passes++;
          await release.future;
          requireOwner();
        },
        requireCurrentMount: requireOwner,
      );
      await Future<void>.delayed(Duration.zero);
      expect(retry.hasBoundRetry, isTrue);
      final joined = retry.retryBound();
      expect(passes, 1);
      release.complete();
      await Future.wait([first, joined]);
      expect(passes, 1);

      ownerCurrent = false;
      await expectLater(retry.retryBound(), throwsStateError);
      expect(passes, 1);
    },
  );

  test(
    'an old account result cannot complete after its mount is replaced',
    () async {
      final config = AvatarConfigService();
      addTearDown(config.onClose);
      final retry = AvatarSelectionStartupRetry.forConfig(config);
      var ownerCurrent = true;
      var published = false;
      final release = Completer<void>();
      void requireOwner() {
        if (!ownerCurrent) throw StateError('account mount replaced');
      }

      final pending = retry.run(
        reconcile: () async {
          await release.future;
          requireOwner();
          published = true;
        },
        requireCurrentMount: requireOwner,
      );
      await Future<void>.delayed(Duration.zero);
      ownerCurrent = false;
      release.complete();
      await expectLater(pending, throwsStateError);
      expect(published, isFalse);
    },
  );
}
