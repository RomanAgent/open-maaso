import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/widgets_hub/data/game_document_loader.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_observation_adapter.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Controller extends Fake implements PlatformWebViewController {
  final scripts = <String>[];
  final callbacks = <JavaScriptChannelParams>[];
  var failScripts = false;
  var failChannel = false;
  var removes = 0;
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams value) async {
    if (failChannel) throw StateError('optional channel unavailable');
    callbacks.add(value);
  }

  @override
  Future<void> removeJavaScriptChannel(String name) async => removes++;
  @override
  Future<void> runJavaScript(String source) async {
    scripts.add(source);
    if (failScripts) throw StateError('document retired');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'optional native channel failure does not fail public loading',
    () async {
      final native = _Controller()..failChannel = true;
      await GameVoiceObservationAdapter.addChannel(
        WebViewController.fromPlatform(native),
        (_) {},
      );
      expect(native.callbacks, isEmpty);
    },
  );

  test(
    'explicit modes keep public shells out of local DOM observation',
    () async {
      final public = _Controller();
      await GameVoiceObservationAdapter.attach(
        WebViewController.fromPlatform(public),
        (_) {},
        mode: GameVoiceObservationMode.publicRelay,
      );
      expect(public.scripts, [GameVoiceObservationAdapter.observerScript]);

      final local = _Controller();
      await GameVoiceObservationAdapter.attach(
        WebViewController.fromPlatform(local),
        (_) {},
        mode: GameVoiceObservationMode.local,
      );
      expect(local.scripts, hasLength(1));
      expect(local.scripts.single, contains('startMaasoGameCompanionObserver'));
      expect(
        local.scripts.single,
        isNot(GameVoiceObservationAdapter.observerScript),
      );
    },
  );

  test(
    'retired callbacks and failed observation do not affect the game',
    () async {
      final native = _Controller()..failScripts = true;
      final controller = WebViewController.fromPlatform(native);
      var current = true;
      final received = <String>[];
      await GameVoiceObservationAdapter.attach(
        controller,
        received.add,
        mode: GameVoiceObservationMode.publicRelay,
        isCurrent: () => current,
      );
      current = false;
      native.callbacks.single.onMessageReceived(
        const JavaScriptMessage(message: 'late observation'),
      );
      expect(received, isEmpty);
      await GameVoiceObservationAdapter.detach(controller);
      expect(native.removes, 2);
    },
  );

  test('public relay separates revisions and replays only requested facts', () {
    final js = getJavascriptRuntime(xhr: false);
    addTearDown(js.dispose);
    final result = js.evaluate('''
var packets=[],requests=[],listener,queried='';
var child={postMessage:function(value){requests.push(value);}};
var frame={contentWindow:child};
var window={MaasoGameVoice:{postMessage:function(value){packets.push(JSON.parse(value));}},
addEventListener:function(name,callback){listener=callback;}};
var document={readyState:'complete',querySelector:function(selector){queried=selector;return frame;}};
${GameVoiceObservationAdapter.observerScript}
function send(value,source){listener({source:source||child,data:value});}
send({kind:'game.event',revision:8,state:{score:8},event:{type:'score.changed',summary:'Eight'}});
send({kind:'companion.snapshot',revision:1,state:{version:1,visibleText:'Score eight'}});
send({kind:'game.state',revision:7,state:{score:7}});
send({kind:'companion.snapshot',revision:0,state:{version:1,visibleText:'old'}});
send({kind:'game.state',revision:99,state:{}},{});
send({kind:'companion.observe.response',requestId:'wrong',observation:{kind:'game.state',revision:100,state:{}}});
send({kind:'companion.observe.response',requestId:requests[0].requestId,
observation:{kind:'game.event',revision:8,state:{score:8},event:{type:'score.changed',summary:'Eight'}}});
JSON.stringify({packets:packets,queried:queried,text:window.__maasoGameVoiceRelayV1.visibleText()});
''');
    expect(result.isError, isFalse, reason: result.stringResult);
    final value = jsonDecode(result.stringResult) as Map;
    expect(value['queried'], 'iframe[data-maaso-game-observation-frame]');
    expect(value['text'], 'Score eight');
    final packets = value['packets'] as List;
    expect(packets.map((p) => p['kind']), [
      'game.event',
      'companion.snapshot',
      'game.state',
    ]);
    expect(packets.last['event'], isNull);
  });

  test(
    'rendered document identity uses fetched UTF-8 bytes and a tagged shell',
    () {
      const content = '<html><head></head><body>中文😀</body></html>';
      final document = OpenedGameDocument(
        embedUrl: Uri.parse('https://example.test/g/test/embed'),
        html: content,
        policy: "sandbox allow-scripts",
      );
      expect(
        document.renderedDocumentDigest,
        sha256.convert(utf8.encode(content)).toString(),
      );
      expect(
        document.sandboxedHtml,
        contains('data-maaso-game-observation-frame'),
      );
      expect(document.sandboxedHtml, isNot(contains('allow-same-origin')));
    },
  );

  test('canonical observer executes its descriptor and DOM fixtures', () async {
    final result = await Process.run('node', [
      'tool/game_companion_observer_test.mjs',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains('privacy, bounds, freshness and retirement passed'),
    );
  });
}
