(function startMaasoGameCompanionObserver(options) {
  'use strict';
  // This observer reports page data. It never invokes game or native actions.
  var root = typeof window === 'object' ? window : null;
  var doc = root && root.document;
  if (!root || !doc || !options || typeof options.send !== 'function') return null;
  var send = options.send;
  var stringify = JSON.stringify;
  var parse = JSON.parse;
  var keys = Object.keys;
  var points = Array.from;
  var encoder = typeof TextEncoder === 'function' ? new TextEncoder() : null;
  var encode = encoder && encoder.encode.bind(encoder);
  var clock = Date.now.bind(Date);
  var readStyle = typeof root.getComputedStyle === 'function' ? root.getComputedStyle.bind(root) : null;
  var schedule = typeof root.setTimeout === 'function' ? root.setTimeout.bind(root) : null;
  var cancel = typeof root.clearTimeout === 'function' ? root.clearTimeout.bind(root) : null;
  var observer = null, timer = null, disposed = false, lastText = '', lastSent = 0, revision = 0;
  var elementPrototype = root.Element && root.Element.prototype;
  var nodePrototype = root.Node && root.Node.prototype;
  var nativeAttribute = elementPrototype && elementPrototype.getAttribute;
  var nativeRect = elementPrototype && elementPrototype.getBoundingClientRect;
  var nativeText = nodePrototype && Object.getOwnPropertyDescriptor(nodePrototype, 'textContent');
  var nativeValue = nodePrototype && Object.getOwnPropertyDescriptor(nodePrototype, 'nodeValue');
  function attribute(node, name) { return nativeAttribute ? nativeAttribute.call(node, name) : node.getAttribute ? node.getAttribute(name) : null; }
  function textContent(node) { return nativeText && nativeText.get ? nativeText.get.call(node) : node.textContent; }
  function nodeValue(node) { return nativeValue && nativeValue.get ? nativeValue.get.call(node) : node.nodeValue; }
  var lastState = null, dirty = true;
  var descriptorKeys = ['version', 'name', 'summary', 'goals', 'rules', 'controls', 'stateSemantics', 'eventSemantics', 'hintScope'];

  function bytes(text) {
    if (encode) return encode(text).length;
    return unescape(encodeURIComponent(text)).length;
  }
  function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
  function text(value, limit) { return typeof value === 'string' && points(value).length <= limit; }
  function bounded(value, limit) { return points(String(value || '')).slice(0, limit).join(''); }
  function descriptor() {
    try {
      var descriptions = doc.querySelectorAll('script[type="application/json"][data-maaso-game-companion]');
      if (descriptions.length !== 1) return null;
      var node = descriptions[0];
      var source = textContent(node);
      if (typeof source !== 'string' || source.length > 3072 || bytes(source) > 3072) return null;
      var value = parse(source);
      if (!object(value) || value.version !== 1 || keys(value).some(function (key) { return descriptorKeys.indexOf(key) < 0; })) return null;
      var result = {version: 1};
      for (var key of keys(value)) {
        if (key === 'version') continue;
        var field = value[key];
        if (['name', 'summary', 'hintScope'].indexOf(key) >= 0) {
          if (!text(field, 512)) return null;
        } else if (['goals', 'rules', 'controls'].indexOf(key) >= 0) {
          if (!(text(field, 512) || (Array.isArray(field) && field.length <= 8 && field.every(function (item) { return text(item, 256); })))) return null;
        } else if (!text(field, 512)) {
          if (!object(field) || keys(field).length > 16 || keys(field).some(function (name) { return !text(name, 64) || !text(field[name], 256); })) return null;
        }
        result[key] = field;
      }
      return bytes(stringify(result)) <= 3072 ? result : null;
    } catch (_) { return null; }
  }
  function privateElement(element) {
    for (var current = element, depth = 0; current && depth < 24; current = current.parentElement, depth++) {
      var tag = String(current.tagName || '').toUpperCase();
      if (['SCRIPT', 'STYLE', 'TEMPLATE', 'NOSCRIPT', 'INPUT', 'TEXTAREA', 'SELECT'].indexOf(tag) >= 0 ||
          current.isContentEditable || attribute(current, 'data-maaso-private') !== null) return true;
    }
    return Boolean(current);
  }
  function visible(element) {
    try {
      if (!element || typeof element.getBoundingClientRect !== 'function') return false;
      for (var current = element, depth = 0; current && depth < 24; current = current.parentElement, depth++) {
        if (current.hidden || attribute(current, 'aria-hidden') === 'true') return false;
        if (readStyle) {
          var style = readStyle(current);
          if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
        }
      }
      if (current) return false;
      var rect = nativeRect ? nativeRect.call(element) : element.getBoundingClientRect();
      var width = root.innerWidth || (doc.documentElement && doc.documentElement.clientWidth) || 0;
      var height = root.innerHeight || (doc.documentElement && doc.documentElement.clientHeight) || 0;
      return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 && rect.top < height && rect.left < width;
    } catch (_) { return false; }
  }
  function visibleText() {
    if (!doc.body || typeof doc.createTreeWalker !== 'function') return '';
    var walker = doc.createTreeWalker(doc.body, 4);
    var collected = [], length = 0, scanned = 0, node;
    while (scanned++ < 240 && length < 512 && (node = walker.nextNode())) {
      var element = node.parentElement;
      if (privateElement(element) || !visible(element)) continue;
      var value = bounded(nodeValue(node), 512).replace(/\s+/g, ' ').trim();
      if (!value) continue;
      value = bounded(value, 512 - length);
      collected.push(value);
      length += points(value).length + 1;
    }
    return bounded(collected.join(' '), 512);
  }
  function controls() {
    if (typeof doc.querySelectorAll !== 'function') return [];
    var nodes = doc.querySelectorAll('button,[role="button"],a[href],input[type="button"],input[type="submit"],input[type="reset"]');
    var result = [];
    for (var index = 0; index < Math.min(nodes.length, 80) && result.length < 12; index++) {
      var node = nodes[index];
      var tag = String(node.tagName).toUpperCase();
      if (tag === 'TEXTAREA' || tag === 'SELECT' || (tag === 'INPUT' &&
          ['button', 'submit', 'reset'].indexOf(String(attribute(node, 'type') || 'text').toLowerCase()) < 0)) continue;
      if (!visible(node) || privateElement(node.parentElement) || node.isContentEditable || attribute(node, 'data-maaso-private') !== null) continue;
      var label = attribute(node, 'aria-label') || attribute(node, 'title') ||
        (String(node.tagName).toUpperCase() === 'INPUT' ? attribute(node, 'value') : textContent(node));
      label = bounded(label, 96).replace(/\s+/g, ' ').trim();
      if (!label) continue;
      result.push({label: label, role: bounded(attribute(node, 'role') || (String(node.tagName).toUpperCase() === 'A' ? 'link' : 'button'), 48)});
    }
    return result;
  }
  function capture(force) {
    if (disposed || doc.hidden) return null;
    try {
      var state = {version: 1};
      var description = descriptor(), seen = visibleText(), buttons = controls();
      if (description) state.descriptor = description;
      if (seen) state.visibleText = seen;
      if (buttons.length) state.controls = buttons;
      if (keys(state).length === 1) return null;
      var value = stringify(state), at = clock();
      // Preserve useful observations even when their combined text is too large.
      if (bytes(value) > 5700) { delete state.controls; value = stringify(state); }
      if (bytes(value) > 5700) { delete state.descriptor; value = stringify(state); }
      if (!force && value === lastText && at - lastSent < 5000) return lastState;
      var message = {kind: 'companion.snapshot', revision: revision + 1, state: state};
      if (bytes(stringify(message)) > 6144) return null;
      send(message);
      revision++; lastText = value; lastSent = at; lastState = state; dirty = false;
      return state;
    } catch (_) { return null; }
  }
  function tick() {
    timer = null;
    if (disposed) return;
    if (dirty || !observer || clock() - lastSent >= 5000) capture(false);
    if (schedule) timer = schedule(tick, 1000);
  }
  function start() {
    if (disposed) return;
    capture(false);
    if (schedule && timer === null) timer = schedule(tick, 1000);
    try {
      if (typeof root.MutationObserver === 'function' && doc.documentElement) {
        observer = new root.MutationObserver(function () { dirty = true; });
        observer.observe(doc.documentElement, {subtree: true, childList: true, characterData: true, attributes: true});
      }
    } catch (_) { observer = null; }
  }
  function dispose() {
    disposed = true;
    if (timer !== null && cancel) cancel(timer);
    timer = null;
    if (observer) observer.disconnect();
    observer = null;
    if (doc.removeEventListener) doc.removeEventListener('DOMContentLoaded', start);
  }
  var api = {capture: function () { return capture(true); }, dispose: dispose};
  if (doc.readyState === 'loading' && doc.addEventListener) doc.addEventListener('DOMContentLoaded', start, {once: true});
  else start();
  return api;
})
