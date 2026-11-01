import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';
import { deflateSync, inflateSync } from 'node:zlib';

// This executes the production SDK. The declared actions and their handlers are
// synthetic conformance examples, not shipped applets or a second dispatcher.
// Inline PNG bytes exercise the SDK's bounded JSON result transport only; they
// do not establish production output handles, chat persistence or WebView QA.
const sdkUrl = new URL('../assets/project_runtime/maaso_project_sdk_v2.js', import.meta.url);
const fixtureUrl = new URL('./fixtures/project_sdk_v2_declared_actions.json', import.meta.url);
const sdk = fs.readFileSync(sdkUrl, 'utf8');
const fixtureSource = fs.readFileSync(fixtureUrl, 'utf8');
const fixture = JSON.parse(fixtureSource);
const emptySchema = { type: 'object', properties: {}, required: [], additionalProperties: false };

async function createHarness(actionIds = fixture.protocol.actions.map(action => action.id)) {
  assert.equal(actionIds.length, fixture.protocol.actions.length);
  assert.equal(new Set(actionIds).size, actionIds.length);
  const events = new Map();
  class Element { replaceChildren() {} }
  const context = vm.createContext({
    TextEncoder,
    HTMLElement: Element,
    setTimeout,
    clearTimeout,
    requestAnimationFrame: callback => setImmediate(callback),
    document: { getElementById: () => new Element(), documentElement: { dataset: {} } },
    CustomEvent: class {
      constructor(type, { detail }) { this.type = type; this.detail = detail; }
    },
    addEventListener: (key, callback) => {
      const listeners = events.get(key) || new Set();
      listeners.add(callback);
      events.set(key, listeners);
    },
    removeEventListener: (key, callback) => events.get(key)?.delete(callback),
    dispatchEvent: event => events.get(event.type)?.forEach(callback => callback(event)),
    fixtureEncodePng: args => encodeRgbaPng(args).toString('base64'),
  });
  const config = {
    sdkVersion: '2.0.0',
    nonce: 'fixture-native-nonce',
    sessionId: 'fixture-session',
    routes: {
      entryRouteId: 'home',
      routes: [{ routeId: 'home', parametersSchema: emptySchema }],
    },
    protocol: {
      ...fixture.protocol,
      actions: fixture.protocol.actions.map((action, index) => ({ ...action, id: actionIds[index] })),
    },
    assets: {},
    initialData: { sentinel: 'original installed value' },
  };
  const run = source => vm.runInContext(source, context);
  run(`globalThis.__MAASO_CONFIG__ = ${JSON.stringify(config)};`);
  run(sdk);
  await run(`
    globalThis.fixtureCalls = {};
    globalThis.fixtureInitialData = JSON.stringify(__MAASO_CONFIG__.initialData);
    const ids = __MAASO_CONFIG__.protocol.actions.map(action => action.id);
    const handlers = [
      args => {
        const text = args.title + ': ' + args.lines.join(' / ');
        return args.uppercase ? text.toUpperCase() : text;
      },
      args => ({
        count: args.entries.length,
        total: args.entries.reduce((sum, entry) => sum + entry.value, 0),
        labels: args.includeLabels ? args.entries.map(entry => entry.label) : [],
      }),
      args => ({
        mimeType: 'image/png',
        width: args.width,
        height: args.height,
        dataBase64: fixtureEncodePng(args),
      }),
    ];
    globalThis.fixtureRegistered = Maaso.register({
      routes: { home: () => new HTMLElement() },
      actions: Object.fromEntries(ids.map((id, index) => [id, async args => {
        fixtureCalls[id] = (fixtureCalls[id] || 0) + 1;
        if (globalThis.fixtureGate) await fixtureGate;
        if (globalThis.fixtureFail === id) throw Error('fixture_async_failure');
        globalThis.fixtureHandlerInput = args;
        globalThis.fixtureHandlerResult = handlers[index](args);
        return fixtureHandlerResult;
      }])),
      observe: () => ({ route: 'home' }),
    });
    fixtureRegistered;
  `);
  return { run, actionIds };
}

function command(harness, actionId, args, requestId, extra = {}) {
  return {
    nonce: 'fixture-native-nonce',
    requestId,
    actionId,
    args,
    expectedStateVersion: harness.run(`__maasoHost.inspect('fixture-native-nonce').stateVersion`),
    ...extra,
  };
}

function receipt(harness, requestId) {
  return JSON.parse(harness.run(
    `JSON.stringify(__maasoHost.receipt('fixture-native-nonce', ${JSON.stringify(requestId)}))`,
  ));
}

function verifyReceiptIdentity(actual, sent, status = 'applied') {
  assert.equal(actual.requestId, sent.requestId);
  assert.equal(actual.actionId, sent.actionId);
  assert.equal(actual.status, status);
  assert.equal(actual.stateVersion, sent.expectedStateVersion + 1);
}

