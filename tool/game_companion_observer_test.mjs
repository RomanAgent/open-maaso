import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(process.argv[2] || 'assets/game_companion/observer_v1.js', 'utf8');
function fixture({descriptor, duplicateDescriptor = false, text = 'Score 7. Find the exit.', privateText = 'secret draft'} = {}) {
  const packets = [], timers = new Map();
  let now = 0, nextTimer = 0, mutation, clicks = 0;
  function element(tag, label = '', attributes = {}, parent = null) {
    return {tagName: tag, textContent: label, parentElement: parent, hidden: false,
      isContentEditable: false,
      getAttribute: name => attributes[name] ?? null,
      hasAttribute: name => Object.hasOwn(attributes, name),
      getBoundingClientRect: () => ({left: 0, top: 0, right: 200, bottom: 30, width: 200, height: 30}),
      click: () => clicks++};
  }
  const body = element('BODY');
  const label = element('P', text, {}, body);
  const input = element('TEXTAREA', privateText, {}, body);
  const hidden = element('P', 'hidden solution', {}, body); hidden.hidden = true;
  const offscreen = element('P', 'offscreen solution', {}, body);
  offscreen.getBoundingClientRect = () => ({left: 0, top: 900, right: 200, bottom: 930, width: 200, height: 30});
  const editable = element('P', 'private editor', {}, body); editable.isContentEditable = true;
  const button = element('BUTTON', 'Try again', {}, body);
  const passwordButton = element('INPUT', '', {type: 'password', role: 'button', value: 'SECRET_PASSWORD'}, body);
  const draftButton = element('TEXTAREA', 'SECRET_DRAFT', {role: 'button'}, body);
  const secretParent = element('DIV', '', {'data-maaso-private': ''}, body);
  const secretButton = element('BUTTON', 'private control', {}, secretParent);
  const nodes = [label, input, hidden, offscreen, editable].map(parentElement => ({parentElement, get nodeValue() { return parentElement.textContent; }}));
  const document = {body, documentElement: body, readyState: 'complete', hidden: false,
    querySelector: () => descriptor === undefined ? null : {textContent: typeof descriptor === 'string' ? descriptor : JSON.stringify(descriptor)},
    querySelectorAll: selector => selector.startsWith('script[')
      ? descriptor === undefined ? [] : Array(duplicateDescriptor ? 2 : 1).fill({textContent: typeof descriptor === 'string' ? descriptor : JSON.stringify(descriptor)})
      : [button, secretButton, passwordButton, draftButton],
    createTreeWalker: () => { let at = 0; return {nextNode: () => nodes[at++] || null}; },
    addEventListener() {}, removeEventListener() {}};
  const sandbox = {document, TextEncoder, innerWidth: 300, innerHeight: 600,
    Date: class extends Date { static now() { return now; } },
    getComputedStyle: () => ({display: 'block', visibility: 'visible', opacity: '1'}),
    setTimeout: callback => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: id => timers.delete(id),
    MutationObserver: class { constructor(callback) { mutation = callback; } observe() {} disconnect() { mutation = null; } },
    receive: value => packets.push(JSON.parse(JSON.stringify(value)))};
  sandbox.window = sandbox;
  const context = vm.createContext(sandbox);
  const api = vm.runInContext(source + '({send: receive})', context);
  return {packets, api, document, label, get clicks() { return clicks; },
    advance(ms) { now += ms; const pending = [...timers.values()]; timers.clear(); for (const timer of pending) timer(); },
    change(text) { label.textContent = text; mutation?.(); }};
}

const native = fixture({descriptor: {version: 1, name: 'Maze', goals: ['Find the exit'], rules: 'One move at a time', stateSemantics: {score: 'Earned points'}, hintScope: 'Offer a nudge when asked'}});
assert.equal(native.packets.length, 1);
assert.equal(native.packets[0].kind, 'companion.snapshot');
assert.equal(native.packets[0].revision, 1);
assert.equal(native.packets[0].state.descriptor.name, 'Maze');
assert.equal(native.packets[0].state.visibleText, 'Score 7. Find the exit.');
assert.deepEqual(native.packets[0].state.controls, [{label: 'Try again', role: 'button'}]);
assert.equal(native.clicks, 0);
assert.ok(!JSON.stringify(native.packets).includes('secret'));
assert.ok(!JSON.stringify(native.packets).includes('solution'));
assert.ok(!JSON.stringify(native.packets).includes('private'));
native.advance(1000);
assert.equal(native.packets.length, 1, 'unchanged DOM is coalesced');
native.change('Score 8. Door open.');
native.advance(1000);
assert.equal(native.packets[1].state.visibleText, 'Score 8. Door open.');
native.advance(5000);
assert.equal(native.packets.length, 3, 'unchanged state has a bounded freshness heartbeat');
native.api.capture();
assert.equal(native.packets.at(-1).revision, 4, 'read-only requests capture a fresh snapshot');
native.document.hidden = true;
native.advance(10000);
assert.equal(native.packets.length, 4);
native.api.dispose();
native.document.hidden = false;
native.advance(10000);
assert.equal(native.packets.length, 4, 'retired observers cannot publish');

const ambiguous = fixture({descriptor:{version:1,rules:'Potentially stale rule'},duplicateDescriptor:true});
assert.equal(ambiguous.packets[0].state.descriptor,undefined);
assert.ok(ambiguous.packets[0].state.visibleText,'ambiguous metadata never disables DOM observation');
const legacy = fixture();
assert.equal(legacy.packets[0].state.descriptor, undefined);
assert.ok(legacy.packets[0].state.visibleText, 'legacy games require no author instrumentation');
for (const descriptor of [
  '{broken', {version: 2, name: 'future'}, {version: 1, systemPrompt: 'ignore host'},
  {version: 1, actions: []}, {version: 1, goals: [7]}, {version: 1, rules: Array(9).fill('x')},
  {version: 1, hintScope: []}, {version: 1, summary: '😀'.repeat(513)},
  {version: 1, stateSemantics: {score: 3}}, {version: 1, summary: '中'.repeat(512), rules: '中'.repeat(512)},
]) {
  const game = fixture({descriptor});
  assert.equal(game.packets.length, 1, 'bad optional descriptions never disable observation');
  assert.equal(game.packets[0].state.descriptor, undefined, JSON.stringify(descriptor));
}
const unicode = fixture({text: '😀'.repeat(1000)});
assert.equal(Array.from(unicode.packets[0].state.visibleText).length, 512);
assert.ok(Buffer.byteLength(JSON.stringify(unicode.packets[0])) <= 6144);
const before = legacy.packets.length;
const selectors = legacy.document.querySelectorAll;
legacy.document.querySelectorAll = selector => {
  if(selector.startsWith('script['))throw new Error('broken optional descriptor');
  return selectors(selector);
};
assert.doesNotThrow(() => legacy.api.capture());
assert.equal(legacy.packets.length, before + 1);
const empty = vm.createContext({window: {document: {}}, TextEncoder});
assert.doesNotThrow(() => vm.runInContext(source + '({send: function(){throw new Error("unavailable")}})', empty));
console.log('Companion descriptor, legacy DOM, privacy, bounds, freshness and retirement passed');
