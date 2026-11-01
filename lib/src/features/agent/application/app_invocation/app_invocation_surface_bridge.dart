import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

import 'app_invocation_descriptor.dart';

/// A fixed invocation transport, not a model-accessible JavaScript evaluator.
/// Only a dedicated Worker receives authored source. The outer document has no
/// authored DOM/scripts, exposes no native account/device API to the Worker,
/// and can terminate a CPU-bound Worker without waiting for its event loop.
abstract final class AppInvocationSurfaceBridge {
  static String build({
    required SurfaceProject source,
    required AppInvocationDescriptor descriptor,
    required String nonce,
  }) {
    if (!RegExp(r'^[a-f0-9]{48}$').hasMatch(nonce)) {
      throw ArgumentError('invocation_bridge_nonce');
    }
    final parsed = html.parse(source.html);
    final scripts = <String>[];
    // Script-element semantics, not an authored HTML/JavaScript vocabulary
    // filter: data blocks must never become executable code in the adapter.
    // https://html.spec.whatwg.org/multipage/scripting.html#prepare-the-script-element
    // https://mimesniff.spec.whatwg.org/#javascript-mime-type
    const classicTypes = {
      'application/ecmascript',
      'application/javascript',
      'application/x-ecmascript',
      'application/x-javascript',
      'text/ecmascript',
      'text/javascript',
      'text/javascript1.0',
      'text/javascript1.1',
      'text/javascript1.2',
      'text/javascript1.3',
      'text/javascript1.4',
      'text/javascript1.5',
      'text/jscript',
      'text/livescript',
      'text/x-ecmascript',
      'text/x-javascript',
    };
    final asciiWhitespace = RegExp(r'^[\t\n\f\r ]+|[\t\n\f\r ]+$');
    String asciiLower(String value) => String.fromCharCodes(
      value.codeUnits.map(
        (unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit,
      ),
    );
    for (final script in parsed.querySelectorAll('script')) {
      final declaredType = script.attributes['type'];
      final language = script.attributes['language'];
      final typeString =
          declaredType == '' ||
              (declaredType == null && (language == null || language.isEmpty))
          ? 'text/javascript'
          : declaredType ?? 'text/$language';
      final normalizedType = asciiLower(typeString);
      if (normalizedType == 'module') {
        // Module scope/import resolution cannot be emulated by classic eval.
        throw StateError('invocation_module_requires_open');
      }
      final classic =
          classicTypes.contains(normalizedType) ||
          (declaredType != null &&
              classicTypes.contains(
                asciiLower(declaredType.replaceAll(asciiWhitespace, '')),
              ));
      if (!classic || script.attributes.containsKey('nomodule')) continue;
      if (script.attributes.containsKey('src')) {
        // External code remains usable in the ordinary player. An offline
        // invocation cannot silently replace that dependency with a stub.
        throw StateError('invocation_network_dependency_requires_open');
      }
      scripts.add(script.text);
    }
    scripts.add(source.js);
    final configuration = _json({
      'nonce': nonce,
      'scripts': scripts,
      'actions': descriptor.actions.map((action) => action.name).toList(),
      'timeoutMs': 8000,
      'maxBytes': 12 * 1024 * 1024,
      'maxOutputs': 4,
    });
    final workerSource = _json(workerBootstrap);
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; child-src blob:; connect-src 'none'; img-src data:; style-src 'unsafe-inline'; media-src 'none'; font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>App invocation</title></head><body>
<script>(()=>{'use strict';
 const config=$configuration, workerSource=$workerSource;
 const nativePost=MaasoInvocationBridge.postMessage.bind(MaasoInvocationBridge);
 const json=JSON.stringify.bind(JSON), parse=JSON.parse.bind(JSON);
 const worker=new Worker(URL.createObjectURL(new Blob([workerSource],{type:'text/javascript'})));
 const channel=new MessageChannel(), receipts=new Map();
 let live=true, ready=false, version=0, actions=[], current=null;
 const post=value=>nativePost(json({nonce:config.nonce,...value}));
 const timeout=()=>{if(!live)return;live=false;worker.terminate();channel.port1.close();
   if(current){const r={requestId:current.requestId,status:'outcomeUnknown',stateVersion:version,errorCode:'runtime_timeout'};receipts.set(r.requestId,r);post({kind:'result',...r});}
   else post({kind:'ready',ready:false,errorCode:'runtime_timeout'});};
 let timer=setTimeout(timeout,config.timeoutMs);
 const encode=buffer=>{const bytes=new Uint8Array(buffer);let s='';for(let i=0;i<bytes.length;i+=32768)s+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(s);};
 channel.port1.onmessage=event=>{if(!live)return;const message=event.data;
   if(!message||typeof message!=='object')return;
   if(message.kind==='ready') {clearTimeout(timer);ready=message.ready===true;
     actions=Array.isArray(message.actions)?message.actions.filter(v=>config.actions.includes(v)):[];
     if(!ready){live=false;worker.terminate();}post({kind:'ready',ready,actions,stateVersion:version,errorCode:message.errorCode});return;}
   if(message.kind!=='result'||!current||message.requestId!==current.requestId)return;
   clearTimeout(timer);version=message.stateVersion;
   try {const outputs=message.outputs||[];if(outputs.length>config.maxOutputs)throw Error('output_limit');
     const encoded=outputs.map(o=>{if(!(o.bytes instanceof ArrayBuffer)||o.bytes.byteLength>config.maxBytes)throw Error('output_limit');
       return {producerOutputKey:o.producerOutputKey,mime:o.mime,base64:encode(o.bytes)};});
     const receipt={requestId:message.requestId,status:message.status,stateVersion:version,result:message.result??null,
       outputs:encoded,errorCode:message.errorCode};receipts.set(message.requestId,receipt);post({kind:'result',...receipt});
   } catch(_){const receipt={requestId:current.requestId,status:'failed',stateVersion:version,errorCode:'output_invalid'};receipts.set(current.requestId,receipt);post({kind:'result',...receipt});}
   current=null;
 };
 worker.onerror=()=>{clearTimeout(timer);if(current)timeout();else{live=false;worker.terminate();post({kind:'ready',ready:false,errorCode:'runtime_dependency_unavailable'});}};
 Object.defineProperty(window,'__maasoInvocationHost',{value:Object.freeze({
   describe(token){if(token!==config.nonce)throw Error('invalid_session');return {ready:ready&&live,actions,stateVersion:version};},
   dispatch(token,command){if(token!==config.nonce||!live||!ready||current)throw Error('runtime_unavailable');
     if(receipts.has(command.requestId)){post({kind:'result',...receipts.get(command.requestId)});return;}
     if(command.expectedStateVersion!==version)throw Error('state_conflict');
     current=command;timer=setTimeout(timeout,config.timeoutMs);channel.port1.postMessage(command);},
   receipt(token,id){if(token!==config.nonce)throw Error('invalid_session');return receipts.get(id)||null;},
   close(token){if(token!==config.nonce)return;live=false;clearTimeout(timer);worker.terminate();channel.port1.close();}
 }),writable:false,configurable:false});
 worker.postMessage({config:{scripts:config.scripts,actions:config.actions,maxBytes:config.maxBytes,maxOutputs:config.maxOutputs},port:channel.port2},[channel.port2]);
})();</script></body></html>''';
  }

  static String _json(Object? value) => jsonEncode(value)
      .replaceAll('<', r'\u003c')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');

  // Executed in WorkerGlobalScope: no document, cookies, native JavaScript
  // channel, account service, WebRTC or filesystem bridge. Blob Workers inherit
  // the outer document's connect-src/script-src policy. Inputs are supplied by
  // the native grant only for explicitly annotated handle arguments.
  static const workerBootstrap = r'''
(()=>{'use strict';
 const stringify=JSON.stringify.bind(JSON),parse=JSON.parse.bind(JSON),keys=Object.keys.bind(Object);
 const isArray=Array.isArray.bind(Array),nativePost=MessagePort.prototype.postMessage;
 let initialized=false;
 self.onmessage=async event=>{
  if(initialized)return;initialized=true;self.onmessage=null;
  const port=event.data.port,config=event.data.config;
  const post=(value,transfer)=>nativePost.call(port,value,transfer||[]);
  let version=0,busy=false,handlers=null,inputs=new Map();
  const clone=value=>{let nodes=0;const seen=new Set();
   function check(v,d){if(++nodes>4096||d>16)throw Error('result_limit');
    if(v===null||typeof v==='string'||typeof v==='boolean')return;
    if(typeof v==='number'&&Number.isFinite(v))return;
    if(typeof v!=='object'||seen.has(v))throw Error('invalid_json');seen.add(v);
    if(isArray(v))v.forEach(x=>check(x,d+1));else{if(Object.getPrototypeOf(v)!==Object.prototype&&Object.getPrototypeOf(v)!==null)throw Error('invalid_json');keys(v).forEach(k=>check(v[k],d+1));}seen.delete(v);}
   check(value,0);const encoded=stringify(value);if(new TextEncoder().encode(encoded).length>65536)throw Error('result_limit');return parse(encoded);};
  const surface={onAgent:null,emit(){},inputImage(id){const input=inputs.get(id);if(!input)throw Error('input_handle_unavailable');return {id:input.id,mime:input.mime,bytes:new Uint8Array(input.bytes)};},
   registerInvocation(spec){if(handlers||!spec||spec.version!==1||typeof spec.actions!=='object')throw Error('invalid_registration');handlers=new Map();
    for(const name of config.actions){if(typeof spec.actions[name]==='function')handlers.set(name,spec.actions[name]);}}
  };
  Object.defineProperty(self,'Surface',{value:surface,writable:false,configurable:false});
  Object.defineProperty(self,'window',{value:self,writable:false,configurable:false});
  try {
    for(const source of config.scripts)(0,eval)(source);
    if(!handlers&&typeof surface.onAgent==='function'){const callback=surface.onAgent;handlers=new Map(config.actions.map(name=>[name,args=>callback(name,args)]));}
    if(!handlers||handlers.size===0)throw Error('no_handler');
  }catch(_){post({kind:'ready',ready:false,errorCode:'runtime_dependency_unavailable'});return;}
  async function output(item,index){const key=item.producerOutputKey||'image-'+index;
    if(!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(key))throw Error('output_key');
    let payload=item.bytes??item;
    if(typeof OffscreenCanvas!=='undefined'&&payload instanceof OffscreenCanvas)payload=await payload.convertToBlob({type:'image/png'});
    let mime=item.mime,bytes;
    if(payload instanceof Blob){mime=mime||payload.type;if(payload.size>config.maxBytes)throw Error('output_limit');bytes=await payload.arrayBuffer();}
    else if(payload instanceof Uint8Array){bytes=payload.buffer.slice(payload.byteOffset,payload.byteOffset+payload.byteLength);}
    else if(payload instanceof ArrayBuffer){bytes=payload.slice(0);}else throw Error('output_type');
    if(!['image/png','image/jpeg'].includes(mime)||!bytes.byteLength||bytes.byteLength>config.maxBytes)throw Error('output_limit');
    return {producerOutputKey:key,mime,bytes};
  }
  port.onmessage=async event=>{
    const command=event.data;if(busy)return;busy=true;
    try {
      if(!command||command.expectedStateVersion!==version||!handlers.has(command.actionId))throw Error('state_conflict');
      inputs=new Map((command.inputImages||[]).map(input=>{
        const binary=atob(input.base64),bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
        if(bytes.length>config.maxBytes)throw Error('input_limit');return [input.id,{id:input.id,mime:input.mime,bytes}];}));
      const value=await handlers.get(command.actionId)(clone(command.args));
      let result=value??null,raw=[];
      if(value instanceof Blob||(typeof OffscreenCanvas!=='undefined'&&value instanceof OffscreenCanvas)){raw=[value];result=null;}
      else if(value&&value.maasoInvocationResultVersion===1){raw=value.outputs||[];result=value.result??null;}
      if(!isArray(raw)||raw.length>config.maxOutputs)throw Error('output_limit');
      const outputs=[];for(let i=0;i<raw.length;i++)outputs.push(await output(raw[i],i));
      if(new Set(outputs.map(o=>o.producerOutputKey)).size!==outputs.length)throw Error('output_duplicate');
      version++;post({kind:'result',requestId:command.requestId,status:'completed',stateVersion:version,result:clone(result),outputs},outputs.map(o=>o.bytes));
    }catch(_){version++;post({kind:'result',requestId:command?.requestId,status:'failed',stateVersion:version,errorCode:'action_failed'});}
    finally {inputs.clear();busy=false;}
  };
  port.start();post({kind:'ready',ready:true,actions:[...handlers.keys()],stateVersion:version});
 };
})();
''';
}
