/* LX compatibility adapter. Original implementation; API signatures checked at:
 * https://lxmusic.toside.cn/mobile/custom-source
 * https://lxmusic.toside.cn/desktop/custom-source
 * This context deliberately has no file, app-cookie, credential, DOM or Node APIs.
 * It is not an execution-time/heap sandbox. Import trusted source scripts only.
 */
(function (g) {
  'use strict';
  const bridge = g.__LXNative;
  const info = g.__LXScriptInfo;
  delete g.__LXNative;
  delete g.__LXScriptInfo;
  const http = new Map(), timers = new Map(), resolutions = new Set();
  let nextID = 0, handler, disposed = false, initialized = false, alerted = false;
  const JSONParse = JSON.parse.bind(JSON), JSONStringify = JSON.stringify.bind(JSON);
  const validHTTP = value => typeof value === 'string' && /^https?:\/\/[^\s/]+/i.test(value);
  const errorText = value => value && value.message ? String(value.message) : String(value);
  const unsupported = feature => { throw new Error('Unsupported LX API: ' + feature); };
  const MAX_REQUEST_BYTES = 1024 * 1024;
  const isBytes = value => value instanceof ArrayBuffer || ArrayBuffer.isView(value) ||
    (value && value.type === 'Buffer' && Array.isArray(value.data));
  function alive() { if (disposed) throw new Error('LX source invalidated'); }
  function bytes(value, encoding) {
    if (typeof value === 'string') {
      if (encoding === 'binary') throw new Error('Binary encoding is not supported for input strings');
      // LX mobile parses every one/two-character hex group, including a final
      // nibble. Do not silently substitute Node's different truncation rule.
      if (encoding === 'hex') return Uint8Array.from(value.match(/.{1,2}/g) || [], pair => parseInt(pair,16));
      const result = bridge.codec('decode', value, encoding || 'utf8');
      if (result.error) throw new Error(result.error);
      return Uint8Array.from(result.bytes);
    }
    if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
    if (Array.isArray(value)) return Uint8Array.from(value);
    if (value && value.type === 'Buffer' && Array.isArray(value.data)) return Uint8Array.from(value.data);
    throw new TypeError('Expected string, ArrayBuffer or byte array');
  }
  function bufToString(value, encoding) {
    if (encoding === 'binary') return value;
    const result = bridge.codec('encode', Array.from(bytes(value)), encoding || 'utf8');
    if (result.error) throw new Error(result.error);
    return result.value;
  }
  function cryptoCall(kind, args) {
    const result = bridge.crypto(kind, args);
    if (result.error) throw new Error(result.error);
    return result.bytes ? Uint8Array.from(result.bytes) : result.value;
  }
  function sendSync(event, data) {
    alive();
    if (event === 'inited') {
      if (initialized) throw new Error('inited may only be sent once');
      if (!data || !data.sources || typeof data.sources !== 'object') throw new Error('Missing sources');
      const sources = {};
      for (const key of Object.keys(data.sources)) {
        // LX filters a multi-platform manifest to the host's supported sources.
        // An extra platform must not prevent its wy/tx/etc. entries from loading.
        if (!['kw','kg','tx','wy','mg','local'].includes(key)) continue;
        const s = data.sources[key];
        if (!s || s.type !== 'music' || !Array.isArray(s.actions) || !s.actions.includes('musicUrl') || !Array.isArray(s.qualitys)) throw new Error('Invalid source manifest: ' + key);
        if (s.qualitys.some(q => typeof q !== 'string' || q.length > 32)) throw new Error('Invalid quality');
        sources[key] = { name: String(s.name || key).slice(0,128), type: 'music', actions: s.actions.filter(a => a === 'musicUrl'), qualitys: s.qualitys.slice(0,32) };
      }
      if (!Object.keys(sources).length) throw new Error('No supported sources');
      initialized = true;
      bridge.send('inited', JSONStringify({sources}));
    } else if (event === 'updateAlert') {
      if (alerted) return Promise.resolve();
      if (!data || typeof data.log !== 'string') throw new Error('updateAlert.log must be a string');
      alerted = true;
      const alert = {log: data.log.slice(0,1024)};
      if (validHTTP(data.updateUrl)) alert.updateUrl = data.updateUrl.slice(0,1024);
      bridge.send(event, JSONStringify(alert));
    } else throw new Error('Unsupported LX event: ' + event);
    return Promise.resolve();
  }
  // Like LX mobile, API validation is reported as a rejected Promise. This
  // supports sources that attach .catch() to initialization/update calls.
  function send(event, data) { try { return sendSync(event,data); } catch (error) { return Promise.reject(error); } }
  function payloadBytes(value) {
    const out = bytes(value);
    if (out.byteLength > MAX_REQUEST_BYTES) throw new Error('HTTP body exceeds 1 MiB');
    return out;
  }
  function multipartParts(formData) {
    if (!formData || typeof formData !== 'object' || Array.isArray(formData)) throw new TypeError('formData must be an object');
    const parts = [];
    for (const name of Object.keys(formData)) {
      if (/[\r\n\0]/.test(name) || name.length>256) throw new Error('Invalid multipart field name');
      const entries = Array.isArray(formData[name]) ? formData[name] : [formData[name]];
      for (const entry of entries) {
        const descriptor = entry && !isBytes(entry) && typeof entry === 'object' && Object.prototype.hasOwnProperty.call(entry,'value') ? entry : {value:entry};
        const options = descriptor.options || {};
        const value = descriptor.value;
        // No file paths, streams, URIs or filesystem APIs are accepted here.
        if (value != null && typeof value === 'object' && !isBytes(value) && !Array.isArray(value)) throw new Error('Unsupported multipart value');
        const part = {name, data:bufToString(payloadBytes(isBytes(value)||Array.isArray(value) ? value : String(value ?? '')),'base64')};
        if (options.filename != null) part.filename=String(options.filename);
        if (options.contentType != null) part.contentType=String(options.contentType);
        for(const key of ['filename','contentType']) if(part[key] && (/[\r\n\0]/.test(part[key]) || part[key].length>512)) throw new Error('Invalid multipart '+key);
        parts.push(part);
        if(parts.length>128)throw new Error('Too many multipart fields');
      }
    }
    return parts;
  }
  function request(url, options, callback) {
    alive();
    if (typeof options === 'function') { callback = options; options = {}; }
    if (typeof callback !== 'function') throw new TypeError('request callback is required');
    if (!validHTTP(url)) throw new Error('Only http/https URLs are supported');
    options = options || {};
    const normalized = {method: String(options.method || 'GET'), headers: options.headers || {}, timeout: options.timeout || 13000,
      binary: options.binary === true || options.encoding === null || options.responseType === 'arraybuffer'};
    if (options.body != null) {
      if (isBytes(options.body)) normalized.bodyBase64=bufToString(payloadBytes(options.body),'base64');
      else if (typeof options.body === 'string') normalized.body = options.body;
      else if (typeof options.body === 'object') {
        normalized.body = JSONStringify(options.body);
        normalized.jsonBody = true;
      } else normalized.body=String(options.body);
    }
    if (options.form != null) normalized.form = options.form;
    if (options.formData != null) normalized.multipart = multipartParts(options.formData);
    if ([normalized.body!=null || normalized.bodyBase64!=null, normalized.form!=null, normalized.multipart!=null].filter(Boolean).length>1) throw new Error('Use only one HTTP body, form or formData');
    const id = String(++nextID);
    http.set(id, callback);
    try { bridge.request(id, url, JSONStringify(normalized)); }
    catch (e) { http.delete(id); throw e; }
    return function cancel() { if (http.delete(id)) bridge.cancelHTTP(id); };
  }
  function setTimer(callback, delay, repeat, args) {
    alive();
    if (typeof callback !== 'function') throw new TypeError('Timer callback must be a function');
    const id = String(++nextID);
    timers.set(id, {callback, args, repeat});
    bridge.timer(id, Math.max(1, Math.min(Number(delay) || 0, 2147483647)), repeat);
    return id;
  }
  function clearTimer(id) { id = String(id); if (timers.delete(id)) bridge.cancelTimer(id); }
  const lx = {
    version: '2.0.0', env: 'mobile', currentScriptInfo: Object.freeze(info || {}),
    EVENT_NAMES: Object.freeze({inited:'inited', request:'request', updateAlert:'updateAlert'}),
    on(event, callback) { try { alive(); if (event !== 'request' || typeof callback !== 'function') throw new TypeError('Only request handlers are supported'); handler = callback; return Promise.resolve(); } catch(error) { return Promise.reject(error); } },
    send, request,
    utils: Object.freeze({
      buffer: Object.freeze({from: bytes, bufToString}),
      crypto: Object.freeze({
        md5: value => { if(typeof value!=='string')throw new TypeError('param required a string'); return cryptoCall('md5', {value}); },
        aesEncrypt: (value, mode, key, iv) => cryptoCall('aesEncrypt', {bytes:Array.from(bytes(value)), mode:String(mode), key:Array.from(bytes(key)), iv:Array.from(bytes(iv || ''))}),
        randomBytes: size => { if (!Number.isInteger(size) || size < 0 || size > 65536) throw new Error('randomBytes size must be 0...65536'); return cryptoCall('randomBytes', {size}); },
        rsaEncrypt: (value, key) => { if(typeof key!=='string')throw new TypeError('Invalid RSA key'); return cryptoCall('rsaEncrypt',{bytes:Array.from(bytes(value)),key}); }
      }),
      zlib: Object.freeze({inflate: () => unsupported('zlib.inflate'), deflate: () => unsupported('zlib.deflate')})
    })
  };
  Object.defineProperty(g, 'lx', {value:Object.freeze(lx), writable:false, configurable:false});
  g.setTimeout = (fn, delay, ...args) => setTimer(fn, delay, false, args);
  g.clearTimeout = clearTimer;
  g.setInterval = (fn, delay, ...args) => setTimer(fn, delay, true, args);
  g.clearInterval = clearTimer;
  g.btoa = value => {
    value = String(value);
    if ([...value].some(c => c.charCodeAt(0) > 255)) throw new Error('btoa requires a binary string');
    return bufToString(Array.from(value, c => c.charCodeAt(0)), 'base64');
  };
  g.atob = value => Array.from(bytes(String(value), 'base64'), n => String.fromCharCode(n)).join('');
  g.console = Object.freeze({log(){}, info(){}, warn(){}, error(){}, debug(){}, trace(){}, assert(){}, clear(){}, dir(){}, dirxml(){}, table(){}, group(){}, groupCollapsed(){}, groupEnd(){}, time(){}, timeLog(){}, timeEnd(){}, count(){}, countReset(){}});
  // Native calls these only on the context's serial queue. Native state remains
  // authoritative; a source cannot gain filesystem/credential APIs by replacing them.
  Object.defineProperties(g, {
    __LXHTTPDone: {value(id, error, responseJSON) {
      const cb = http.get(id); if (!cb || disposed) return; http.delete(id);
      if (error) cb(new Error(error), null, null);
      else {
        const response = JSONParse(responseJSON);
        if (typeof response.bodyBase64 === 'string') {
          // LX mobile serializes its network Buffer through the native bridge.
          response.body={type:'Buffer',data:Array.from(bytes(response.bodyBase64,'base64'))};
          delete response.bodyBase64;
        }
        cb(null, response, response.body);
      }
    }},
    __LXTimerFire: {value(id) {
      const timer = timers.get(id); if (!timer || disposed) return;
      if (!timer.repeat) timers.delete(id);
      timer.callback(...timer.args);
    }},
    __LXResolve: {value(id, payloadJSON) {
      if (!initialized || disposed || !handler) { bridge.resolve(id, '', 'Source is not initialized'); return; }
      resolutions.add(id);
      try {
        const result = handler(JSONParse(payloadJSON));
        if (!result || typeof result.then !== 'function') throw new Error('LX request handler must return a Promise');
        Promise.resolve(result).then(url => {
          if (!resolutions.delete(id) || disposed) return;
          if (!validHTTP(url)) { bridge.resolve(id, '', 'Source returned an invalid music URL'); return; }
          bridge.resolve(id, url, '');
        }, error => { if (resolutions.delete(id) && !disposed) bridge.resolve(id, '', errorText(error)); });
      } catch (error) { if (resolutions.delete(id)) bridge.resolve(id, '', errorText(error)); }
    }},
    __LXCancelResolve: {value(id) { resolutions.delete(id); }},
    __LXDispose: {value() { disposed = true; handler = null; http.clear(); timers.clear(); resolutions.clear(); }}
  });
})(globalThis);
