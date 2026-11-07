import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/offline/offline_network_guard.dart';

const _androidPath =
    'third_party/webview_flutter_android/android/src/main/java/'
    'io/flutter/plugins/webviewflutter/WebViewProxyApi.java';
const _webKitPath =
    'third_party/webview_flutter_wkwebview/lib/src/webkit_webview_controller.dart';

void main() {
  test(
    'transport constructors are sealed in main and synchronously read child realms',
    () async {
      // Node supplies isolated ECMAScript realms; native frame injection is a
      // separate platform contract checked below and by the device build.
      final program =
          r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const guard = GUARD_SOURCE;
const constructors = ['RTCPeerConnection','webkitRTCPeerConnection',
  'mozRTCPeerConnection','RTCDataChannel','WebTransport','RTCIceGatherer',
  'RTCIceTransport','RTCDtlsTransport','RTCSctpTransport','RTCRtpSender',
  'RTCRtpReceiver'];
function realm() {
  const context = vm.createContext({});
  vm.runInContext(`
    class HTMLIFrameElement {
      constructor(child) { this.child = child; }
      get contentWindow() { return this.child; }
      get contentDocument() { return new Document(this.child); }
    }
    class HTMLFrameElement extends HTMLIFrameElement {}
    class Document {
      constructor(child) { this.child = child; }
      get defaultView() { return this.child; }
    }
    const inherited = {RTCPeerConnection: function OriginalPeer(){}};
    const window = Object.assign(Object.create(inherited),
      {HTMLIFrameElement,HTMLFrameElement,Document});
    globalThis.host = window;
  `, context);
  for (const name of constructors.slice(1)) {
    Object.defineProperty(context.host, name, {
      value:function NetworkTransport(){},writable:true,configurable:true});
  }
  return context;
}
function verify(window) {
  for (const name of constructors) {
    assert.equal(window[name], undefined, name);
    const descriptor = Object.getOwnPropertyDescriptor(window, name);
    assert.equal(descriptor.configurable, false, name);
    assert.equal(descriptor.writable, false, name);
    assert.throws(()=>Object.defineProperty(window, name, {value:function(){}}));
    let ancestor = Object.getPrototypeOf(window);
    while (ancestor) {
      assert.equal(ancestor[name], undefined, 'prototype escape: '+name);
      ancestor = Object.getPrototypeOf(ancestor);
    }
  }
}
const main = realm();
vm.runInContext(guard, main);
verify(main.host);
const child = realm();
const frame = new main.host.HTMLIFrameElement(child.host);
assert.equal(frame.contentWindow, child.host);
verify(child.host);
const child2 = realm();
const frame2 = new main.host.HTMLIFrameElement(child2.host);
assert.equal(frame2.contentDocument.defaultView, child2.host);
verify(child2.host);
const grandchild = realm();
assert.equal(new child.host.HTMLIFrameElement(grandchild.host).contentWindow,
  grandchild.host);
verify(grandchild.host);
const child3 = realm();
assert.equal(new main.host.Document(child3.host).defaultView, child3.host);
verify(child3.host);
vm.runInContext(guard, main);
verify(main.host);
console.log('all realms sealed');
'''
              .replaceFirst(
                'GUARD_SOURCE',
                jsonEncode(offlineNetworkGuardScript),
              );
      final result = await Process.run('node', ['--eval', program]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('all realms sealed'));
    },
  );

  test('Android embeds the identical cross-frame transport policy', () {
    final source = File(_androidPath).readAsStringSync();
    final start = source.indexOf(
      'private static final String OFFLINE_DOCUMENT_START_SCRIPT =',
    );
    final end = source.indexOf(
      'private static boolean invocationProfilesRecovered;',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final script = RegExp(r'"(?:\\.|[^"\\])*"')
        .allMatches(source.substring(start, end))
        .map((match) => jsonDecode(match.group(0)!) as String)
        .join();
    expect(script.trim(), offlineNetworkGuardScript.trim());
  });

  test(
    'Android offline profile fails closed before allocation and keeps legacy profiles separate',
    () {
      final source = File(_androidPath).readAsStringSync();
      expect(source, contains('name.matches("maaso_offline_[a-f0-9]{32}")'));
      expect(
        source,
        contains('name.matches("maaso_(?:invocation|offline)_[a-f0-9]{32}")'),
      );
      final factory = source.substring(
        source.indexOf('public WebView withProfile('),
      );
      expect(
        factory.indexOf('WebViewFeature.DOCUMENT_START_SCRIPT'),
        lessThan(factory.indexOf('new WebViewPlatformView(this, profileName)')),
      );
      final offlineStart = source.indexOf(
        'if (isOfflineProfile(profileName)) {',
      );
      final offlineEnd = source.indexOf('currentWebViewClient =', offlineStart);
      final offline = source.substring(offlineStart, offlineEnd);
      expect(offline, contains('setBlockNetworkLoads(true)'));
      expect(offline, contains('setBlockNetworkImage(true)'));
      expect(offline, contains('setAllowFileAccess(false)'));
      expect(offline, contains('setAllowContentAccess(false)'));
      expect(offline, contains('WebViewCompat.addDocumentStartJavaScript('));
      expect(offline, contains('java.util.Collections.singleton("*")'));
      expect(source, contains('this(api, null);'));
      expect(
        source,
        contains('if (isPrivateProfile(name)) deleteInvocationProfile'),
      );
    },
  );

  test(
    'WebKit policy is ephemeral, immutable, all-frame, and restored before channel scripts',
    () {
      final source = File(_webKitPath).readAsStringSync();
      final method = source.substring(
        source.indexOf('Future<void> addOfflineDocumentStartScript('),
        source.indexOf('/// Whether horizontal swipe gestures'),
      );
      expect(method, contains('!_webKitParams.useNonPersistentDataStore'));
      expect(method, contains('offline_policy_is_immutable'));
      expect(method, contains('UserScriptInjectionTime.atDocumentStart'));
      expect(method, contains('isForMainFrameOnly: false'));
      final reset = source.substring(
        source.indexOf('Future<void> _resetUserScripts('),
      );
      expect(
        reset.indexOf('await controller.removeAllUserScripts();'),
        lessThan(
          reset.indexOf('await _addOfflineScript(controller, offlineScript);'),
        ),
      );
      expect(
        reset.indexOf('await _addOfflineScript(controller, offlineScript);'),
        lessThan(reset.indexOf('addJavaScriptChannel(params)')),
      );
    },
  );
}
