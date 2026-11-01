import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const hostSource = await readFile(
  new URL('../../web/maaso_unity_avatar.js', import.meta.url),
  'utf8',
);

const manifest = Object.freeze({
  schemaVersion: 1,
  buildName: 'MaasoAvatar',
  unityVersion: '6000.5.2f1',
  productVersion: '1.0.0',
  files: {
    loader: 'Build/MaasoAvatar.loader.js',
    data: 'Build/MaasoAvatar.data',
    framework: 'Build/MaasoAvatar.framework.js',
    wasm: 'Build/MaasoAvatar.wasm',
    streamingAssets: null,
  },
});

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.nodeType = 1;
    this.style = {};
    this.attributes = new Map();
    this.children = [];
    this.parentNode = null;
    this.isConnected = true;
    this.tabIndex = 0;
    this.listeners = new Map();
    this._appendHook = null;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    this.children.push(child);
    child.parentNode = this;
    this._appendHook?.(child);
    return child;
  }

  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index >= 0) this.children.splice(index, 1);
    child.parentNode = null;
    return child;
  }

  getBoundingClientRect() {
    return { width: 640, height: 480 };
  }

  addEventListener(type, callback) {
    const callbacks = this.listeners.get(type) ?? [];
    callbacks.push(callback);
    this.listeners.set(type, callbacks);
  }

  removeEventListener(type, callback) {
    const callbacks = this.listeners.get(type) ?? [];
    this.listeners.set(
      type,
      callbacks.filter((candidate) => candidate !== callback),
    );
  }

  dispatch(type, values = {}) {
    const event = {
      currentTarget: this,
      preventDefault() {},
      ...values,
    };
    for (const callback of this.listeners.get(type) ?? []) callback(event);
  }
}

class FakeDocument {
  constructor(baseURI) {
    this.baseURI = baseURI;
    this.head = new FakeElement('head');
  }

  createElement(tagName) {
    return new FakeElement(tagName);
  }

  querySelector(selector) {
    if (!selector.startsWith('script[')) return null;
    return this.head.children.find((child) => child.tagName === 'SCRIPT') ?? null;
  }
}

function createHarness({
  deferredManifest = false,
  hangingQuit = false,
  fastQuitTimeout = false,
  fastStartupTimeout = false,
  nonSettlingStage = null,
} = {}) {
  const document = new FakeDocument('https://example.test/nested/app/');
  const fetchUrls = [];
  const fetchSignals = [];
  const createCalls = [];
  const createInvocations = [];
  const instances = [];
  const windowListeners = new Map();
  let loaderAppendCount = 0;
  let releaseManifest;
  const manifestGate = deferredManifest
    ? new Promise((resolve) => {
        releaseManifest = resolve;
      })
    : Promise.resolve();

  const window = {
    document,
    URL,
    AbortController,
    TextEncoder,
    Promise,
    Map,
    Object,
    Number,
    Math,
    JSON,
    encodeURIComponent,
    fetch: async (url, options = {}) => {
      fetchUrls.push(url);
      fetchSignals.push(options.signal ?? null);
      if (nonSettlingStage === 'manifest' && fetchUrls.length === 1) {
        return new Promise((resolve, reject) => {
          options.signal?.addEventListener('abort', () => {
            const error = new Error('The manifest request was aborted');
            error.name = 'AbortError';
            reject(error);
          });
        });
      }
      await manifestGate;
      return {
        ok: true,
        status: 200,
        async json() {
          return structuredClone(manifest);
        },
      };
    },
    setTimeout(callback, milliseconds, ...args) {
      const shouldRunImmediately =
        (fastQuitTimeout && milliseconds === 10000) ||
        (fastStartupTimeout && milliseconds === 90000);
      const delay = shouldRunImmediately ? 0 : milliseconds;
      return setTimeout(callback, delay, ...args);
    },
    clearTimeout,
    requestAnimationFrame(callback) {
      return setTimeout(() => callback(Date.now()), 0);
    },
    cancelAnimationFrame: clearTimeout,
    addEventListener(type, callback) {
      const callbacks = windowListeners.get(type) ?? [];
      callbacks.push(callback);
      windowListeners.set(type, callbacks);
    },
  };
  window.window = window;

  document.head._appendHook = (script) => {
    if (script.tagName !== 'SCRIPT') return;
    loaderAppendCount += 1;
    if (nonSettlingStage === 'loader' && loaderAppendCount === 1) return;
    Promise.resolve().then(() => {
      window.createUnityInstance = async (canvas, config, onProgress) => {
        createInvocations.push({ canvas, config });
        if (nonSettlingStage === 'instance' && createInvocations.length === 1) {
          return new Promise(() => {});
        }
        onProgress(0.25);
        onProgress(1);
        const instance = {
          messages: [],
          quitCalls: 0,
          SendMessage(gameObject, receiver, payload) {
            this.messages.push({ gameObject, receiver, payload });
          },
          async Quit() {
            this.quitCalls += 1;
            if (hangingQuit) return new Promise(() => {});
          },
        };
        instances.push(instance);
        createCalls.push({ canvas, config, instance });
        return instance;
      };
      script.onload();
    });
  };

  vm.runInNewContext(hostSource, { window }, {
    filename: 'web/maaso_unity_avatar.js',
  });
  return {
    host: window.maasoUnityAvatarHost,
    document,
    fetchUrls,
    fetchSignals,
    createCalls,
    createInvocations,
    instances,
    get loaderAppendCount() {
      return loaderAppendCount;
    },
    dispatchWindow(type, values = {}) {
      for (const callback of windowListeners.get(type) ?? []) callback(values);
    },
    releaseManifest() {
      releaseManifest?.();
    },
  };
}

