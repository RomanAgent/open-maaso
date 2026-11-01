import 'dart:convert';
import 'dart:math';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

/// Builds the host-owned document for [SurfaceRendering.workerCanvas].
///
/// The generated source is encoded into a dedicated Worker blob. It is never
/// inserted into a Window script element. The Worker receives no DOM or Canvas
/// object; it can only define pure game callbacks and return bounded drawing
/// commands that are interpreted by trusted host code.
class SurfaceWorkerCanvasHost {
  const SurfaceWorkerCanvasHost._();

  static String build(SurfaceProject project, {required int lifecycleToken}) {
    final heartbeatToken = _secureToken();
    final stoppedMessage = AgentPromptCatalog.text(
      'runtime.surface.worker_canvas.stopped',
    );
    final bootstrap = _workerBootstrap.replaceAll(
      '__HEARTBEAT_TOKEN__',
      heartbeatToken,
    );
    final workerSource = '$bootstrap\n${project.js}\n';
    return _hostTemplate
        .replaceFirst(
          '/*__SURFACE_BACKGROUND__*/',
          project.transparent ? 'transparent' : '#10131a',
        )
        .replaceAll('__HEARTBEAT_TOKEN__', heartbeatToken)
        .replaceAll('__LIFECYCLE_TOKEN__', lifecycleToken.toString())
        .replaceFirst(
          '__GAME_STOPPED_MESSAGE__',
          const HtmlEscape().convert(stoppedMessage),
        )
        .replaceFirst(
          '__WORKER_SOURCE_BASE64__',
          base64Encode(utf8.encode(workerSource)),
        );
  }

