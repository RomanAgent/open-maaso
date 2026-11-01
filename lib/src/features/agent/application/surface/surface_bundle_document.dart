import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';

/// The v2 host has its own policy. It never changes the legacy Surface policy.
final class SurfaceBundleDocument {
  const SurfaceBundleDocument._();

  static String baseUrl(String nonce, int session) {
    final origin = sha256
        .convert(utf8.encode(nonce))
        .toString()
        .substring(0, 32);
    return 'https://$origin.maaso-bundle.invalid/session/$session/';
  }

  static String safeJson(Object? value) => jsonEncode(value)
      .replaceAll('<', r'\u003c')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');

  static String build({
    required ValidatedProjectBundleV2 bundle,
    required String nonce,
    required String sessionId,
    required Map<String, Object?> initialData,
    required int dataVersion,
    Map<String, Object?>? initialPlay,
    Map<String, Object?>? initialFrame,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{24,128}$').hasMatch(nonce)) {
      throw const FormatException('invalid_bundle_nonce');
    }
    final assets = <String, String>{};
    for (final file in bundle.manifest.files) {
      if (file.role == ProjectBundleV2FileRole.asset) {
        assets[file.path] =
            'data:${file.mimeType};base64,${base64Encode(bundle.files[file.path]!)}';
      }
    }
    final config = <String, Object?>{
      'sdkVersion': '2.0.0',
      'nonce': nonce,
      'sessionId': sessionId,
      'routes': jsonDecode(utf8.decode(bundle.files['routes.json']!)),
      'protocol': bundle.protocol.toJson(),
      'assets': assets,
      'initialData': initialData,
      'dataVersion': dataVersion,
      'initialPlay': ?initialPlay,
      'initialFrame': ?initialFrame,
    };
    var source = bundle.runtimeHtml;
    if ('__MAASO_CONFIG_JSON__'.allMatches(source).length != 1) {
      throw const FormatException('bundle_bootstrap_placeholder');
    }
    final identity = safeJson({
      'nonce': nonce,
      'sessionId': sessionId,
      'projectId': bundle.manifest.projectId,
      'revisionId': bundle.manifest.revisionId,
      'candidateDigest': bundle.candidateDigest,
    });
    final bootstrap =
        '''(() => {
 const identity=$identity, config=${safeJson(config)}, pending=new Map();
 const post=MaasoProjectBridge.postMessage.bind(MaasoProjectBridge), stringify=JSON.stringify.bind(JSON);
 let next=0;
 const send=(operation,payload)=>new Promise((resolve,reject)=>{
   if(pending.size>=32){reject(Error('bridge_busy'));return;}
   const id=String(++next),timer=setTimeout(()=>{pending.delete(id);reject(Error('bridge_timeout'));},15000);
   pending.set(id,{resolve,reject,timer});
   post(stringify({...identity,id,operation,payload}));
 });
 Object.defineProperty(globalThis,'__maasoNativeReply',{value:(token,id,result,error)=>{
   if(token!==identity.nonce)return;const p=pending.get(id);if(!p)return;
   pending.delete(id);clearTimeout(p.timer);error?p.reject(Error(error)):p.resolve(result);
 },writable:false,configurable:false});
 config.dataBridge=(values,expectedDataVersion)=>send('data_save',{values,expectedDataVersion});
 config.playBridge=command=>send('play_submit',command);
 config.playReceiptBridge=requestId=>send('play_receipt',{requestId});
 Object.defineProperty(globalThis,'__maasoNativeControlDispatch',{value:(token,command,callbackToken)=>{
   if(token!==identity.nonce)return;
   Promise.resolve().then(()=>globalThis.__maasoHost.act({...command,nonce:identity.nonce})).then(receipt=>{
     send('control_result',{callbackToken,receipt}).catch(()=>{});
   },error=>{
     const known=['invalid_command','request_id_conflict','state_conflict','observation_conflict','receipt_limit','action_not_available'].includes(error?.message);
     send('control_result',{callbackToken,receipt:{requestId:command.requestId,actionId:command.actionId,
       status:known?'rejected':'unknown',error:known?error.message:'runtime_error'}}).catch(()=>{});
   });
 },writable:false,configurable:false});
 addEventListener('DOMContentLoaded',()=>requestAnimationFrame(()=>requestAnimationFrame(()=>{
   try {const view=globalThis.__maasoHost.inspect(identity.nonce),root=document.getElementById('maaso-project-root'),r=root?.getBoundingClientRect();
     send('frame',{ready:view.ready===true&&!!r&&r.width>0&&r.height>0}).catch(()=>{});
   }catch(_){send('frame',{ready:false}).catch(()=>{});}
 })));
 return config;
})()''';
    source = source.replaceFirst('__MAASO_CONFIG_JSON__', bootstrap);
    source = source.replaceAllMapped(
      RegExp(r'maaso-asset:([A-Za-z0-9_./-]+)'),
      (match) =>
          assets[match[1]] ??
          (throw const FormatException('undeclared_bundle_asset')),
    );
    final document = html.parse(source);
    if (document.querySelectorAll('main#maaso-project-root').length != 1 ||
        document
            .querySelectorAll('iframe,frame,frameset,object,embed,base,link')
            .isNotEmpty) {
      throw const FormatException('invalid_bundle_document');
    }
    if (document.querySelectorAll('meta[http-equiv]').isNotEmpty) {
      // Policy belongs to the host; authored refresh and alternate CSP fail.
      throw const FormatException('authored_bundle_http_equiv');
    }
    final hashes = <String>[];
    for (final script in document.querySelectorAll('script')) {
      if (script.attributes.containsKey('src') ||
          !{
            null,
            '',
            'text/javascript',
            'application/javascript',
          }.contains(script.attributes['type'])) {
        throw const FormatException('external_bundle_script');
      }
      hashes.add(
        "'sha256-${base64Encode(sha256.convert(utf8.encode(script.text)).bytes)}'",
      );
    }
    if (hashes.isEmpty) throw const FormatException('missing_bundle_script');
    final policy =
        "default-src 'none'; script-src ${hashes.join(' ')}; "
        "style-src 'unsafe-inline'; img-src data:; media-src 'none'; font-src 'none'; "
        "connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; "
        "object-src 'none'; base-uri 'none'; form-action 'none'";
    final meta = Element.tag('meta')
      ..attributes['http-equiv'] = 'Content-Security-Policy'
      ..attributes['content'] = policy;
    document.head!.nodes.insert(0, meta);
    return '<!doctype html>${document.documentElement!.outerHtml}';
  }
}

/// Native navigation is not a project action. Only the initial host-created
/// document can load, never an authored external/data/blob replacement.
bool surfaceBundleAllowsInitialNavigation({
  required String source,
  required String? expectedDocument,
  required bool loading,
  required bool allowInitial,
}) =>
    allowInitial &&
    expectedDocument != null &&
    (source == expectedDocument || (loading && source == 'about:blank'));
