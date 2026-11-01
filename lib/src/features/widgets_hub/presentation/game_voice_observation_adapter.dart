import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:webview_flutter/webview_flutter.dart';

enum GameVoiceObservationMode { local, publicRelay }

/// Reads the current player; it never dispatches a game operation.
abstract final class GameVoiceObservationAdapter {
  static const channelName = 'MaasoGameVoice';
  static const observerAsset = 'assets/game_companion/observer_v1.js';
  static Future<String>? _observerSource;

  static Future<String> loadObserverSource() => _observerSource ??= rootBundle
      .loadString(observerAsset)
      .catchError((Object error, StackTrace stack) {
        _observerSource = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<void> addChannel(
    WebViewController controller,
    void Function(String) onObservation,
  ) async {
    try {
      await controller.addJavaScriptChannel(
        channelName,
        onMessageReceived: (message) => onObservation(message.message),
      );
    } on Object {
      // Public documents may load even when this optional native channel fails.
    }
  }

  static Future<void> attach(
    WebViewController controller,
    void Function(String) onObservation, {
    required GameVoiceObservationMode mode,
    bool Function()? isCurrent,
  }) async {
    await controller.removeJavaScriptChannel(channelName);
    if (isCurrent?.call() == false) return;
    await addChannel(controller, (source) {
      if (isCurrent?.call() != false) onObservation(source);
    });
    if (isCurrent?.call() == false) return;
    try {
      if (mode == GameVoiceObservationMode.publicRelay) {
        await controller.runJavaScript(observerScript);
      } else {
        final source = await loadObserverSource();
        if (isCurrent?.call() == false) return;
        await controller.runJavaScript(localObserverScript(source));
      }
    } on Object {
      // Optional observation never fails admission or the playable document.
    }
  }

  static String localObserverScript(String source) =>
      """
(function(){try{
  if(window.__maasoGameCompanionObserverV1)window.__maasoGameCompanionObserverV1.dispose();
  window.__maasoGameCompanionObserverV1=($source)({send:function(value){
    if(window.MaasoGameVoice)window.MaasoGameVoice.postMessage(JSON.stringify(value));
  }});
}catch(_){}})();
""";

  static Future<void> detach(WebViewController controller) async {
    try {
      await controller
          .runJavaScript(r"""
(function(){try{
  if(window.__maasoGameCompanionObserverV1)window.__maasoGameCompanionObserverV1.dispose();
  delete window.__maasoGameCompanionObserverV1;
  if(window.__maasoGameVoiceRelayV1)window.__maasoGameVoiceRelayV1.pause();
}catch(_){}})();
""")
          .timeout(const Duration(milliseconds: 500));
    } on Object {
      // A retired WebView may already have removed its document.
    }
    await controller.removeJavaScriptChannel(channelName);
  }

  /// Installs the listener before the sandboxed iframe starts its game code.
  static String publishedDocument(String document) =>
      document.replaceFirst('<head>', '<head><script>$observerScript</script>');

  static Future<String?> readVisibleText(WebViewController controller) async {
    try {
      Object? value = await controller.runJavaScriptReturningResult(r"""
(function(){try{
  var local=window.__maasoGameCompanionObserverV1;
  if(local){var state=local.capture();return state&&state.visibleText||'';}
  var relay=window.__maasoGameVoiceRelayV1;
  if(relay){relay.requestLatest();return relay.visibleText();}
  return '';
}catch(_){return '';}})()
""");
      if (value is String && value.startsWith('"')) {
        value = jsonDecode(value);
      }
      return value is String && value.trim().isNotEmpty ? value : null;
    } on Object {
      return null;
    }
  }

  static const observerScript = r'''
(function(){
  if(window.__maasoGameVoiceRelayV1){window.__maasoGameVoiceRelayV1.resume();return;}
  var enabled=true,sequence=0,pending='',requestedAt=0;
  var latest={},revisions={game:-1,snapshot:-1};
  var encoder=typeof TextEncoder==='function'?new TextEncoder():null;
  function byteLength(text){return encoder?encoder.encode(text).length:unescape(encodeURIComponent(text)).length;}
  function frame(){return document.querySelector('iframe[data-maaso-game-observation-frame]');}
  function normalize(raw){
    try{
      if(!raw||typeof raw!=='object'||Array.isArray(raw)||!Number.isSafeInteger(raw.revision)||raw.revision<0)return null;
      var snapshot=raw.kind==='companion.snapshot',event=raw.kind==='game.event';
      if(!snapshot&&!event&&raw.kind!=='game.state')return null;
      var fields=event?['kind','revision','state','event']:['kind','revision','state'];
      var names=Object.keys(raw);
      if(names.length!==fields.length||names.some(function(k){return fields.indexOf(k)<0;}))return null;
      if(!raw.state||typeof raw.state!=='object'||Array.isArray(raw.state))return null;
      if(snapshot&&raw.state.version!==1)return null;
      var nodes=0;
      function copy(v,d){
        if(++nodes>512||d>8)throw new Error('bounds');
        if(v===null||typeof v==='boolean')return v;
        if(typeof v==='number'&&Number.isFinite(v))return v;
        if(typeof v==='string'&&Array.from(v).length<=512)return v;
        if(Array.isArray(v)){if(v.length>512)throw new Error('bounds');return v.map(function(x){return copy(x,d+1);});}
        if(v&&typeof v==='object'){
          var keys=Object.keys(v),out=Object.create(null);
          if(keys.length>512)throw new Error('bounds');
          keys.forEach(function(k){if(Array.from(k).length>64)throw new Error('bounds');out[k]=copy(v[k],d+1);});return out;
        }
        throw new Error('type');
      }
      var value={kind:raw.kind,revision:raw.revision,state:copy(raw.state,0)};
      if(event)value.event=copy(raw.event,0);
      return byteLength(JSON.stringify(value))<=(snapshot?6144:8192)?value:null;
    }catch(_){return null;}
  }
  function receive(raw,replay){
    var value=normalize(raw);if(!value)return;
    var family=value.kind==='companion.snapshot'?'snapshot':'game';
    if(!replay&&value.revision<=revisions[family])return;
    revisions[family]=Math.max(revisions[family],value.revision);
    if(replay&&value.kind==='game.event')value={kind:'game.state',revision:value.revision,state:value.state};
    latest[family]=value;
    if(enabled&&window.MaasoGameVoice)window.MaasoGameVoice.postMessage(JSON.stringify(value));
  }
  function requestLatest(){
    if(!enabled)return;
    var child=frame();if(!child||!child.contentWindow)return;
    pending=Date.now().toString(36)+'-'+(++sequence);requestedAt=Date.now();
    child.contentWindow.postMessage({kind:'companion.observe.request',requestId:pending},'*');
  }
  window.addEventListener('message',function(message){
    var child=frame();if(!child||message.source!==child.contentWindow)return;
    var data=message.data;if(!data||typeof data!=='object'||Array.isArray(data))return;
    if(data.kind==='companion.observe.response'){
      if(data.requestId===pending&&Date.now()-requestedAt<=5000)receive(data.observation,true);
    }else receive(data,false);
  });
  window.__maasoGameVoiceRelayV1={
    pause:function(){enabled=false;pending='';},
    resume:function(){
      enabled=true;
      ['game','snapshot'].forEach(function(family){if(latest[family])receive(latest[family],true);});
      requestLatest();
    },
    requestLatest:requestLatest,
    visibleText:function(){var value=latest.snapshot;return value&&value.state.visibleText||'';}
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',requestLatest,{once:true});
  requestLatest();
})();
''';
}
