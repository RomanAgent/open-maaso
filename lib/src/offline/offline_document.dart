import 'dart:convert';
import 'offline_store.dart';

/// Runtime policy, applied before any authored bytes. Authors cannot relax it.
const offlineContentSecurityPolicy =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'";

String offlineWorkDocument(String source, Map<String, String> state) {
  return '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="$offlineContentSecurityPolicy"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><script>${offlineStoragePrelude(state)}</script></head><body>$source</body></html>';
}

/// Account/work-owned storage shim, shared by the original local player.
String offlineStoragePrelude(Map<String, String> state, {String? scopeToken}) {
  final initial = jsonEncode(state).replaceAll('<', r'\u003c');
  final scope = jsonEncode(scopeToken).replaceAll('<', r'\u003c');
  return '''

(function(){
  // WebRTC is not consistently governed by connect-src in embedded engines.
  for (const name of ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','WebTransport']) {
    try { Object.defineProperty(window,name,{value:undefined,writable:false,configurable:false}); } catch (_) {}
  }
  const values=Object.assign(Object.create(null),$initial);
  const send=(value)=>{try{window.MaasoOfflineStorage.postMessage(JSON.stringify(Object.assign({},value,{scopeToken:$scope})));}catch(_){}};
  const storage={getItem:k=>Object.prototype.hasOwnProperty.call(values,String(k))?values[String(k)]:null,setItem:(k,v)=>{k=String(k);v=String(v);if(k.length>256||v.length>65536)throw Error('Local storage limit');const next=Object.assign(Object.create(null),values,{[k]:v});if(Object.keys(next).length>128||new TextEncoder().encode(JSON.stringify(next)).length>262144)throw Error('Local storage limit');values[k]=v;send({op:'set',key:k,value:v});},removeItem:k=>{k=String(k);delete values[k];send({op:'remove',key:k});},clear:()=>{for(const k of Object.keys(values))delete values[k];send({op:'clear'});},key:i=>Object.keys(values)[i]??null};
  Object.defineProperty(storage,'length',{get:()=>Object.keys(values).length});
  Object.defineProperty(window,'localStorage',{value:storage,writable:false,configurable:false});
})();
''';
}

/// No authored navigation may leave the initial isolated document.
bool offlineInitialNavigation(String url) =>
    url == 'about:blank' || url.startsWith('data:text/html');

Map<String, String>? applyOfflineStorageEvent(
  Map<String, String> current,
  String message,
) {
  if (message.length > OfflineStore.maxWorkStateBytes * 2) return null;
  try {
    final event = jsonDecode(message);
    if (event is! Map) return null;
    final result = Map<String, String>.from(current);
    final key = event['key'];
    switch (event['op']) {
      case 'set':
        final value = event['value'];
        if (key is! String ||
            key.length > 256 ||
            value is! String ||
            value.length > 65536) {
          return null;
        }
        result[key] = value;
      case 'remove':
        if (key is! String) return null;
        result.remove(key);
      case 'clear':
        result.clear();
      default:
        return null;
    }
    if (result.length > OfflineStore.maxWorkStateEntries ||
        utf8.encode(jsonEncode(result)).length >
            OfflineStore.maxWorkStateBytes) {
      return null;
    }
    return result;
  } catch (_) {
    return null;
  }
}
