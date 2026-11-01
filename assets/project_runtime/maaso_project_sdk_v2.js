(() => {
  'use strict';
  const config = globalThis.__MAASO_CONFIG__;
  if (!config || config.sdkVersion !== '2.0.0' || typeof config.nonce !== 'string') throw Error('missing_runtime_configuration');
  const nonce = config.nonce;
  const declaredRoutes = new Map(config.routes.routes.map(r => [r.routeId, r]));
  const declaredActions = new Map(config.protocol.actions.map(a => [a.id, a]));
  const receipts = new Map();
  const data = new Map(Object.entries(config.initialData || {}));
  let dataVersion = config.dataVersion || 0, dataTail = Promise.resolve(), dataError = null;
  async function flushData() { await dataTail; if (dataError) throw Error('data_commit_failed'); }

  let implementation, stack = [{routeId: config.routes.entryRouteId, params: {}}];
  let version = 1, busy = false, lastError = '', playing = config.initialPlay || null;
  let playFrame = null;
  const clone = value => {
    let nodes = 0;
    function validate(item, depth) {
      if (++nodes > 4096 || depth > 16) throw Error('payload_limit');
      if (item === null || typeof item === 'boolean' || typeof item === 'string') return;
      if (typeof item === 'number' && Number.isFinite(item)) return;
      if (Array.isArray(item)) {item.forEach(v => validate(v, depth + 1));return;}
      if (typeof item === 'object' && (Object.getPrototypeOf(item) === Object.prototype || Object.getPrototypeOf(item) === null)) {Object.values(item).forEach(v => validate(v, depth + 1));return;}
      throw Error('invalid_json_value');
    }
    validate(value, 0);
    const encoded = JSON.stringify(value);
    if (encoded === undefined || new TextEncoder().encode(encoded).length > 65536) throw Error('payload_limit');
    return JSON.parse(encoded);
  };
  function matches(schema, value, depth = 0) {
    if (depth > 8) return false;
    switch (schema.type) {
      case 'object': return value !== null && typeof value === 'object' && !Array.isArray(value) &&
        Object.keys(value).every(k => Object.hasOwn(schema.properties, k)) && schema.required.every(k => Object.hasOwn(value, k)) &&
        Object.entries(value).every(([k, v]) => matches(schema.properties[k], v, depth + 1));
      case 'array': return Array.isArray(value) && value.length <= schema.maxItems && value.length >= (schema.minItems || 0) && value.every(v => matches(schema.items, v, depth + 1));
      case 'string': return typeof value === 'string' && [...value].length <= (schema.maxLength ?? 2048) && [...value].length >= (schema.minLength || 0) && (!schema.enum || schema.enum.includes(value));
      case 'number': case 'integer': return typeof value === 'number' && Number.isFinite(value) && (schema.type !== 'integer' || Number.isSafeInteger(value)) && value >= schema.minimum && value <= schema.maximum;
      case 'boolean': return typeof value === 'boolean';
      default: return false;
    }
  }
  function assertRoute(id, params) {
    const definition = declaredRoutes.get(id);
    if (!definition || !matches(definition.parametersSchema, params)) throw Error('invalid_route');
  }
  async function render() {
    const current = stack.at(-1);
    const next = await implementation.routes[current.routeId](clone(current.params));
    if (!(next instanceof HTMLElement)) throw Error('route_must_return_element');
    document.getElementById('maaso-project-root').replaceChildren(next);
    document.documentElement.dataset.maasoRoute = current.routeId;
    await new Promise(resolve => requestAnimationFrame(() => resolve()));
  }
  async function navigate(routeId, params = {}) {
    if (!implementation) throw Error('runtime_not_ready');
    assertRoute(routeId, params);
    const previous = stack;
    stack = [...stack, {routeId, params: clone(params)}];
    if (stack.length > 32) { stack = previous; throw Error('route_stack_limit'); }
    try { await render(); version++; } catch (error) { stack = previous; throw error; }
  }
  async function back() {
    if (stack.length === 1) return false;
    const previous = stack; stack = stack.slice(0, -1);
    try { await render(); version++; return true; } catch (error) { stack = previous; throw error; }
  }
  function inspect() {
    if (!implementation) return {ready: false, error: lastError};
    return {ready: true, controlProtocolVersion: 1, dataVersion, routeId: stack.at(-1).routeId, params: clone(stack.at(-1).params), canGoBack: stack.length > 1,
      stateVersion: version, actions: [...declaredActions.keys()].filter(id => typeof implementation.actions[id] === 'function'),
      visibleState: clone(implementation.observe()), error: lastError};
  }
  function canonical(value) {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
    return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
  }
  async function act(command) {
    if (command.nonce !== nonce || typeof command.requestId !== 'string' || !/^[A-Za-z0-9_-]{8,96}$/.test(command.requestId)) throw Error('invalid_command');
    const identity = canonical([command.actionId, command.args, command.expectedStateVersion, command.expectedObservation || null]);
    const existing = receipts.get(command.requestId);
    if (existing) { if (existing.identity !== identity) throw Error('request_id_conflict'); return clone(existing.receipt); }
    if (busy || !implementation || command.expectedStateVersion !== version) throw Error('state_conflict');
    if (receipts.size >= 1024) throw Error('receipt_limit');
    const definition = declaredActions.get(command.actionId);
    const action = implementation.actions[command.actionId];
    if (!definition || typeof action !== 'function' || !matches(definition.argsSchema, command.args)) throw Error('action_not_available');
    if (command.expectedObservation && canonical(inspect()) !== canonical(command.expectedObservation)) throw Error('observation_conflict');
    receipts.set(command.requestId, {identity, receipt: {requestId: command.requestId,
      actionId: command.actionId, status: 'pending', stateVersion: version}});
    busy = true;
    try {
      const result = clone(await action(clone(command.args)) ?? null);
      await flushData();
      version++;
      const receipt = {requestId: command.requestId, actionId: command.actionId, status: 'applied', stateVersion: version, result, observation: inspect()};
      receipts.set(command.requestId, {identity, receipt});
      return clone(receipt);
    } catch (error) {
      // A handler may have mutated state before throwing. Fence stale callers
      // and retain a failed receipt instead of silently retrying its effects.
      version++;
      const receipt = {requestId: command.requestId, actionId: command.actionId, status: 'failed', stateVersion: version, error: 'action_failed'};
      receipts.set(command.requestId, {identity, receipt}); lastError = 'action_failed'; return clone(receipt);
    } finally { busy = false; }
  }
  function acceptFrame(value) {
    const frame = clone(value);
    if (!frame || new TextEncoder().encode(JSON.stringify(frame)).length > 8192 ||
        frame.protocolVersion !== 2 || frame.projectId !== config.protocol.projectId ||
        frame.revisionId !== config.protocol.revisionId || frame.sessionId !== config.sessionId ||
        typeof frame.matchId !== 'string' || !Number.isSafeInteger(frame.matchEpoch) ||
        !Number.isSafeInteger(frame.frameSequence) || frame.frameSequence < 0 ||
        !['ready','playing','paused','ended'].includes(frame.phase)) throw Error('invalid_play_frame');
    if (playing && (frame.matchId !== playing.matchId || frame.seatId !== playing.seatId || frame.matchEpoch < playing.matchEpoch)) return false;
    if (playFrame && frame.matchId === playFrame.matchId &&
        (frame.matchEpoch < playFrame.matchEpoch ||
          frame.matchEpoch === playFrame.matchEpoch && frame.frameSequence <= playFrame.frameSequence)) return false;
    playFrame = frame;
    globalThis.dispatchEvent(new CustomEvent('maaso:play-frame', {detail: clone(frame)}));
    return true;
  }
  const api = {
    async register(value) {
      if (implementation) throw Error('already_registered');
      if (!value || typeof value.observe !== 'function' || !value.routes || !value.actions) throw Error('invalid_registration');
      for (const id of declaredRoutes.keys()) if (typeof value.routes[id] !== 'function') throw Error('route_not_implemented');
      for (const id of declaredActions.keys()) if (typeof value.actions[id] !== 'function' && config.protocol.projectKind !== 'game') throw Error('action_not_implemented');
      implementation = value;
      try { await render(); } catch (error) { implementation = null; lastError = 'initial_render_failed'; throw error; }
    },
    navigate, back,
    asset(path) { if (!Object.hasOwn(config.assets, path)) throw Error('undeclared_asset'); return config.assets[path]; },
    data: Object.freeze({
      get(key) { if (typeof key !== 'string' || !key || key.length > 96 || /[\u0000-\u001f\u007f]/.test(key)) throw Error('invalid_data_key'); return data.has(key) ? clone(data.get(key)) : null; },
      set(key, value) {
        if (typeof key !== 'string' || !key || key.length > 96 || /[\u0000-\u001f\u007f]/.test(key) || data.size >= 256 && !data.has(key)) throw Error('data_limit');
        const previous = clone(Object.fromEntries(data));
        const snapshot = clone({...previous, [key]: clone(value)});
        data.set(key, snapshot[key]); version++;
        const operation = dataTail.then(async () => {
          if (typeof config.dataBridge === 'function') {
            const receipt = await config.dataBridge(snapshot, dataVersion);
            if (!receipt || !Number.isSafeInteger(receipt.dataVersion) || receipt.dataVersion !== dataVersion + 1) throw Error('invalid_data_receipt');
            dataVersion = receipt.dataVersion;
          }
          dataError = null; lastError = ''; return {dataVersion};
        });
        dataTail = operation.catch(() => {data.clear();for(const [k,v] of Object.entries(previous)) data.set(k,v);dataError='data_commit_failed';lastError='data_commit_failed';});
        return operation;
      },
    }),
    playObserve() { return playing === null ? null : clone(playing); },
    playFrame() { return playFrame === null ? null : clone(playFrame); },
    onPlayFrame(listener) {
      if (typeof listener !== 'function') throw Error('invalid_listener');
      const receive = event => listener(clone(event.detail));
      globalThis.addEventListener('maaso:play-frame', receive);
      if (playFrame !== null) listener(clone(playFrame));
      return () => globalThis.removeEventListener('maaso:play-frame', receive);
    },
    onPlayState(listener) {
      if (typeof listener !== 'function') throw Error('invalid_listener');
      const receive = event => listener(clone(event.detail));
      globalThis.addEventListener('maaso:play', receive);
      if (playing !== null) listener(clone(playing));
      return () => globalThis.removeEventListener('maaso:play', receive);
    },
    playReceipt(requestId) {
      if (typeof requestId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/.test(requestId) || typeof config.playReceiptBridge !== 'function') throw Error('play_receipt_unavailable');
      return config.playReceiptBridge(requestId);
    },
    playSubmit(command) {
      if (!config.playBridge || typeof config.playBridge !== 'function') throw Error('play_host_unavailable');
      const keys = ['requestId', 'observationId', 'actionId', 'args', 'expectedDecisionRevision', 'expectedTurnId', 'actionToken'];
      if (!command || Object.keys(command).length !== keys.length || !keys.every(k => Object.hasOwn(command, k))) throw Error('invalid_play_command');
      const action = declaredActions.get(command.actionId);
      if (!action || !matches(action.argsSchema, command.args)) throw Error('action_not_available');
      return config.playBridge(clone(command));
    },
  };
  Object.defineProperty(globalThis, 'Maaso', {value: Object.freeze(api), writable: false, configurable: false});
  Object.defineProperty(globalThis, '__maasoHost', {value: Object.freeze({
    controlInfo(token) { if (token !== nonce) throw Error('invalid_session'); return {controlProtocolVersion:1, ready:!!implementation, projectKind:config.protocol.projectKind}; },
    inspect(token) { if (token !== nonce) throw Error('invalid_session'); return inspect(); },
    act,
    receipt(token, requestId) {
      if (token !== nonce || typeof requestId !== 'string' || !/^[A-Za-z0-9_-]{8,96}$/.test(requestId)) throw Error('invalid_session');
      return receipts.has(requestId) ? clone(receipts.get(requestId).receipt) : null;
    },
    async navigate(token, id, params) { if (token !== nonce) throw Error('invalid_session'); await navigate(id, params); return inspect(); },
    async back(token) { if (token !== nonce) throw Error('invalid_session'); await back(); return inspect(); },
    updatePlay(token, view) { if (token !== nonce) throw Error('invalid_session'); playing = clone(view); if (playFrame && (playFrame.matchId !== playing.matchId || playFrame.matchEpoch !== playing.matchEpoch || playFrame.seatId !== playing.seatId)) playFrame = null; globalThis.dispatchEvent(new CustomEvent('maaso:play', {detail: clone(view)})); },
    updatePlayFrame(token, frame) { if (token !== nonce) throw Error('invalid_session'); return acceptFrame(frame); },
    async flushData(token) { if (token !== nonce) throw Error('invalid_session'); await flushData(); return {dataVersion}; },
    exportData(token) { if (token !== nonce) throw Error('invalid_session'); return clone(Object.fromEntries(data)); },
  }), writable: false, configurable: false});
  if (config.initialFrame) acceptFrame(config.initialFrame);
})();
