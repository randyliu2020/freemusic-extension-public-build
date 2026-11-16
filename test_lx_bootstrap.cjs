/* Standalone contract tests; only synthetic scripts/URLs, no network. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const bootstrap = fs.readFileSync(__dirname + '/LXBootstrap.js', 'utf8');
function harness() {
  const events = [], requests = [], cancelled = [], resolved = [], timers = new Map();
  const context = vm.createContext({__LXScriptInfo:{name:'Fixture',rawScript:'fixture'}});
  context.__LXNative = {
    send: (event, json) => events.push([event, JSON.parse(json)]),
    request: (id, url, json) => requests.push({id,url,options:JSON.parse(json)}),
    cancelHTTP: id => cancelled.push(id),
    timer: (id, delay, repeat) => timers.set(id,{delay,repeat}),
    cancelTimer: id => timers.delete(id),
    resolve: (id, url, error) => resolved.push({id,url,error}),
    codec: (operation, value, encoding) => {
      if (!['utf8','utf-8','base64','hex'].includes(encoding)) return {error:'Unsupported buffer encoding'};
      return operation === 'decode' ? {bytes:[...Buffer.from(value,encoding)]} : {value:Buffer.from(value).toString(encoding)};
    },
    crypto: (operation, args) => {
      if (operation === 'md5') return {value:crypto.createHash('md5').update(args.value).digest('hex')};
      if (operation === 'randomBytes') return {bytes:[...crypto.randomBytes(args.size)]};
      if (operation === 'aesEncrypt') {
        const cipher = crypto.createCipheriv(args.mode, Buffer.from(args.key), args.mode.endsWith('ecb') ? null : Buffer.from(args.iv));
        return {bytes:[...Buffer.concat([cipher.update(Buffer.from(args.bytes)),cipher.final()])]};
      }
      return {error:'Unsupported crypto'};
    }
  };
  vm.runInContext(bootstrap,context);
  const run = source => vm.runInContext(source,context);
  return {context,run,events,requests,cancelled,resolved,timers};
}
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  const h = harness();
  assert.equal(h.run('typeof __LXNative'), 'undefined');
  assert.equal(h.run('typeof require'), 'undefined');
  assert.equal(h.run('typeof fetch'), 'undefined');
  assert.equal(h.run('lx.env'), 'mobile');
  const extended = harness();
  assert.equal(extended.run("typeof lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']},qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}).then"),'function');
  assert.deepEqual(Object.keys(extended.events[0][1].sources),['wy']);
  assert.equal(extended.run("typeof lx.on('request',()=>Promise.resolve('https://fixture.invalid/late-handler')).then"),'function');
  assert.equal(h.run("lx.utils.buffer.bufToString(lx.utils.buffer.from('中文😀'), 'base64')"), Buffer.from('中文😀').toString('base64'));
  assert.equal(h.run("lx.utils.buffer.bufToString(lx.utils.buffer.from('e4b8ade69687', 'hex'))"), '中文');
  assert.equal(h.run("lx.utils.buffer.bufToString(new Uint8Array([0,255,128]),'hex')"),'00ff80');
  assert.equal(h.run("atob(btoa('abc\\u00ff'))"),'abcÿ');
  assert.throws(() => h.run("btoa('中文')"),/binary string/);
  assert.equal(h.run("lx.utils.crypto.md5('abc')"),'900150983cd24fb0d6963f7d28e17f72');
  assert.equal(h.run("lx.utils.crypto.randomBytes(32).length"),32);
  assert.throws(() => h.run('lx.utils.crypto.randomBytes(-1)'),/0\.\.\.65536/);
  assert.throws(() => h.run('lx.utils.crypto.rsaEncrypt()'),/Unsupported LX API/);
  assert.throws(() => h.run('lx.utils.zlib.inflate()'),/Unsupported LX API/);
  const encrypted = h.run("lx.utils.buffer.bufToString(lx.utils.crypto.aesEncrypt('hello','aes-128-ecb','0123456789abcdef',''),'hex')");
  assert.equal(encrypted,'674c7ef38e78cabd9cec9c125823a639');
  assert.equal(h.run("lx.utils.buffer.bufToString(lx.utils.crypto.aesEncrypt('hello','aes-128-cbc','0123456789abcdef','abcdef0123456789'),'hex')"),'ffcb80bec2437fc2e30b0ef0a8ec5b64');
  h.run("globalThis.cancel = lx.request('https://fixture.invalid/api',{method:'POST',body:'literal=abc&x=%20'},(e,r,b)=>{globalThis.response=[e,r,b]})");
  assert.equal(h.requests[0].options.body,'literal=abc&x=%20');
  assert.equal(h.requests[0].options.jsonBody,undefined);
  h.run("__LXHTTPDone('1','',JSON.stringify({statusCode:200,headers:{},body:{ok:true}}))");
  assert.equal(h.run('response[2].ok'),true);
  assert.equal(h.run('response[1].body === response[2]'),true);
  h.run("lx.request('https://fixture.invalid/json',{body:{hello:'world'}},()=>{})");
  assert.equal(h.requests[1].options.body,'{"hello":"world"}');
  assert.equal(h.requests[1].options.jsonBody,true);
  h.run("globalThis.cancel2=lx.request('https://fixture.invalid/cancel',{},()=>{throw Error('cancel callback must not run')});cancel2();cancel2()");
  assert.deepEqual(h.cancelled,['3']);
  h.run("__LXHTTPDone('3','',JSON.stringify({body:'ignored'}))");
  assert.throws(()=>h.run("lx.request('file:///etc/passwd',{},()=>{})"),/http\/https/);
  assert.throws(()=>h.run("lx.request('https://fixture.invalid',{formData:{}},()=>{})"),/formData/);
  assert.throws(()=>h.run("lx.request('https://fixture.invalid',{responseType:'arraybuffer'},()=>{})"),/binary HTTP response/);
  h.run("globalThis.timerValue='';globalThis.timer=setTimeout((a,b)=>timerValue=a+b,25,'a','b')");
  const timerID=h.run('timer'); assert.equal(h.timers.get(timerID).delay,25);
  h.run(`__LXTimerFire('${timerID}')`); assert.equal(h.run('timerValue'),'ab');
  h.run("lx.on(lx.EVENT_NAMES.request,({source,action,info})=>Promise.resolve('https://fixture.invalid/'+source+'/'+action+'/'+info.musicInfo.songmid+'/'+info.type));lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})");
  assert.equal(h.events[0][0],'inited');
  const payload={source:'wy',action:'musicUrl',info:{type:'128k',musicInfo:{songmid:'42'}}};
  h.context.__LXResolve('r1',JSON.stringify(payload)); await tick();
  assert.equal(h.resolved[0].url,'https://fixture.invalid/wy/musicUrl/42/128k');
  h.run("lx.send('updateAlert',{log:'update',updateUrl:'https://fixture.invalid/release'});lx.send('updateAlert',{log:'second'})");
  assert.equal(h.events.filter(e=>e[0]==='updateAlert').length,1);
  h.run("lx.on('request',()=>Promise.reject(new Error('fixture rejection')))");
  h.context.__LXResolve('r2',JSON.stringify(payload)); await tick();
  assert.equal(h.resolved[1].error,'fixture rejection');
  h.run("lx.on('request',()=>Promise.resolve('file:///bad'))");
  h.context.__LXResolve('r3',JSON.stringify(payload)); await tick();
  assert.match(h.resolved[2].error,/invalid music URL/);
  h.run("lx.on('request',()=>'https://fixture.invalid/not-promise')");
  h.context.__LXResolve('r4',JSON.stringify(payload)); await tick();
  assert.match(h.resolved[3].error,/must return a Promise/);
  h.run("lx.on('request',()=>new Promise(resolve=>{globalThis.finish=resolve}))");
  h.context.__LXResolve('r5',JSON.stringify(payload));h.context.__LXCancelResolve('r5');
  h.run("finish('https://fixture.invalid/cancelled')");await tick(); assert.equal(h.resolved.length,4);
  h.run('__LXDispose()');assert.throws(()=>h.run("lx.request('https://fixture.invalid',{},()=>{})"),/invalidated/);
  assert.throws(()=>h.run("setTimeout(()=>{},10)"),/invalidated/);
  console.log('PASS: LX bootstrap fixture contract (no real source/network)');
})().catch(error=>{console.error(error);process.exitCode=1});
