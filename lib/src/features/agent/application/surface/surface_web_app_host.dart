import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';

/// Host-owned document for ordinary browser [SurfaceRendering.webApp] content.
///
/// The authored HTML, CSS, and JavaScript run as ordinary top-level Web
/// content. The host adds only the Surface event bridge and a visual
/// first-frame probe; it does not replace Web APIs with a drawing DSL.
class SurfaceWebAppHost {
  const SurfaceWebAppHost._();

  /// One scope for the complete assembled project, including every source
  /// file in its declared order. Static source diagnostics still use the
  /// original project.js offsets; engine script positions include this prefix.
  static const authoredScriptPrefix = '';
  static const authoredScriptSourceLineOffset = 0;

  static const String _preflightHostSuffix = '.maaso-preflight.invalid';
  static const String _visibleHostSuffix = '.maaso-visible.invalid';

  /// Stable per-project/role/session URL used only as the base of an
  /// in-memory host document. Native callbacks can use it to reject events
  /// from a superseded load without exposing a real network origin.
  ///
  /// Preflight and visible documents deliberately use different origins so
  /// authored storage writes during admission cannot mutate the real game.
  static String documentBaseUrl(
    SurfaceProject project, {
    required int lifecycleToken,
    required SurfaceWebAppDocumentRole role,
  }) {
    _requireLifecycleToken(lifecycleToken);
    final projectDigest = sha256
        .convert(utf8.encode('${role.name}:${project.id}'))
        .toString()
        .substring(0, 32);
    final hostSuffix = switch (role) {
      SurfaceWebAppDocumentRole.preflight => _preflightHostSuffix,
      SurfaceWebAppDocumentRole.visible => _visibleHostSuffix,
    };
    return 'https://$projectDigest$hostSuffix/'
        'session/$lifecycleToken/';
  }

