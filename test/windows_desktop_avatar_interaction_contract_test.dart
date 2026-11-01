import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'windows/runner/windows_desktop_companion_host.cpp',
  ).readAsStringSync();
  final header = File(
    'windows/runner/windows_desktop_companion_host.h',
  ).readAsStringSync();

  test(
    'native alpha mask matches its region and rejects invalid frames',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) {
        markTestSkipped('The standalone C++ runner uses the POSIX c++ driver.');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'maaso-alpha-mask-',
      );
      try {
        final executable = '${directory.path}/alpha-mask-test';
        final compile = await Process.run('c++', [
          '-std=c++17',
          '-Wall',
          '-Wextra',
          '-Werror',
          'test/native/desktop_avatar_alpha_mask_test.cpp',
          '-o',
          executable,
        ]);
        expect(
          compile.exitCode,
          0,
          reason: '${compile.stdout}\n${compile.stderr}',
        );
        final result = await Process.run(executable, const <String>[]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('pixel, region, lifecycle and bounds checks passed'),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'alpha silhouette owns clicks while both display windows pass through',
    () {
      final hit = _functionBody(
        source,
        'bool WindowsDesktopCompanionHost::IsAvatarPoint(',
      );
      expect(
        hit,
        contains('avatar_hit_mask_.Contains(client_point.x, client_point.y)'),
      );
      expect(hit, isNot(contains('AvatarBounds')));
      expect(hit, isNot(contains('hit_inset')));
      expect(
        source,
        contains('extended_style | WS_EX_TRANSPARENT, kPetWindowClass'),
      );
      expect(
        source,
        contains('extended_style | WS_EX_TRANSPARENT, kBubbleWindowClass'),
      );
      final region = _functionBody(
        source,
        'void WindowsDesktopCompanionHost::UpdateAvatarHitRegion(',
      );
      expect(region, contains('next.Build(pet_surface_pixels_'));
      expect(region, contains('next.SameShape(avatar_hit_mask_)'));
      expect(region, contains('::ExtCreateRegion('));
      expect(region, contains('::SetWindowRgn(overlay_window_, region, TRUE)'));
      expect(region, contains('avatar_hit_mask_ = std::move(next)'));
      expect(
        region.indexOf('::SetWindowRgn('),
        lessThan(region.indexOf('avatar_hit_mask_ = std::move(next)')),
      );
      expect(
        region.substring(region.indexOf('avatar_hit_mask_ = std::move(next)')),
        isNot(contains('DeleteObject')),
      );
    },
  );

  test(
    'only displayed frames publish hit regions and invalid new frames fail open',
    () {
      final present = _functionBody(
        source,
        'void WindowsDesktopCompanionHost::PresentLatestDesktopPetFrame()',
      );
      final noFrame = _between(
        present,
        'if (!pet_unity_player_host_->CopyLatestDesktopPetFrame(',
        'if (!EnsurePetSurface(',
      );
      expect(noFrame, isNot(contains('ClearAvatarHitRegion')));
      expect(
        present,
        contains(
          'if (UpdatePetLayeredWindow()) {\n    UpdateAvatarHitRegion();',
        ),
      );
      expect(present, contains('} else {\n    ClearAvatarHitRegion();'));
      expect(
        _between(present, 'if (!EnsurePetSurface(', 'const RECT avatar_bounds'),
        contains('ClearAvatarHitRegion();'),
      );
      expect(
        _between(
          present,
          'if (avatar_width <= 0',
          'const uint64_t required_bytes',
        ),
        contains('ClearAvatarHitRegion();'),
      );
      expect(
        _between(present, 'if (required_bytes >', 'const size_t surface_bytes'),
        contains('ClearAvatarHitRegion();'),
      );
      for (final signature in [
        'bool WindowsDesktopCompanionHost::Show(',
        'void WindowsDesktopCompanionHost::Hide()',
        'void WindowsDesktopCompanionHost::ReleasePetSurface()',
        'void WindowsDesktopCompanionHost::ResizeForDpi(',
        'void WindowsDesktopCompanionHost::ApplyPresentationGeometry()',
      ]) {
        expect(
          _functionBody(source, signature),
          contains('ClearAvatarHitRegion();'),
        );
      }
      final show = _functionBody(
        source,
        'bool WindowsDesktopCompanionHost::Show(',
      );
      expect(
        _between(
          show,
          '::SetWindowPos(overlay_window_',
          '::SetWindowPos(bubble_window_',
        ),
        isNot(contains('SWP_SHOWWINDOW')),
      );
    },
  );

  test(
    'empty mask cannot steal new input or interrupt existing mouse capture',
    () {
      final clear = _functionBody(
        source,
        'void WindowsDesktopCompanionHost::ClearAvatarHitRegion()',
      );
      expect(clear, contains('avatar_hit_mask_.Clear();'));
      expect(clear, contains('::CreateRectRgn(0, 0, 0, 0)'));
      expect(
        clear,
        contains(
          'if (!pointer_down_active_) ::ShowWindow(overlay_window_, SW_HIDE)',
        ),
      );
      expect(clear, isNot(contains('ReleaseCapture')));
      final overlay = _functionBody(
        source,
        'LRESULT WindowsDesktopCompanionHost::HandleOverlayMessage(',
      );
      expect(overlay, contains('if (pointer_down_active_) return HTCLIENT'));
      final move = _functionBody(
        source,
        'void WindowsDesktopCompanionHost::MoveWindows(',
      );
      expect(
        move,
        contains('pointer_down_active_ || !avatar_hit_mask_.Empty()'),
      );
      for (final signature in [
        'void WindowsDesktopCompanionHost::EndDrag(',
        'void WindowsDesktopCompanionHost::CancelDrag()',
      ]) {
        expect(
          _functionBody(source, signature),
          contains('avatar_hit_mask_.Empty()'),
        );
      }
    },
  );

  test('show accepts exactly one bounded interaction generation', () {
    final handleMethodCall = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::HandleMethodCall(',
    );
    final showBranch = _between(
      handleMethodCall,
      'if (call.method_name() == "show")',
      'if (call.method_name() == "hide")',
    );
    final show = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::Show(',
    );
    final configurePresentation = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::ConfigurePresentation(',
    );

    expect(showBranch, contains('arguments->size() != 1'));
    expect(showBranch, contains('ReadInt(*arguments, "interactionGeneration"'));
    expect(showBranch, contains('interaction_generation < 1'));
    expect(
      showBranch,
      contains('interaction_generation > std::numeric_limits<int32_t>::max()'),
    );
    expect(
      showBranch,
      contains('Show(&error, static_cast<int32_t>(interaction_generation))'),
    );
    expect(showBranch, contains('invalid_desktop_companion_show'));
    expect(show, contains('interaction_generation_ = interaction_generation'));
    expect(
      show.indexOf('interaction_generation_ = interaction_generation'),
      lessThan(show.indexOf('visible_ = true')),
    );
    expect(
      configurePresentation,
      contains('Show(&error, interaction_generation_)'),
    );
    expect(header, contains('int32_t interaction_generation'));
    expect(source, isNot(contains('AdvanceInteractionGeneration')));
    expect(header, isNot(contains('AdvanceInteractionGeneration')));
  });

  test('left press distinguishes tap from drag and capture cancellation', () {
    final overlay = _functionBody(
      source,
      'LRESULT WindowsDesktopCompanionHost::HandleOverlayMessage(',
    );
    final leftDown = _between(
      overlay,
      'case WM_LBUTTONDOWN:',
      'case WM_MOUSEMOVE:',
    );
    final leftUp = _between(
      overlay,
      'case WM_LBUTTONUP:',
      'case WM_CAPTURECHANGED:',
    );
    final captureChanged = _between(
      overlay,
      'case WM_CAPTURECHANGED:',
      'case WM_RBUTTONUP:',
    );
    final rightUp = _between(overlay, 'case WM_RBUTTONUP:', 'case WM_TIMER:');
    final beginDrag = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::BeginDrag(',
    );
    final continueDrag = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::ContinueDrag(',
    );
    final endDrag = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::EndDrag(',
    );
    final cancelDrag = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::CancelDrag(',
    );
    final threshold = _functionBody(
      source,
      'bool WindowsDesktopCompanionHost::MovedBeyondDragThreshold(',
    );

    expect(header, contains('kMaximumTapDurationMilliseconds = 500'));
    expect(header, contains('kTapMoveLogicalPixels = 6'));
    expect(leftDown, contains('BeginDrag(cursor, client_point)'));
    expect(leftDown, isNot(contains('MoveWindows(')));
    expect(leftUp, contains('EndDrag(cursor)'));
    expect(captureChanged, contains('CancelDrag()'));
    expect(captureChanged, isNot(contains('EndDrag(')));
    expect(rightUp, contains('PresentContextMenu(cursor)'));
    expect(rightUp, contains('IsAvatarPoint(client_point)'));
    expect(rightUp, isNot(contains('InvokeAvatarInteraction')));

    expect(beginDrag, contains('dragging_ = false'));
    expect(
      beginDrag,
      contains('pointer_down_generation_ = interaction_generation_'),
    );
    expect(beginDrag, contains('::SetCapture(overlay_window_)'));
    expect(
      continueDrag.indexOf('MovedBeyondDragThreshold(screen_point)'),
      lessThan(continueDrag.indexOf('MoveWindows(proposed.x, proposed.y)')),
    );
    expect(endDrag, contains('!was_dragging'));
    expect(endDrag, contains('!MovedBeyondDragThreshold(screen_point)'));
    expect(endDrag, contains('elapsed <= kMaximumTapDurationMilliseconds'));
    expect(endDrag, contains('generation == interaction_generation_'));
    expect(
      endDrag,
      contains('InvokeAvatarInteraction(client_point, generation)'),
    );
    expect(cancelDrag, isNot(contains('InvokeAvatarInteraction')));
    expect(
      threshold,
      contains('std::hypot(delta_x, delta_y) > Scale(kTapMoveLogicalPixels)'),
    );
  });

  test('tap callback has the exact version one semantic payload', () {
    final invoke = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::InvokeAvatarInteraction(',
    );
    final keys = RegExp(
      r'flutter::EncodableValue\("([^"]+)"\)',
    ).allMatches(invoke).map((match) => match.group(1)!).toList();

    expect(invoke, contains('"avatarInteraction"'));
    expect(invoke, contains('flutter::EncodableValue(1)'));
    expect(invoke, contains('std::string("tap")'));
    expect(keys, <String>[
      'version',
      'type',
      'normalizedX',
      'normalizedY',
      'region',
      'generation',
      'timestampMs',
    ]);
    expect(invoke, contains('generation != interaction_generation_'));
    expect(invoke, contains('BoundedTimestampMilliseconds()'));
    expect(invoke.toLowerCase(), isNot(contains('mouth')));
    expect(invoke.toLowerCase(), isNot(contains('tts')));
  });

  test('normalization is top-down and regions are strictly bounded', () {
    final invoke = _functionBody(
      source,
      'void WindowsDesktopCompanionHost::InvokeAvatarInteraction(',
    );
    final region = _functionBody(
      source,
      'std::string WindowsDesktopCompanionHost::AvatarRegionForPoint(',
    );
    final returnedRegions = RegExp(
      r'return "([^"]+)";',
    ).allMatches(region).map((match) => match.group(1)!).toSet();

    expect(
      invoke,
      contains('(static_cast<double>(client_point.y) - avatar.top) / height'),
    );
    expect(invoke, isNot(contains('1.0 -')));
    expect(region, contains('const bool inside_actual_avatar'));
    expect(region, contains('if (!inside_actual_avatar)'));
    expect(region, contains('normalized_y <= 0.28'));
    expect(region, contains('normalized_y >= 0.82'));
    expect(region, contains('normalized_x <= 0.32'));
    expect(region, contains('normalized_x >= 0.68'));
    expect(returnedRegions, <String>{
      'head',
      'torso',
      'leftSide',
      'rightSide',
      'feet',
      'avatar',
    });
  });

  test('timestamp is sourced from monotonic uptime and safely bounded', () {
    final timestamp = _functionBody(
      source,
      'int64_t BoundedTimestampMilliseconds(',
    );

    expect(timestamp, contains('::GetTickCount64()'));
    expect(timestamp, contains('std::numeric_limits<int64_t>::max()'));
    expect(timestamp, contains('static_cast<int64_t>(now)'));
  });
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
  expect(
    openBrace,
    greaterThan(signatureIndex),
    reason: 'Missing body $signature',
  );
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