async function settle(rounds = 12) {
  for (let index = 0; index < rounds; index += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

function parse(value) {
  return JSON.parse(value);
}

test('loads one Unity canvas from a document.baseURI-relative manifest', async () => {
  const harness = createHarness();
  const events = [];
  const subscription = harness.host.subscribe((event) => events.push(parse(event)));

  assert.equal(events.length, 0, 'state replay must be asynchronous');
  await Promise.resolve();
  assert.deepEqual(events[0], {
    version: 1,
    generation: 0,
    sequence: 0,
    type: 'unready',
    payload: { reason: 'idle', recoverable: true },
  });

  const container = new FakeElement('div');
  harness.host.mount(container, 'home-avatar');
  await settle();

  assert.deepEqual(harness.fetchUrls, [
    'https://example.test/nested/app/unity/avatar/player/maaso-avatar-manifest.json',
  ]);
  assert.equal(harness.createCalls.length, 1);
  assert.equal(container.children.length, 1);
  const root = container.children[0];
  const canvas = root.children[0];
  assert.equal(canvas.id, 'maaso-unity-avatar-canvas');
  assert.equal(root.style.pointerEvents, 'none');
  assert.equal(canvas.style.pointerEvents, 'none');
  assert.equal(container.style.pointerEvents, 'none');
  assert.equal(
    harness.createCalls[0].config.codeUrl,
    'https://example.test/nested/app/unity/avatar/player/Build/MaasoAvatar.wasm',
  );
  assert.equal(
    Object.hasOwn(harness.createCalls[0].config, 'streamingAssetsUrl'),
    false,
  );
  assert.equal(
    harness.createCalls[0].config.webglContextAttributes.alpha,
    true,
  );
  assert.equal(
    harness.createCalls[0].config.webglContextAttributes.premultipliedAlpha,
    true,
  );
  assert.equal(
    harness.createCalls[0].config.webglContextAttributes.preserveDrawingBuffer,
    false,
  );
  assert.equal(
    harness.createCalls[0].config.webglContextAttributes.powerPreference,
    2,
  );

  canvas.dispatch('maaso-unity-avatar-ready');
  const ready = parse(harness.host.snapshot());
  assert.equal(ready.type, 'ready');
  assert.equal(ready.generation, 1);
  assert.deepEqual(ready.payload, {});
  assert.equal(harness.host.unsubscribe(subscription), true);
});

test('validates, bounds, and coalesces queued commands before Unity is ready', async () => {
  const harness = createHarness();
  const container = new FakeElement('div');
  harness.host.mount(container, 'queue-avatar');

  assert.deepEqual(
    parse(await harness.host.invoke('setMouthOpen', '{"value":0.2}')),
    { ok: true, state: 'queued', generation: 1 },
  );
  assert.equal(
    parse(await harness.host.invoke('setMouthOpen', '{"value":0.8}')).ok,
    true,
  );
  assert.equal(
    await harness.host
      .invoke('playMotion', '{"type":"wave"}')
      .then(() => null, (error) => error.code),
    'not_ready',
  );
  assert.equal(
    await harness.host
      .invoke(
        'loadAvatar',
        '{"requestId":"stale","modelUrl":"unity://masso/avatar_agent"}',
      )
      .then(() => null, (error) => error.code),
    'not_ready',
  );
  assert.equal(
    await harness.host
      .invoke('arbitrarySendMessage', '{}')
      .then(() => null, (error) => error.code),
    'invalid_method',
  );
  assert.equal(
    await harness.host
      .invoke('live.captureCover', '{"requestId":"unsupported-on-web"}')
      .then(() => null, (error) => error.code),
    'invalid_method',
  );
  assert.equal(
    await harness.host
      .invoke(
        'setExpression',
        JSON.stringify({ value: 'x'.repeat(33 * 1024) }),
      )
      .then(() => null, (error) => error.code),
    'arguments_too_large',
  );

  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  await settle(2);

  const messages = harness.instances[0].messages;
  assert.equal(messages.length, 1);
  assert.deepEqual(
    messages.map((message) => [message.gameObject, message.receiver]),
    [['Main Camera', 'OnFlutterCommand']],
  );
  const envelopes = messages.map((message) => parse(message.payload));
  assert.deepEqual(envelopes.map((envelope) => envelope.method), [
    'setMouthOpen',
  ]);
  assert.deepEqual(parse(envelopes[0].json), { value: 0.8 });

  assert.deepEqual(
    parse(await harness.host.invoke('playMotion', '{"type":"wave"}')),
    { ok: true, state: 'sent', generation: 1 },
  );
  assert.equal(harness.instances[0].messages.length, 2);
  assert.equal(
    parse(harness.instances[0].messages[1].payload).method,
    'playMotion',
  );
});



test('forwards ready viseme timelines unchanged with existing JSON and 32 KiB bounds', async (t) => {
  const harness = createHarness();
  const lease = 'viseme-ready';
  t.after(async () => {
    harness.host.detach(lease);
    await settle(2);
  });
  harness.host.mount(new FakeElement('div'), lease);
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  const track = {
    format: 'vrm_viseme_v2',
    envelope: [0, 0.4, 0.7, 0],
    cues: [{ frame: 0, viseme: 'sil' }, { frame: 1, viseme: 'aa' }],
    frameRate: 30,
  };
  assert.deepEqual(
    parse(await harness.host.invoke('startVisemeTimeline', JSON.stringify(track))),
    { ok: true, state: 'sent', generation: 1 },
  );
  const [message] = harness.instances[0].messages;
  assert.equal(message.gameObject, 'Main Camera');
  assert.equal(message.receiver, 'OnFlutterCommand');
  const command = parse(message.payload);
  assert.equal(command.method, 'startVisemeTimeline');
  assert.deepEqual(parse(command.json), track);

  for (const malformed of ['{not-json', '[]', 'null']) {
    assert.equal(
      await harness.host.invoke('startVisemeTimeline', malformed)
        .then(() => null, (error) => error.code),
      'invalid_arguments',
    );
  }
  assert.equal(
    await harness.host.invoke(
      'startVisemeTimeline', JSON.stringify({ padding: 'x'.repeat(33 * 1024) }),
    ).then(() => null, (error) => error.code),
    'arguments_too_large',
  );
  assert.equal(harness.instances[0].messages.length, 1);
});

test('forwards bounded space, arbiter, and doorway commands only while ready', async (t) => {
  const harness = createHarness();
  const lease = 'space-ready';
  t.after(async () => {
    harness.host.detach(lease);
    await settle(2);
  });
  harness.host.mount(new FakeElement('div'), lease);
  const methods = [
    'enterAgentSpace', 'leaveAgentSpace', 'requestAgentSpaceMoveAtScreenPoint',
    'avatarArbiterCommand', 'avatarArbiterReset', 'transitionLoginDoorway',
  ];
  for (const method of methods) {
    assert.equal(
      await harness.host.invoke(method, JSON.stringify({ requestId: 'before-ready', sessionId: 'space', ...(method === 'requestAgentSpaceMoveAtScreenPoint' ? {x: 0.2, y: 0.3} : {}) }))
        .then(() => null, (error) => error.code),
      'not_ready',
    );
  }
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  for (const method of methods) {
    const packet = JSON.stringify({ requestId: method, sessionId: 'space', ...(method === 'requestAgentSpaceMoveAtScreenPoint' ? {x: 0.2, y: 0.3} : {}) });
    assert.equal(parse(await harness.host.invoke(method, packet)).state, 'sent');
  }
  assert.deepEqual(
    harness.instances[0].messages.map((message) => parse(message.payload).method),
    methods,
  );
});

test('personal space commands enforce exact session fields and bounded movement', async (t) => {
  const harness = createHarness();
  const lease = 'space-contract';
  t.after(() => harness.host.detach(lease));
  harness.host.mount(new FakeElement('div'), lease);
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  for (const args of [
    {}, {requestId: 'entry'}, {requestId: 'entry', sessionId: ''},
    {requestId: 'entry', sessionId: 'space with whitespace'},
    {requestId: 'entry', sessionId: 'x'.repeat(129)},
    {requestId: 1, sessionId: 'space'},
    {requestId: 'entry', sessionId: 'space', mapId: 'other'},
    {requestId: 'entry', sessionId: 'space', animated: 1},
    {requestId: 'entry', sessionId: 'space', animated: 'true'},
    {requestId: 'entry', sessionId: 'space', animated: null},
    {requestId: 'entry', sessionId: 'space', viewportTop: 0.1},
    {requestId: 'entry', sessionId: 'space', viewportBottom: 0.1},
    {requestId: 'entry', sessionId: 'space', viewportTop: true, viewportBottom: 0},
    {requestId: 'entry', sessionId: 'space', viewportTop: -0.01, viewportBottom: 0},
    {requestId: 'entry', sessionId: 'space', viewportTop: 0, viewportBottom: 0.46},
    {requestId: 'entry', sessionId: 'space', viewportTop: NaN, viewportBottom: 0},
    {requestId: 'entry', sessionId: 'space', viewportTop: 0, viewportBottom: Infinity},
  ]) {
    assert.equal(await harness.host.invoke('enterAgentSpace', JSON.stringify(args))
      .then(() => null, error => error.code), 'invalid_arguments');
  }
  for (const values of [{x: -0.1, y: 0}, {x: 1.01, y: 0}, {x: true, y: 0},
    {x: '0.5', y: 0}, {x: null, y: 0}, {x: 0.5}, {x: 0.5, y: 0.5, extra: true},
    {x: 0.5, y: 0.5, animated: true},
    {x: 0.5, y: 0.5, viewportTop: 0, viewportBottom: 0}]) {
    assert.equal(await harness.host.invoke('requestAgentSpaceMoveAtScreenPoint',
      JSON.stringify({requestId: 'move', sessionId: 'space', ...values}))
      .then(() => null, error => error.code), 'invalid_arguments');
  }
  for (const method of ['enterAgentSpace', 'requestAgentSpaceMoveAtScreenPoint', 'leaveAgentSpace']) {
    const arguments_ = {requestId: method, sessionId: 'space',
      ...(method === 'requestAgentSpaceMoveAtScreenPoint' ? {x: 0, y: 1} : {})};
    assert.equal(parse(await harness.host.invoke(method, JSON.stringify(arguments_))).state, 'sent');
    const sent = parse(harness.instances[0].messages.at(-1).payload);
    assert.equal(sent.method, method);
    assert.deepEqual(parse(sent.json), arguments_);
  }
  for (const method of ['enterAgentSpace', 'leaveAgentSpace']) {
    for (const options of [
      {animated: true}, {animated: false},
      {viewportTop: 0, viewportBottom: 0.45},
      {animated: true, viewportTop: 0.1, viewportBottom: 0.3},
    ]) {
      const arguments_ = {requestId: method, sessionId: 'space', ...options};
      assert.equal(parse(await harness.host.invoke(method, JSON.stringify(arguments_))).state, 'sent');
      const sent = parse(harness.instances[0].messages.at(-1).payload);
      assert.equal(sent.method, method);
      assert.deepEqual(parse(sent.json), arguments_);
    }
  }
});

test('personal space receipts are strict and retired world callbacks are rejected', async (t) => {
  const harness = createHarness();
  const lease = 'space-receipts';
  t.after(() => harness.host.detach(lease));
  const events = [];
  harness.host.subscribe(event => events.push(parse(event)));
  harness.host.mount(new FakeElement('div'), lease);
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  const receipt = {method: 'enterAgentSpace', requestId: 'entry', sessionId: 'space', ok: true, code: ''};
  for (const invalid of [
    {...receipt, ok: 'true'}, {...receipt, code: 0}, {...receipt, sessionId: ''},
    {...receipt, requestId: 'with whitespace'}, {...receipt, extra: true},
    {method: receipt.method, requestId: 'entry', sessionId: 'space', ok: true},
  ]) assert.equal(harness.host.emitFromUnity('commandResult', JSON.stringify(invalid)), false);
  assert.equal(harness.host.emitFromUnity('commandResult', JSON.stringify(receipt)), true);
  assert.deepEqual(events.at(-1).payload, receipt);
  assert.equal(harness.host.emitFromUnity('commandResult', JSON.stringify({
    ...receipt, method: 'leaveAgentSpace', ok: false, code: 'session_mismatch',
  })), true);
  assert.equal(harness.host.emitFromUnity('commandResult', JSON.stringify({
    ...receipt, ok: false, code: 'space_transition_cancelled',
  })), true);
  assert.equal(harness.host.emitFromUnity('commandResult', '{"method":"furnitureState"}'), true);
  assert.equal(harness.host.emitFromUnity('worldEvent', '{}'), false);
  assert.equal(harness.host.emitFromUnity('commandResult', '{"method":"joinWorld"}'), false);
});

test('world methods and inherited object properties are no longer dispatchable', async () => {
  const harness = createHarness();
  for (const method of ['worldMapCache', 'worldPrivateRoute', 'worldPrivateFurniture',
    'prepareWorldMap', 'switchWorld', 'joinWorld', 'applyWorldSnapshot', 'showWorldChat',
    'playWorldHighlight', 'leaveWorld', 'focusWorldResident', 'toString', '__proto__']) {
    assert.equal(await harness.host.invoke(method, '{}').then(() => null, error => error.code),
      'invalid_method');
  }
});

test('viseme timelines are never queued before ready or replayed after context loss', async (t) => {
  const harness = createHarness();
  const lease = 'viseme-lifecycle';
  t.after(async () => {
    harness.host.detach(lease);
    await settle(2);
  });
  const track = JSON.stringify({
    format: 'vrm_viseme_v2', envelope: [0, 0.5, 0],
    cues: [{ frame: 0, viseme: 'sil' }, { frame: 1, viseme: 'aa' }], frameRate: 30,
  });
  harness.host.mount(new FakeElement('div'), lease);
  assert.equal(
    await harness.host.invoke('startVisemeTimeline', track)
      .then(() => null, (error) => error.code),
    'not_ready',
  );
  await settle();
  const oldCanvas = harness.createCalls[0].canvas;
  oldCanvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(harness.instances[0].messages.length, 0);
  await harness.host.invoke('startVisemeTimeline', track);
  assert.equal(harness.instances[0].messages.length, 1);

  oldCanvas.dispatch('webglcontextlost');
  assert.equal(
    await harness.host.invoke('startVisemeTimeline', track)
      .then(() => null, (error) => error.code),
    'not_ready',
  );
  harness.host.retry(lease);
  await settle();
  const currentCanvas = harness.createCalls[1].canvas;
  oldCanvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(
    await harness.host.invoke('startVisemeTimeline', track)
      .then(() => null, (error) => error.code),
    'not_ready',
  );
  currentCanvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(harness.instances[1].messages.length, 0);
  assert.equal(
    parse(await harness.host.invoke('startVisemeTimeline', track)).state,
    'sent',
  );
  assert.equal(harness.instances[1].messages.length, 1);
});

test('reparents one canvas and ignores stale lease detach calls', async () => {
  const harness = createHarness();
  const first = new FakeElement('div');
  const second = new FakeElement('div');
  const third = new FakeElement('div');

  harness.host.mount(first, 'lease-a');
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  const root = first.children[0];

  harness.host.mount(second, 'lease-b');
  await settle(2);
  assert.equal(harness.createCalls.length, 1);
  assert.equal(first.children.length, 0);
  assert.equal(second.children[0], root);

  harness.host.detach('lease-a');
  assert.equal(second.children[0], root);
  assert.equal(parse(harness.host.snapshot()).type, 'ready');

  harness.host.detach('lease-b');
  assert.equal(second.children.length, 0);
  assert.equal(parse(harness.host.snapshot()).type, 'unready');

  harness.host.mount(third, 'lease-c');
  await settle(2);
  assert.equal(third.children[0], root);
  assert.equal(harness.createCalls.length, 1);
  assert.equal(parse(harness.host.snapshot()).type, 'ready');
});

test('pauses a detached initial load until the next mount', async () => {
  const harness = createHarness({ deferredManifest: true });
  const first = new FakeElement('div');
  const second = new FakeElement('div');
  harness.host.mount(first, 'loading-lease-a');
  await settle(2);
  assert.equal(harness.fetchUrls.length, 1);

  harness.host.detach('loading-lease-a');
  harness.releaseManifest();
  await settle(4);
  assert.equal(harness.createCalls.length, 0);

  harness.host.mount(second, 'loading-lease-b');
  await settle();
  assert.equal(harness.createCalls.length, 1);
  assert.equal(second.children.length, 1);
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(parse(harness.host.snapshot()).type, 'ready');
});

test('retry supersedes every non-settling startup stage', async (t) => {
  for (const stage of ['manifest', 'loader', 'instance']) {
    await t.test(stage, async () => {
      const harness = createHarness({ nonSettlingStage: stage });
      const container = new FakeElement('div');
      harness.host.mount(container, `startup-${stage}-lease`);
      await settle();

      assert.equal(parse(harness.host.snapshot()).generation, 1);
      harness.host.retry(`startup-${stage}-lease`);
      await settle(24);

      assert.equal(parse(harness.host.snapshot()).generation, 2);
      assert.equal(harness.createCalls.length, 1);
      if (stage === 'manifest') {
        assert.equal(harness.fetchUrls.length, 2);
        assert.equal(harness.fetchSignals[0].aborted, true);
      } else if (stage === 'loader') {
        assert.equal(harness.loaderAppendCount, 2);
      } else {
        assert.equal(harness.createInvocations.length, 2);
        assert.notEqual(
          harness.createInvocations[0].canvas,
          harness.createInvocations[1].canvas,
        );
      }

      harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
      const ready = parse(harness.host.snapshot());
      assert.equal(ready.type, 'ready');
      assert.equal(ready.generation, 2);
    });
  }
});

test('startup watchdog aborts a stuck stage and leaves retry recoverable', async () => {
  const harness = createHarness({
    fastStartupTimeout: true,
    nonSettlingStage: 'manifest',
  });
  const container = new FakeElement('div');
  harness.host.mount(container, 'startup-watchdog-lease');
  await settle();

  const timedOut = parse(harness.host.snapshot());
  assert.equal(timedOut.type, 'error');
  assert.equal(timedOut.payload.code, 'unity_startup_timeout');
  assert.equal(timedOut.payload.recoverable, true);
  assert.equal(timedOut.payload.details.stage, 'manifest');
  assert.equal(harness.fetchSignals[0].aborted, true);

  harness.host.retry('startup-watchdog-lease');
  await settle(24);
  assert.equal(harness.createCalls.length, 1);
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(parse(harness.host.snapshot()).type, 'ready');
  assert.equal(parse(harness.host.snapshot()).generation, 2);
});



test('publishes unready before a ready-generation command error', async () => {
  const harness = createHarness();
  const events = [];
  harness.host.subscribe((event) => events.push(parse(event)));
  const container = new FakeElement('div');
  harness.host.mount(container, 'send-error-lease');
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  harness.instances[0].SendMessage = () => {
    throw new Error('simulated send failure');
  };

  const response = parse(
    await harness.host.invoke('setExpression', '{"smile":0.5}'),
  );
  assert.equal(response.state, 'queued');
  assert.deepEqual(events.slice(-2).map((event) => event.type), [
    'unready',
    'error',
  ]);
  assert.equal(events.at(-2).generation, events.at(-1).generation);
  assert.ok(events.at(-1).sequence > events.at(-2).sequence);
});

test('orders events and replaces a context-lost instance only for the active lease', async () => {
  const harness = createHarness();
  const events = [];
  harness.host.subscribe((event) => events.push(parse(event)));
  const container = new FakeElement('div');
  harness.host.mount(container, 'active-lease');
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');

  let prevented = false;
  const canvas = harness.createCalls[0].canvas;
  canvas.dispatch('webglcontextlost', {
    preventDefault() {
      prevented = true;
    },
  });
  assert.equal(prevented, true);
  assert.deepEqual(events.slice(-2).map((event) => event.type), [
    'unready',
    'error',
  ]);
  assert.ok(events.at(-1).sequence > events.at(-2).sequence);
  assert.equal(parse(harness.host.snapshot()).payload.code, 'webgl_context_lost');
  canvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(parse(harness.host.snapshot()).type, 'error');
  assert.equal(
    await harness.host
      .invoke('live.applyScene', '{"requestId":"must-not-replay"}')
      .then(() => null, (error) => error.code),
    'not_ready',
  );

  harness.host.retry('stale-lease');
  await settle(2);
  assert.equal(harness.createCalls.length, 1);

  const beforeRetry = events.length;
  harness.host.retry('active-lease');
  assert.deepEqual(
    events.slice(beforeRetry).map((event) => event.type),
    ['unready', 'loading'],
  );
  assert.equal(events.at(-2).generation, 2);
  assert.equal(events.at(-2).sequence, 1);
  assert.equal(events.at(-1).sequence, 2);
  const beforeStaleCanvasEvent = events.length;
  canvas.dispatch('maaso-unity-avatar-ready');
  canvas.dispatch('maaso-unity-avatar-command-result', {
    detail: '{"method":"live.applyScene","requestId":"stale"}',
  });
  assert.equal(events.length, beforeStaleCanvasEvent);
  assert.equal(parse(harness.host.snapshot()).type, 'loading');
  await settle();
  assert.equal(harness.instances[0].quitCalls, 1);
  assert.equal(harness.createCalls.length, 2);
  assert.notEqual(harness.createCalls[0].canvas, harness.createCalls[1].canvas);
  harness.createCalls[1].canvas.dispatch('maaso-unity-avatar-ready');
  const secondReady = parse(harness.host.snapshot());
  assert.equal(secondReady.generation, 2);
  assert.equal(secondReady.type, 'ready');

  const beforeResultSequence = secondReady.sequence;
  harness.createCalls[1].canvas.dispatch('maaso-unity-avatar-command-result', {
    detail: '{"method":"loadAvatar","ok":true}',
  });
  assert.deepEqual(
    events.at(-1).payload,
    { method: 'loadAvatar', ok: true },
  );
  assert.equal(events.at(-1).type, 'commandResult');
  assert.ok(events.at(-1).sequence > beforeResultSequence);
  const replayableState = parse(harness.host.snapshot());
  assert.equal(replayableState.type, 'ready');
  assert.equal(replayableState.sequence, events.at(-1).sequence);
  assert.equal(
    harness.instances[1].messages.some(
      (message) => parse(message.payload).method === 'live.applyScene',
    ),
    false,
  );
});

test('preserves a ready Unity instance across a BFCache round trip', async () => {
  const harness = createHarness();
  const container = new FakeElement('div');
  harness.host.mount(container, 'bfcache-lease');
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  assert.equal(parse(harness.host.snapshot()).type, 'ready');

  harness.dispatchWindow('pagehide', { persisted: true });
  assert.equal(harness.instances[0].quitCalls, 0);
  assert.equal(parse(harness.host.snapshot()).payload.reason, 'bfcache');

  harness.dispatchWindow('pageshow', { persisted: true });
  assert.equal(harness.instances[0].quitCalls, 0);
  assert.equal(harness.createCalls.length, 1);
  assert.equal(parse(harness.host.snapshot()).type, 'ready');
  assert.equal(
    parse(harness.host.snapshot()).payload.reason,
    'bfcache_restore',
  );

  harness.dispatchWindow('pagehide', { persisted: false });
  await settle(2);
  assert.equal(harness.instances[0].quitCalls, 1);
});

test('does not create a second Unity instance when Quit times out', async () => {
  const harness = createHarness({ hangingQuit: true, fastQuitTimeout: true });
  const container = new FakeElement('div');
  harness.host.mount(container, 'quit-timeout-lease');
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');

  harness.host.retry('quit-timeout-lease');
  await settle();
  const failed = parse(harness.host.snapshot());
  assert.equal(failed.type, 'error');
  assert.equal(failed.payload.code, 'unity_quit_failed');
  assert.match(failed.payload.message, /refresh the page/i);
  assert.equal(harness.instances[0].quitCalls, 1);
  assert.equal(harness.createCalls.length, 1);
});

test('replays only durable state after context-loss retry', async () => {
  const harness = createHarness();
  const container = new FakeElement('div');
  harness.host.mount(container, 'durable-state-lease');
  await settle();
  harness.createCalls[0].canvas.dispatch('maaso-unity-avatar-ready');
  await harness.host.invoke('setExpression', '{"smile":0.75}');
  await harness.host.invoke(
    'enterAgentSpace',
    '{"requestId":"entry","sessionId":"space-before-retry"}',
  );
  await harness.host.invoke(
    'leaveAgentSpace',
    '{"requestId":"exit","sessionId":"space-before-retry"}',
  );
  await harness.host.invoke('playMotion', '{"type":"wave"}');

  harness.createCalls[0].canvas.dispatch('webglcontextlost');
  harness.host.retry('durable-state-lease');
  await settle();
  harness.createCalls[1].canvas.dispatch('maaso-unity-avatar-ready');

  const replayed = harness.instances[1].messages.map((message) =>
    parse(message.payload),
  );
  assert.deepEqual(replayed.map((envelope) => envelope.method), [
    'setExpression',
  ]);
  assert.deepEqual(parse(replayed[0].json), { smile: 0.75 });
  assert.equal(replayed.some((envelope) => envelope.method === 'enterAgentSpace'), false);
  assert.equal(replayed.some((envelope) => envelope.method === 'playMotion'), false);
});
