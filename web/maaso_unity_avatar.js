(function installMaasoUnityAvatarHost(global) {
  'use strict';

  if (global.maasoUnityAvatarHost) return;

  var HOST_VERSION = 1;
  var MANIFEST_RELATIVE_URL =
    'unity/avatar/player/maaso-avatar-manifest.json';
  var UNITY_GAME_OBJECT = 'Main Camera';
  var UNITY_RECEIVER = 'OnFlutterCommand';
  var MAX_ARGUMENT_BYTES = 32 * 1024;
  var MAX_QUEUE_ENTRIES = 128;
  var MAX_QUEUE_BYTES = 256 * 1024;
  var UNITY_STARTUP_TIMEOUT_MS = 90000;
  var UNITY_READY_TIMEOUT_MS = 30000;
  var UNITY_QUIT_TIMEOUT_MS = 10000;

  var ALLOWED_METHODS = Object.freeze({
    setExpression: true,
    setMouthOpen: true,
    setGaze: true,
    clearGaze: true,
    startLipSync: true,
    startVisemeTimeline: true,
    stopLipSync: true,
    playPrimitive: true,
    playAnimationClip: true,
    setHandIkTarget: true,
    setBodyPose: true,
    transitionPresence: true,
    transitionLoginDoorway: true,
    setPhoneInteraction: true,
    setLocalAvatarVisible: true,
    playMotion: true,
    playMotionSequence: true,
    setFraming: true,
    setViewportSafeArea: true,
    setWorldTimeOfDay: true,
    setWorldCamera: true,
    avatarArbiterCommand: true,
    avatarArbiterReset: true,
    reactToScreenTap: true,
    enterAgentSpace: true,
    leaveAgentSpace: true,
    requestAgentSpaceMoveAtScreenPoint: true,
    loadAvatar: true,
    pause: true,
    resume: true,
    prepareView: true,
  });

  var COALESCE_KEYS = Object.freeze({
    setExpression: 'expression',
    setMouthOpen: 'mouth',
    setGaze: 'gaze',
    clearGaze: 'gaze',
    stopLipSync: 'lip-sync',
    setBodyPose: 'body-pose',
    setFraming: 'framing',
    setViewportSafeArea: 'safe-area',
    setWorldTimeOfDay: 'world-time',
    setWorldCamera: 'world-camera',
    pause: 'lifecycle',
    resume: 'lifecycle',
    prepareView: 'prepare-view',
  });

  var UNITY_EVENT_TYPES = Object.freeze({
    ready: true,
    unready: true,
    log: true,
    error: true,
    commandResult: true,
  });

  var subscribers = new Map();
  var nextSubscriberId = 1;
  var generation = 0;
  var sequence = 0;
  var lifecycleType = 'unready';
  var lifecyclePayload = Object.freeze({
    reason: 'idle',
    recoverable: true,
  });

  var activeMount = null;
  var rootElement = null;
  var canvasElement = null;
  var canvasGeneration = 0;
  var canvasEventListeners = [];
  var unityInstance = null;
  var unityReady = false;
  var unityEventGeneration = 0;
  var pendingUnityReadyPayload = null;
  var readyTimer = null;
  var attemptSerial = Promise.resolve();
  var mountWaiters = [];
  var retiringQuitPromise = null;
  var loaderPromise = null;
  var loaderUrl = null;
  var loaderGeneration = 0;
  var loaderPending = false;
  var activeGenerationAttempt = null;
  var commandQueue = [];
  var queuedBytes = 0;
  var durableState = new Map();
  var durableBytes = 0;
  var durableReplayGeneration = -1;

  function eventEnvelope(type, payload) {
    return {
      version: HOST_VERSION,
      generation: generation,
      sequence: sequence,
      type: type,
      payload: payload,
    };
  }

  function snapshot() {
    return JSON.stringify(eventEnvelope(lifecycleType, lifecyclePayload));
  }

  function deliver(record, serialized) {
    try {
      record.callback(serialized);
      record.received = true;
    } catch (_) {
      // A failed Dart callback must not break Unity or other subscribers.
    }
  }

  function publish(type, payload, isLifecycle) {
    sequence += 1;
    if (isLifecycle) {
      lifecycleType = type;
      lifecyclePayload = payload;
    }
    var serialized = JSON.stringify(eventEnvelope(type, payload));
    subscribers.forEach(function notifySubscriber(record) {
      deliver(record, serialized);
    });
  }

  function subscribe(callback) {
    if (typeof callback !== 'function') {
      throw new TypeError('Unity avatar subscriber must be a function');
    }
    var id = nextSubscriberId;
    nextSubscriberId += 1;
    var record = { callback: callback, received: false };
    subscribers.set(id, record);
    Promise.resolve().then(function replayCurrentState() {
      if (subscribers.get(id) === record && !record.received) {
        deliver(record, snapshot());
      }
    });
    return id;
  }

  function unsubscribe(id) {
    return subscribers.delete(id);
  }

  function utf8Length(value) {
    if (typeof global.TextEncoder === 'function') {
      return new global.TextEncoder().encode(value).byteLength;
    }
    return unescape(encodeURIComponent(value)).length;
  }

  function result(ok, values) {
    return JSON.stringify(Object.assign({ ok: ok }, values || {}));
  }

  function rejectedInvocation(code, message, details) {
    var error = new Error(message);
    error.name = 'MaasoUnityAvatarHostError';
    error.code = code;
    error.details = details || {};
    return Promise.reject(error);
  }

  function hostError(code, message, recoverable, details) {
    var payload = {
      code: code,
      message: message,
      recoverable: recoverable !== false,
    };
    if (details) payload.details = details;
    var mustClearReady = unityReady || lifecycleType === 'ready';
    unityReady = false;
    pendingUnityReadyPayload = null;
    if (mustClearReady) {
      publish(
        'unready',
        { reason: 'error', code: code, recoverable: recoverable !== false },
        true
      );
    }
    publish('error', payload, true);
  }

  function log(level, message, details) {
    var payload = { level: level, message: message };
    if (details) payload.details = details;
    publish('log', payload, false);
  }

  function isRelativeSafePath(value) {
    if (typeof value !== 'string' || value.length === 0) return false;
    if (value.indexOf('\\') !== -1 || value.charAt(0) === '/') return false;
    if (/^[a-zA-Z][a-zA-Z\d+.-]*:/.test(value)) return false;
    if (value.indexOf('?') !== -1 || value.indexOf('#') !== -1) return false;
    var segments = value.split('/');
    return segments.every(function isSafeSegment(segment) {
      return segment !== '' && segment !== '.' && segment !== '..';
    });
  }

  function resolveSameOriginRelative(value, manifestUrl, fieldName) {
    if (!isRelativeSafePath(value)) {
      throw new Error('Manifest field files.' + fieldName + ' is unsafe');
    }
    var resolved = new global.URL(value, manifestUrl);
    var root = new global.URL('.', manifestUrl);
    if (
      resolved.origin !== root.origin ||
      resolved.username !== '' ||
      resolved.password !== '' ||
      resolved.pathname.indexOf(root.pathname) !== 0
    ) {
      throw new Error('Manifest field files.' + fieldName + ' escapes its root');
    }
    return resolved.href;
  }

  function validateManifest(raw, manifestUrl) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new Error('Manifest root must be an object');
    }
    if (raw.schemaVersion !== HOST_VERSION) {
      throw new Error('Unsupported Unity avatar manifest schema');
    }
    ['buildName', 'unityVersion', 'productVersion'].forEach(function (field) {
      if (typeof raw[field] !== 'string' || raw[field].trim() === '') {
        throw new Error('Manifest field ' + field + ' is missing');
      }
    });
    if (!raw.files || typeof raw.files !== 'object' || Array.isArray(raw.files)) {
      throw new Error('Manifest files map is missing');
    }
    var loader = resolveSameOriginRelative(
      raw.files.loader,
      manifestUrl,
      'loader'
    );
    var data = resolveSameOriginRelative(raw.files.data, manifestUrl, 'data');
    var framework = resolveSameOriginRelative(
      raw.files.framework,
      manifestUrl,
      'framework'
    );
    var wasm = resolveSameOriginRelative(raw.files.wasm, manifestUrl, 'wasm');
    var streamingAssets = null;
    if (
      raw.files.streamingAssets !== null &&
      raw.files.streamingAssets !== undefined
    ) {
      streamingAssets = resolveSameOriginRelative(
        raw.files.streamingAssets,
        manifestUrl,
        'streamingAssets'
      );
    }
    var config = {
      dataUrl: data,
      frameworkUrl: framework,
      codeUrl: wasm,
      companyName: 'FuturPals',
      productName: raw.buildName,
      productVersion: raw.productVersion,
      webglContextAttributes: {
        alpha: true,
        premultipliedAlpha: true,
        preserveDrawingBuffer: false,
        powerPreference: 2,
      },
    };
    if (streamingAssets !== null) {
      config.streamingAssetsUrl = streamingAssets;
    }
    return {
      loaderUrl: loader,
      config: config,
    };
  }

  async function fetchManifest(currentGeneration, signal) {
    var baseUrl = new global.URL(global.document.baseURI);
    var manifestUrl = new global.URL(MANIFEST_RELATIVE_URL, baseUrl);
    if (manifestUrl.origin !== baseUrl.origin) {
      throw new Error('Unity avatar manifest must be same-origin');
    }
    publish(
      'loading',
      { stage: 'manifest', url: manifestUrl.href },
      true
    );
    var requestOptions = {
      cache: 'no-cache',
      credentials: 'same-origin',
    };
    if (signal) requestOptions.signal = signal;
    var response = await global.fetch(manifestUrl.href, requestOptions);
    if (currentGeneration !== generation) return null;
    if (!response || !response.ok) {
      throw new Error(
        'Unity avatar manifest request failed' +
          (response ? ' (' + response.status + ')' : '')
      );
    }
    return validateManifest(await response.json(), manifestUrl);
  }

  function removeLoaderScript(url) {
    if (!global.document || typeof global.document.querySelector !== 'function') {
      return;
    }
    var selector = 'script[data-maaso-unity-avatar-loader="' +
      encodeURIComponent(url) + '"]';
    var script = global.document.querySelector(selector);
    if (script && script.parentNode) script.parentNode.removeChild(script);
  }

  function loadUnityLoader(url, currentGeneration) {
    if (typeof global.createUnityInstance === 'function') {
      if (loaderUrl && loaderUrl !== url) {
        return Promise.reject(
          new Error('Unity loader changed; reload the page before retrying')
        );
      }
      loaderUrl = url;
      return Promise.resolve();
    }
    if (loaderPromise && loaderUrl === url) return loaderPromise;
    if (loaderPromise && loaderUrl !== url) {
      return Promise.reject(
        new Error('A different Unity loader is already loading')
      );
    }
    loaderUrl = url;
    loaderGeneration = currentGeneration;
    loaderPending = true;
    var rawLoaderPromise = new Promise(function injectLoader(resolve, reject) {
      var script = global.document.createElement('script');
      script.async = true;
      script.src = url;
      script.setAttribute(
        'data-maaso-unity-avatar-loader',
        encodeURIComponent(url)
      );
      script.onload = function onLoaderReady() {
        if (typeof global.createUnityInstance !== 'function') {
          reject(new Error('Unity loader did not expose createUnityInstance'));
          return;
        }
        resolve();
      };
      script.onerror = function onLoaderError() {
        reject(new Error('Unity loader script failed to load'));
      };
      global.document.head.appendChild(script);
    });
    var guardedLoaderPromise = rawLoaderPromise.then(
      function keepResolvedLoader() {
        if (loaderPromise === guardedLoaderPromise) {
          loaderPending = false;
          loaderGeneration = 0;
        }
      },
      function resetRejectedLoader(error) {
        if (loaderPromise === guardedLoaderPromise) {
          removeLoaderScript(url);
          loaderPromise = null;
          loaderUrl = null;
          loaderGeneration = 0;
          loaderPending = false;
        }
        throw error;
      }
    );
    loaderPromise = guardedLoaderPromise;
    return guardedLoaderPromise;
  }

  function cancelPendingLoader(currentGeneration) {
    if (!loaderPending || loaderGeneration !== currentGeneration) return;
    var pendingPromise = loaderPromise;
    var pendingUrl = loaderUrl;
    if (pendingUrl) removeLoaderScript(pendingUrl);
    if (loaderPromise === pendingPromise) {
      loaderPromise = null;
      loaderUrl = null;
      loaderGeneration = 0;
      loaderPending = false;
    }
  }

  function createGenerationAttempt(currentGeneration) {
    var resolveCancellation;
    var cancellation = new Promise(function captureCancellation(resolve) {
      resolveCancellation = resolve;
    });
    var abortController = null;
    if (typeof global.AbortController === 'function') {
      try {
        abortController = new global.AbortController();
      } catch (_) {
        abortController = null;
      }
    }
    return {
      generation: currentGeneration,
      stage: 'mount',
      cancelled: false,
      cancellation: cancellation,
      resolveCancellation: resolveCancellation,
      abortController: abortController,
      watchdogTimer: null,
    };
  }

  function cancelGenerationAttempt(attempt, code, message) {
    if (!attempt || attempt.cancelled) return;
    attempt.cancelled = true;
    if (attempt.watchdogTimer !== null) {
      global.clearTimeout(attempt.watchdogTimer);
      attempt.watchdogTimer = null;
    }
    var error = new Error(message);
    error.code = code;
    error.stage = attempt.stage;
    attempt.resolveCancellation(error);
    if (attempt.abortController) {
      try {
        attempt.abortController.abort();
      } catch (_) {
        // The generation fence still settles even if AbortController fails.
      }
    }
    cancelPendingLoader(attempt.generation);
  }

  function armStartupWatchdog(attempt) {
    if (!attempt || attempt.cancelled || attempt.watchdogTimer !== null) return;
    attempt.watchdogTimer = global.setTimeout(function onStartupTimeout() {
      cancelGenerationAttempt(
        attempt,
        'unity_startup_timeout',
        'Unity startup timed out during ' + (attempt.stage || 'startup')
      );
    }, UNITY_STARTUP_TIMEOUT_MS);
  }

  function awaitGenerationStep(promise, attempt, stage) {
    attempt.stage = stage;
    return Promise.race([
      Promise.resolve(promise),
      attempt.cancellation.then(function rejectCancelledGeneration(error) {
        throw error;
      }),
    ]);
  }

  function finishGenerationAttempt(attempt) {
    if (!attempt) return;
    if (attempt.watchdogTimer !== null) {
      global.clearTimeout(attempt.watchdogTimer);
      attempt.watchdogTimer = null;
    }
    if (activeGenerationAttempt === attempt) activeGenerationAttempt = null;
  }

  function retireStaleCreatedInstance(created) {
    if (!created || typeof created.Quit !== 'function') return;
    Promise.resolve(created.Quit()).catch(function ignoreStaleQuitFailure() {});
  }

  function clearReadyTimer() {
    if (readyTimer !== null) {
      global.clearTimeout(readyTimer);
      readyTimer = null;
    }
  }

  function disconnectMountObserver(record) {
    if (!record) return;
    if (record.resizeObserver) {
      record.resizeObserver.disconnect();
      record.resizeObserver = null;
    }
    if (record.animationFrame !== null) {
      global.cancelAnimationFrame(record.animationFrame);
      record.animationFrame = null;
    }
  }

  function mountIsReady(record) {
    if (!record || record !== activeMount || !record.element.isConnected) {
      return false;
    }
    var bounds = record.element.getBoundingClientRect();
    return bounds.width > 0 && bounds.height > 0;
  }

  function createRootIfNeeded() {
    if (!rootElement) {
      rootElement = global.document.createElement('div');
      rootElement.setAttribute('aria-hidden', 'true');
      rootElement.style.width = '100%';
      rootElement.style.height = '100%';
      rootElement.style.overflow = 'hidden';
      rootElement.style.background = 'transparent';
      rootElement.style.pointerEvents = 'none';
    }
    if (!canvasElement) {
      canvasElement = global.document.createElement('canvas');
      canvasElement.id = 'maaso-unity-avatar-canvas';
      canvasElement.setAttribute('aria-hidden', 'true');
      canvasElement.tabIndex = -1;
      canvasElement.style.display = 'block';
      canvasElement.style.width = '100%';
      canvasElement.style.height = '100%';
      canvasElement.style.background = 'transparent';
      canvasElement.style.pointerEvents = 'none';
      canvasGeneration = generation;
      rootElement.appendChild(canvasElement);
    }
    return rootElement;
  }

  function unbindCanvasEvents() {
    canvasEventListeners.forEach(function removeCanvasEvent(binding) {
      binding.canvas.removeEventListener(binding.type, binding.callback);
    });
    canvasEventListeners = [];
  }

  function bindCanvasEvent(canvas, type, callback) {
    canvas.addEventListener(type, callback);
    canvasEventListeners.push({
      canvas: canvas,
      type: type,
      callback: callback,
    });
  }

  function bindCanvasEvents(currentGeneration) {
    unbindCanvasEvents();
    var canvas = canvasElement;
    if (!canvas) return;

    function belongsToCurrentGeneration() {
      return (
        canvas === canvasElement &&
        currentGeneration === generation &&
        unityEventGeneration === currentGeneration
      );
    }

    bindCanvasEvent(canvas, 'maaso-unity-avatar-ready', function onAvatarReady() {
      if (!belongsToCurrentGeneration()) return;
      emitFromUnity('ready', '{}');
    });
    bindCanvasEvent(
      canvas,
      'maaso-unity-avatar-command-result',
      function onAvatarCommandResult(event) {
        if (!belongsToCurrentGeneration()) return;
        emitFromUnity(
          'commandResult',
          typeof event.detail === 'string' ? event.detail : '{}'
        );
      }
    );

    bindCanvasEvent(canvas, 'webglcontextlost', function onContextLost(event) {
      if (!belongsToCurrentGeneration()) return;
      event.preventDefault();
      unityReady = false;
      publish(
        'unready',
        { reason: 'webgl_context_lost', recoverable: true },
        true
      );
      hostError(
        'webgl_context_lost',
        'Unity WebGL graphics context was lost',
        true,
        { generation: canvasGeneration }
      );
      unityEventGeneration = 0;
      unbindCanvasEvents();
    });
    bindCanvasEvent(
      canvas,
      'webglcontextrestored',
      function onContextRestored() {
        if (!belongsToCurrentGeneration()) return;
        log('info', 'WebGL context restored; retry is required');
      }
    );
  }

  function attachRoot(record) {
    var root = createRootIfNeeded();
    record.element.style.width = '100%';
    record.element.style.height = '100%';
    record.element.style.overflow = 'hidden';
    record.element.style.background = 'transparent';
    record.element.style.pointerEvents = 'none';
    if (root.parentNode !== record.element) record.element.appendChild(root);
  }

  function activateMount(record) {
    if (!mountIsReady(record)) return false;
    disconnectMountObserver(record);
    attachRoot(record);
    record.ready = true;
    notifyMountWaiters();
    if (unityInstance && unityReady) {
      publish(
        'ready',
        { leaseId: record.leaseId, reused: true },
        true
      );
    } else if (generation === 0) {
      beginGeneration(false);
    }
    return true;
  }

  function observeMount(record) {
    function checkMount() {
      if (record !== activeMount) {
        disconnectMountObserver(record);
        return;
      }
      if (activateMount(record)) return;
      record.animationFrame = global.requestAnimationFrame(checkMount);
    }

    if (typeof global.ResizeObserver === 'function') {
      record.resizeObserver = new global.ResizeObserver(function onResize() {
        activateMount(record);
      });
      record.resizeObserver.observe(record.element);
    }
    record.animationFrame = global.requestAnimationFrame(checkMount);
  }

  function validLeaseId(leaseId) {
    return (
      typeof leaseId === 'string' &&
      leaseId.length > 0 &&
      leaseId.length <= 128 &&
      !/[\u0000-\u001f\u007f]/.test(leaseId)
    );
  }

  function mount(element, leaseId) {
    if (!element || element.nodeType !== 1 || !element.style) {
      hostError('invalid_mount', 'Unity avatar mount must be an HTMLElement');
      return;
    }
    if (!validLeaseId(leaseId)) {
      hostError('invalid_lease', 'Unity avatar lease id is invalid');
      return;
    }
    if (
      activeMount &&
      activeMount.element === element &&
      activeMount.leaseId === leaseId
    ) {
      activateMount(activeMount);
      return;
    }
    disconnectMountObserver(activeMount);
    activeMount = {
      element: element,
      leaseId: leaseId,
      ready: false,
      resizeObserver: null,
      animationFrame: null,
    };
    if (!activateMount(activeMount)) observeMount(activeMount);
  }

  function detach(leaseId) {
    if (!activeMount || activeMount.leaseId !== leaseId) return;
    var detached = activeMount;
    activeMount = null;
    disconnectMountObserver(detached);
    if (rootElement && rootElement.parentNode === detached.element) {
      detached.element.removeChild(rootElement);
    }
    publish(
      'unready',
      { reason: 'detached', leaseId: leaseId, recoverable: true },
      true
    );
  }

  function waitForMountedContainer(currentGeneration) {
    if (currentGeneration !== generation) return Promise.resolve(null);
    if (activeMount && mountIsReady(activeMount)) {
      attachRoot(activeMount);
      activeMount.ready = true;
      return Promise.resolve(activeMount);
    }
    return new Promise(function wait(resolve) {
      mountWaiters.push({ generation: currentGeneration, resolve: resolve });
    });
  }

  function notifyMountWaiters() {
    if (mountWaiters.length === 0) return;
    var mounted = activeMount && mountIsReady(activeMount) ? activeMount : null;
    var pending = [];
    mountWaiters.forEach(function settleMountWaiter(waiter) {
      if (waiter.generation !== generation) {
        waiter.resolve(null);
      } else if (mounted) {
        attachRoot(mounted);
        mounted.ready = true;
        waiter.resolve(mounted);
      } else {
        pending.push(waiter);
      }
    });
    mountWaiters = pending;
  }

  function cancelAllMountWaiters() {
    var pending = mountWaiters;
    mountWaiters = [];
    pending.forEach(function cancelMountWaiter(waiter) {
      waiter.resolve(null);
    });
  }

  function promiseWithTimeout(promise, milliseconds, message) {
    return new Promise(function enforceTimeout(resolve, reject) {
      var settled = false;
      var timer = global.setTimeout(function onTimeout() {
        if (settled) return;
        settled = true;
        reject(new Error(message));
      }, milliseconds);
      promise.then(
        function onResolved(value) {
          if (settled) return;
          settled = true;
          global.clearTimeout(timer);
          resolve(value);
        },
        function onRejected(error) {
          if (settled) return;
          settled = true;
          global.clearTimeout(timer);
          reject(error);
        }
      );
    });
  }

  async function quitUnityInstance() {
    clearReadyTimer();
    unityEventGeneration = 0;
    unbindCanvasEvents();
    unityReady = false;
    pendingUnityReadyPayload = null;
    if (!retiringQuitPromise && unityInstance) {
      var retiringInstance = unityInstance;
      unityInstance = null;
      if (typeof retiringInstance.Quit !== 'function') {
        throw new Error('Unity instance does not expose Quit');
      }
      var trackedQuit = Promise.resolve().then(function requestUnityQuit() {
        return retiringInstance.Quit();
      });
      var guardedQuit = trackedQuit.then(
        function clearCompletedQuit() {
          if (retiringQuitPromise === guardedQuit) retiringQuitPromise = null;
        },
        function clearRejectedQuit(error) {
          if (retiringQuitPromise === guardedQuit) retiringQuitPromise = null;
          throw error;
        }
      );
      retiringQuitPromise = guardedQuit;
    }
    if (!retiringQuitPromise) return;
    await promiseWithTimeout(
      retiringQuitPromise,
      UNITY_QUIT_TIMEOUT_MS,
      'Unity shutdown timed out; refresh the page to recover'
    );
  }

  function replaceCanvas() {
    unbindCanvasEvents();
    if (canvasElement && canvasElement.parentNode) {
      canvasElement.parentNode.removeChild(canvasElement);
    }
    canvasElement = null;
    canvasGeneration = 0;
    createRootIfNeeded();
    if (activeMount && mountIsReady(activeMount)) attachRoot(activeMount);
  }

  async function runGeneration(currentGeneration, restart, attempt) {
    try {
      if (attempt.cancelled || currentGeneration !== generation) return;
      if (restart) {
        publish('loading', { stage: 'quitting' }, true);
        await awaitGenerationStep(
          quitUnityInstance(),
          attempt,
          'quitting'
        );
        if (currentGeneration !== generation) return;
        replaceCanvas();
      }
      var mounted = await waitForMountedContainer(currentGeneration);
      if (!mounted || currentGeneration !== generation) return;
      armStartupWatchdog(attempt);
      var signal = attempt.abortController
        ? attempt.abortController.signal
        : null;
      var manifest = await awaitGenerationStep(
        fetchManifest(currentGeneration, signal),
        attempt,
        'manifest'
      );
      if (!manifest || currentGeneration !== generation) return;
      publish('loading', { stage: 'loader', url: manifest.loaderUrl }, true);
      await awaitGenerationStep(
        loadUnityLoader(manifest.loaderUrl, currentGeneration),
        attempt,
        'loader'
      );
      if (currentGeneration !== generation) return;
      mounted = await waitForMountedContainer(currentGeneration);
      if (!mounted || currentGeneration !== generation) return;
      attachRoot(mounted);
      canvasGeneration = currentGeneration;
      unityEventGeneration = currentGeneration;
      bindCanvasEvents(currentGeneration);
      publish('loading', { stage: 'instance' }, true);
      var creationPromise = Promise.resolve().then(function createInstance() {
        return global.createUnityInstance(
          canvasElement,
          manifest.config,
          function onProgress(value) {
            if (currentGeneration !== generation || attempt.cancelled) return;
            var progress = Number(value);
            if (!Number.isFinite(progress)) return;
            publish(
              'progress',
              { value: Math.max(0, Math.min(1, progress)) },
              true
            );
          }
        );
      });
      creationPromise.then(
        function retireLateInstance(created) {
          if (currentGeneration !== generation || attempt.cancelled) {
            retireStaleCreatedInstance(created);
          }
        },
        function ignoreLateCreationFailure() {}
      );
      var created = await awaitGenerationStep(
        creationPromise,
        attempt,
        'instance'
      );
      if (currentGeneration !== generation || attempt.cancelled) {
        return;
      }
      unityInstance = created;
      if (unityReady) {
        publish('ready', pendingUnityReadyPayload || {}, true);
        pendingUnityReadyPayload = null;
        replayDurableState();
        return;
      }
      publish('loading', { stage: 'unity-ready' }, true);
      clearReadyTimer();
      readyTimer = global.setTimeout(function onUnityReadyTimeout() {
        if (currentGeneration !== generation || unityReady) return;
        hostError(
          'unity_ready_timeout',
          'Unity loaded but did not report avatar readiness',
          true
        );
      }, UNITY_READY_TIMEOUT_MS);
    } catch (error) {
      if (
        currentGeneration !== generation ||
        (error &&
          (error.code === 'generation_superseded' ||
            error.code === 'page_exit'))
      ) {
        return;
      }
      unityEventGeneration = 0;
      var message = error && error.message ? error.message : String(error);
      var code = 'unity_init_failed';
      if (error && error.code === 'unity_startup_timeout') {
        code = 'unity_startup_timeout';
      } else if (/manifest/i.test(message)) code = 'manifest_invalid';
      else if (/loader/i.test(message)) code = 'loader_failed';
      else if (/Quit|shutdown/i.test(message)) code = 'unity_quit_failed';
      hostError(code, message, true, {
        stage: (error && error.stage) || attempt.stage,
      });
    } finally {
      finishGenerationAttempt(attempt);
    }
  }

  function beginGeneration(restart) {
    cancelGenerationAttempt(
      activeGenerationAttempt,
      'generation_superseded',
      'Unity startup was superseded by a newer generation'
    );
    generation += 1;
    notifyMountWaiters();
    sequence = 0;
    unityReady = false;
    unityEventGeneration = 0;
    unbindCanvasEvents();
    pendingUnityReadyPayload = null;
    clearReadyTimer();
    publish(
      'unready',
      { reason: restart ? 'retry' : 'starting', recoverable: true },
      true
    );
    publish('loading', { stage: restart ? 'retry' : 'mount' }, true);
    var currentGeneration = generation;
    var attempt = createGenerationAttempt(currentGeneration);
    activeGenerationAttempt = attempt;
    attemptSerial = attemptSerial
      .catch(function ignorePreviousAttemptFailure() {})
      .then(function serializeUnityAttempt() {
        return runGeneration(currentGeneration, restart, attempt);
      });
  }

  function retry(leaseId) {
    if (!activeMount || activeMount.leaseId !== leaseId) return;
    beginGeneration(true);
  }

  function queueHasRoom(extraEntries, extraBytes) {
    return (
      commandQueue.length + extraEntries <= MAX_QUEUE_ENTRIES &&
      queuedBytes + extraBytes <= MAX_QUEUE_BYTES
    );
  }

  function evictOldestCoalescibleUntilFits(extraEntries, extraBytes) {
    while (!queueHasRoom(extraEntries, extraBytes)) {
      var index = commandQueue.findIndex(function findCoalescible(entry) {
        return entry.coalesceKey !== null;
      });
      if (index < 0) return false;
      queuedBytes -= commandQueue[index].bytes;
      commandQueue.splice(index, 1);
    }
    return true;
  }

  function enqueue(command) {
    if (command.coalesceKey !== null) {
      var existingIndex = commandQueue.findIndex(function sameState(entry) {
        return entry.coalesceKey === command.coalesceKey;
      });
      if (existingIndex >= 0) {
        var previous = commandQueue[existingIndex];
        commandQueue.splice(existingIndex, 1);
        queuedBytes -= previous.bytes;
        if (!evictOldestCoalescibleUntilFits(0, command.bytes)) {
          commandQueue.splice(existingIndex, 0, previous);
          queuedBytes += previous.bytes;
          return false;
        }
        commandQueue.splice(
          Math.min(existingIndex, commandQueue.length),
          0,
          command
        );
        queuedBytes += command.bytes;
        return true;
      }
    }
    if (!evictOldestCoalescibleUntilFits(1, command.bytes)) return false;
    commandQueue.push(command);
    queuedBytes += command.bytes;
    return true;
  }

  function rememberDurableState(command) {
    if (command.coalesceKey === null) return true;
    var previous = durableState.get(command.coalesceKey);
    var nextBytes = durableBytes - (previous ? previous.bytes : 0) + command.bytes;
    if (nextBytes > MAX_QUEUE_BYTES) return false;
    durableState.set(command.coalesceKey, command);
    durableBytes = nextBytes;
    return true;
  }

  function replayDurableState() {
    if (durableReplayGeneration === generation) {
      flushQueue();
      return;
    }
    commandQueue = [];
    queuedBytes = 0;
    var accepted = true;
    durableState.forEach(function enqueueDurableCommand(command) {
      if (!enqueue(command)) accepted = false;
    });
    durableReplayGeneration = generation;
    if (!accepted) {
      hostError(
        'durable_state_overflow',
        'Unity avatar durable state could not be restored',
        true
      );
      return;
    }
    flushQueue();
  }

  function sendCommand(command) {
    unityInstance.SendMessage(
      UNITY_GAME_OBJECT,
      UNITY_RECEIVER,
      JSON.stringify({
        method: command.method,
        json: command.argumentsJson,
      })
    );
  }

  function flushQueue() {
    while (unityInstance && unityReady && commandQueue.length > 0) {
      var command = commandQueue.shift();
      queuedBytes -= command.bytes;
      try {
        sendCommand(command);
      } catch (error) {
        commandQueue.unshift(command);
        queuedBytes += command.bytes;
        hostError(
          'send_failed',
          error && error.message ? error.message : 'Unity command failed',
          true
        );
        return;
      }
    }
  }

  function isAgentSpaceMethod(method) {
    return method === 'enterAgentSpace' || method === 'leaveAgentSpace' ||
      method === 'requestAgentSpaceMoveAtScreenPoint';
  }

  function agentSpaceIdentifier(value) {
    return typeof value === 'string' && /^[A-Za-z0-9._:-]{1,128}$/.test(value);
  }

  function exactKeys(value, keys) {
    var actual = Object.keys(value);
    return actual.length === keys.length && keys.every(function (key) {
      return Object.prototype.hasOwnProperty.call(value, key);
    });
  }

  function validAgentSpaceArguments(method, value) {
    var moving = method === 'requestAgentSpaceMoveAtScreenPoint';
    var keys = moving ? ['requestId', 'sessionId', 'x', 'y'] : ['requestId', 'sessionId'];
    if (!moving) {
      if (Object.prototype.hasOwnProperty.call(value, 'animated')) {
        if (typeof value.animated !== 'boolean') return false;
        keys.push('animated');
      }
      var hasTop = Object.prototype.hasOwnProperty.call(value, 'viewportTop');
      var hasBottom = Object.prototype.hasOwnProperty.call(value, 'viewportBottom');
      if (hasTop !== hasBottom) return false;
      if (hasTop) {
        keys.push('viewportTop', 'viewportBottom');
        if (!['viewportTop', 'viewportBottom'].every(function (key) {
          return typeof value[key] === 'number' && Number.isFinite(value[key]) &&
            value[key] >= 0 && value[key] <= 0.45;
        })) return false;
      }
    }
    if (!exactKeys(value, keys) || !agentSpaceIdentifier(value.requestId) ||
        !agentSpaceIdentifier(value.sessionId)) return false;
    return !moving || ['x', 'y'].every(function (key) {
      return typeof value[key] === 'number' && Number.isFinite(value[key]) &&
        value[key] >= 0 && value[key] <= 1;
    });
  }

  function validAgentSpaceReceipt(value) {
    return exactKeys(value, ['method', 'requestId', 'sessionId', 'ok', 'code']) &&
      agentSpaceIdentifier(value.requestId) && agentSpaceIdentifier(value.sessionId) &&
      typeof value.ok === 'boolean' && typeof value.code === 'string' &&
      (value.code === '' || agentSpaceIdentifier(value.code));
  }

  function invoke(method, argumentsJson) {
    if (typeof method !== 'string' || ALLOWED_METHODS[method] !== true) {
      return rejectedInvocation(
        'invalid_method',
        'Unity avatar method is not allowed',
        { method: String(method || '') }
      );
    }
    if (typeof argumentsJson !== 'string') {
      return rejectedInvocation(
        'invalid_arguments',
        'Unity avatar arguments must be JSON text',
        { method: method }
      );
    }
    var bytes = utf8Length(argumentsJson);
    if (bytes > MAX_ARGUMENT_BYTES) {
      return rejectedInvocation(
        'arguments_too_large',
        'Unity avatar arguments exceed 32 KiB',
        { method: method, maxBytes: MAX_ARGUMENT_BYTES }
      );
    }
    var parsed;
    try {
      parsed = JSON.parse(argumentsJson);
    } catch (_) {
      return rejectedInvocation(
        'invalid_arguments',
        'Unity avatar arguments are not valid JSON',
        { method: method }
      );
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return rejectedInvocation(
        'invalid_arguments',
        'Unity avatar arguments must be a JSON object',
        { method: method }
      );
    }
    if (isAgentSpaceMethod(method) && !validAgentSpaceArguments(method, parsed)) {
      return rejectedInvocation(
        'invalid_arguments', 'Personal-room command is invalid', { method: method }
      );
    }
    var normalized = JSON.stringify(parsed);
    var command = {
      method: method,
      argumentsJson: normalized,
      bytes: utf8Length(method) + utf8Length(normalized),
      coalesceKey: COALESCE_KEYS[method] || null,
    };
    if (!rememberDurableState(command)) {
      return rejectedInvocation(
        'queue_overflow',
        'Unity avatar durable state is full',
        { method: method, maxBytes: MAX_QUEUE_BYTES }
      );
    }
    if (unityInstance && unityReady) {
      try {
        sendCommand(command);
        return Promise.resolve(
          result(true, {
            state: 'sent',
            generation: generation,
          })
        );
      } catch (error) {
        hostError(
          'send_failed',
          error && error.message ? error.message : 'Unity command failed',
          true
        );
        if (command.coalesceKey === null) {
          return rejectedInvocation(
            'send_failed',
            'Unity avatar command could not be sent',
            { method: method, generation: generation }
          );
        }
      }
    }
    if (command.coalesceKey === null) {
      return rejectedInvocation(
        'not_ready',
        'Unity avatar is not ready for transactional commands',
        { method: method, generation: generation }
      );
    }
    if (!enqueue(command)) {
      return rejectedInvocation(
        'queue_overflow',
        'Unity avatar state queue is full',
        {
          method: method,
          maxEntries: MAX_QUEUE_ENTRIES,
          maxBytes: MAX_QUEUE_BYTES,
        }
      );
    }
    return Promise.resolve(
      result(true, {
        state: 'queued',
        generation: generation,
      })
    );
  }

  function parseUnityPayload(payloadJson) {
    if (typeof payloadJson !== 'string') {
      throw new Error('Unity event payload must be JSON text');
    }
    if (utf8Length(payloadJson) > MAX_ARGUMENT_BYTES) {
      throw new Error('Unity event payload exceeds 32 KiB');
    }
    return payloadJson.trim() === '' ? {} : JSON.parse(payloadJson);
  }

  function emitFromUnity(type, payloadJson) {
    if (!UNITY_EVENT_TYPES[type]) return false;
    if (unityEventGeneration !== generation) return false;
    var payload;
    try {
      payload = parseUnityPayload(payloadJson);
    } catch (error) {
      hostError(
        'invalid_unity_event',
        error && error.message ? error.message : 'Invalid Unity event',
        true
      );
      return false;
    }
    if (type === 'commandResult') {
      if (!payload || typeof payload !== 'object' || Array.isArray(payload) ||
          typeof payload.method !== 'string' ||
          (payload.method !== 'furnitureState' && ALLOWED_METHODS[payload.method] !== true)) return false;
      if (isAgentSpaceMethod(payload.method) && !validAgentSpaceReceipt(payload)) return false;
    }
    if (type === 'ready') {
      unityReady = true;
      pendingUnityReadyPayload = payload;
      clearReadyTimer();
      if (unityInstance) {
        publish('ready', payload, true);
        pendingUnityReadyPayload = null;
        replayDurableState();
      }
      return true;
    }
    if (type === 'unready') {
      unityReady = false;
      publish('unready', payload, true);
      return true;
    }
    if (type === 'error') {
      var wasReady = unityReady || lifecycleType === 'ready';
      unityReady = false;
      pendingUnityReadyPayload = null;
      if (wasReady) {
        publish(
          'unready',
          { reason: 'unity_error', recoverable: true },
          true
        );
      }
      publish('error', payload, true);
      return true;
    }
    publish(type, payload, false);
    return true;
  }

  function disposeForPageExit() {
    cancelGenerationAttempt(
      activeGenerationAttempt,
      'page_exit',
      'Unity startup was cancelled because the page is exiting'
    );
    clearReadyTimer();
    disconnectMountObserver(activeMount);
    activeMount = null;
    cancelAllMountWaiters();
    unityEventGeneration = 0;
    unbindCanvasEvents();
    if (unityInstance && typeof unityInstance.Quit === 'function') {
      Promise.resolve(unityInstance.Quit()).catch(function ignoreQuitFailure() {});
    }
    unityInstance = null;
    unityReady = false;
  }

  function onPageHide(event) {
    if (event && event.persisted === true) {
      publish(
        'unready',
        { reason: 'bfcache', recoverable: true },
        true
      );
      return;
    }
    disposeForPageExit();
  }

  function onPageShow(event) {
    if (!event || event.persisted !== true) return;
    if (activeMount && unityInstance && unityReady) {
      publish(
        'ready',
        { reason: 'bfcache_restore', reused: true },
        true
      );
      flushQueue();
    } else if (activeMount && generation > 0) {
      publish(
        'loading',
        { stage: 'bfcache_restore' },
        true
      );
    }
  }

  global.maasoUnityAvatarHost = Object.freeze({
    subscribe: subscribe,
    unsubscribe: unsubscribe,
    mount: mount,
    detach: detach,
    retry: retry,
    invoke: invoke,
    snapshot: snapshot,
    emitFromUnity: emitFromUnity,
  });
  if (typeof global.addEventListener === 'function') {
    global.addEventListener('pagehide', onPageHide);
    global.addEventListener('pageshow', onPageShow);
  }
})(window);