  static bool isDocumentBaseUrl(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty) {
      return false;
    }
    final hostSuffix = uri.host.endsWith(_preflightHostSuffix)
        ? _preflightHostSuffix
        : uri.host.endsWith(_visibleHostSuffix)
        ? _visibleHostSuffix
        : null;
    if (hostSuffix == null ||
        uri.host.length != 32 + hostSuffix.length ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(uri.host.substring(0, 32))) {
      return false;
    }
    final pathMatch = RegExp(r'^/session/[1-9][0-9]*/$').firstMatch(uri.path);
    return pathMatch != null;
  }

  static bool matchesDocumentBaseUrl(String source, String expected) {
    final actualUri = Uri.tryParse(source);
    final expectedUri = Uri.tryParse(expected);
    if (actualUri == null ||
        expectedUri == null ||
        !isDocumentBaseUrl(actualUri.toString()) ||
        !isDocumentBaseUrl(expectedUri.toString())) {
      return false;
    }
    return actualUri.replace(fragment: '') == expectedUri.replace(fragment: '');
  }

  static String build(SurfaceProject project, {required int lifecycleToken}) {
    _requireLifecycleToken(lifecycleToken);
    final background = project.transparent ? 'transparent' : '#ffffff';
    // A complete authored document keeps its head order and body attributes.
    // Nesting it inside another body silently discards those attributes.
    var authoredHead = '';
    var authoredBody = project.html;
    var htmlAttributes = '';
    var bodyAttributes = '';
    if (RegExp(
      r'<(?:!doctype\s+html|html)(?:\s|>)',
      caseSensitive: false,
    ).hasMatch(project.html)) {
      final document = html_parser.parse(project.html);
      String attributes(Map<dynamic, String> values) => values.entries
          .map(
            (entry) =>
                ' ${entry.key}="${const HtmlEscape(HtmlEscapeMode.attribute).convert(entry.value)}"',
          )
          .join();
      authoredHead = document.head?.innerHtml ?? '';
      authoredBody = document.body?.innerHtml ?? '';
      htmlAttributes = attributes(document.documentElement?.attributes ?? {});
      bodyAttributes = attributes(document.body?.attributes ?? {});
    }
    final authoredScriptUrl =
        'data:text/javascript;charset=utf-8;base64,${base64Encode(utf8.encode(project.js))}';
    final authoredStyleUrl =
        'data:text/css;charset=utf-8;base64,${base64Encode(utf8.encode(project.css))}';
    final ownedScriptSources = {
      ...SurfaceRuntimeDiagnostic.mountedScriptSources(project.html),
      authoredScriptUrl: project.js,
    };
    final ownedScriptLocations = {
      for (final entry in ownedScriptSources.entries)
        entry.key: {
          'hash': SurfaceRuntimeDiagnostic.hashSource(entry.value),
          'lines':
              '\n'.allMatches(_normalizeHtmlLineEndings(entry.value)).length +
              1,
        },
    };
    var hostScript =
        '''
(function () {
  'use strict';
  var lifecycleToken = $lifecycleToken;
  var authoredFirstSourceLine = 1;
  var ownedScriptLocations = ${jsonEncode(ownedScriptLocations)};
  var canMapAuthoredSource = true;
  var NativeReferenceError = window.ReferenceError;
  var NativeTypeError = window.TypeError;
  var NativeSyntaxError = window.SyntaxError;
  var NativeRangeError = window.RangeError;
  var navigationPrefix = '${SurfaceWebAppNavigationMessage.navigationScheme}://';
  var stringifyJson = JSON.stringify.bind(JSON);
  var parseJson = JSON.parse.bind(JSON);
  var readKeys = Object.keys.bind(Object);
  var isArray = Array.isArray.bind(Array);
  var codePoints = Array.from.bind(Array);
  var isSafeInteger = Number.isSafeInteger.bind(Number);
  var isFiniteNumber = Number.isFinite.bind(Number);
  var toNumber = Number.bind(null);
  var toStringValue = String.bind(null);
  var readFloat = parseFloat;
  var min = Math.min.bind(Math);
  var max = Math.max.bind(Math);
  var encodeComponent = window.encodeURIComponent.bind(window);
  var encodeBase64 = window.btoa.bind(window);
  var decodeLegacy = window.unescape.bind(window);
  var navigateTo = window.location.assign.bind(window.location);
  var validationChannel = window.SurfaceValidationLifecycle;
  var postValidation = validationChannel &&
      typeof validationChannel.postMessage === 'function'
    ? validationChannel.postMessage.bind(validationChannel)
    : null;
  var cryptoSource = window.crypto;
  var fillRandom = cryptoSource &&
      typeof cryptoSource.getRandomValues === 'function'
    ? cryptoSource.getRandomValues.bind(cryptoSource)
    : null;
  var requestFrame = typeof window.requestAnimationFrame === 'function'
      ? window.requestAnimationFrame.bind(window)
      : function (callback) { return window.setTimeout(callback, 16); };
  var readStyle = window.getComputedStyle.bind(window);
  var readRect = Element.prototype.getBoundingClientRect;
  var elementContains = Element.prototype.contains;
  var readQueryAll = Element.prototype.querySelectorAll;
  var readQuery = Element.prototype.querySelector;
  var createElement = document.createElement.bind(document);
  var CanvasConstructor = window.HTMLCanvasElement;
  var CanvasContextConstructor = window.CanvasRenderingContext2D;
  var getCanvasContext = CanvasConstructor &&
      CanvasConstructor.prototype.getContext;
  var readCanvasPixels = CanvasContextConstructor &&
      CanvasContextConstructor.prototype.getImageData;
  var drawCanvasImage = CanvasContextConstructor &&
      CanvasContextConstructor.prototype.drawImage;
  // Test adapters may have no DOM constructors. Capture their factory once;
  // real browsers always use the native prototype methods captured above.
  var probeCanvas = null;
  var probeContext = null;
  if (!getCanvasContext || !readCanvasPixels || !drawCanvasImage) {
    try {
      probeCanvas = createElement('canvas');
      getCanvasContext = getCanvasContext || probeCanvas.getContext;
      probeContext = getCanvasContext.call(probeCanvas, '2d');
      if (probeContext) {
        readCanvasPixels = readCanvasPixels || probeContext.getImageData;
        drawCanvasImage = drawCanvasImage || probeContext.drawImage;
      }
    } catch (_) {}
  }
  var ObserverConstructor = window.MutationObserver;
  var observeMutations = ObserverConstructor &&
      ObserverConstructor.prototype.observe;
  var disconnectObserver = ObserverConstructor &&
      ObserverConstructor.prototype.disconnect;
  var scheduleInterval = window.setInterval.bind(window);
  var cancelInterval = window.clearInterval.bind(window);
  var readElementsAtPoint =
      typeof document.elementsFromPoint === 'function'
    ? document.elementsFromPoint.bind(document)
    : null;
  var ImageConstructor = typeof window.Image === 'function'
    ? window.Image
    : null;
  var backgroundImageStates = Object.create(null);
  var backgroundImageProbes = Object.create(null);
  var readySent = false;
  var fatalSent = false;
  var probePending = false;
  var observer = null;
  var probeTimer = null;
  var loadedFrames = new WeakSet();

  function createLifecycleNonce() {
    if (fillRandom === null) return null;
    try {
      var bytes = new Uint8Array(16);
      fillRandom(bytes);
      var value = '';
      for (var index = 0; index < bytes.length; index += 1) {
        value += bytes[index].toString(16).padStart(2, '0');
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  var lifecycleNonce = postValidation === null
    ? null
    : createLifecycleNonce();

  function encodePayload(value) {
    var json = stringifyJson(value);
    return encodeBase64(decodeLegacy(encodeComponent(json)))
      .replace(/\\+/g, '-')
      .replace(/\\//g, '_')
      .replace(/=+\$/g, '');
  }

  function navigateMessage(kind, payload) {
    try {
      navigateTo(navigationPrefix + kind + '?payload=' +
        encodeComponent(encodePayload(payload)));
    } catch (_) {}
  }

  if (lifecycleNonce !== null && postValidation !== null) {
    try {
      postValidation('{"version":1,"session":' + lifecycleToken +
        ',"kind":"bootstrap","nonce":"' + lifecycleNonce + '"}');
    } catch (_) {}
  }

  // Observe execution before authored scripts run. Static menu paint cannot
  // admit a document whose script failed to parse, threw, or rejected startup.
  // Keep error text, URLs, stacks and authored data out of the host channel.
  // Only a real engine ErrorEvent can supply an owned source location.
  function reportRuntimeFailure(event) {
    if (fatalSent || lifecycleNonce === null || postValidation === null) return;
    fatalSent = true;
    stopProbes();
    try {
      var diagnostic = '';
      try {
        var owned = event && ownedScriptLocations[event.filename];
        if (event && event.isTrusted === true && canMapAuthoredSource && owned &&
          isSafeInteger(event.lineno) && isSafeInteger(event.colno)) {
        var line = event.lineno - authoredFirstSourceLine + 1;
        var column = event.colno;
        if (line >= 1 && line <= owned.lines &&
            column >= 1 && column <= 8388608) {
          var error = event.error;
          var category = error instanceof NativeReferenceError ? 'reference_error'
            : error instanceof NativeTypeError ? 'type_error'
            : error instanceof NativeSyntaxError ? 'syntax_error'
            : error instanceof NativeRangeError ? 'range_error' : 'runtime_error';
          diagnostic = ',"diagnostic":' + stringifyJson({
            category: category, sourceHash: owned.hash,
            line: line, column: column
          });
        }
        }
      } catch (_) {
        // Arbitrary thrown values (including hostile proxies) cannot suppress
        // the original closed runtime failure when classification is unsafe.
        diagnostic = '';
      }
      postValidation('{"version":1,"session":' + lifecycleToken +
        ',"kind":"lifecycle","status":"fatal",' +
        '"reason":"runtime_failed","nonce":"' + lifecycleNonce + '"' +
        diagnostic + '}');
    } catch (_) {}
  }

  window.addEventListener('error', function (event) {
    var target = event && event.target;
    // Resource failures may have a working fallback. An actual unhandled
    // script exception still fails; a missing optional CDN does not.
    if (target === window) {
      reportRuntimeFailure(event);
    }
  }, true);
  window.addEventListener('unhandledrejection', reportRuntimeFailure, true);

  // Browser libraries may install normal polyfills. Probe functions were
  // captured before authored code; do not freeze the application's intrinsics.
  // These lifecycle observations do not grant native account/device authority.
  window.addEventListener('load', function (event) {
    if (event.target && event.target.tagName === 'IFRAME') {
      loadedFrames.add(event.target);
      reportFirstFrame();
    }
  }, true);

  window.Surface = {
    emit: function (event, data) {
      navigateMessage('event', {
        version: 1,
        session: lifecycleToken,
        event: toStringValue(event || ''),
        data: data === undefined ? null : data
      });
    },
    onAgent: null
  };

  window.__applyAgent = function (action, data) {
    if (typeof window.Surface.onAgent === 'function') {
      try { window.Surface.onAgent(action, data); } catch (_) {}
    }
  };

  function elementIsVisible(element) {
    if (!element || element.nodeType !== 1) return false;
    var rect;
    try {
      var current = element;
      while (current !== null) {
        var style = readStyle(current);
        if (style.display === 'none' || style.visibility === 'hidden' ||
            style.visibility === 'collapse' ||
            style.contentVisibility === 'hidden' ||
            toNumber(style.opacity) === 0 ||
            /opacity\\(\\s*(?:0(?:\\.0*)?|0%)\\s*\\)/i.test(style.filter || '') ||
            !maskAllowsPaint(style)) {
          return false;
        }
        current = current.parentElement;
      }
      rect = readRect.call(element);
    } catch (_) {
      return false;
    }
    var width = toNumber(rect.width);
    var height = toNumber(rect.height);
    if (!(width > 1 && height > 1)) return false;
    var left = toNumber(rect.left);
    var top = toNumber(rect.top);
    if (!isFiniteNumber(left)) left = 0;
    if (!isFiniteNumber(top)) top = 0;
    var right = toNumber(rect.right);
    var bottom = toNumber(rect.bottom);
    if (!isFiniteNumber(right)) right = left + width;
    if (!isFiniteNumber(bottom)) bottom = top + height;
    var documentRoot = document.documentElement;
    var viewportWidth = max(
      toNumber(window.innerWidth) || 0,
      documentRoot ? toNumber(documentRoot.clientWidth) || 0 : 0
    );
    var viewportHeight = max(
      toNumber(window.innerHeight) || 0,
      documentRoot ? toNumber(documentRoot.clientHeight) || 0 : 0
    );
    var visibleLeft = max(left, 0);
    var visibleTop = max(top, 0);
    var visibleRight = min(right, viewportWidth);
    var visibleBottom = min(bottom, viewportHeight);
    current = element.parentElement;
    while (current !== null) {
      try {
        var ancestorStyle = readStyle(current);
        var clipsX = /^(?:auto|hidden|clip|scroll)\$/.test(
          ancestorStyle.overflowX || ancestorStyle.overflow || ''
        );
        var clipsY = /^(?:auto|hidden|clip|scroll)\$/.test(
          ancestorStyle.overflowY || ancestorStyle.overflow || ''
        );
        if (clipsX || clipsY) {
          var ancestorRect = readRect.call(current);
          if (clipsX) {
            visibleLeft = max(visibleLeft, toNumber(ancestorRect.left));
            visibleRight = min(visibleRight, toNumber(ancestorRect.right));
          }
          if (clipsY) {
            visibleTop = max(visibleTop, toNumber(ancestorRect.top));
            visibleBottom = min(
              visibleBottom,
              toNumber(ancestorRect.bottom)
            );
          }
        }
      } catch (_) {
        return false;
      }
      current = current.parentElement;
    }
    if (!(viewportWidth > 1 && viewportHeight > 1 &&
        visibleRight - visibleLeft > 1 &&
        visibleBottom - visibleTop > 1)) {
      return false;
    }
    if (readElementsAtPoint === null || elementContains === undefined) {
      return true;
    }
    var insetX = min(2, (visibleRight - visibleLeft) / 4);
    var insetY = min(2, (visibleBottom - visibleTop) / 4);
    var points = [
      [(visibleLeft + visibleRight) / 2, (visibleTop + visibleBottom) / 2],
      [visibleLeft + insetX, visibleTop + insetY],
      [visibleRight - insetX, visibleTop + insetY],
      [visibleLeft + insetX, visibleBottom - insetY],
      [visibleRight - insetX, visibleBottom - insetY]
    ];
    try {
      for (var pointIndex = 0; pointIndex < points.length; pointIndex += 1) {
        var hits = readElementsAtPoint(
          points[pointIndex][0],
          points[pointIndex][1]
        );
        for (var hitIndex = 0; hitIndex < hits.length; hitIndex += 1) {
          var hit = hits[hitIndex];
          if (hit === element || elementContains.call(element, hit)) {
            return true;
          }
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  function colorPaints(value) {
    if (!value) return false;
    var normalized = toStringValue(value).replace(/\\s+/g, '').toLowerCase();
    if (normalized === 'transparent') return false;
    var hex = /^#([0-9a-f]+)\$/.exec(normalized);
    if (hex !== null) {
      if (hex[1].length === 4) return hex[1][3] !== '0';
      if (hex[1].length === 8) return hex[1].slice(6) !== '00';
      return true;
    }
    return !/^rgba\\([^)]*,(?:0(?:\\.0*)?|0%)\\)\$/.test(normalized) &&
      !/^hsla\\([^)]*,(?:0(?:\\.0*)?|0%)\\)\$/.test(normalized) &&
      !/^(?:rgb|hsl)\\([^)]*\\/(?:0(?:\\.0*)?|0%)\\)\$/.test(normalized);
  }

  function settleBackgroundImage(source, image, loaded) {
    if (backgroundImageProbes[source] !== image) return;
    delete backgroundImageProbes[source];
    var painted = loaded && image.naturalWidth > 0 && image.naturalHeight > 0;
    backgroundImageStates[source] = painted ? 'ready' : 'failed';
    if (painted) reportFirstFrame();
  }

  function startBackgroundImageProbe(source) {
    if (ImageConstructor === null || backgroundImageStates[source]) return;
    var image;
    try {
      image = new ImageConstructor();
    } catch (_) {
      backgroundImageStates[source] = 'failed';
      return;
    }
    backgroundImageStates[source] = 'loading';
    backgroundImageProbes[source] = image;
    image.onload = function () {
      settleBackgroundImage(source, image, true);
    };
    image.onerror = function () {
      settleBackgroundImage(source, image, false);
    };
    try {
      image.src = source;
      if (backgroundImageStates[source] === 'loading' && image.complete) {
        settleBackgroundImage(source, image, true);
      }
    } catch (_) {
      settleBackgroundImage(source, image, false);
    }
  }

  function loadedBackgroundUrlPaints(value) {
    var pattern = /url\\(\\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\\s*\\)/gi;
    var match;
    var painted = false;
    while ((match = pattern.exec(toStringValue(value))) !== null) {
      var source = (match[1] || match[2] || match[3] || '').trim();
      if (!source) continue;
      if (backgroundImageStates[source] === 'ready') painted = true;
      startBackgroundImageProbe(source);
    }
    return painted;
  }

  function imagePaints(value, fallbackColor) {
    if (!value || value === 'none') return false;
    var normalized = toStringValue(value).toLowerCase();
    if (/(?:repeating-)?(?:linear|radial|conic)-gradient\\(/.test(normalized)) {
      var colors = normalized.match(
        /#[0-9a-f]{3,8}\\b|(?:rgba?|hsla?)\\([^)]*\\)|\\btransparent\\b/g
      );
      if (colors === null || colors.length === 0) {
        if (colorPaints(fallbackColor)) return true;
      } else {
        for (var index = 0; index < colors.length; index += 1) {
          if (colorPaints(colors[index])) return true;
        }
      }
    }
    return loadedBackgroundUrlPaints(value);
  }

  function shadowPaints(value, fallbackColor) {
    if (!value || value === 'none') return false;
    var colors = toStringValue(value).toLowerCase().match(
      /#[0-9a-f]{3,8}\\b|(?:rgba?|hsla?)\\([^)]*\\)|\\btransparent\\b/g
    );
    if (colors === null || colors.length === 0) {
      return colorPaints(fallbackColor);
    }
    for (var index = 0; index < colors.length; index += 1) {
      if (colorPaints(colors[index])) return true;
    }
    return false;
  }

  function textPaints(style) {
    if (!style) return false;
    var fill = style.webkitTextFillColor;
    var fillPaints = !fill || fill === 'currentcolor'
      ? colorPaints(style.color)
      : colorPaints(fill);
    if (fillPaints) return true;
    var strokeWidth = readFloat(style.webkitTextStrokeWidth || '0');
    var stroke = style.webkitTextStrokeColor;
    if (!stroke || stroke === 'currentcolor') stroke = style.color;
    return strokeWidth > 0 && colorPaints(stroke);
  }

  function maskAllowsPaint(style) {
    if (!style) return false;
    var masks = [style.maskImage, style.webkitMaskImage];
    for (var index = 0; index < masks.length; index += 1) {
      var mask = masks[index];
      if (mask && mask !== 'none' && !imagePaints(mask, 'transparent')) {
        return false;
      }
    }
    return true;
  }

  function borderPaints(style, side) {
    return readFloat(style['border' + side + 'Width'] || '0') > 0 &&
      style['border' + side + 'Style'] !== 'none' &&
      style['border' + side + 'Style'] !== 'hidden' &&
      colorPaints(style['border' + side + 'Color']);
  }

  function stylePaints(style) {
    if (!style) return false;
    if (colorPaints(style.backgroundColor) ||
        imagePaints(style.backgroundImage, style.color) ||
        shadowPaints(style.boxShadow, style.color)) {
      return true;
    }
    return borderPaints(style, 'Top') || borderPaints(style, 'Right') ||
      borderPaints(style, 'Bottom') || borderPaints(style, 'Left');
  }

  function pseudoPaints(style) {
    if (stylePaints(style)) return true;
    if (!style || !style.content) return false;
    var content = toStringValue(style.content).trim();
    return content !== 'none' && content !== 'normal' &&
      content !== '""' && content !== "''" && textPaints(style);
  }

  function canvasHasPixels(canvas) {
    if (!canvas.width || !canvas.height) return false;
    try {
      if (!getCanvasContext || !drawCanvasImage || !readCanvasPixels) return false;
      var sample = createElement('canvas');
      sample.width = 32;
      sample.height = 32;
      var context = getCanvasContext.call(sample, '2d', {willReadFrequently: true});
      if (!context) return false;
      drawCanvasImage.call(context, canvas, 0, 0, sample.width, sample.height);
      var pixels = readCanvasPixels.call(context, 0, 0, sample.width, sample.height).data;
      for (var index = 0; index < pixels.length; index += 4) {
        if (pixels[index + 3] !== 0) return true;
      }
      return false;
    } catch (error) {
      // A tainted canvas can only result from content having been drawn into it.
      return error !== null && error.name === 'SecurityError';
    }
  }

  function svgHasGraphics(svg) {
    if (!readQueryAll) return false;
    var graphics = readQueryAll.call(svg,
      'circle,ellipse,image,line,path,polygon,polyline,rect,text,textPath,use'
    );
    for (var index = 0; index < graphics.length; index += 1) {
      if (elementIsVisible(graphics[index])) return true;
    }
    return false;
  }

  function nodeHasRenderedContent(node) {
    if (!elementIsVisible(node)) return false;
    var tag = node.tagName.toLowerCase();
    if (tag === 'iframe') return loadedFrames.has(node);
    if (tag === 'canvas') return canvasHasPixels(node);
    if (tag === 'svg') return svgHasGraphics(node);
    if (tag === 'img') {
      return node.complete && node.naturalWidth > 0 && node.naturalHeight > 0;
    }
    if (tag === 'picture') {
      var image = readQuery ? readQuery.call(node, 'img') : null;
      return image !== null && nodeHasRenderedContent(image);
    }
    if (tag === 'video') {
      return node.readyState >= 2 && node.videoWidth > 0 && node.videoHeight > 0;
    }
    if (tag === 'audio') return node.controls === true;
    if (tag === 'button' || tag === 'input' || tag === 'textarea' ||
        tag === 'select' || tag === 'a') {
      try {
        var controlStyle = readStyle(node);
        var label = toStringValue(
          node.value || node.textContent || node.placeholder || ''
        ).trim();
        return stylePaints(controlStyle) ||
          (label.length > 0 && textPaints(controlStyle));
      } catch (_) {
        return false;
      }
    }
    if ((node.textContent || '').trim().length > 0) {
      try {
        return textPaints(readStyle(node));
      } catch (_) {
        return false;
      }
    }
    try {
      return stylePaints(readStyle(node)) ||
        pseudoPaints(readStyle(node, '::before')) ||
        pseudoPaints(readStyle(node, '::after'));
    } catch (_) {
      return false;
    }
  }

  function hasVisibleContent() {
    var body = document.body;
    if (!body || !readQueryAll) return false;
    var nodes = readQueryAll.call(body, '*');
    for (var index = 0; index < nodes.length; index += 1) {
      if (nodeHasRenderedContent(nodes[index])) return true;
    }
    for (var child = body.firstChild; child !== null; child = child.nextSibling) {
      if (child.nodeType === 3 && child.textContent.trim().length > 0) {
        try {
          return elementIsVisible(body) && textPaints(readStyle(body));
        } catch (_) {
          return false;
        }
      }
    }
    return false;
  }

  function stopProbes() {
    if (observer !== null && disconnectObserver) disconnectObserver.call(observer);
    observer = null;
    if (probeTimer !== null) cancelInterval(probeTimer);
    probeTimer = null;
  }

  function reportFirstFrame() {
    if (readySent || fatalSent || probePending || lifecycleNonce === null ||
        postValidation === null ||
        !hasVisibleContent()) {
      return;
    }
    probePending = true;
    requestFrame(function () {
      requestFrame(function () {
        probePending = false;
        if (readySent || fatalSent ||
                !hasVisibleContent()) return;
        readySent = true;
        stopProbes();
        try {
          postValidation('{"version":1,"session":' + lifecycleToken +
            ',"kind":"lifecycle","status":"ready",' +
            '"reason":"first_frame_ready","nonce":"' +
            lifecycleNonce + '"}');
        } catch (_) {}
      });
    });
  }

  function observeDocument() {
    if (readySent || fatalSent) return;
    reportFirstFrame();
    try {
      if (ObserverConstructor && observeMutations) {
        observer = new ObserverConstructor(reportFirstFrame);
        observeMutations.call(observer, document.documentElement, {
          attributes: true,
          childList: true,
          characterData: true,
          subtree: true
        });
      }
    } catch (_) {}
    probeTimer = scheduleInterval(reportFirstFrame, 100);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', observeDocument, {once: true});
  } else {
    observeDocument();
  }
})();
''';
    // Mount exact UTF-8 source as resources rather than escaping raw HTML
    // delimiters inside JS/CSS. String.raw, regex and CSS @import retain their
    // browser semantics; diagnostic line 1 is the actual source line 1.
    // Authored Web content may use libraries, modules, assets and network
    // services. Browser origin/CORS rules still apply. The native runtime,
    // project-bundle grants and navigation authority remain separate.
    const policy =
        "default-src 'none'; "
        "script-src 'unsafe-inline' 'unsafe-eval' http: https: data: blob:; "
        "style-src 'unsafe-inline' http: https: data: blob:; "
        "img-src http: https: data: blob:; media-src http: https: data: blob:; "
        "font-src http: https: data: blob:; connect-src http: https: ws: wss: data: blob:; "
        "frame-src http: https: data: blob:; child-src http: https: data: blob:; "
        "worker-src http: https: data: blob:; object-src 'none'; "
        "base-uri 'none'; form-action 'none'";
    final policyAttribute = const HtmlEscape(
      HtmlEscapeMode.attribute,
    ).convert(policy);
    return '''<!DOCTYPE html>
<html$htmlAttributes>
<head>
<meta charset="UTF-8" />
<meta http-equiv="Content-Security-Policy" content="$policyAttribute" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
<style>
html,body{margin:0;width:100%;min-height:100%;background:$background;overflow:hidden;}
*,*::before,*::after{box-sizing:border-box;}
</style>
<link rel="stylesheet" href="$authoredStyleUrl" />
<script>$hostScript</script>
$authoredHead
</head>
<body$bodyAttributes>
$authoredBody
<script crossorigin="anonymous" src="$authoredScriptUrl"></script>
</body>
</html>
''';
  }

  static String _normalizeHtmlLineEndings(String source) =>
      source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static void _requireLifecycleToken(int lifecycleToken) {
    if (lifecycleToken <= 0) {
      throw ArgumentError.value(
        lifecycleToken,
        'lifecycleToken',
        'must be positive',
      );
    }
  }
}

