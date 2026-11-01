import 'dart:convert';

import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as parser;
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';

import 'app_invocation_descriptor.dart';

/// Ordinary browser execution in an invocation-owned WebView/profile. There is
/// deliberately no native JavaScript channel. Native code can only send fixed
/// commands and read bounded, untrusted results from this document.
abstract final class AppInvocationWebDocument {
  static String build({
    required SurfaceProject source,
    required AppInvocationDescriptor descriptor,
  }) {
    final document = parser.parse(
      SurfaceWebAppHost.build(source, lifecycleToken: 1),
    );
    final head = document.head!;
    final host = head.querySelector('script')!;
    final bridge = html.Element.tag('script')
      ..attributes['data-maaso-invocation'] = '1'
      ..text = bootstrap.replaceFirst(
        '__DECLARED_ACTIONS__',
        jsonEncode(descriptor.actions.map((action) => action.name).toList())
            .replaceAll('<', r'\u003c')
            .replaceAll('\u2028', r'\u2028')
            .replaceAll('\u2029', r'\u2029'),
      );
    // The shared host installs Surface first; the invocation bridge follows it
    // before authored head scripts, modules, body content, and source.js.
    head.nodes.insert(head.nodes.indexOf(host) + 1, bridge);
    return document.outerHtml;
  }

