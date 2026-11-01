// Cross-function fixture: production adapter dispatches these declared names.
// No agent.md, backend calls, native services, or domain-specific adapter code.
(() => {
  const be32 = n => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
  function png(red) {
    const raw = [0, red, 30, 40, 0, red, 30, 40, 255, 0, red, 30, 40, 128, red, 30, 40, 255];
    let a = 1, b = 0;
    for (const byte of raw) { a = (a + byte) % 65521; b = (b + a) % 65521; }
    const zlib = [120, 1, 1, raw.length, 0, 255 - raw.length, 255, ...raw, ...be32((b << 16) | a)];
    function chunk(type, data) {
      const name = [...type].map(c => c.charCodeAt(0));
      let crc = 0xffffffff;
      for (const value of [...name, ...data]) {
        crc ^= value;
        for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
      }
      return [...be32(data.length), ...name, ...data, ...be32((crc ^ 0xffffffff) >>> 0)];
    }
    return new Uint8Array([137,80,78,71,13,10,26,10,
      ...chunk('IHDR', [...be32(2), ...be32(2), 8, 6, 0, 0, 0]),
      ...chunk('IDAT', zlib), ...chunk('IEND', [])]);
  }
  Surface.registerInvocation({version: 1, actions: {
    'values.total': ({values}) => ({total: values.reduce((sum, value) => sum + value, 0)}),
    'pixels.make': ({red}) => ({maasoInvocationResultVersion: 1,
      result: {width: 2, height: 2, red}, outputs: [{producerOutputKey: 'primary', mime: 'image/png', bytes: png(red)}]}),
    'image.echo': ({image}) => {
      const input = Surface.inputImage(image);
      return {maasoInvocationResultVersion: 1, result: {byteLength: input.bytes.length},
        outputs: [{producerOutputKey: 'echo', mime: input.mime, bytes: input.bytes}]};
    },
    'network.probe': async ({url}) => {
      const denied = async fn => { try { await fn(); return false; } catch (_) { return true; } };
      const fetchRejected = await denied(() => fetch(url));
      const importScriptsRejected = await denied(() => importScripts(url));
      const dynamicImportRejected = await denied(() => import(url));
      const xhrRejected = await new Promise(resolve => {
        try { const xhr = new XMLHttpRequest(); xhr.open('GET', url); xhr.onload = () => resolve(false);
          xhr.onerror = () => resolve(true); xhr.ontimeout = () => resolve(true); xhr.timeout = 500; xhr.send();
        } catch (_) { resolve(true); }
      });
      const webSocketRejected = await new Promise(resolve => {
        try { const ws = new WebSocket(url.replace('http:', 'ws:'));
          ws.onopen = () => { ws.close(); resolve(false); }; ws.onerror = () => resolve(true);
          setTimeout(() => { ws.close(); resolve(true); }, 500);
        } catch (_) { resolve(true); }
      });
      return {fetchRejected, importScriptsRejected, dynamicImportRejected, xhrRejected, webSocketRejected,
        document: typeof document, nativeBridge: typeof MaasoInvocationBridge, webkit: typeof webkit,
        rtc: typeof RTCPeerConnection, filesystem: typeof require};
    },
    'storage.probe': async ({url, write}) => {
      const result = {cacheApi: typeof caches, serviceWorkerApi: typeof navigator.serviceWorker,
        cacheUsable: false, cacheBefore: null, cacheAfter: null, cacheError: null,
        serviceWorkerRejected: true, serviceWorkerError: 'api_unavailable'};
      try {
        if (typeof caches !== 'undefined') {
          const cache = await caches.open('maaso-invocation-probe');
          result.cacheBefore = (await cache.keys()).length;
          if (write) await cache.put(url, new Response('invocation-owned-cache'));
          result.cacheAfter = (await cache.keys()).length;
          result.cacheUsable = true;
        }
      } catch (error) { result.cacheError = String(error?.name || error); }
      if (navigator.serviceWorker) {
        try { await navigator.serviceWorker.register(url); result.serviceWorkerRejected = false; result.serviceWorkerError = null; }
        catch (error) { result.serviceWorkerError = String(error?.name || error); }
      }
      return result;
    },
    'spin.forever': () => { while (true) {} },
  }});
})();