enum SurfaceWebAppDocumentRole { preflight, visible }

enum SurfaceWebAppNavigationKind { event }

/// Strict, bounded authored events transported without a native channel.
///
/// A WebView navigation delegate consumes these URLs and prevents the
/// navigation. First-frame lifecycle uses a separate host-owned channel with
/// the same observable facade in preflight and visible WebViews.
class SurfaceWebAppNavigationMessage {
  const SurfaceWebAppNavigationMessage._({
    required this.kind,
    required this.payload,
  });

  static const String navigationScheme = 'maaso-surface';
  static const int maximumPayloadBytes = 8 * 1024;

  final SurfaceWebAppNavigationKind kind;
  final Map<String, Object?> payload;

  int get session => payload['session']! as int;

  String get event => payload['event']! as String;

  Object? get data => payload['data'];

  static SurfaceWebAppNavigationMessage? tryParse(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null ||
        uri.scheme != navigationScheme ||
        uri.authority != uri.host ||
        uri.path.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.queryParametersAll.length != 1 ||
        !uri.queryParametersAll.containsKey('payload')) {
      return null;
    }
    final kind = switch (uri.host) {
      'event' => SurfaceWebAppNavigationKind.event,
      _ => null,
    };
    final encodedValues = uri.queryParametersAll['payload'];
    if (kind == null || encodedValues == null || encodedValues.length != 1) {
      return null;
    }
    final encoded = encodedValues.single;
    if (encoded.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      return null;
    }