  static const bootstrap = r'''
(()=>{'use strict';
 const declared=__DECLARED_ACTIONS__, stringify=JSON.stringify.bind(JSON), parse=JSON.parse.bind(JSON);
 const getPrototype=Object.getPrototypeOf.bind(Object), keys=Object.keys.bind(Object), isArray=Array.isArray.bind(Array);
 const objectPrototype=Object.prototype, textEncoder=new TextEncoder(), receipts=new Map();
 const maxBytes=12*1024*1024,maxOutputs=4;
 let live=true,loaded=document.readyState==='complete',failed=false,busy=false,version=0,handlers=null,inputs=new Map();
 const surface=window.Surface;
 const clone=value=>{let nodes=0;const seen=new Set();
  function check(v,d){if(++nodes>4096||d>16)throw Error('result_limit');
   if(v===null||typeof v==='boolean')return;
   if(typeof v==='string'){if(v.length>65536)throw Error('result_limit');return;}
   if(typeof v==='number'&&Number.isFinite(v))return;
   if(typeof v!=='object'||seen.has(v))throw Error('invalid_json');seen.add(v);
   if(isArray(v))v.forEach(x=>check(x,d+1));else{if(getPrototype(v)!==objectPrototype&&getPrototype(v)!==null)throw Error('invalid_json');keys(v).forEach(k=>{if(k.length>65536)throw Error('result_limit');check(v[k],d+1);});}seen.delete(v);}
  check(value,0);const encoded=stringify(value);if(textEncoder.encode(encoded).length>65536)throw Error('result_limit');return parse(encoded);};
 const encode=buffer=>{const bytes=new Uint8Array(buffer);let s='';for(let i=0;i<bytes.length;i+=32768)s+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(s);};
 const actionNames=()=>handlers?[...handlers.keys()]:(typeof surface.onAgent==='function'?declared.slice():[]);
 Object.defineProperty(surface,'registerInvocation',{value:spec=>{
  if(handlers||!spec||spec.version!==1||!spec.actions||typeof spec.actions!=='object')throw Error('invalid_registration');
  handlers=new Map();for(const name of declared)if(typeof spec.actions[name]==='function')handlers.set(name,spec.actions[name]);
 },writable:false,configurable:false});
 Object.defineProperty(surface,'inputImage',{value:id=>{const input=inputs.get(id);if(!input)throw Error('input_handle_unavailable');return {id:input.id,mime:input.mime,bytes:new Uint8Array(input.bytes)};},writable:false,configurable:false});
 // Events remain authored observations; they never invoke a native command or
 // navigate away from this invocation document.
 surface.emit=()=>{};
 window.addEventListener('load',()=>{loaded=true;},{once:true});
 window.addEventListener('error',event=>{if(event.target===window&&!loaded)failed=true;},true);
 window.addEventListener('unhandledrejection',()=>{if(!loaded)failed=true;},true);
 async function output(item,index){const key=item.producerOutputKey||'image-'+index;
  if(!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(key))throw Error('output_key');
  let payload=item.bytes??item;
  if(typeof HTMLCanvasElement!=='undefined'&&payload instanceof HTMLCanvasElement)payload=await new Promise((resolve,reject)=>payload.toBlob(blob=>blob?resolve(blob):reject(Error('canvas_output_unavailable')),'image/png'));
  if(typeof OffscreenCanvas!=='undefined'&&payload instanceof OffscreenCanvas)payload=await payload.convertToBlob({type:'image/png'});
  let mime=item.mime,bytes;
  if(payload instanceof Blob){mime=mime||payload.type;if(payload.size>maxBytes)throw Error('output_limit');bytes=await payload.arrayBuffer();}
  else if(payload instanceof Uint8Array)bytes=payload.buffer.slice(payload.byteOffset,payload.byteOffset+payload.byteLength);
  else if(payload instanceof ArrayBuffer)bytes=payload.slice(0);else throw Error('output_type');
  if(!['image/png','image/jpeg'].includes(mime)||!bytes.byteLength||bytes.byteLength>maxBytes)throw Error('output_limit');
  return {producerOutputKey:key,mime,base64:encode(bytes)};
 }
 async function execute(command){
  try{
   inputs=new Map((command.inputImages||[]).map(input=>{const binary=atob(input.base64),bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);if(bytes.length>maxBytes)throw Error('input_limit');return [input.id,{id:input.id,mime:input.mime,bytes}];}));
   const value=await (handlers?handlers.get(command.actionId)(clone(command.args)):surface.onAgent(command.actionId,clone(command.args)));
   if(!live)return;
   let result=value??null,raw=[];
   if(value instanceof Blob||(typeof HTMLCanvasElement!=='undefined'&&value instanceof HTMLCanvasElement)||(typeof OffscreenCanvas!=='undefined'&&value instanceof OffscreenCanvas)){raw=[value];result=null;}
   else if(value&&value.maasoInvocationResultVersion===1){raw=value.outputs||[];result=value.result??null;}
   if(!isArray(raw)||raw.length>maxOutputs)throw Error('output_limit');
   const outputs=[];for(let i=0;i<raw.length;i++)outputs.push(await output(raw[i],i));
   if(!live)return;
   if(new Set(outputs.map(o=>o.producerOutputKey)).size!==outputs.length)throw Error('output_duplicate');
   const frozen=clone(result);version++;
   receipts.set(command.requestId,{requestId:command.requestId,status:'completed',stateVersion:version,result:frozen,outputs});
  }catch(_){if(live){version++;receipts.set(command.requestId,{requestId:command.requestId,status:'failed',stateVersion:version,errorCode:'action_failed'});}}
  finally{inputs.clear();busy=false;}
 }
 Object.defineProperty(window,'__maasoInvocationHost',{value:Object.freeze({
  describe(){return stringify({ready:live&&loaded&&!failed&&actionNames().length>0,actions:actionNames(),stateVersion:version,errorCode:failed?'runtime_dependency_unavailable':null});},
  dispatch(command){if(!live||!loaded||failed||busy)throw Error('runtime_unavailable');
   if(receipts.has(command.requestId))return;
   if(command.expectedStateVersion!==version||!actionNames().includes(command.actionId))throw Error('state_conflict');
   busy=true;void execute(command);
  },
  receipt(id){return stringify(receipts.get(id)||null);},
  release(){live=false;inputs.clear();},
  close(){live=false;inputs.clear();receipts.clear();}
 }),writable:false,configurable:false});
})();
''';
}
