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
        if(args.mode.endsWith('ecb'))cipher.setAutoPadding(false);
        return {bytes:[...Buffer.concat([cipher.update(Buffer.from(args.bytes)),cipher.final()])]};
      }
      if(operation === 'rsaEncrypt') {
        const key=crypto.createPublicKey(args.key),length=Math.ceil(key.asymmetricKeyDetails.modulusLength/8);
        if(args.bytes.length>length)return {error:'RSA NoPadding input/key size unsupported'};
        const block=Buffer.alloc(length);Buffer.from(args.bytes).copy(block,length-args.bytes.length);
        return {bytes:[...crypto.publicEncrypt({key,padding:crypto.constants.RSA_NO_PADDING},block)]};
      }
      return {error:'Unsupported crypto'};
    }
  };
  vm.runInContext(bootstrap,context);
  const run = source => vm.runInContext(source,context);
  return {context,run,events,requests,cancelled,resolved,timers};
}
const tick = () => new Promise(resolve => setImmediate(resolve));
// Independently authored authentication/failover fixture. No downloaded source,
// real endpoint, credential, or host network is evaluated by this test.
async function authenticatedQQFixture() {
  function source() {
    const h = harness();
    h.run(`
      const call = (path, headers={}) => new Promise((resolve,reject) => {
        const attempt = host => lx.request('https://' + host + '.invalid/' + path,
          {method:'GET',timeout:path==='session'?6000:8000,headers},
          (error,response) => {
            if ((error || response.statusCode >= 500) && host==='first') return attempt('second');
            if (error) return reject(error);
            const body = typeof response.body==='string' ? JSON.parse(response.body) : response.body;
            resolve(body);
          });
        attempt('first');
      });
      const session = call('session').then(body => {
        if (!body.session) throw Error('fixture session unavailable');
        return body.session;
      });
      lx.on('request',async ({source,action,info}) => {
        if(source!=='tx'||action!=='musicUrl'||!info.musicInfo.songmid) throw Error('fixture request shape');
        const key = await session;
        const body = await call('track?mid='+encodeURIComponent(info.musicInfo.songmid)+'&quality='+info.type,
          {'X-Fixture-Session':key});
        if(body.code!==200||!body.url) throw Error(body.message||'fixture no media');
        return body.url;
      });
      lx.send('inited',{sources:{tx:{type:'music',actions:['musicUrl','lyric','pic'],qualitys:['128k','320k','flac','hires']}}});
    `);
    return h;
  }
  const payload = JSON.stringify({source:'tx',action:'musicUrl',info:{type:'128k',musicInfo:{songmid:'anonymous_mid'}}});
  function done(h,index,body,statusCode=200,error='') {
    const request=h.requests[index]; assert.ok(request,'expected pending fixture request');
    h.context.__LXHTTPDone(request.id,error,JSON.stringify({statusCode,headers:{},body}));
  }
  const h=source();
  h.context.__LXResolve('a',payload);h.context.__LXResolve('b',payload);await tick();
  assert.equal(h.requests.length,1,'initializing and simultaneous requests share one pending session');
  assert.equal(h.requests[0].options.timeout,6000);
  done(h,0,{session:'anonymous-fixture-session'});await tick();
  assert.equal(h.requests.length,3);
  assert.equal(h.requests[1].options.timeout,8000);
  assert.equal(h.requests[1].options.headers['X-Fixture-Session'],'anonymous-fixture-session');
  assert.equal(h.requests[1].url,'https://first.invalid/track?mid=anonymous_mid&quality=128k');
  done(h,1,{code:200,url:'https://media.invalid/full-length.mp3'});
  done(h,2,JSON.stringify({code:403,message:'fixture verification required'}));await tick();
  assert.deepEqual(h.resolved,[{id:'a',url:'https://media.invalid/full-length.mp3',error:''},
    {id:'b',url:'',error:'fixture verification required'}]);
  assert.equal(h.requests.length,3,'business rejection is not treated as a transport retry or media success');
  h.context.__LXResolve('c',payload);await tick();
  h.context.__LXCancelResolve('c');
  done(h,3,{code:200,url:'https://media.invalid/late.mp3'});await tick();
  assert.equal(h.resolved.length,2,'cancelled resolution cannot publish a late playable URL');
  const fallback=source();fallback.context.__LXResolve('fallback',payload);await tick();
  done(fallback,0,null,0,'fixture network failure');await tick();
  assert.equal(fallback.requests[1].url,'https://second.invalid/session');
  done(fallback,1,{session:'anonymous-fixture-session'});await tick();
  done(fallback,2,{message:'fixture unavailable'},503);await tick();
  assert.match(fallback.requests[3].url,/^https:\/\/second\.invalid\/track\?/);
  done(fallback,3,{code:200,url:'https://media.invalid/backup.mp3'});await tick();
  assert.equal(fallback.resolved[0].url,'https://media.invalid/backup.mp3');
  assert.equal(fallback.requests.reduce((sum,request)=>sum+request.options.timeout,0),28000,
    'two sequential session attempts plus two parse attempts can require a 28-second outer budget');
}
(async () => {
  const h = harness();
  assert.equal(h.run('typeof __LXNative'), 'undefined');
  assert.equal(h.run('typeof require'), 'undefined');
  assert.equal(h.run('typeof fetch'), 'undefined');
  assert.equal(h.run('typeof Buffer'), 'undefined');
  assert.equal(h.run('lx.env'), 'mobile');
  assert.equal(h.run('lx.version'), '2.0.0');
  assert.equal(h.run('lx.currentScriptInfo.rawScript'),'fixture');
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
  assert.throws(() => h.run('lx.utils.crypto.rsaEncrypt()'),/Invalid RSA key/);
  assert.throws(() => h.run('lx.utils.zlib.inflate()'),/Unsupported LX API/);
  const encrypted = h.run("lx.utils.buffer.bufToString(lx.utils.crypto.aesEncrypt('0123456789abcdef','aes-128-ecb','0123456789abcdef',''),'hex')");
  assert.equal(encrypted,'72727e881edcfd0100a718687909b565');
  assert.throws(()=>h.run("lx.utils.crypto.aesEncrypt('hello','aes-128-ecb','0123456789abcdef','')"));
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
  const binary=harness();
  binary.run("lx.request('https://fixture.invalid/binary',{method:'POST',body:new Uint8Array([0,255,128]),binary:true},(e,r,b)=>{globalThis.binaryReply=[e,r,b]})");
  assert.equal(binary.requests[0].options.bodyBase64,'AP+A');
  assert.equal(binary.requests[0].options.binary,true);
  binary.context.__LXHTTPDone('1','',JSON.stringify({statusCode:200,statusMessage:'ok',headers:{},bodyBase64:'AP+A'}));
  assert.equal(binary.run('binaryReply[2].type'),'Buffer');
  assert.equal(binary.run("lx.utils.buffer.bufToString(lx.utils.buffer.from(binaryReply[2]),'hex')"),'00ff80');
  assert.equal(binary.run('binaryReply[1].body===binaryReply[2]'),true);
  assert.equal(binary.run("lx.utils.buffer.bufToString(lx.utils.buffer.from('abc','hex'),'hex')"),'ab0c');
  assert.equal(binary.run("lx.utils.buffer.bufToString(lx.utils.buffer.from('gg','hex'),'hex')"),'00');
  assert.equal(binary.run("Array.isArray(lx.utils.buffer.bufToString([1,2],'binary'))"),true);
  binary.run("lx.request('https://fixture.invalid/form',{method:'POST',formData:{text:'中文',file:{value:new Uint8Array([0,255]),options:{filename:'test.bin',contentType:'application/octet-stream'}}}},()=>{})");
  assert.deepEqual(binary.requests[1].options.multipart,[{name:'text',data:'5Lit5paH'},{name:'file',data:'AP8=',filename:'test.bin',contentType:'application/octet-stream'}]);
  assert.throws(()=>binary.run("lx.request('https://fixture.invalid/form',{formData:{file:{uri:'file:///private'}}},()=>{})"),/Unsupported multipart/);
  assert.throws(()=>binary.run("lx.request('https://fixture.invalid/form',{formData:{'bad\\r\\nheader':'value'}},()=>{})"),/Invalid multipart/);
  assert.throws(()=>binary.run("lx.request('https://fixture.invalid/form',{body:'a',form:{}},()=>{})"),/only one/);
  assert.throws(()=>binary.run("lx.request('https://fixture.invalid/form',{body:new Uint8Array(1048577)},()=>{})"),/1 MiB/);
  assert.throws(()=>binary.run("lx.utils.crypto.md5(123)"),/string/);
  await assert.rejects(binary.run("lx.on('unsupported',()=>{})"),/Only request/);
  await assert.rejects(binary.run("lx.send('unsupported',{})"),/Unsupported LX event/);
  assert.doesNotThrow(()=>binary.run("console.group('fixture');console.table({a:1});console.time('x');console.timeEnd('x');console.groupEnd()"));
  const publicKey='-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCVSng5pQU3K5uc/BhOVIJaQCwWo4wAFYuGnSKtBC940NyvpvwXdyoWCVYjvoA694YjeT89VjBw4Ytt78l0PLbqsughA4uGmDzSQdiYFld614S+vlVwM+CZMPIYoCiEN+xi2saoN5Rd4zMJyNbg0ArZk74YlrgVOaVQonToT+crxwIDAQAB\n-----END PUBLIC KEY-----';
  binary.context.fixturePublicKey=publicKey;
  assert.equal(binary.run("lx.utils.buffer.bufToString(lx.utils.crypto.rsaEncrypt('LX RSA fixture',fixturePublicKey),'hex')"),'5e5519516031099dfe498ea0bcddf9dd9bda08341df240d2c88881dc9e280a1a5c34f28250d424036e5a21cbc37a40b9e7a8cedd157630544268858b3731490805412ffa1b52a8b7f159dc89a97a18e75504264f285e9e57d29a28ffd043efc6521cfa45275090786b71425a0a0d2fe92f9ca4448405d9875ae017bac1bc03ff');
  assert.throws(()=>binary.run("lx.utils.crypto.rsaEncrypt(new Uint8Array(129),fixturePublicKey)"),/size/);
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
  await authenticatedQQFixture();
  console.log('PASS: LX bootstrap fixture contract (no real source/network)');
})().catch(error=>{console.error(error);process.exitCode=1});