    late final List<int> bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(encoded));
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty || bytes.length > maximumPayloadBytes) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic> ||
        !_isBoundedJsonValue(decoded, depth: 0)) {
      return null;
    }
    final payload = decoded.cast<String, Object?>();
    if (payload['version'] != 1 ||
        payload['session'] is! int ||
        (payload['session']! as int) <= 0) {
      return null;
    }

    const keys = <String>{'version', 'session', 'event', 'data'};
    final event = payload['event'];
    if (payload.length != keys.length ||
        !payload.keys.every(keys.contains) ||
        event is! String ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_.:-]{0,127}$').hasMatch(event)) {
      return null;
    }

    return SurfaceWebAppNavigationMessage._(kind: kind, payload: payload);
  }

  static bool _isBoundedJsonValue(Object? value, {required int depth}) {
    if (depth > 16) return false;
    if (value == null || value is bool || value is String || value is num) {
      return true;
    }
    if (value is List) {
      return value.every((item) => _isBoundedJsonValue(item, depth: depth + 1));
    }
    if (value is Map<String, dynamic>) {
      return value.entries.every(
        (entry) => _isBoundedJsonValue(entry.value, depth: depth + 1),
      );
    }
    return false;
  }
}

enum SurfaceWebAppLifecycleKind { bootstrap, ready, fatal }

