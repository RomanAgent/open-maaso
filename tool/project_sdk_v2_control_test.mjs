import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const sdk=fs.readFileSync('assets/project_runtime/maaso_project_sdk_v2.js','utf8');
assert.equal(sdk, fs.readFileSync('../agent_cloud/tools/project-runner/sdk_v2.mjs','utf8'));
const schema={type:'object',properties:{value:{type:'integer',minimum:0,maximum:10}},required:['value'],additionalProperties:false};
async function setup(extra={}) {
  const events=new Map();
  class Element { replaceChildren(){} }
  const sandbox={TextEncoder,HTMLElement:Element,setTimeout,clearTimeout,
    requestAnimationFrame:cb=>setImmediate(cb),
    document:{getElementById:()=>new Element(),documentElement:{dataset:{}}},
    CustomEvent:class {constructor(type,{detail}){this.type=type;this.detail=detail;}},
    addEventListener:(key,fn)=>{const set=events.get(key)||new Set();set.add(fn);events.set(key,set);},
    removeEventListener:(key,fn)=>events.get(key)?.delete(fn),
    dispatchEvent:event=>events.get(event.type)?.forEach(fn=>fn(event)),...extra};
  const context=vm.createContext(sandbox);
  const config={sdkVersion:'2.0.0',nonce:'test-nonce',sessionId:'test-session',routes:{entryRouteId:'home',routes:[{routeId:'home',parametersSchema:{type:'object',properties:{},required:[],additionalProperties:false}}]},protocol:{projectId:'project-one',revisionId:'revision-one',projectKind:'applet',actions:[{id:'app.set',argsSchema:schema}]},assets:{},initialData:{}};
  vm.runInContext(`globalThis.__MAASO_CONFIG__=${JSON.stringify(config)};`,context);
  vm.runInContext(sdk,context);
  const run=source=>vm.runInContext(source,context);
  await run(`globalThis.count=0;globalThis.applied=0;awaitRegister=Maaso.register({routes:{home:()=>new HTMLElement()},actions:{'app.set':async args=>{if(globalThis.gate)await gate;count=args.value;applied++;return {value:count};}},observe:()=>({count})});awaitRegister`);
  return {run,context};
}
function command(extra={}) {return JSON.stringify({nonce:'test-nonce',requestId:'request_0001',actionId:'app.set',args:{value:1},expectedStateVersion:1,...extra});}
let cases=0;
{
  const {run}=await setup();
  assert.equal(run(`__maasoHost.controlInfo('test-nonce').controlProtocolVersion`),1);
  assert.throws(()=>run(`__maasoHost.controlInfo('foreign')`),/invalid_session/);
  assert.equal(run(`__maasoHost.receipt('test-nonce','request_0001')`),null);
  await run(`__maasoHost.act(${command()})`);
  assert.equal(run(`__maasoHost.receipt('test-nonce','request_0001').status`),'applied');
  await run(`__maasoHost.act(${command()})`);
  assert.equal(run('applied'),1);
  await assert.rejects(run(`__maasoHost.act(${command({args:{value:2}})})`),/request_id_conflict/);
  assert.equal(run('applied'),1); cases++;
}
{
  const {run}=await setup();
  run(`globalThis.gate=new Promise(resolve=>globalThis.release=resolve);`);
  const pending=run(`__maasoHost.act(${command()})`);
  assert.equal(run(`__maasoHost.receipt('test-nonce','request_0001').status`),'pending');
  assert.equal((await run(`__maasoHost.act(${command()})`)).status,'pending');
  await assert.rejects(run(`__maasoHost.act(${command({requestId:'request_0002'})})`),/state_conflict/);
  run('release()');await pending;
  assert.equal(run('applied'),1);cases++;
}
{
  const {run}=await setup();
  run(`globalThis.observation=__maasoHost.inspect('test-nonce');count=4;`);
  await assert.rejects(run(`__maasoHost.act({...${command()},expectedObservation:observation})`),/observation_conflict/);
  assert.equal(run('applied'),0);cases++;
}
{
  const {run}=await setup();
  run(`globalThis.observation=__maasoHost.inspect('test-nonce')`);
  await run(`__maasoHost.act({...${command()},expectedObservation:observation})`);
  assert.equal((await run(`__maasoHost.act({...${command()},expectedObservation:Object.fromEntries(Object.entries(observation).reverse())})`)).status,'applied');
  assert.equal(run('applied'),1);cases++;
}
{
  const {run}=await setup();
  run(`__MAASO_CONFIG__.dataBridge=async()=>{throw Error('offline')};`);
  await assert.rejects(run(`Maaso.data.set('value',1)`),/offline/);
  assert.equal(run(`Maaso.data.get('value')`),null);
  assert.throws(()=>run(`Maaso.data.set('large','x'.repeat(65536))`),/payload_limit/);
  assert.equal(run(`Maaso.data.get('large')`),null);cases++;
}
{
  const {run}=await setup();
  const frame={protocolVersion:2,projectId:'project-one',revisionId:'revision-one',sessionId:'test-session',matchId:'match-one',matchEpoch:1,seatId:'player1',frameSequence:1,simTick:1,decisionRevision:1,windowId:'window-1',phase:'playing',allowedView:{x:1}};
  const send=f=>run(`__maasoHost.updatePlayFrame('test-nonce',${JSON.stringify(f)})`);
  run(`globalThis.seen=[];globalThis.unsubscribe=Maaso.onPlayFrame(frame=>seen.push(frame.simTick));`);
  assert.equal(send(frame),true);
  assert.equal(send({...frame,simTick:0,frameSequence:0}),false);
  assert.equal(send({...frame,matchEpoch:0,frameSequence:2}),false);
  assert.equal(send({...frame,matchEpoch:2,frameSequence:0,simTick:2}),true);
  assert.deepEqual([...run('seen')],[1,2]);
  assert.throws(()=>send({...frame,sessionId:'foreign'}),/invalid_play_frame/);
  assert.throws(()=>send({...frame,allowedView:{huge:'x'.repeat(8192)}}),/invalid_play_frame/);
  run('unsubscribe()');send({...frame,matchEpoch:2,frameSequence:1});
  assert.equal(run('seen.length'),2);cases++;
}
console.log(JSON.stringify({passed:cases,sdkMirror:true,scope:'SDK semantic control and frame contracts; not a physical WebView acceptance'}));
