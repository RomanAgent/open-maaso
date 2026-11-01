import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_gateway.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_readiness.dart';

import '../tool/project_harness/project_build_readiness_probe.dart';

ProjectBuildV2Readiness server({
  bool enabled = true,
  bool workerReady = true,
  bool production = true,
  List<String> keys = const ['reviewed'],
}) => ProjectBuildV2Readiness.fromJson({
  'schemaVersion': 2,
  'enabled': enabled,
  'workerReady': workerReady,
  'verifierKeyIds': keys,
  'profile': ProjectBuildV2Readiness.verificationProfile,
  'runtime': production ? 'runsc' : 'runc',
  'productionIsolation': production,
});

void main() {
  test(
    'disabled client still reads service but cannot advertise creation',
    () async {
      var reads = 0;
      final receipt = await const ProjectBuildReadinessProbe().inspect(
        debugBuild: true,
        clientFlagEnabled: false,
        clientCreationEnabled: false,
        accountMounted: true,
        isForeground: () => true,
        trustedKeyIds: {'reviewed'},
        isCurrent: () => true,
        hostCreationReady: () => false,
        readReadiness: () async {
          reads++;
          return server();
        },
      );
      expect(reads, 1);
      expect(receipt['creationReady'], isFalse);
      expect(receipt['blockedChecks'], contains('clientFlagEnabled'));
      expect(receipt['modelCalls'], 0);
      expect(receipt['modelExecutionInvoked'], isFalse);
      expect(receipt['credentialsExported'], isFalse);
    },
  );

  test(
    'ready requires production response and actual host admission',
    () async {
      Future<Map<String, Object?>> probe({
        bool production = true,
        bool hostReady = true,
        Set<String> trusted = const {'reviewed'},
      }) => const ProjectBuildReadinessProbe().inspect(
        debugBuild: true,
        clientFlagEnabled: true,
        clientCreationEnabled: true,
        accountMounted: true,
        isForeground: () => true,
        trustedKeyIds: trusted,
        isCurrent: () => true,
        hostCreationReady: () => hostReady,
        readReadiness: () async => server(production: production),
      );
      expect((await probe())['creationReady'], isTrue);
      final development = await probe(production: false);
      expect(development['creationReady'], isFalse);
      expect(development['blockedChecks'], contains('productionIsolation'));
      expect((await probe(hostReady: false))['creationReady'], isFalse);
      final mismatch = await probe(trusted: {'different'});
      expect(mismatch['creationReady'], isFalse);
      expect(mismatch['blockedChecks'], contains('verifierTrusted'));
    },
  );

  test('missing account or non-debug build performs no API read', () async {
    for (final (debug, mounted) in [(false, true), (true, false)]) {
      var reads = 0;
      final receipt = await const ProjectBuildReadinessProbe().inspect(
        debugBuild: debug,
        clientFlagEnabled: true,
        clientCreationEnabled: true,
        accountMounted: mounted,
        isForeground: () => true,
        trustedKeyIds: {'reviewed'},
        isCurrent: () => true,
        hostCreationReady: () => true,
        readReadiness: () async {
          reads++;
          return server();
        },
      );
      expect(reads, 0);
      expect(receipt['creationReady'], isFalse);
    }
  });

  test('404 receipt retains status without raw exception data', () async {
    final receipt = await const ProjectBuildReadinessProbe().inspect(
      debugBuild: true,
      clientFlagEnabled: false,
      clientCreationEnabled: false,
      accountMounted: true,
      isForeground: () => true,
      trustedKeyIds: {'reviewed'},
      isCurrent: () => true,
      hostCreationReady: () => false,
      readReadiness: () async => throw ProjectBuildV2RequestException(
        404,
        'sensitive-token private-account private-origin',
      ),
    );
    expect(receipt['httpStatus'], 404);
    expect(receipt['blockedChecks'], contains('serviceReadSucceeded'));
    expect(jsonEncode(receipt), isNot(contains('sensitive-token')));
    expect(jsonEncode(receipt), isNot(contains('private-account')));
    expect(jsonEncode(receipt), isNot(contains('private-origin')));
  });

  test(
    'scope change while awaiting readiness invalidates successful result',
    () async {
      var current = true;
      final receipt = await const ProjectBuildReadinessProbe().inspect(
        debugBuild: true,
        clientFlagEnabled: true,
        clientCreationEnabled: true,
        accountMounted: true,
        isForeground: () => true,
        trustedKeyIds: {'reviewed'},
        isCurrent: () => current,
        hostCreationReady: () => true,
        readReadiness: () async {
          current = false;
          return server();
        },
      );
      expect(receipt['creationReady'], isFalse);
      expect(receipt['blockedChecks'], contains('accountCurrent'));
      final checks = receipt['checks']! as Map<String, bool>;
      expect(checks['serviceReadSucceeded'], isFalse);
      expect(checks['hostCreationReady'], isFalse);
    },
  );
  test(
    'background transition before host signal settles cannot advertise ready',
    () async {
      var foreground = true;
      final receipt = await const ProjectBuildReadinessProbe().inspect(
        debugBuild: true,
        clientFlagEnabled: true,
        clientCreationEnabled: true,
        accountMounted: true,
        isForeground: () => foreground,
        trustedKeyIds: {'reviewed'},
        isCurrent: () => true,
        hostCreationReady: () => true,
        readReadiness: () async {
          foreground = false;
          return server();
        },
      );
      expect(receipt['creationReady'], isFalse);
      expect(receipt['blockedChecks'], contains('foreground'));
      final checks = receipt['checks']! as Map<String, bool>;
      expect(checks['accountCurrent'], isTrue);
      expect(checks['serviceReadSucceeded'], isTrue);
      expect(checks['foreground'], isFalse);
    },
  );
}