/// Authenticated lifecycle messages used by preflight and visible WebViews.
/// Authored code can observe the facade, but it cannot read the per-document
/// nonce held by the host closure.
class SurfaceWebAppLifecycleMessage {
  const SurfaceWebAppLifecycleMessage._({
    required this.kind,
    required this.session,
    required this.nonce,
    this.diagnostic,
  });

  static const int maximumMessageBytes = 1024;

  final SurfaceWebAppLifecycleKind kind;
  final int session;
  final String nonce;
  final SurfaceRuntimeDiagnostic? diagnostic;

  String get gatePayloadJson {
    if (kind == SurfaceWebAppLifecycleKind.bootstrap) {
      throw StateError('Bootstrap messages cannot be sent to the gate.');
    }
    final failed = kind == SurfaceWebAppLifecycleKind.fatal;
    return jsonEncode(<String, Object?>{
      'version': 1,
      'session': session,
      'status': failed ? 'fatal' : 'ready',
      'reason': failed ? 'runtime_failed' : 'first_frame_ready',
      if (diagnostic != null) 'diagnostic': diagnostic!.toJson(),
    });
  }

  static SurfaceWebAppLifecycleMessage? tryParse(String source) {
    if (source.isEmpty || utf8.encode(source).length > maximumMessageBytes) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['session'] is! int ||
        (decoded['session']! as int) <= 0 ||
        !_isValidSurfaceLifecycleNonce(decoded['nonce'])) {
      return null;
    }
    final kind = switch (decoded['kind']) {
      'bootstrap' => SurfaceWebAppLifecycleKind.bootstrap,
      'lifecycle' => switch ((decoded['status'], decoded['reason'])) {
        ('ready', 'first_frame_ready') => SurfaceWebAppLifecycleKind.ready,
        ('fatal', 'runtime_failed') => SurfaceWebAppLifecycleKind.fatal,
        _ => null,
      },
      _ => null,
    };
    if (kind == null) return null;
    final diagnostic = decoded.containsKey('diagnostic')
        ? SurfaceRuntimeDiagnostic.tryParse(decoded['diagnostic'])
        : null;
    if (decoded.containsKey('diagnostic') &&
        (kind != SurfaceWebAppLifecycleKind.fatal || diagnostic == null)) {
      return null;
    }
    final keys = kind == SurfaceWebAppLifecycleKind.bootstrap
        ? const <String>{'version', 'session', 'kind', 'nonce'}
        : <String>{
            'version',
            'session',
            'kind',
            'status',
            'reason',
            'nonce',
            if (diagnostic != null) 'diagnostic',
          };
    if (decoded.length != keys.length ||
        !decoded.keys.every(keys.contains) ||
        (kind == SurfaceWebAppLifecycleKind.ready &&
            (decoded['status'] != 'ready' ||
                decoded['reason'] != 'first_frame_ready'))) {
      return null;
    }
    return SurfaceWebAppLifecycleMessage._(
      kind: kind,
      session: decoded['session']! as int,
      nonce: decoded['nonce']! as String,
      diagnostic: diagnostic,
    );
  }
}

bool _isValidSurfaceLifecycleNonce(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value);
