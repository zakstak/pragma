#!/usr/bin/env bash
# Resolve persistent cache settings and publish group-readable receipts.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$PRAGMA_DIR" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawnSync} = require('node:child_process');
const pragma = process.argv[2];
const {cacheAccess,prepareCache,shareReceipt} = require(`${pragma}/lib/shadow-cache.js`);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(),'pragma-shared-cache-'));
const repo = path.join(temporary,'repo');
const shared = path.join(temporary,'shared cache');
const systemConfig = path.join(temporary,'system.gitconfig');
fs.mkdirSync(repo); fs.mkdirSync(shared);
fs.chmodSync(shared,0o3770);
const env = {...process.env,GIT_CONFIG_SYSTEM:systemConfig,GIT_CONFIG_GLOBAL:path.join(temporary,'global.gitconfig'),GIT_CONFIG_NOSYSTEM:'0',PRAGMA_SHADOW_CACHE_DIR:'',PRAGMA_SHADOW_SHARED:''};
function command(program,args,extra={}) {
  const result = spawnSync(program,args,{cwd:repo,env:{...env,...extra},encoding:'utf8'});
  assert.equal(result.status,0,result.stderr+result.stdout);
  return result.stdout.trim();
}
function git(args){return command('git',args);}
function capture(extra={}) {
  const receiptFile=path.join(temporary,`receipt-${Math.random()}`);
  command(process.execPath,[`${pragma}/lib/shadow.js`,'npm',receiptFile,'required'],extra);
  return fs.readFileSync(receiptFile,'utf8');
}
function collect(args=[],extra={}) {
  return JSON.parse(command(process.execPath,[`${pragma}/tools/collect-shadow.js`,...args],extra));
}
try {
  git(['init','-q']);
  git(['config','user.name','Fixture']); git(['config','user.email','fixture@example.invalid']);
  git(['config','commit.gpgsign','false']);
  fs.writeFileSync(path.join(repo,'package.json'),JSON.stringify({name:'cache-fixture',scripts:{typecheck:'node -e "console.log(123)"','typecheck:shadow':'node -e "console.log(123)"'}}));
  fs.writeFileSync(path.join(repo,'tsconfig.json'),'{}\n');
  git(['add','.']); git(['-c','core.hooksPath=/dev/null','commit','-qm','fixture']);
  const privateReceipt=capture();
  assert.equal(fs.statSync(privateReceipt).mode&0o777,0o700);
  assert.equal(fs.statSync(path.join(privateReceipt,'summary.json')).mode&0o777,0o600);
  assert.equal(JSON.parse(fs.readFileSync(path.join(privateReceipt,'metadata.json'))).cache_access.mode,'private');
  console.log('PASS: default receipts retain private directory and file permissions');
  git(['config','--file',systemConfig,'pragma.shadowCacheDir',shared]);
  git(['config','--file',systemConfig,'pragma.shadowCacheShared','true']);
  const sharedReceipt=capture();
  function inspect(directory) {
    for(const entry of fs.readdirSync(directory,{withFileTypes:true})) {
      const location=path.join(directory,entry.name); const status=fs.lstatSync(location);
      assert.equal(status.gid,fs.statSync(shared).gid);
      if(entry.isDirectory()){assert.equal(status.mode&0o7777,0o2750);inspect(location);}
      else assert.equal(status.mode&0o777,0o640,location);
    }
  }
  assert.equal(fs.statSync(sharedReceipt).mode&0o7777,0o2750); inspect(sharedReceipt);
  const summary=JSON.parse(fs.readFileSync(path.join(sharedReceipt,'summary.json')));
  assert.equal(summary.cache_access.mode,'shared-group');
  assert.equal(summary.cache_access.source,'pragma.shadowCacheDir');
  assert.equal(collect().runs.length,1);
  assert.equal(collect(['--repo',repo]).runs.length,1);
  assert.equal(collect(['--cache',path.dirname(privateReceipt)]).runs.length,1);
  console.log('PASS: system Git setting routes captures and collectors to the same group-readable cache');
  const local=path.join(temporary,'local cache'); fs.mkdirSync(local);fs.chmodSync(local,0o3770);
  git(['config','pragma.shadowCacheDir',local]);
  const localReceipt=capture();assert.equal(path.dirname(localReceipt),local);
  const override=path.join(temporary,'environment cache');
  const overrideReceipt=capture({PRAGMA_SHADOW_CACHE_DIR:override,PRAGMA_SHADOW_SHARED:'0'});
  assert.equal(path.dirname(overrideReceipt),override);
  assert.equal(fs.statSync(overrideReceipt).mode&0o777,0o700);
  assert.equal(collect([],{PRAGMA_SHADOW_CACHE_DIR:override}).runs.length,1);
  console.log('PASS: repository settings override system settings; environment settings override both');
  git(['config','pragma.shadowCacheDir','relative/path']);
  const invalid=spawnSync(process.execPath,[`${pragma}/lib/shadow.js`,'npm',path.join(temporary,'invalid'),'required'],{cwd:repo,env,encoding:'utf8'});
  assert.notEqual(invalid.status,0);assert.match(invalid.stderr,/absolute directory path/);
  git(['config','--unset','pragma.shadowCacheDir']);
  for(const mode of [0o0770,0o2770,0o3777]) {
    fs.chmodSync(local,mode);assert.throws(()=>prepareCache(local,true),/mode 3770/);
  }
  assert.throws(()=>prepareCache(path.join(temporary,'absent'),true),/must already exist/);
  assert.equal(fs.existsSync(path.join(temporary,'absent')),false);
  const settings=JSON.parse(command(process.execPath,['-e','const {resolveCache,cacheAccess}=require(process.argv[1]); console.log(JSON.stringify({...resolveCache(process.cwd()),...cacheAccess(process.cwd())}));',`${pragma}/lib/shadow-cache.js`]));
  assert.equal(settings.directory,shared);
  assert.equal(settings.shared,true);
  assert.throws(()=>cacheAccess(repo,{PRAGMA_SHADOW_SHARED:'maybe'}),/must be/);
  console.log('PASS: invalid shared permissions and configuration fail before creating receipts');
  const external=path.join(temporary,'external');fs.writeFileSync(external,'untouched');fs.chmodSync(external,0o600);
  const link=path.join(sharedReceipt,'external-link');fs.symlinkSync(external,link);
  shareReceipt(sharedReceipt,fs.statSync(shared).gid);
  assert.equal(fs.statSync(external).mode&0o777,0o600);
  assert.equal(fs.statSync(shared).mode&0o7777,0o3770);
  assert.equal(fs.statSync(privateReceipt).mode&0o777,0o700);
  fs.linkSync(external,path.join(sharedReceipt,'hard-link'));
  assert.throws(()=>shareReceipt(sharedReceipt,fs.statSync(shared).gid),/hard-linked artifact/);
  assert.equal(fs.statSync(external).mode&0o777,0o600);
  console.log('PASS: publishing sharing leaves linked targets, private receipts, and cache permissions untouched');
} finally {fs.rmSync(temporary,{recursive:true,force:true});}
JS
