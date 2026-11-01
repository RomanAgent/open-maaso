import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('full App avatar uses the real desktop Unity transports', () {
    final source = File(
      'lib/src/core/widgets/unity_avatar_view.dart',
    ).readAsStringSync();

    expect(source, contains('case TargetPlatform.macOS:'));
    expect(source, contains('_MacOSUnityAvatarPortalView'));
    expect(source, contains('fillViewport: widget.includeWorld'));
    expect(source, contains('await portal.summon('));
    expect(source, contains('includeWorld: capture.includeWorld'));
    expect(source, contains('AvatarPortalCapturePolicy.fitSceneViewport('));
    expect(source, contains('MediaQuery.devicePixelRatioOf(context)'));
    expect(source, contains('this.includeWorld = false'));
    final home = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final space = File(
      'lib/src/features/agent_space/presentation/agent_space_page.dart',
    ).readAsStringSync();
    expect(home, contains('includeWorld: true'));
    expect(space, contains('includeWorld: true'));
    expect(space, contains('holdToWalk: !_leaving'));
    expect(space, contains('showLoadingPlaceholder: false'));
    final macPortalView = source.substring(
      source.indexOf('class _MacOSUnityAvatarPortalView'),
      source.indexOf('void _applyInitialUnityAvatar'),
    );
    expect(macPortalView, isNot(contains('portal.release()')));
    expect(
      macPortalView,
      contains('WidgetsBinding.instance.addPostFrameCallback'),
    );
    expect(macPortalView, contains('SchedulerPhase.persistentCallbacks'));

    expect(source, contains('case TargetPlatform.windows:'));
    expect(source, contains('WindowsUnityPlayerHostView('));

    final desktopCases = source.substring(
      source.indexOf('case TargetPlatform.macOS:'),
      source.indexOf('case TargetPlatform.fuchsia:'),
    );
    expect(
      desktopCases,
      isNot(contains('return const _UnityAvatarPlaceholder')),
    );
  });

  test('Web uses Unity WebGL while unsupported desktop retains fallback', () {
    final source = File(
      'lib/src/core/widgets/unity_avatar_view.dart',
    ).readAsStringSync();

    expect(source, contains('kIsWeb'));
    expect(source, contains('UnityWebGLAvatarHost('));
    expect(
      source,
      isNot(contains('if (kIsWeb) return const _UnityAvatarPlaceholder();')),
    );
    expect(source, contains('case TargetPlatform.linux:'));
  });
}
