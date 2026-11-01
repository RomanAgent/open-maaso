import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'account runtime mounts desktop ASR after DB behind the desktop gate',
    () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final mount = _between(
        mainSource,
        'Future<AccountRuntimeLease> _mountAccountRuntime({',
        'class _MountedAccountRuntime',
      );
      final database = mount.indexOf('final mountedDatabase =');
      final gate = mount.indexOf(
        'if (platformCapabilities.supportsOnDeviceSpeechModels)',
      );
      final packs = mount.indexOf('putOwned<DesktopLocalAsrPackRuntime>');
      final service = mount.indexOf('putOwnedAsync<DesktopLocalAsrService>');
      final featureFlags = mount.indexOf('final featureFlags =');

      expect(database, greaterThanOrEqualTo(0));
      expect(gate, greaterThan(database));
      expect(packs, greaterThan(gate));
      expect(service, greaterThan(packs));
      expect(featureFlags, greaterThan(service));
      expect(mount, contains('SembastDesktopLocalAsrPreferenceStore'));
      expect(
        mount,
        contains('DesktopLocalAsrModelCatalog.productionSelectableModelPacks'),
      );
      expect(mount, contains('isCurrentMount: desktopLocalAsrMountIsCurrent'));
    },
  );

  test('account teardown drains recognizer before its pack runtime', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final drain = _between(
      mainSource,
      'Future<void> _drainAccountRuntimeProducers() async {',
      'void _registerDefaultVadServices()',
    );

    expect(drain, contains("'desktop_local_asr'"));
    expect(drain, contains('DesktopLocalAsrService>()?.sealAndDrain()'));
    expect(drain, contains("'desktop_local_asr_packs'"));
    expect(drain, contains('await desktopLocalAsrDrain;'));
    expect(drain, contains('DesktopLocalAsrPackRuntime>()?.sealAndDrain()'));
  });

  test('cold start and merely opening settings perform no ASR model IO', () {
    final serviceSource = File(
      'lib/src/core/services/desktop_local_asr_service.dart',
    ).readAsStringSync();
    final init = _between(
      serviceSource,
      'Future<DesktopLocalAsrService> init() async {',
      '  Future<void> selectModel(String modelId)',
    );
    expect(init, isNot(contains('_checkModelAvailable(')));
    expect(init, isNot(contains('_recognizerFactory.create(')));

    final settingsSource = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final prepare = _between(
      settingsSource,
      'Future<void> _prepareAdvancedBaseServices() async {',
      '  @override\n  Widget build(BuildContext context)',
    );
    final localAsrBuild = _between(
      settingsSource,
      'class _DesktopLocalAsrSectionState',
      'class _DesktopLocalAsrModelCard',
    );
    final buildStart = localAsrBuild.lastIndexOf(
      'Widget build(BuildContext context)',
    );
    expect(buildStart, greaterThanOrEqualTo(0));
    final build = localAsrBuild.substring(buildStart);

    expect(prepare, isNot(contains('DesktopLocalAsr')));
    expect(build, isNot(contains('runtime.resolve(')));
    expect(build, isNot(contains('runtime.isAvailable(')));
    expect(build, isNot(contains('importUserDirectory(')));
  });

  test('local ASR IO is conditionally isolated from web and mobile builds', () {
    final recognizerEntry = File(
      'lib/src/core/services/desktop_local_asr_recognizer.dart',
    ).readAsStringSync();
    final packEntry = File(
      'lib/src/core/services/desktop_local_asr_pack_runtime.dart',
    ).readAsStringSync();
    final core = File(
      'lib/src/core/services/desktop_local_asr_service.dart',
    ).readAsStringSync();

    expect(recognizerEntry, contains("if (dart.library.io)"));
    expect(recognizerEntry, contains('desktop_local_asr_recognizer_stub.dart'));
    expect(packEntry, contains("if (dart.library.io)"));
    expect(packEntry, contains('desktop_local_asr_pack_runtime_stub.dart'));
    expect(core, isNot(contains("import 'dart:io'")));
    expect(core, isNot(contains('sherpa_onnx')));
  });

  test('production code cannot start a raw ASR worker outside the factory', () {
    final recognizerSource = File(
      'lib/src/core/services/desktop_local_asr_recognizer_io.dart',
    ).readAsStringSync();

    expect(
      recognizerSource,
      isNot(
        contains('static Future<SherpaDesktopLocalAsrWorkerTransport> start('),
      ),
    );
    expect(
      recognizerSource,
      contains('SherpaDesktopLocalAsrWorkerTransport._start('),
    );
  });
}

String _between(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start);
  expect(start, greaterThanOrEqualTo(0), reason: startMarker);
  expect(end, greaterThan(start), reason: endMarker);
  return source.substring(start, end);
}
