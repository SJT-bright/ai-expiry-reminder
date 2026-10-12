'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {DatabaseSync} = require('node:sqlite');
const {Store,nextRoll,timingAllowed,isDisplayable,weeklyPlan,DAY,WEEK} = require('../core');
const {ratePools,jwtClaims,readAll,tail} = require('../readers');
const now = Math.floor(Date.now()/1000);
function setup(t) { const dir = fs.mkdtempSync(path.join(os.tmpdir(),'ar-test-')); const store = new Store(dir); t.after(() => { try { store.close(); } catch {} fs.rmSync(dir,{recursive:true,force:true}); }); return {store,dir}; }
const item = (patch = {}) => ({name:'订阅',vendor:'厂商',expires_at:now+DAY*30,...patch});
test('manual records and reminder settings survive reopen', t => {
  const {store,dir} = setup(t); const id = store.save(item()); store.setHours(id,51,store.item(id)); store.saveState({displayHorizonDays:90}); store.close();
  const reopened = new Store(dir); assert.equal(reopened.item(id).name,'订阅'); assert.equal(reopened.hours(id),51); assert.equal(reopened.state.displayHorizonDays,90); reopened.close();
});
test('rolling uses the original anchor even after multiple missed periods', () => {
  const anchor = now-3*WEEK-300; const window = item({kind:'window',expires_at:anchor,repeat_hours:168});
  assert.equal(nextRoll(window,now),anchor+4*WEEK); assert.equal(nextRoll({...window,expires_at:now},now),now+WEEK);
  assert.equal(nextRoll({...window,repeat_hours:0},now),null); assert.equal(nextRoll({...window,archived_at:now},now),null);
});
test('calendar monthly reset clamps short months and preserves original reset day', () => {
  const stamp = new Date(2026,1,15,12).getTime()/1000;
  const window = item({kind:'window',reset_rule:'calendarMonth',reset_param:31});
  assert.equal(nextRoll(window,stamp),new Date(2026,1,28).getTime()/1000);
  assert.equal(nextRoll(window,new Date(2026,1,28,1).getTime()/1000),new Date(2026,2,31).getTime()/1000);
  assert.equal(nextRoll({...window,reset_param:32},stamp),null);
});
test('weekly calendar resets cross year boundaries at local midnight', () => {
  const stamp = new Date(2026,11,31,23).getTime()/1000;
  const expected = new Date(2027,0,4).getTime()/1000;
  assert.equal(nextRoll(item({kind:'window',reset_rule:'calendarWeek',reset_param:1}),stamp),expected);
});
test('timing rejects zero, fractional hours, and intervals equal to cycle', () => {
  const window = item({kind:'window',repeat_hours:5});
  assert.equal(timingAllowed(window,2),true); assert.equal(timingAllowed(window,5),false); assert.equal(timingAllowed(window,0),false); assert.equal(timingAllowed(window,2.1),false);
});
test('weekly split uses first reset, skips expired rounds, and retains distant rounds', t => {
  const {store} = setup(t); const ids = store.saveWeekly(item({expires_at:now+15*WEEK}),now-2*WEEK,now);
  assert.equal(ids.length,15); assert.equal(store.item(ids[0]).expires_at,now+WEEK); assert.equal(store.item(ids.at(-1)).expires_at,now+15*WEEK);
  assert.equal(new Set(store.items().map(r => r.group_id)).size,1);
});
test('weekly split validates limits instead of truncating', () => {
  assert.throws(() => weeklyPlan(now+521*WEEK,now),/520/); assert.throws(() => weeklyPlan(now-1,now),/首次/); assert.throws(() => weeklyPlan(now-2*WEEK,now-3*WEEK,now),/未来/);
});
test('weekly conversion deletes old group only after all writes can succeed', t => {
  const {store} = setup(t); const ids = store.saveWeekly(item({expires_at:now+4*WEEK}),now+WEEK,now); const before = store.items();
  store.db.exec("CREATE TRIGGER fail_week BEFORE INSERT ON items WHEN NEW.name LIKE '%第2/%' BEGIN SELECT RAISE(ABORT,'injected'); END;");
  assert.throws(() => store.saveWeekly(item({id:ids[0],expires_at:now+8*WEEK}),now+WEEK,now),/injected/);
  assert.deepEqual(store.items(),before);
});
test('editing first weekly date shifts later weeks and derived window atomically', t => {
  const {store} = setup(t); const ids = store.saveWeekly(item({expires_at:now+4*WEEK}),now+WEEK,now);
  store.save(item({id:'qreset:'+ids[1],kind:'window',repeat_hours:168,expires_at:now+2*WEEK}));
  store.save({...store.item(ids[0]),expires_at:now+WEEK+3600});
  assert.equal(store.item(ids[1]).expires_at,now+2*WEEK+3600); assert.equal(store.item('qreset:'+ids[1]).expires_at,now+2*WEEK+3600);
});
test('failed group alignment rolls back parent and siblings', t => {
  const {store} = setup(t); const ids = store.saveWeekly(item({expires_at:now+3*WEEK}),now+WEEK,now); const before = store.items();
  store.db.exec(`CREATE TRIGGER fail_align BEFORE UPDATE ON items WHEN NEW.id='${ids[1]}' BEGIN SELECT RAISE(ABORT,'alignment failed'); END;`);
  assert.throws(() => store.save({...store.item(ids[0]),expires_at:now+WEEK+3600}),/alignment failed/); assert.deepEqual(store.items(),before);
});
test('one-off records never generate a guessed companion', t => { const {store} = setup(t); store.save(item({name:'Grok'})); assert.equal(store.items().length,1); });
test('deleting a record and derived window preserves unrelated records and settings', t => {
  const {store,dir} = setup(t); const id = store.save(item()); const other = store.save(item({name:'保留'})); store.save(item({id:'qreset:'+id,kind:'window',repeat_hours:168})); store.setHours(id,10,store.item(id));
  store.delete(id); assert.equal(store.items().length,1); assert.equal(store.item(other).name,'保留'); assert.equal(store.hours(id),5);
  const backup = path.join(dir,'backups',fs.readdirSync(path.join(dir,'backups'))[0]); const db = new DatabaseSync(backup,{readOnly:true}); assert.equal(db.prepare('SELECT COUNT(*) AS n FROM items').get().n,3); db.close();
});
test('archive and purge retain malformed windows, rolling windows remain active', t => {
  const {store} = setup(t); const id = store.save(item({expires_at:now-4*DAY})); store.save(item({name:'滚动',kind:'window',expires_at:now-8*DAY,repeat_hours:168}));
  store.db.prepare('INSERT INTO items(id,name,kind,source,expires_at) VALUES(?,?,?,?,?)').run('broken','规则残缺','window','manual',now-4*DAY);
  store.lifecycle(now); assert.ok(store.item(id).archived_at); assert.ok(store.item('broken').archived_at); assert.ok(store.items().find(r => r.name==='滚动').expires_at>now);
  store.lifecycle(now+31*DAY); assert.equal(store.item(id),null); assert.ok(store.item('broken'));
});
test('lifecycle rolls used percentage into unknown and keeps anchor phase', t => {
  const {store} = setup(t); const id = store.save(item({kind:'window',expires_at:now-100,repeat_hours:5,used_percent:100})); store.lifecycle(now);
  assert.equal(store.item(id).expires_at,now-100+5*3600); assert.equal(store.item(id).used_percent,null);
});
test('import validates entire batch before writing and can restore a backup', t => {
  const {store,dir} = setup(t); const id = store.save(item()); const data = store.exportData();
  assert.throws(() => store.importData({...data,items:[...data.items,{name:'坏数据',expires_at:NaN}]}),/有效/); assert.equal(store.items().length,1);
  const backup = store.backup(); store.delete(id); assert.equal(store.importSQLite(backup),1); assert.equal(store.item(id).name,'订阅'); assert.ok(fs.existsSync(path.join(dir,'data.sqlite')));
});
test('import failed write leaves all existing records intact', t => {
  const {store} = setup(t); store.save(item()); const before = store.items(); store.db.exec("CREATE TRIGGER fail_import BEFORE INSERT ON items WHEN NEW.name='拒绝' BEGIN SELECT RAISE(ABORT,'blocked'); END;");
  assert.throws(() => store.importData({format:'ai-expiry-reminder',items:[item({id:'valid'}),item({id:'bad',name:'拒绝'})]}),/blocked/); assert.deepEqual(store.items(),before);
});
test('official record edits are rejected and custom official timing is independent', t => {
  const {store} = setup(t); assert.throws(() => store.save(item({id:'auto:codex:window'})),/官方/);
  const official = item({id:'auto:codex:window',kind:'window',repeat_hours:5}); store.setHours(official.id,2,official); assert.equal(store.hours(official.id),2); assert.equal(store.items().length,0);
});
test('state range invalid input never changes saved state', t => {
  const {store} = setup(t); assert.throws(() => store.saveState({displayHorizonDays:0})); assert.equal(store.state.displayHorizonDays,40); assert.throws(() => store.saveState({displayHorizonDays:1.5}));
});
test('legacy JSON migration retains malformed source rows across settings save', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'ar-legacy-')); t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  fs.writeFileSync(path.join(dir,'state.json'),JSON.stringify({manualItems:[{id:'old',name:'旧订阅',expiresAt:new Date((now+DAY)*1000).toISOString()},{id:'bad',name:'缺日期'}]}));
  const store = new Store(dir); assert.equal(store.items().length,1); store.saveState({panelCollapsed:false}); assert.equal(JSON.parse(fs.readFileSync(path.join(dir,'state.json'))).manualItems[0].id,'bad'); store.close();
});
test('malformed existing state fails without overwriting original file', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'ar-corrupt-')); t.after(() => fs.rmSync(dir,{recursive:true,force:true})); const file = path.join(dir,'state.json'); fs.writeFileSync(file,'INVALID');
  assert.throws(() => new Store(dir)); assert.equal(fs.readFileSync(file,'utf8'),'INVALID');
});
test('rate parser ignores null and quoted fake JSON, accepts numeric strings', () => {
  const fake = JSON.stringify({payload:{rate_limits:null,other:{resets_at:now,window_minutes:300}}});
  const real = JSON.stringify({payload:{rate_limits:{limit_id:'pool',limit_name:'模型',primary:{resets_at:String(now+3600),window_minutes:'300',used_percent:null},secondary:null}}});
  const quoted = JSON.stringify({message:'"rate_limits": {"primary":{"resets_at":123,"window_minutes":300}}'});
  const pools = ratePools([fake,real,quoted].join('\n')); assert.equal(pools.length,1); assert.equal(pools[0].windows[0].used,null); assert.equal(pools[0].windows[0].minutes,300);
});
test('same pool uses complete latest report without combining old windows', () => {
  const entry = value => JSON.stringify({rate_limits:{limit_id:'codex',...value}});
  const pools = ratePools([entry({primary:{resets_at:now+1,window_minutes:300},secondary:{resets_at:now+WEEK,window_minutes:10080}}),entry({secondary:{resets_at:now+2*WEEK,window_minutes:10080}})].join('\n'));
  assert.equal(pools[0].windows.length,1); assert.equal(pools[0].windows[0].reset,now+2*WEEK);
});
test('JWT base64url round trip and invalid token rejection', () => {
  const expected = {'https://api.openai.com/auth':{chatgpt_plan_type:'pro',extra:'中文>>'}};
  assert.deepEqual(jwtClaims('x.'+Buffer.from(JSON.stringify(expected)).toString('base64url')+'.y'),expected); assert.equal(jwtClaims('not-a-token'),null);
});
test('tail reader drops only partial first line and preserves multibyte text', async t => {
  const {dir} = setup(t); const file = path.join(dir,'sample.jsonl'); fs.writeFileSync(file,'x'.repeat(100)+'\n'+JSON.stringify({text:'中文尾部'})+'\n'); const text = await tail(file,45); assert.ok(text.includes('中文尾部')); assert.doesNotThrow(() => JSON.parse(text.trim()));
});
test('missing local readers produce statuses and never invent expiry', async t => { const {dir} = setup(t); const result = await readAll(dir,now); assert.equal(result.items.length,0); assert.equal(result.statuses.length,4); });
test('local source read is read-only and expired rate window remains explicitly pending', async t => {
  const {dir} = setup(t); fs.mkdirSync(path.join(dir,'.codex/sessions'),{recursive:true}); const auth = path.join(dir,'.codex/auth.json'), session = path.join(dir,'.codex/sessions/sample.jsonl');
  fs.writeFileSync(auth,JSON.stringify({tokens:{id_token:'x.'+Buffer.from(JSON.stringify({'https://api.openai.com/auth':{chatgpt_plan_type:'pro',chatgpt_subscription_active_until:new Date((now+DAY)*1000).toISOString()}})).toString('base64url')+'.y'}}));
  fs.writeFileSync(session,JSON.stringify({payload:{rate_limits:{primary:{resets_at:now-60,window_minutes:300,used_percent:99}}}})+'\n');
  const before = fs.readFileSync(session); const result = await readAll(dir,now); const window = result.items.find(r => r.kind==='window'); assert.equal(window.used_percent,null); assert.match(window.note,/等待/); assert.deepEqual(fs.readFileSync(session),before);
});
test('display grace and archive apply consistently', () => { assert.equal(isDisplayable(item({expires_at:now-4*DAY}),now),false); assert.equal(isDisplayable(item({expires_at:now-2*DAY}),now),true); assert.equal(isDisplayable(item({archived_at:now}),now),false); });
