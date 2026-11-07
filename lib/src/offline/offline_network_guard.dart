/// Installed by the native WebView before authored code in every frame.
/// CSP still blocks ordinary requests; this closes non-CSP WebRTC transports.
/// The same source is pinned in the Android fork's offline-only constructor.
const offlineNetworkGuardScript = r'''
(function() {
  'use strict';
  const define = Object.defineProperty;
  const own = Object.getOwnPropertyDescriptor;
  const parent = Object.getPrototypeOf;
  const call = Reflect.apply;
  const seen = new WeakSet();
  const blocked = ['RTCPeerConnection','webkitRTCPeerConnection','mozRTCPeerConnection','RTCDataChannel','WebTransport','RTCIceGatherer','RTCIceTransport','RTCDtlsTransport','RTCSctpTransport','RTCRtpSender','RTCRtpReceiver'];
  function seal(target, name) {
    try { define(target, name, {value:undefined,writable:false,configurable:false}); } catch (_) {}
  }
  function guardFrameGetter(proto, name, isDocument) {
    if (!proto) return;
    const descriptor = own(proto, name);
    if (!descriptor || !descriptor.get || !descriptor.configurable) return;
    const getter = descriptor.get;
    try {
      define(proto, name, {enumerable:descriptor.enumerable,configurable:false,get:function() {
        const value = call(getter, this, []);
        try { protect(isDocument ? value && value.defaultView : value); } catch (_) {}
        return value;
      }});
    } catch (_) {}
  }
  function protect(frame) {
    if (!frame || seen.has(frame)) return;
    seen.add(frame);
    for (const name of blocked) {
      let target = frame;
      while (target) {
        try { if (own(target, name)) seal(target, name); target = parent(target); }
        catch (_) { break; }
      }
      seal(frame, name);
    }
    try {
      for (const type of [frame.HTMLIFrameElement,frame.HTMLFrameElement]) {
        if (!type) continue;
        guardFrameGetter(type.prototype, 'contentWindow', false);
        guardFrameGetter(type.prototype, 'contentDocument', true);
      }
      if (frame.Document) guardFrameGetter(frame.Document.prototype, 'defaultView', false);
    } catch (_) {}
  }
  protect(window);
})();
''';