// A tiny test-only PNG producer, supplied as an ordinary declared action's
// implementation. Dispatch and JSON validation remain entirely in the SDK.
function encodeRgbaPng({ width, height, rgba }) {
  assert.equal(rgba.length, width * height * 4);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  const scanlines = Buffer.alloc(height * (1 + width * 4));
  for (let row = 0; row < height; row++) {
    Buffer.from(rgba.slice(row * width * 4, (row + 1) * width * 4))
      .copy(scanlines, row * (1 + width * 4) + 1);
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', header),
    pngChunk('IDAT', deflateSync(scanlines)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function pngChunk(type, data) {
  const tag = Buffer.from(type, 'ascii');
  const result = Buffer.alloc(data.length + 12);
  result.writeUInt32BE(data.length, 0);
  tag.copy(result, 4);
  data.copy(result, 8);
  result.writeUInt32BE(crc32(Buffer.concat([tag, data])), data.length + 8);
  return result;
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function decodeRgbaPng(bytes) {
  assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  let offset = 8;
  let width, height;
  const compressed = [];
  const types = [];
  while (offset < bytes.length) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    assert.equal(bytes.readUInt32BE(offset + 8 + length), crc32(bytes.subarray(offset + 4, offset + 8 + length)));
    types.push(type);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.deepEqual([...data.subarray(8)], [8, 6, 0, 0, 0]);
    }
    if (type === 'IDAT') compressed.push(data);
    offset += length + 12;
  }
  assert.equal(offset, bytes.length);
  assert.deepEqual(types, ['IHDR', 'IDAT', 'IEND']);
  const scanlines = inflateSync(Buffer.concat(compressed));
  assert.equal(scanlines.length, height * (1 + width * 4));
  const rgba = [];
  for (let row = 0; row < height; row++) {
    const start = row * (1 + width * 4);
    assert.equal(scanlines[start], 0);
    rgba.push(...scanlines.subarray(start + 1, start + 1 + width * 4));
  }
  return { width, height, rgba };
}

let passed = 0;
for (const actionIds of [undefined, ['orbit:alpha_27', 'unrelated-47', 'zeta.custom:89']]) {
  const harness = await createHarness(actionIds);
  const { run, actionIds: ids } = harness;
  assert.deepEqual(JSON.parse(run(`JSON.stringify(__maasoHost.inspect('fixture-native-nonce').actions)`)), ids);
  const text = command(harness, ids[0], { title: 'Today', lines: ['one', 'two'], uppercase: false }, 'request_text_1');
  const textResult = await run(`__maasoHost.act(${JSON.stringify(text)})`);
  verifyReceiptIdentity(textResult, text);
  assert.equal(textResult.result, 'Today: one / two');
  const changed = command(harness, ids[0], { title: 'Later', lines: ['three'], uppercase: true }, 'request_text_2');
  assert.equal((await run(`__maasoHost.act(${JSON.stringify(changed)})`)).result, 'LATER: THREE');
  const structured = command(harness, ids[1], {
    entries: [{ label: 'credit', value: 9 }, { label: 'debit', value: -4 }],
    includeLabels: true,
  }, 'request_json_1');
  const structuredResult = await run(`__maasoHost.act(${JSON.stringify(structured)})`);
  verifyReceiptIdentity(structuredResult, structured);
  assert.deepEqual(JSON.parse(JSON.stringify(structuredResult.result)), { count: 2, total: 5, labels: ['credit', 'debit'] });
  const imageArgs = { width: 2, height: 1, rgba: [255, 0, 40, 0, 10, 200, 30, 128] };
  const image = command(harness, ids[2], imageArgs, 'request_image_1');
  const imageResult = await run(`__maasoHost.act(${JSON.stringify(image)})`);
  verifyReceiptIdentity(imageResult, image);
  assert.equal(imageResult.result.mimeType, 'image/png');
  const bytes = Buffer.from(imageResult.result.dataBase64, 'base64');
  assert.deepEqual(decodeRgbaPng(bytes), imageArgs);
  const secondImage = command(harness, ids[2], { width: 1, height: 1, rgba: [11, 22, 33, 255] }, 'request_image_2');
  const secondResult = await run(`__maasoHost.act(${JSON.stringify(secondImage)})`);
  const secondBytes = Buffer.from(secondResult.result.dataBase64, 'base64');
  assert.deepEqual(decodeRgbaPng(secondBytes), secondImage.args);
  assert.notEqual(createHash('sha256').update(bytes).digest('hex'), createHash('sha256').update(secondBytes).digest('hex'));
  assert.equal(run(`JSON.stringify(__MAASO_CONFIG__.initialData) === fixtureInitialData`), true);
  passed++;
}

{
  const harness = await createHarness();
  const { run, actionIds: ids } = harness;
  const sent = command(harness, ids[0], { title: 'Once', lines: ['original'], uppercase: false }, 'request_async_1');
  run(`globalThis.fixtureGate = new Promise(resolve => globalThis.fixtureRelease = resolve);
       globalThis.fixtureCommand = ${JSON.stringify(sent)};`);
  const pending = run('__maasoHost.act(fixtureCommand)');
  assert.equal(receipt(harness, sent.requestId).status, 'pending');
  const duplicate = await run(`__maasoHost.act(${JSON.stringify(sent)})`);
  assert.equal(duplicate.status, 'pending');
  await assert.rejects(run(`__maasoHost.act(${JSON.stringify({ ...sent, args: { ...sent.args, title: 'Conflict' } })})`), /request_id_conflict/);
  run(`fixtureCommand.args.lines[0] = 'mutated after admission'; fixtureRelease();`);
  const completed = await pending;
  verifyReceiptIdentity(completed, sent);
  assert.equal(completed.result, 'Once: original');
  assert.deepEqual(receipt(harness, sent.requestId), JSON.parse(JSON.stringify(completed)));
  const replay = await run(`__maasoHost.act(${JSON.stringify(sent)})`);
  assert.deepEqual(JSON.parse(JSON.stringify(replay)), receipt(harness, sent.requestId));
  assert.equal(run(`fixtureCalls[${JSON.stringify(ids[0])}]`), 1);
  passed++;
}

{
  const harness = await createHarness();
  const { run, actionIds: ids } = harness;
  const sent = command(harness, ids[1], { entries: [{ label: 'x', value: 1 }], includeLabels: true }, 'request_failed_1');
  run(`globalThis.fixtureGate = new Promise(resolve => globalThis.fixtureRelease = resolve);
       globalThis.fixtureFail = ${JSON.stringify(ids[1])};`);
  const pending = run(`__maasoHost.act(${JSON.stringify(sent)})`);
  assert.equal(receipt(harness, sent.requestId).status, 'pending');
  run('fixtureRelease()');
  const failed = await pending;
  verifyReceiptIdentity(failed, sent, 'failed');
  assert.equal(failed.error, 'action_failed');
  assert.equal(Object.hasOwn(failed, 'result'), false);
  run('globalThis.fixtureFail = null;');
  assert.deepEqual(JSON.parse(JSON.stringify(await run(`__maasoHost.act(${JSON.stringify(sent)})`))), receipt(harness, sent.requestId));
  assert.equal(run(`fixtureCalls[${JSON.stringify(ids[1])}]`), 1);
  passed++;
}

{
  const harness = await createHarness();
  const { run, actionIds: ids } = harness;
  const valid = { title: 'Bounded', lines: ['value'], uppercase: false };
  const invalid = [
    { title: 7, lines: ['value'], uppercase: false },
    { lines: ['value'], uppercase: false },
    { ...valid, extra: 'undeclared' },
    { ...valid, title: 'x'.repeat(33) },
    { ...valid, lines: Array(9).fill('x') },
  ];
  for (const [index, args] of invalid.entries()) {
    const sent = command(harness, ids[0], args, `request_invalid_${index}`);
    await assert.rejects(run(`__maasoHost.act(${JSON.stringify(sent)})`), /action_not_available/);
    assert.equal(receipt(harness, sent.requestId), null);
  }
  const unknown = command(harness, 'not.declared', valid, 'request_unknown_1');
  await assert.rejects(run(`__maasoHost.act(${JSON.stringify(unknown)})`), /action_not_available/);
  assert.equal(run('Object.keys(fixtureCalls).length'), 0);
  passed++;
}

{
  const harness = await createHarness();
  const { run, actionIds: ids } = harness;
  const sent = command(harness, ids[1], { entries: [{ label: 'stored', value: 6 }], includeLabels: true }, 'request_snapshot_1');
  const returned = await run(`__maasoHost.act(${JSON.stringify(sent)})`);
  returned.result.labels[0] = 'caller mutation';
  run(`fixtureHandlerInput.entries[0].value = 99;
       fixtureHandlerResult.labels[0] = 'handler mutation';
       globalThis.fixtureReceipt = __maasoHost.receipt('fixture-native-nonce', 'request_snapshot_1');
       fixtureReceipt.result.labels[0] = 'reader mutation';`);
  assert.deepEqual(receipt(harness, sent.requestId).result, { count: 1, total: 6, labels: ['stored'] });
  assert.deepEqual(sent.args, { entries: [{ label: 'stored', value: 6 }], includeLabels: true });
  assert.throws(() => run(`__maasoHost.receipt('foreign-nonce', 'request_snapshot_1')`), /invalid_session/);
  passed++;
}

assert.equal(fs.readFileSync(sdkUrl, 'utf8'), sdk);
assert.equal(fs.readFileSync(fixtureUrl, 'utf8'), fixtureSource);
console.log(JSON.stringify({
  passed,
  productionSdkSha256: createHash('sha256').update(sdk).digest('hex'),
  scope: 'Production SDK declared-action dispatch with fixture text, JSON and PNG results; document-memory receipts only',
  doesNotVerify: ['bundle admission', 'native permission grants', 'persistent invocation isolation', 'chat result persistence', 'physical WebView'],
}));
