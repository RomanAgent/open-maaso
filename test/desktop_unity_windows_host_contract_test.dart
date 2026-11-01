import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner exposes a fixed-path parent HWND Unity host', () {
    final host = File(
      'windows/runner/unity_player_host.cpp',
    ).readAsStringSync();
    final window = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final avatarBridge = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'WindowsUnityAvatarMessageBridge.cs',
    ).readAsStringSync();
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();

    expect(host, contains(r'unity\\MaasoAvatar.exe'));
    expect(host, contains('-parentHWND '));
    expect(host, contains(' delayed '));
    expect(host, contains('-force-d3d11'));
    expect(host, contains('CreateProcessW'));
    expect(host, contains('SetParent'));
    expect(host, contains('GWLP_USERDATA'));
    expect(host, contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'));
    expect(host, isNot(contains('ShellExecute')));
    expect(host, isNot(contains('-single-instance')));
    expect(host, contains('receiver_result == static_cast<DWORD_PTR>(TRUE)'));
    expect(host, contains('next_session_token'));
    expect(host, contains('if (!IsRunning()) {\n    Stop();\n    return;'));
    expect(host, contains('if (token != avatar_session_token_)'));
    expect(
      host,
      contains('if (token != avatar_session_token_) {\n    return false;'),
    );
    expect(avatarBridge, contains('installedWindowProcedure'));
    expect(avatarBridge, contains('WmNcDestroy'));
    expect(avatarBridge, contains('CallWindowProcW'));
    expect(avatarBridge, contains('current != installedWindowProcedure'));
    expect(window, contains('maaso/desktop_unity_host'));
    expect(window, contains('invalid_unity_host_bounds'));
    expect(cmake, contains('Builds/Windows'));
    expect(cmake, contains('CMAKE_INSTALL_PREFIX}/unity'));
    expect(cmake, contains('OPTIONAL'));
  });
}
