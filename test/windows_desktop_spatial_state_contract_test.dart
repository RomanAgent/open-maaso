import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'windows/runner/windows_desktop_companion_host.cpp',
  ).readAsStringSync();
  final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();

  test('native spatial v1 is strict and stored under the user registry', () {
    final load = _functionBody(source, 'bool LoadPersistedSpatialStateV1(');
    final save = _functionBody(source, 'bool SavePersistedSpatialStateV1(');
    final readDouble = _functionBody(source, 'bool ReadRegistryDouble(');
    final readDevice = _functionBody(source, 'bool ReadRegistryDevice(');

    expect(source, contains('kNativeSpatialVersion = 1'));
    expect(source, contains(r'L"Software\\Maaso\\DesktopCompanion"'));
    for (final valueName in <String>[
      'SpatialVersion',
      'MonitorDevice',
      'NormalizedX',
      'NormalizedY',
      'AttachmentKind',
      'AttachmentMonitorDevice',
      'AttachmentWindowHandle',
      'AttachmentWindowProcessId',
    ]) {
      expect(source, contains('L"$valueName"'));
    }
    expect(load, contains('HKEY_CURRENT_USER'));
    expect(load, contains('KEY_QUERY_VALUE'));
    expect(load, contains('version == kNativeSpatialVersion'));
    expect(load, contains('state.normalized_x >= 0.0'));
    expect(load, contains('state.normalized_x <= 1.0'));
    expect(load, contains('state.normalized_y >= 0.0'));
    expect(load, contains('state.normalized_y <= 1.0'));
    expect(readDouble, contains('type != REG_BINARY'));
    expect(readDouble, contains('size != sizeof(double)'));
    expect(readDouble, contains('!std::isfinite(value)'));
    expect(readDevice, contains('type != REG_SZ'));
    expect(readDevice, contains('CCHDEVICENAME'));
    expect(save, contains('RegCreateKeyExW(HKEY_CURRENT_USER'));
    expect(save, contains('KEY_SET_VALUE'));
    expect(
      save.indexOf('WriteRegistryDword(key, kSpatialVersionValue, 0)'),
      lessThan(
        save.lastIndexOf('WriteRegistryDword(key, kSpatialVersionValue,'),
      ),
    );
    expect(cmake, contains('"advapi32.lib"'));
  });

  test('monitor identity and normalized fallback survive topology changes', () {
    final monitor = _functionBody(source, 'bool ReadMonitorSnapshot(');
    final findMonitor = _functionBody(source, 'bool FindMonitorByDevice(');
    final normalize = _functionBody(source, 'double NormalizedAxis(');
    final denormalize = _functionBody(source, 'POINT OriginFromNormalized(');
    final loadInitial = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::LoadInitialBounds(',
    );
    final restore = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::RestoreSpatialPosition(',
    );

    expect(source, contains('MONITORINFOEXW info'));
    expect(monitor, contains('GetMonitorInfoW'));
    expect(source, contains('snapshot.info.szDevice'));
    expect(findMonitor, contains('EnumDisplayMonitors'));
    expect(normalize, contains('work_start - std::max(0, leading_inset)'));
    expect(
      normalize,
      contains('work_end - extent + std::max(0, trailing_inset)'),
    );
    expect(normalize, contains('static_cast<double>(origin) - minimum'));
    expect(normalize, contains('std::clamp('));
    expect(denormalize, contains('work.left - std::max(0, left_inset)'));
    expect(denormalize, contains('work.top +'));
    expect(
      denormalize,
      contains('work.right - width + std::max(0, right_inset)'),
    );
    expect(denormalize, contains('work.bottom - work.top - height'));
    expect(loadInitial, contains('LoadPersistedSpatialStateV1(&persisted)'));
    expect(loadInitial, contains('persisted.monitor_device'));
    expect(loadInitial, contains('RestoreSpatialPosition()'));
    expect(
      restore.indexOf('FindMonitorByDevice(spatial_monitor_device_'),
      lessThan(restore.indexOf('FindPrimaryMonitor(&monitor)')),
    );
    expect(restore, contains('OriginFromNormalized('));
    expect(restore, contains('ResolveSpatialAttachment(&attached)'));
    expect(restore, contains('ClearSpatialAttachment()'));
    expect(restore, contains('const POINT clamped = ClampOrigin(origin)'));

    const workLeft = -1920;
    const workRight = 0;
    const width = 300;
    const leftInset = 70;
    const rightInset = 70;
    const origin = -1700;
    const minimum = workLeft - leftInset;
    const maximum = workRight - width + rightInset;
    final normalized = (origin - minimum) / (maximum - minimum);
    expect(normalized, closeTo(0.1648, 0.0001));
    final restored = minimum + (normalized * (maximum - minimum)).round();
    expect(restored, origin);
    expect(restored, isNegative);
  });

  test('horizontal bounds expose the avatar at both work-area edges', () {
    final clamp = _functionBody(
      source,
      'POINT WindowsDesktopCompanionHost::ClampOrigin(',
    );
    final snap = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::ApplyDropSnap(',
    );
    final resolve = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::ResolveSpatialAttachment(',
    );
    final resize = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::ResizeForDpi(',
    );
    final loadInitial = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::LoadInitialBounds(',
    );
    final updateFallback = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::UpdateSpatialFallbackFromBounds(',
    );

    expect(
      source,
      contains('return RECT{Scale(70), Scale(140), Scale(230), Scale(420)}'),
    );
    expect(clamp, contains('const RECT avatar = AvatarBounds()'));
    expect(clamp, contains('info.rcWork.left - avatar.left'));
    expect(clamp, contains('info.rcWork.right - width + width - avatar.right'));
    expect(snap, contains('POINT{work.left - left_inset, current.y}'));
    expect(
      snap,
      contains('POINT{work.right - width + right_inset, current.y}'),
    );
    expect(resolve, contains('spatial_normalized_y_, left_inset, right_inset'));
    expect(resolve, contains('monitor.info.rcWork.left - left_inset'));
    expect(
      resolve,
      contains('monitor.info.rcWork.right - width + right_inset'),
    );
    expect(resize, contains('avatar.left,\n        width - avatar.right'));
    expect(
      loadInitial,
      contains('work->right - width + (width - AvatarBounds().right)'),
    );
    expect(
      updateFallback,
      contains(
        'width, avatar.left,\n                     width - avatar.right',
      ),
    );

    const workLeft = 0.0;
    const workRight = 1440.0;
    for (final scale in <double>[1.2, 1.8, 2.4, 3.0]) {
      final panelWidth = 300 * scale;
      final avatarLeft = 70 * scale;
      final avatarRight = 230 * scale;
      final rightInset = panelWidth - avatarRight;
      final leftOrigin = workLeft - avatarLeft;
      final rightOrigin = workRight - panelWidth + rightInset;
      expect(leftOrigin + avatarLeft, workLeft);
      expect(rightOrigin + avatarRight, workRight);
    }
  });

  test('DPI and visual scale are each applied once at 96 144 and 192 DPI', () {
    final dpiScale = _functionBody(source, 'int DpiScaledLogicalPixels(');
    final resize = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::ResizeForDpi(',
    );
    final scale = _functionBody(
      source,
      'int WindowsDesktopCompanionHost::Scale(',
    );
    final applyGeometry = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::ApplyPresentationGeometry(',
    );

    expect(
      dpiScale,
      contains('static_cast<double>(dpi == 0 ? 96 : dpi) / 96.0'),
    );
    expect(dpiScale, isNot(contains('presentation_visual_scale_')));
    expect(RegExp('presentation_visual_scale_').allMatches(scale).length, 1);
    expect(scale, contains('logical_pixels * dpi_scale *'));
    expect(
      resize.indexOf('dpi_ = next_dpi == 0 ? 96 : next_dpi'),
      lessThan(resize.indexOf('const int width = Scale(300)')),
    );
    expect(resize, contains('RestoreSpatialPosition()'));
    expect(applyGeometry, contains('const int width = Scale(300)'));
    expect(applyGeometry, contains('const int height = Scale(420)'));
    expect(applyGeometry, contains('RestoreSpatialPosition()'));

    for (final entry in <(int, int)>[(96, 300), (144, 450), (192, 600)]) {
      final (dpi, expectedWidth) = entry;
      expect((300 * (dpi / 96.0)).round(), expectedWidth);
    }
  });

  test('drop snap uses work edges, eligible windows, and hysteresis', () {
    final snap = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::ApplyDropSnap(',
    );
    final enumerate = _functionBody(
      source,
      'BOOL CALLBACK CollectSnapWindowCallback(',
    );
    final eligible = _functionBody(source, 'bool IsEligibleSnapWindow(');
    final reservedEdge = _functionBody(source, 'bool HasReservedWorkEdge(');
    final endDrag = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::EndDrag(',
    );
    final cancelDrag = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::CancelDrag(',
    );

    expect(snap, contains('if (!presentation_snap_enabled_)'));
    expect(snap, contains('monitor.info.rcWork'));
    for (final edge in <String>[
      'kWorkLeft',
      'kWorkTop',
      'kWorkRight',
      'kWorkBottom',
    ]) {
      expect(snap, contains('SpatialAttachmentKind::$edge'));
    }
    expect(RegExp(r'if \(HasReservedWorkEdge\(').allMatches(snap).length, 4);
    expect(
      reservedEdge,
      contains('monitor.rcWork.left > monitor.rcMonitor.left'),
    );
    expect(
      reservedEdge,
      contains('monitor.rcWork.top > monitor.rcMonitor.top'),
    );
    expect(
      reservedEdge,
      contains('monitor.rcWork.right < monitor.rcMonitor.right'),
    );
    expect(
      reservedEdge,
      contains('monitor.rcWork.bottom < monitor.rcMonitor.bottom'),
    );
    expect(snap, contains('EnumWindows(CollectSnapWindowCallback'));
    expect(snap, contains('SameAttachment(candidate'));
    expect(
      snap.indexOf('candidate.distance <= release_distance'),
      lessThan(snap.indexOf('nearest->distance <= acquire_distance')),
    );
    expect(enumerate, contains('bounds.top - context->pet_height'));
    expect(enumerate, contains('std::clamp(context->current_origin.x'));
    expect(eligible, contains('!::IsWindowVisible(window)'));
    expect(eligible, contains('::IsIconic(window)'));
    expect(eligible, contains('::GetAncestor(window, GA_ROOT) != window'));
    expect(eligible, contains('::GetWindow(window, GW_OWNER) != nullptr'));
    expect(eligible, contains('WS_EX_TOOLWINDOW'));
    expect(eligible, contains('candidate_process_id == own_process_id'));
    expect(eligible, contains('IsMaasoAuxiliaryProcess(candidate_process_id)'));
    expect(source, contains('QueryFullProcessImageNameW'));
    expect(source, contains('L"MaasoAvatar.exe"'));
    expect(source, contains('L"UnityCrashHandler64.exe"'));
    expect(source, contains('L"UnityCrashHandler32.exe"'));
    expect(eligible, contains('DwmGetWindowAttribute'));
    expect(eligible, contains('DWMWA_CLOAKED'));
    expect(eligible, contains('DWMWA_EXTENDED_FRAME_BOUNDS'));
    expect(
      eligible.indexOf('DWMWA_EXTENDED_FRAME_BOUNDS'),
      lessThan(eligible.indexOf('GetWindowRect(window, &candidate_bounds)')),
    );
    expect(eligible, contains('FAILED(frame_bounds_result)'));
    expect(
      eligible,
      contains('candidate_bounds.right - candidate_bounds.left'),
    );
    expect(
      eligible,
      contains('candidate_bounds.bottom - candidate_bounds.top'),
    );
    expect(
      endDrag.indexOf('ApplyDropSnap()'),
      lessThan(endDrag.indexOf('SaveBounds()')),
    );
    expect(cancelDrag, isNot(contains('ApplyDropSnap()')));
  });

  test('attachment restoration falls back when its live target is gone', () {
    final resolve = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::ResolveSpatialAttachment(',
    );
    final configure = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::ConfigurePresentation(',
    );

    expect(resolve, contains('FindMonitorByDevice('));
    expect(resolve, contains('IsEligibleSnapWindow('));
    expect(
      resolve,
      contains('target_process_id != spatial_attachment_window_process_id_'),
    );
    expect(resolve, contains('target.top - height'));
    expect(configure, contains('if (!presentation_snap_enabled_)'));
    expect(configure, contains('ClearSpatialAttachment()'));
    expect(configure, contains('attachment_cleared'));
  });

  test('every show revalidates attachment before Unity starts or appears', () {
    final show = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::Show(',
    );

    final ensureWindows = show.indexOf('EnsureWindows(error_message)');
    final restore = show.indexOf('RestoreSpatialPosition()');
    final ensureSurface = show.indexOf('EnsurePetSurface(');
    final startUnity = show.indexOf('pet_unity_player_host_->Start(');
    final showWindow = show.indexOf('SWP_NOACTIVATE | SWP_SHOWWINDOW');
    expect(ensureWindows, greaterThanOrEqualTo(0));
    expect(restore, greaterThan(ensureWindows));
    expect(restore, lessThan(ensureSurface));
    expect(restore, lessThan(startUnity));
    expect(restore, lessThan(showWindow));
  });

  test(
    'snap is event-driven and keeps the three native windows synchronized',
    () {
      final snap = _functionBody(
        source,
        'bool WindowsDesktopCompanionHost::ApplyDropSnap(',
      );
      final move = _functionBody(
        source,
        'void WindowsDesktopCompanionHost::MoveWindows(',
      );
      final overlay = _functionBody(
        source,
        'LRESULT WindowsDesktopCompanionHost::HandleOverlayMessage(',
      );
      final displayChange = _between(
        overlay,
        'case WM_DISPLAYCHANGE:',
        'case WM_DPICHANGED:',
      );

      expect(RegExp(r'ApplyDropSnap\(\);').allMatches(source).length, 1);
      expect(snap, isNot(contains('SetTimer')));
      expect(source, isNot(contains('SetWinEventHook')));
      expect(source, isNot(contains('SetWindowsHookEx')));
      expect(source, isNot(contains('EVENT_OBJECT_LOCATIONCHANGE')));
      expect(
        RegExp(
          r'SetWindowPos\((pet|overlay|bubble)_window_, z_order',
        ).allMatches(move).length,
        3,
      );
      expect(displayChange, contains('RestoreSpatialPosition()'));
      expect(displayChange, contains('SaveBounds()'));
    },
  );
}

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, greaterThanOrEqualTo(0), reason: 'Missing $start');
  expect(endIndex, greaterThan(startIndex), reason: 'Missing $end');
  return source.substring(startIndex, endIndex);
}

String _functionBody(String source, String signature) {
  final signatureIndex = source.indexOf(signature);
  expect(
    signatureIndex,
    greaterThanOrEqualTo(0),
    reason: 'Missing function $signature',
  );
  final openBrace = source.indexOf('{', signatureIndex + signature.length);
  expect(openBrace, greaterThan(signatureIndex), reason: 'Missing $signature');
  var depth = 0;
  for (var index = openBrace; index < source.length; index += 1) {
    switch (source.codeUnitAt(index)) {
      case 0x7b:
        depth += 1;
        break;
      case 0x7d:
        depth -= 1;
        if (depth == 0) {
          return source.substring(openBrace + 1, index);
        }
        break;
    }
  }
  fail('Unterminated function $signature');
}
