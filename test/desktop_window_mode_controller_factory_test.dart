import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_window_mode_controller_factory.dart';

void main() {
  test('widget tests never connect to a native desktop window plugin', () {
    final controller = createDesktopWindowModeController();
    addTearDown(controller.dispose);

    expect(controller.mode, DesktopWindowMode.unsupported);
  });
}
