import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('surface webview host uses webview_flutter', () {
    final source = File(
      'lib/src/core/widgets/surface_web_view.dart',
    ).readAsStringSync();

    expect(
      source,
      contains("import 'package:webview_flutter/webview_flutter.dart';"),
    );
    expect(source, contains('WebViewController'));
    expect(source, contains('WebViewWidget(controller: _controller)'));
    expect(source, contains('addJavaScriptChannel'));
    expect(source, isNot(contains('flutter_inappwebview')));
    expect(source, isNot(contains('InAppWebView')));
  });

  test('surface stage renders through SurfaceWebView only', () {
    final source = File(
      'lib/src/core/widgets/surface_stage.dart',
    ).readAsStringSync();

    expect(source, contains('SurfaceWebView'));
    expect(source, isNot(contains('flutter_inappwebview')));
    expect(source, isNot(contains('InAppWebView')));
  });
}