  static String _secureToken() {
    final random = Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  static const String _hostTemplate = r'''
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
<meta http-equiv="x-dns-prefetch-control" content="off" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' blob:; worker-src blob:; child-src blob:; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'; navigate-to 'none'" />
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:/*__SURFACE_BACKGROUND__*/;}
#game{display:block;width:100%;height:100%;outline:none;touch-action:none;user-select:none;-webkit-user-select:none;}
#game-status{position:fixed;inset:0;display:none;place-items:center;padding:24px;background:#10131ae6;color:#f5f7fb;font:600 16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;text-align:center;}
body[data-game-stopped="true"] #game-status{display:grid;}
</style>
</head>
<body>
<canvas id="game" tabindex="0" aria-label="Agent game canvas"></canvas>
<div id="game-status" role="status" aria-live="polite">__GAME_STOPPED_MESSAGE__</div>
<script>
(function () {
  'use strict';

  const token = '__HEARTBEAT_TOKEN__';
  const lifecycleToken = __LIFECYCLE_TOKEN__;
  const canvas = document.getElementById('game');
  const status = document.getElementById('game-status');
  let lifecycleReported = false;

  function reportLifecycle(statusName, reason) {
    if (lifecycleReported) return;
    lifecycleReported = true;
    try {
      SurfaceLifecycle.postMessage(JSON.stringify({
        version: 1,
        session: lifecycleToken,
        status: statusName,
        reason: reason,
      }));
    } catch (_) {}
  }

  const sourceBytes = Uint8Array.from(
    atob('__WORKER_SOURCE_BASE64__'),
    function (character) { return character.charCodeAt(0); }
  );
  const workerSource = new TextDecoder('utf-8', { fatal: true }).decode(sourceBytes);
  const workerUrl = URL.createObjectURL(
    new Blob([workerSource], { type: 'text/javascript;charset=utf-8' })
  );
  let worker = null;
  try {
    worker = new Worker(workerUrl, { name: 'maaso-agent-game' });
  } catch (_) {
    URL.revokeObjectURL(workerUrl);
    document.body.setAttribute('data-game-stopped', 'true');
    status.hidden = false;
    reportLifecycle('fatal', 'worker_start_failed');
    return;
  }
  const colorPattern = /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
  let initialized = false;
  let fallback = false;
  let fallbackContext = null;
  let width = 1;
  let height = 1;
  let dpr = 1;
  let lastHeartbeat = Date.now();
  let stopped = false;
  let pendingPointerMove = null;
  let pointerFrame = 0;
  let drawWindowStartedAt = 0;
  let drawMessagesInWindow = 0;
  let emitTimes = [];
  let agentTimes = [];

  function finiteNumber(value, minimum, maximum) {
    if (typeof value !== 'number' || !Number.isFinite(value)) return null;
    return Math.max(minimum, Math.min(maximum, value));
  }

  function safeText(value, maximumLength) {
    if (typeof value !== 'string') return null;
    return value.length <= maximumLength ? value : value.slice(0, maximumLength);
  }

  function safeColor(value) {
    return typeof value === 'string' && colorPattern.test(value) ? value : null;
  }

  function hostLineWidth(value) {
    if (value === undefined) return 1;
    return finiteNumber(value, 0.1, 100);
  }

  function normalizeHostCommand(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    const type = raw.type;
    if (type === 'clear') {
      const color = safeColor(raw.color);
      return color === null ? null : { type: type, color: color };
    }
    if (type === 'fillRect' || type === 'strokeRect') {
      const x = finiteNumber(raw.x, -100000, 100000);
      const y = finiteNumber(raw.y, -100000, 100000);
      const commandWidth = finiteNumber(raw.width, -100000, 100000);
      const commandHeight = finiteNumber(raw.height, -100000, 100000);
      const color = safeColor(raw.color);
      if (x === null || y === null || commandWidth === null ||
          commandHeight === null || color === null) return null;
      const command = {
        type: type,
        x: x,
        y: y,
        width: commandWidth,
        height: commandHeight,
        color: color,
      };
      if (type === 'strokeRect') {
        const lineWidth = hostLineWidth(raw.lineWidth);
        if (lineWidth === null) return null;
        command.lineWidth = lineWidth;
      }
      return command;
    }
    if (type === 'line') {
      const x1 = finiteNumber(raw.x1, -100000, 100000);
      const y1 = finiteNumber(raw.y1, -100000, 100000);
      const x2 = finiteNumber(raw.x2, -100000, 100000);
      const y2 = finiteNumber(raw.y2, -100000, 100000);
      const color = safeColor(raw.color);
      const lineWidth = hostLineWidth(raw.lineWidth);
      if (x1 === null || y1 === null || x2 === null || y2 === null ||
          color === null || lineWidth === null) return null;
      return {
        type: type,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        color: color,
        lineWidth: lineWidth,
      };
    }
    if (type === 'circle') {
      const x = finiteNumber(raw.x, -100000, 100000);
      const y = finiteNumber(raw.y, -100000, 100000);
      const radius = finiteNumber(raw.r, 0, 100000);
      const fillColor = raw.fillColor === undefined || raw.fillColor === null
        ? null
        : safeColor(raw.fillColor);
      const strokeColor = raw.strokeColor === undefined || raw.strokeColor === null
        ? null
        : safeColor(raw.strokeColor);
      const lineWidth = hostLineWidth(raw.lineWidth);
      if (x === null || y === null || radius === null ||
          (raw.fillColor !== undefined && raw.fillColor !== null && fillColor === null) ||
          (raw.strokeColor !== undefined && raw.strokeColor !== null && strokeColor === null) ||
          (fillColor === null && strokeColor === null) || lineWidth === null) return null;
      return {
        type: type,
        x: x,
        y: y,
        r: radius,
        fillColor: fillColor,
        strokeColor: strokeColor,
        lineWidth: lineWidth,
      };
    }
    if (type === 'text') {
      const x = finiteNumber(raw.x, -100000, 100000);
      const y = finiteNumber(raw.y, -100000, 100000);
      const color = safeColor(raw.color);
      const size = finiteNumber(raw.size, 4, 128);
      if (x === null || y === null || color === null || size === null ||
          typeof raw.text !== 'string' || raw.text.length > 256 ||
          (raw.align !== 'left' && raw.align !== 'center' && raw.align !== 'right')) {
        return null;
      }
      return {
        type: type,
        x: x,
        y: y,
        text: raw.text,
        color: color,
        size: size,
        align: raw.align,
      };
    }
    return null;
  }

  function resizeFallbackCanvas() {
    if (!fallback || !fallbackContext) return;
    canvas.width = Math.max(1, Math.round(width * dpr));
    canvas.height = Math.max(1, Math.round(height * dpr));
    fallbackContext.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function setFill(context, color) {
    context.fillStyle = color;
  }

  function setStroke(context, color, lineWidth) {
    context.strokeStyle = color;
    context.lineWidth = lineWidth;
  }

  function applyCommand(context, command) {
    const type = command.type;
    if (type === 'clear') {
      context.clearRect(0, 0, width, height);
      setFill(context, command.color);
      context.fillRect(0, 0, width, height);
    } else if (type === 'fillRect') {
      setFill(context, command.color);
      context.fillRect(command.x, command.y, command.width, command.height);
    } else if (type === 'strokeRect') {
      setStroke(context, command.color, command.lineWidth);
      context.strokeRect(command.x, command.y, command.width, command.height);
    } else if (type === 'line') {
      setStroke(context, command.color, command.lineWidth);
      context.beginPath();
      context.moveTo(command.x1, command.y1);
      context.lineTo(command.x2, command.y2);
      context.stroke();
    } else if (type === 'circle') {
      context.beginPath();
      context.arc(command.x, command.y, command.r, 0, Math.PI * 2);
      if (command.fillColor !== null) {
        setFill(context, command.fillColor);
        context.fill();
      }
      if (command.strokeColor !== null) {
        setStroke(context, command.strokeColor, command.lineWidth);
        context.stroke();
      }
    } else if (type === 'text') {
      setFill(context, command.color);
      context.font = command.size + 'px sans-serif';
      context.textAlign = command.align;
      context.textBaseline = 'alphabetic';
      context.fillText(command.text, command.x, command.y);
    }
  }

  function applyCommands(commands) {
    if (!fallbackContext) return;
    try {
      const serialized = JSON.stringify(commands);
      if (serialized === undefined ||
          new TextEncoder().encode(serialized).length > 256 * 1024) return;
      commands = JSON.parse(serialized);
    } catch (_) {
      return;
    }
    if (!Array.isArray(commands) || commands.length > 512) return;
    const now = performance.now();
    if (now - drawWindowStartedAt >= 1000) {
      drawWindowStartedAt = now;
      drawMessagesInWindow = 0;
    }
    if (++drawMessagesInWindow > 90) return;
    for (const raw of commands) {
      const command = normalizeHostCommand(raw);
      if (command === null) continue;
      try { applyCommand(fallbackContext, command); } catch (_) {}
    }
  }

  function relaySurfaceEvent(message) {
    if (!message || typeof message.event !== 'string') return;
    if (!/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(message.event)) return;
    const now = performance.now();
    emitTimes = emitTimes.filter(function (time) { return now - time < 1000; });
    if (emitTimes.length >= 10) return;
    try {
      const data = message.data === undefined ? null : message.data;
      const serializedData = JSON.stringify(data);
      if (serializedData === undefined) return;
      if (new TextEncoder().encode(serializedData).length > 8192) return;
      emitTimes.push(now);
      SurfaceEvent.postMessage(JSON.stringify({
        event: message.event,
        data: JSON.parse(serializedData),
      }));
    } catch (_) {}
  }

  function measure() {
    const bounds = canvas.getBoundingClientRect();
    width = Math.max(1, Math.min(4096, Math.round(bounds.width)));
    height = Math.max(1, Math.min(4096, Math.round(bounds.height)));
    const pixelRatioLimit = Math.min(4096 / width, 4096 / height);
    dpr = Math.max(
      1,
      Math.min(3, pixelRatioLimit, Number(window.devicePixelRatio) || 1)
    );
  }

  function updateSize() {
    measure();
    if (!initialized || stopped) return;
    resizeFallbackCanvas();
    worker.postMessage({ type: 'resize', width: width, height: height, dpr: dpr });
  }

  function initializeWorker() {
    if (initialized || stopped) return;
    initialized = true;
    measure();
    if (typeof canvas.transferControlToOffscreen === 'function') {
      const offscreen = canvas.transferControlToOffscreen();
      worker.postMessage(
        { type: 'init', canvas: offscreen, width: width, height: height, dpr: dpr, fallback: false },
        [offscreen]
      );
    } else {
      fallback = true;
      fallbackContext = canvas.getContext('2d', { alpha: true });
      if (!fallbackContext) {
        stop('canvas_unavailable');
        return;
      }
      resizeFallbackCanvas();
      worker.postMessage({ type: 'init', width: width, height: height, dpr: dpr, fallback: true });
    }
  }

  function stop(reason) {
    if (stopped) return;
    stopped = true;
    worker.terminate();
    URL.revokeObjectURL(workerUrl);
    document.body.setAttribute('data-game-stopped', 'true');
    status.hidden = false;
    if (reason) {
      reportLifecycle('fatal', reason);
      console.error('[SurfaceRuntime] workerCanvas stopped: ' + reason);
    }
  }

  Object.defineProperty(window, '__disposeSurfaceWorker', {
    value: function (expectedToken) {
      if (expectedToken !== lifecycleToken) return false;
      stop('');
      return true;
    },
    writable: false,
    configurable: false,
  });

  worker.addEventListener('message', function (event) {
    const message = event.data;
    if (!message || typeof message !== 'object' || Array.isArray(message)) return;
    if (message.token !== token) return;
    if (message.type === 'ready') {
      lastHeartbeat = Date.now();
      initializeWorker();
    } else if (message.type === 'heartbeat') {
      lastHeartbeat = Date.now();
    } else if (message.type === 'draw' && fallback) {
      applyCommands(message.commands);
      if (message.firstFrame === true) {
        reportLifecycle('ready', 'first_frame_ready');
      }
    } else if (message.type === 'firstFrame' && !fallback) {
      reportLifecycle('ready', 'first_frame_ready');
    } else if (message.type === 'emit') {
      relaySurfaceEvent(message);
    } else if (message.type === 'error') {
      const reason = safeText(message.reason, 64);
      if (message.fatal === true) stop(reason || 'runtime_failed');
    }
  });
  worker.addEventListener('error', function () {
    stop('worker_start_failed');
  });

  setInterval(function () {
    if (!stopped && Date.now() - lastHeartbeat > 5000) {
      stop('watchdog_timeout');
    }
  }, 1000);

  function pointerEvent(type, event) {
    const bounds = canvas.getBoundingClientRect();
    return {
      type: type,
      x: finiteNumber(event.clientX - bounds.left, -100000, 100000) || 0,
      y: finiteNumber(event.clientY - bounds.top, -100000, 100000) || 0,
      button: finiteNumber(event.button, -1, 16) || 0,
      buttons: finiteNumber(event.buttons, 0, 65535) || 0,
      pointerId: finiteNumber(event.pointerId, 0, 2147483647) || 0,
    };
  }

  function sendInput(event) {
    if (!initialized || stopped) return;
    worker.postMessage({ type: 'input', event: event });
  }

  canvas.addEventListener('pointerdown', function (event) {
    canvas.focus();
    event.preventDefault();
    sendInput(pointerEvent('pointerDown', event));
  }, { passive: false });
  canvas.addEventListener('pointermove', function (event) {
    event.preventDefault();
    pendingPointerMove = pointerEvent('pointerMove', event);
    if (pointerFrame === 0) {
      pointerFrame = requestAnimationFrame(function () {
        pointerFrame = 0;
        if (pendingPointerMove !== null) sendInput(pendingPointerMove);
        pendingPointerMove = null;
      });
    }
  }, { passive: false });
  function sendPointerUp(event) {
    event.preventDefault();
    sendInput(pointerEvent('pointerUp', event));
  }
  canvas.addEventListener('pointerup', sendPointerUp, { passive: false });
  canvas.addEventListener('pointercancel', sendPointerUp, { passive: false });

  function keyEvent(type, event) {
    return {
      type: type,
      key: safeText(event.key, 32) || '',
      code: safeText(event.code, 64) || '',
      repeat: event.repeat === true,
    };
  }
  canvas.addEventListener('keydown', function (event) {
    event.preventDefault();
    sendInput(keyEvent('keyDown', event));
  });
  canvas.addEventListener('keyup', function (event) {
    event.preventDefault();
    sendInput(keyEvent('keyUp', event));
  });

  window.__applyAgent = function (action, data) {
    const name = safeText(action, 64);
    if (name === null || !/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(name)) return;
    const now = performance.now();
    agentTimes = agentTimes.filter(function (time) { return now - time < 1000; });
    if (agentTimes.length >= 10) return;
    try {
      const serializedData = JSON.stringify(data === undefined ? null : data);
      if (serializedData === undefined) return;
      if (new TextEncoder().encode(serializedData).length > 8192) return;
      agentTimes.push(now);
      sendInput({ type: 'agent', action: name, data: JSON.parse(serializedData) });
    } catch (_) {}
  };

  if (typeof ResizeObserver === 'function') {
    new ResizeObserver(updateSize).observe(canvas);
  }
  window.addEventListener('resize', updateSize);
  window.addEventListener('pagehide', function () { stop(''); }, { once: true });
  measure();
})();
</script>
</body>
</html>
''';

  static const String _workerBootstrap = r'''
(function () {
  'use strict';

  const root = globalThis;
  const token = '__HEARTBEAT_TOKEN__';
  const nativePostMessage = root.postMessage.bind(root);
  const nativeClose = root.close.bind(root);
  const nativeSetTimeout = root.setTimeout.bind(root);
  const nativeClearTimeout = root.clearTimeout.bind(root);
  const nativeNow = root.performance.now.bind(root.performance);
  const nativeAddEventListener = root.addEventListener.bind(root);
  const arrayIsArray = Array.isArray;
  const objectKeys = Object.keys;
  const objectFreeze = Object.freeze;
  const objectGetPrototypeOf = Object.getPrototypeOf;
  const objectGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
  const objectDefineProperty = Object.defineProperty;
  const objectAssign = Object.assign;
  const hasOwn = Object.prototype.hasOwnProperty.call.bind(
    Object.prototype.hasOwnProperty
  );
  const arrayMap = Array.prototype.map.call.bind(Array.prototype.map);
  const jsonStringify = JSON.stringify;
  const jsonParse = JSON.parse;
  const regexpTest = RegExp.prototype.test.call.bind(RegExp.prototype.test);
  const reflectApply = Reflect.apply;
  const textEncoder = new TextEncoder();
  const encodeText = textEncoder.encode.bind(textEncoder);
  const numberIsFinite = Number.isFinite;
  const mathMax = Math.max;
  const mathMin = Math.min;
  const mathRound = Math.round;
  const mathPi = Math.PI;
  const safeString = String;
  const colorPattern = /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
  const namePattern = /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/;
  let definition = null;
  let state = null;
  let runtime = null;
  let renderer = null;
  let frameHandle = null;
  let startedAt = 0;
  let lastFrameAt = 0;
  let lastHeartbeatAt = 0;
  let fatal = false;
  let firstFrameSent = false;
  let emitTimes = [];

  function post(type, body) {
    nativePostMessage(objectAssign({ type: type, token: token }, body || {}));
  }

  function fail(error) {
    if (fatal) return;
    fatal = true;
    let message = '';
    try {
      message = error && error.message
        ? safeString(error.message)
        : safeString(error);
    } catch (_) {}
    let reason = 'runtime_failed';
    if (message.indexOf('draw ') >= 0 ||
        message.indexOf('draw command') >= 0 ||
        message.indexOf('draw may') >= 0 ||
        message.indexOf('unsupported draw command') >= 0 ||
        message.indexOf('fillColor') >= 0 ||
        message.indexOf('strokeColor') >= 0 ||
        message.indexOf('lineWidth') >= 0 ||
        message.indexOf('safe hex color') >= 0 ||
        message.indexOf('text align') >= 0) {
      reason = 'invalid_draw_commands';
    } else if (message.indexOf('game state') >= 0) {
      reason = 'invalid_state';
    } else if (message.indexOf('Game.define') >= 0) {
      reason = 'invalid_game_definition';
    } else if (message.indexOf('canvas') >= 0 ||
               message.indexOf('Canvas') >= 0) {
      reason = 'canvas_unavailable';
    } else if (message.indexOf('security boundary') >= 0 ||
               message.indexOf('dynamic code') >= 0) {
      reason = 'security_boundary_failed';
    }
    post('error', { reason: reason, fatal: true });
    nativeSetTimeout(nativeClose, 0);
  }

  function finiteNumber(value, minimum, maximum, field) {
    if (typeof value !== 'number' || !numberIsFinite(value)) {
      throw new TypeError(field + ' must be a finite number');
    }
    return mathMax(minimum, mathMin(maximum, value));
  }

  function optionalLineWidth(value) {
    return value === undefined
      ? 1
      : finiteNumber(value, 0.1, 100, 'lineWidth');
  }

  function color(value, field) {
    if (typeof value !== 'string' || !regexpTest(colorPattern, value)) {
      throw new TypeError(field + ' must be a safe hex color');
    }
    return value;
  }

  function optionalColor(value, field) {
    return value === undefined || value === null ? null : color(value, field);
  }

  function jsonClone(value, maximumBytes, label) {
    if (value && typeof value.then === 'function') {
      throw new TypeError(label + ' must be synchronous');
    }
    const source = jsonStringify(value);
    if (source === undefined) throw new TypeError(label + ' must be JSON serializable');
    if (encodeText(source).length > maximumBytes) {
      throw new RangeError(label + ' is too large');
    }
    return jsonParse(source);
  }

  function normalizeState(value) {
    return jsonClone(value === undefined ? null : value, 256 * 1024, 'game state');
  }

  function normalizeCommand(raw, index) {
    if (!raw || typeof raw !== 'object' || arrayIsArray(raw)) {
      throw new TypeError('draw command ' + index + ' must be an object');
    }
    const type = raw.type;
    if (type === 'clear') {
      return { type: type, color: color(raw.color, 'color') };
    }
    if (type === 'fillRect') {
      return {
        type: type,
        x: finiteNumber(raw.x, -100000, 100000, 'x'),
        y: finiteNumber(raw.y, -100000, 100000, 'y'),
        width: finiteNumber(raw.width, -100000, 100000, 'width'),
        height: finiteNumber(raw.height, -100000, 100000, 'height'),
        color: color(raw.color, 'color'),
      };
    }
    if (type === 'strokeRect') {
      return {
        type: type,
        x: finiteNumber(raw.x, -100000, 100000, 'x'),
        y: finiteNumber(raw.y, -100000, 100000, 'y'),
        width: finiteNumber(raw.width, -100000, 100000, 'width'),
        height: finiteNumber(raw.height, -100000, 100000, 'height'),
        color: color(raw.color, 'color'),
        lineWidth: optionalLineWidth(raw.lineWidth),
      };
    }
    if (type === 'line') {
      return {
        type: type,
        x1: finiteNumber(raw.x1, -100000, 100000, 'x1'),
        y1: finiteNumber(raw.y1, -100000, 100000, 'y1'),
        x2: finiteNumber(raw.x2, -100000, 100000, 'x2'),
        y2: finiteNumber(raw.y2, -100000, 100000, 'y2'),
        color: color(raw.color, 'color'),
        lineWidth: optionalLineWidth(raw.lineWidth),
      };
    }
    if (type === 'circle') {
      const fillColor = optionalColor(raw.fillColor, 'fillColor');
      const strokeColor = optionalColor(raw.strokeColor, 'strokeColor');
      if (fillColor === null && strokeColor === null) {
        throw new TypeError('circle requires fillColor or strokeColor');
      }
      return {
        type: type,
        x: finiteNumber(raw.x, -100000, 100000, 'x'),
        y: finiteNumber(raw.y, -100000, 100000, 'y'),
        r: finiteNumber(raw.r, 0, 100000, 'r'),
        fillColor: fillColor,
        strokeColor: strokeColor,
        lineWidth: optionalLineWidth(raw.lineWidth),
      };
    }
    if (type === 'text') {
      if (typeof raw.text !== 'string' || raw.text.length > 256) {
        throw new TypeError('text must be a string of at most 256 characters');
      }
      if (raw.align !== 'left' && raw.align !== 'center' && raw.align !== 'right') {
        throw new TypeError('text align must be left, center, or right');
      }
      return {
        type: type,
        x: finiteNumber(raw.x, -100000, 100000, 'x'),
        y: finiteNumber(raw.y, -100000, 100000, 'y'),
        text: raw.text,
        color: color(raw.color, 'color'),
        size: finiteNumber(raw.size, 4, 128, 'size'),
        align: raw.align,
      };
    }
    throw new TypeError('unsupported draw command: ' + safeString(type));
  }

  function normalizeCommands(value) {
    let commands = jsonClone(value, 256 * 1024, 'draw commands');
    if (!arrayIsArray(commands)) throw new TypeError('draw must return a command list');
    const flattenedCommands = [];
    for (let index = 0; index < commands.length; index += 1) {
      const candidate = commands[index];
      if (!arrayIsArray(candidate)) {
        flattenedCommands[flattenedCommands.length] = candidate;
        continue;
      }
      const nestedCommands = candidate;
      for (let index = 0; index < nestedCommands.length; index += 1) {
        if (arrayIsArray(nestedCommands[index])) {
          throw new TypeError('nested draw command list must contain only commands');
        }
        flattenedCommands[flattenedCommands.length] = nestedCommands[index];
      }
    }
    if (flattenedCommands.length > 512) {
      throw new RangeError('draw may return at most 512 commands');
    }
    return arrayMap(flattenedCommands, normalizeCommand);
  }

  function contextMember(context, name) {
    let prototype = objectGetPrototypeOf(context);
    while (prototype !== null) {
      const descriptor = objectGetOwnPropertyDescriptor(prototype, name);
      if (descriptor) return descriptor.value || descriptor.set;
      prototype = objectGetPrototypeOf(prototype);
    }
    return null;
  }

  function createRenderer(context) {
    const methods = {};
    const methodNames = [
      'clearRect', 'fillRect', 'strokeRect', 'beginPath', 'moveTo', 'lineTo',
      'stroke', 'arc', 'fill', 'setTransform', 'fillText',
    ];
    for (let index = 0; index < methodNames.length; index += 1) {
      const name = methodNames[index];
      methods[name] = contextMember(context, name);
      if (typeof methods[name] !== 'function') throw new Error('canvas method unavailable: ' + name);
    }
    const setters = {};
    const setterNames = ['fillStyle', 'strokeStyle', 'lineWidth', 'font', 'textAlign', 'textBaseline'];
    for (let index = 0; index < setterNames.length; index += 1) {
      const name = setterNames[index];
      setters[name] = contextMember(context, name);
      if (typeof setters[name] !== 'function') throw new Error('canvas property unavailable: ' + name);
    }
    function call(name, args) { reflectApply(methods[name], context, args); }
    function set(name, value) { reflectApply(setters[name], context, [value]); }
    return {
      resize: function () {
        call('setTransform', [runtime.dpr, 0, 0, runtime.dpr, 0, 0]);
      },
      draw: function (commands) {
        for (let index = 0; index < commands.length; index += 1) {
          const command = commands[index];
          if (command.type === 'clear') {
            call('clearRect', [0, 0, runtime.width, runtime.height]);
            set('fillStyle', command.color);
            call('fillRect', [0, 0, runtime.width, runtime.height]);
          } else if (command.type === 'fillRect') {
            set('fillStyle', command.color);
            call('fillRect', [command.x, command.y, command.width, command.height]);
          } else if (command.type === 'strokeRect') {
            set('strokeStyle', command.color);
            set('lineWidth', command.lineWidth);
            call('strokeRect', [command.x, command.y, command.width, command.height]);
          } else if (command.type === 'line') {
            set('strokeStyle', command.color);
            set('lineWidth', command.lineWidth);
            call('beginPath', []);
            call('moveTo', [command.x1, command.y1]);
            call('lineTo', [command.x2, command.y2]);
            call('stroke', []);
          } else if (command.type === 'circle') {
            call('beginPath', []);
            call('arc', [command.x, command.y, command.r, 0, mathPi * 2]);
            if (command.fillColor !== null) {
              set('fillStyle', command.fillColor);
              call('fill', []);
            }
            if (command.strokeColor !== null) {
              set('strokeStyle', command.strokeColor);
              set('lineWidth', command.lineWidth);
              call('stroke', []);
            }
          } else if (command.type === 'text') {
            set('fillStyle', command.color);
            set('font', command.size + 'px sans-serif');
            set('textAlign', command.align);
            set('textBaseline', 'alphabetic');
            call('fillText', [command.text, command.x, command.y]);
          }
          }
      },
    };
  }

  function dimensions() {
    return objectFreeze({ width: runtime.width, height: runtime.height, dpr: runtime.dpr });
  }

  function frameInfo(time, dt) {
    return objectFreeze({
      dt: dt,
      time: time,
      width: runtime.width,
      height: runtime.height,
    });
  }

  function acceptState(candidate) {
    state = normalizeState(candidate === undefined ? state : candidate);
  }

  function sendHeartbeat(now) {
    if (now - lastHeartbeatAt < 1000) return;
    lastHeartbeatAt = now;
    post('heartbeat');
  }

  function scheduleFrame() {
    if (fatal || runtime === null) return;
    frameHandle = nativeSetTimeout(frame, 16);
  }

  function frame() {
    if (fatal || runtime === null) return;
    try {
      const now = nativeNow();
      const time = mathMax(0, now - startedAt);
      const dt = mathMax(0, mathMin(100, now - lastFrameAt));
      lastFrameAt = now;
      acceptState(definition.update(state, frameInfo(time, dt)));
      const commands = normalizeCommands(definition.draw(state, frameInfo(time, dt)));
      state = normalizeState(state);
      if (renderer !== null) {
        renderer.draw(commands);
        if (!firstFrameSent) {
          firstFrameSent = true;
          post('firstFrame');
        }
      } else {
        const isFirstFrame = !firstFrameSent;
        firstFrameSent = true;
        post('draw', { commands: commands, firstFrame: isFirstFrame });
      }
      sendHeartbeat(now);
      scheduleFrame();
    } catch (error) {
      fail(error);
    }
  }

  function resize(width, height, dpr) {
    runtime.width = mathRound(finiteNumber(width, 1, 4096, 'width'));
    runtime.height = mathRound(finiteNumber(height, 1, 4096, 'height'));
    const pixelRatioLimit = mathMin(4096 / runtime.width, 4096 / runtime.height);
    runtime.dpr = finiteNumber(dpr, 1, mathMin(3, pixelRatioLimit), 'dpr');
    if (runtime.canvas !== null) {
      runtime.canvas.width = mathMax(1, mathRound(runtime.width * runtime.dpr));
      runtime.canvas.height = mathMax(1, mathRound(runtime.height * runtime.dpr));
      renderer.resize();
    }
  }

  function normalizeInput(raw) {
    if (!raw || typeof raw !== 'object' || arrayIsArray(raw)) {
      throw new TypeError('input event must be an object');
    }
    if (raw.type === 'pointerDown' || raw.type === 'pointerMove' || raw.type === 'pointerUp') {
      return objectFreeze({
        type: raw.type,
        x: finiteNumber(raw.x, -100000, 100000, 'x'),
        y: finiteNumber(raw.y, -100000, 100000, 'y'),
        button: mathRound(finiteNumber(raw.button, -1, 16, 'button')),
        buttons: mathRound(finiteNumber(raw.buttons, 0, 65535, 'buttons')),
        pointerId: mathRound(finiteNumber(raw.pointerId, 0, 2147483647, 'pointerId')),
      });
    }
    if (raw.type === 'keyDown' || raw.type === 'keyUp') {
      if (typeof raw.key !== 'string' || raw.key.length > 32) throw new TypeError('key is invalid');
      if (typeof raw.code !== 'string' || raw.code.length > 64) throw new TypeError('code is invalid');
      return objectFreeze({
        type: raw.type,
        key: raw.key,
        code: raw.code,
        repeat: raw.repeat === true,
      });
    }
    if (raw.type === 'agent') {
      if (typeof raw.action !== 'string' || !regexpTest(namePattern, raw.action)) {
        throw new TypeError('agent action is invalid');
      }
      return objectFreeze({ type: 'agent', action: raw.action, data: jsonClone(raw.data, 8192, 'agent data') });
    }
    throw new TypeError('unsupported input event');
  }

  function handleMessage(event) {
    if (fatal) return;
    const message = event.data;
    try {
      if (!message || typeof message !== 'object' || arrayIsArray(message)) return;
      if (message.type === 'init' && runtime === null) {
        if (definition === null) throw new Error('Game.define must run before initialization');
        runtime = {
          canvas: message.fallback === true ? null : message.canvas,
          width: 1,
          height: 1,
          dpr: 1,
        };
        if (message.fallback !== true) {
          if (!runtime.canvas) throw new Error('OffscreenCanvas is unavailable');
          const context = runtime.canvas.getContext('2d', { alpha: true });
          if (!context) throw new Error('OffscreenCanvas 2D context is unavailable');
          renderer = createRenderer(context);
        }
        resize(message.width, message.height, message.dpr);
        state = normalizeState(definition.init(dimensions()));
        startedAt = nativeNow();
        lastFrameAt = startedAt;
        lastHeartbeatAt = startedAt;
        post('heartbeat');
        scheduleFrame();
      } else if (message.type === 'resize' && runtime !== null) {
        resize(message.width, message.height, message.dpr);
        acceptState(definition.input(state, objectFreeze({
          type: 'resize',
          width: runtime.width,
          height: runtime.height,
          dpr: runtime.dpr,
        })));
      } else if (message.type === 'input' && runtime !== null) {
        acceptState(definition.input(state, normalizeInput(message.event)));
      }
    } catch (error) {
      fail(error);
    }
  }

  function define(candidate) {
    if (definition !== null) throw new Error('Game.define may only be called once');
    if (!candidate || typeof candidate !== 'object' || arrayIsArray(candidate)) {
      throw new TypeError('Game.define expects an object');
    }
    const keys = objectKeys(candidate);
    if (keys.length !== 4 ||
        !hasOwn(candidate, 'init') ||
        !hasOwn(candidate, 'update') ||
        !hasOwn(candidate, 'draw') ||
        !hasOwn(candidate, 'input')) {
      throw new TypeError('Game.define requires exactly init, update, draw, and input');
    }
    for (let index = 0; index < keys.length; index += 1) {
      const key = keys[index];
      if (key !== 'init' && key !== 'update' && key !== 'draw' && key !== 'input') {
        throw new TypeError('Game.define contains unsupported field: ' + key);
      }
      if (typeof candidate[key] !== 'function') {
        throw new TypeError('Game.define ' + key + ' must be a function');
      }
    }
    definition = objectFreeze({
      init: candidate.init,
      update: candidate.update,
      draw: candidate.draw,
      input: candidate.input,
    });
  }

  function emit(name, payload) {
    if (typeof name !== 'string' || !regexpTest(namePattern, name)) {
      throw new TypeError('invalid game event name');
    }
    const now = nativeNow();
    const recentEmitTimes = [];
    for (let index = 0; index < emitTimes.length; index += 1) {
      if (now - emitTimes[index] < 1000) recentEmitTimes.push(emitTimes[index]);
    }
    emitTimes = recentEmitTimes;
    if (emitTimes.length >= 10) throw new RangeError('Game.emit is limited to 10 events per second');
    const data = jsonClone(payload === undefined ? null : payload, 8192, 'event payload');
    emitTimes[emitTimes.length] = now;
    post('emit', { event: name, data: data });
  }

  const gameApi = objectFreeze({ define: define, emit: emit });
  objectDefineProperty(root, 'Game', {
    value: gameApi,
    writable: false,
    configurable: false,
    enumerable: true,
  });
  nativeAddEventListener('message', handleMessage);
  nativeAddEventListener('error', function (event) { fail(event.error || event.message); });
  nativeAddEventListener('unhandledrejection', function (event) { fail(event.reason); });

  function lockedDescriptorMatches(descriptor, replacement) {
    return descriptor !== undefined &&
      hasOwn(descriptor, 'value') &&
      descriptor.value === replacement &&
      descriptor.writable === false &&
      descriptor.configurable === false;
  }

  function lockDescriptor(target, name, replacement) {
    try {
      objectDefineProperty(target, name, {
        value: replacement,
        writable: false,
        configurable: false,
      });
    } catch (_) {
      throw new Error('worker security boundary could not lock ' + name);
    }
    const descriptor = objectGetOwnPropertyDescriptor(target, name);
    if (!lockedDescriptorMatches(descriptor, replacement)) {
      throw new Error('worker security boundary did not lock ' + name);
    }
  }

  function verifyGlobalLock(name, replacement) {
    const rootDescriptor = objectGetOwnPropertyDescriptor(root, name);
    if (!lockedDescriptorMatches(rootDescriptor, replacement)) return false;
    let current = root;
    while (current !== null) {
      const descriptor = objectGetOwnPropertyDescriptor(current, name);
      if (descriptor !== undefined &&
          !lockedDescriptorMatches(descriptor, replacement)) return false;
      current = objectGetPrototypeOf(current);
    }
    return true;
  }

  function lockGlobal(name, replacement) {
    let current = root;
    let rootHadDescriptor = false;
    while (current !== null) {
      const descriptor = objectGetOwnPropertyDescriptor(current, name);
      if (descriptor !== undefined) {
        if (current === root) rootHadDescriptor = true;
        lockDescriptor(current, name, replacement);
      }
      current = objectGetPrototypeOf(current);
    }
    if (!rootHadDescriptor) lockDescriptor(root, name, replacement);
    if (!verifyGlobalLock(name, replacement)) {
      throw new Error('worker security boundary verification failed for ' + name);
    }
  }

  function lockGlobals(names, replacement) {
    for (let index = 0; index < names.length; index += 1) {
      lockGlobal(names[index], replacement);
    }
    for (let index = 0; index < names.length; index += 1) {
      if (!verifyGlobalLock(names[index], replacement)) {
        throw new Error(
          'worker security boundary recovery check failed for ' + names[index]
        );
      }
    }
  }

  function lockFunctionConstructor(constructor) {
    if (!constructor || !constructor.prototype) return;
    try {
      objectDefineProperty(constructor.prototype, 'constructor', {
        value: undefined,
        writable: false,
        configurable: false,
      });
    } catch (_) {
      throw new Error('worker security boundary could not disable dynamic code');
    }
    const descriptor = objectGetOwnPropertyDescriptor(
      constructor.prototype,
      'constructor'
    );
    if (!lockedDescriptorMatches(descriptor, undefined)) {
      throw new Error('worker security boundary left dynamic code available');
    }
  }

  function removeEventSurface() {
    lockGlobals([
      'addEventListener', 'removeEventListener', 'dispatchEvent', 'onmessage',
      'onmessageerror', 'onerror', 'onunhandledrejection',
      'onrejectionhandled',
    ], undefined);
  }

  const functionConstructors = [];
  try { functionConstructors.push(root.Function); } catch (_) {}
  try { functionConstructors.push(objectGetPrototypeOf(async function () {}).constructor); } catch (_) {}
  try { functionConstructors.push(objectGetPrototypeOf(function* () {}).constructor); } catch (_) {}
  try { functionConstructors.push(objectGetPrototypeOf(async function* () {}).constructor); } catch (_) {}
  for (const constructor of functionConstructors) {
    lockFunctionConstructor(constructor);
  }

  for (const intrinsic of [
    Object, Object.prototype, Array, Array.prototype, String, String.prototype,
    Number, Number.prototype, Boolean, Boolean.prototype, RegExp,
    RegExp.prototype, Math, JSON, Reflect, Function.prototype,
  ]) {
    try { objectFreeze(intrinsic); } catch (_) {}
  }

  removeEventSurface();
  const disabledGlobals = [
    'fetch', 'XMLHttpRequest', 'WebSocket', 'WebSocketStream', 'EventSource',
    'importScripts', 'indexedDB', 'caches', 'Cache', 'CacheStorage',
    'IDBCursor', 'IDBCursorWithValue', 'IDBDatabase', 'IDBFactory', 'IDBIndex',
    'IDBKeyRange', 'IDBObjectStore', 'IDBOpenDBRequest', 'IDBRequest',
    'IDBTransaction', 'IDBVersionChangeEvent', 'Notification',
    'StorageManager', 'FileSystemHandle', 'FileSystemFileHandle',
    'FileSystemDirectoryHandle', 'FileSystemSyncAccessHandle',
    'requestFileSystem', 'webkitRequestFileSystem', 'openDatabase',
    'sharedStorage', 'scheduler', 'Scheduler', 'TaskController', 'TaskSignal',
    'Worker', 'SharedWorker', 'BroadcastChannel', 'MessageChannel',
    'MessagePort', 'RTCPeerConnection', 'webkitRTCPeerConnection',
    'mozRTCPeerConnection', 'RTCDataChannel', 'RTCIceTransport',
    'RTCIceGatherer', 'RTCDtlsTransport', 'RTCSctpTransport',
    'RTCQuicTransport', 'WebTransport', 'OffscreenCanvas',
    'OffscreenCanvasRenderingContext2D', 'createImageBitmap', 'postMessage',
    'close', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
    'requestAnimationFrame', 'cancelAnimationFrame', 'requestIdleCallback',
    'cancelIdleCallback', 'setImmediate', 'clearImmediate', 'queueMicrotask',
    'eval', 'Function',
    'Promise', 'WebAssembly',
  ];
  lockGlobals(disabledGlobals, undefined);

  function noConsoleOutput() {}
  objectFreeze(noConsoleOutput);
  const quietConsole = objectFreeze({
    log: noConsoleOutput,
    info: noConsoleOutput,
    warn: noConsoleOutput,
    error: noConsoleOutput,
    debug: noConsoleOutput,
    trace: noConsoleOutput,
    dir: noConsoleOutput,
    table: noConsoleOutput,
    group: noConsoleOutput,
    groupEnd: noConsoleOutput,
    time: noConsoleOutput,
    timeEnd: noConsoleOutput,
    count: noConsoleOutput,
    countReset: noConsoleOutput,
    assert: noConsoleOutput,
  });
  lockGlobal('console', quietConsole);
  if (!verifyGlobalLock('console', quietConsole)) {
    throw new Error('worker security boundary left console available');
  }
  const restrictedNavigator = objectFreeze({
    sendBeacon: undefined,
    serviceWorker: undefined,
  });
  lockGlobal('navigator', restrictedNavigator);
  if (!verifyGlobalLock('navigator', restrictedNavigator)) {
    throw new Error('worker security boundary left navigator available');
  }

  nativeSetTimeout(function () { post('ready'); }, 0);
})();
''';
}
