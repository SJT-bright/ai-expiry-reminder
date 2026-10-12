'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const DAY = 86400, WEEK = 7 * DAY, MAX_ROUNDS = 520;
const COLUMNS = ['id','name','vendor','kind','expires_at','repeat_hours','source','note','used_percent','group_id','created_at','updated_at','reset_rule','reset_param','purchase_at','archived_at'];
const seconds = () => Date.now() / 1000;
const numeric = v => v !== null && v !== undefined && v !== '' && typeof v !== 'boolean' && Number.isFinite(Number(v)) ? Number(v) : null;
const uid = () => crypto.randomUUID().toUpperCase();
function nextRoll(item, now) {
  if (item.kind !== 'window' || item.archived_at != null) return null;
  if (['calendarMonth','calendarWeek','anchorMonth'].includes(item.reset_rule)) {
    const param = numeric(item.reset_param), date = new Date(now * 1000);
    if (!Number.isInteger(param) || param < 1 || param > (item.reset_rule === 'calendarWeek' ? 7 : 31)) return null;
    if (item.reset_rule === 'calendarWeek') {
      let shift = (param - (date.getDay() || 7) + 7) % 7 || 7;
      return new Date(date.getFullYear(), date.getMonth(), date.getDate() + shift).getTime() / 1000;
    }
    for (let offset = 0; offset < 25; offset++) {
      const last = new Date(date.getFullYear(), date.getMonth() + offset + 1, 0).getDate();
      const next = new Date(date.getFullYear(), date.getMonth() + offset, Math.min(param, last)).getTime() / 1000;
      if (next > now) return next;
    }
    return null;
  }
  const hours = numeric(item.repeat_hours), anchor = numeric(item.expires_at);
  if (hours === null || hours <= 0 || anchor === null) return null;
  const interval = hours * 3600;
  const result = anchor > now ? anchor : anchor + (Math.floor((now - anchor) / interval) + 1) * interval;
  return Number.isFinite(result) && result > now ? result : null;
}
function timingAllowed(item, hours) {
  if (!Number.isInteger(hours) || hours < 1 || hours > 3650 * 24 + 23) return false;
  if (item.kind !== 'window') return true;
  if (item.reset_rule === 'calendarWeek') return hours < 168;
  if (['calendarMonth','anchorMonth'].includes(item.reset_rule)) {
    const date = new Date(item.expires_at * 1000), day = date.getDate();
    const last = new Date(date.getFullYear(), date.getMonth(), 0).getDate();
    const previous = new Date(date.getFullYear(), date.getMonth() - 1, Math.min(day, last), date.getHours(), date.getMinutes(), date.getSeconds());
    return hours * 3600 < item.expires_at - previous.getTime() / 1000;
  }
  const period = numeric(item.repeat_hours);
  return period === null || period <= 0 || hours < period;
}
function isDisplayable(item, now = seconds()) {
  return item.archived_at == null && (nextRoll(item, now) !== null || item.expires_at > now - 3 * DAY);
}
function weeklyPlan(expiry, first, now = seconds()) {
  const span = expiry - first;
  if (!Number.isFinite(span) || span < 0 || span >= MAX_ROUNDS * WEEK) throw new Error('首次重置不能晚于订阅到期，分周最多 520 轮。');
  const all = Array.from({length: Math.floor(span / WEEK) + 1}, (_, i) => first + i * WEEK);
  const dates = all.filter(t => t > now);
  if (!dates.length) throw new Error('没有未来的周重置日期，请调整首次重置或订阅到期。');
  const remaining = (expiry - all.at(-1)) / DAY;
  return { dates, dropped: all.length - dates.length, advice: remaining > 0 ? `末轮距订阅到期还剩 ${remaining.toFixed(1)} 天，请按实际额度决定续费。` : '最后一次周重置与订阅到期相同。' };
}
function cleanItem(input, now = seconds()) {
  const expiry = numeric(input.expires_at);
  if (expiry === null || expiry <= 0 || expiry > 253402300799) throw new Error('请填写有效的到期日期和时间。');
  const vendor = String(input.vendor || '').trim() || '未分类';
  const name = String(input.name || '').trim() || vendor + (input.kind === 'window' ? '·周期额度' : '·订阅');
  if (name.length > 200 || vendor.length > 100 || String(input.note || '').length > 16000) throw new Error('名称、供应商或备注过长。');
  const kind = input.kind === 'window' ? 'window' : 'subscription';
  const id = input.id || uid();
  if (typeof id !== 'string' || id.length > 240 || id.startsWith('auto:')) throw new Error('不能编辑官方数据。');
  const rule = ['rolling','calendarWeek','calendarMonth','anchorMonth'].includes(input.reset_rule) ? input.reset_rule : null;
  const item = { id, name, vendor, kind, expires_at:expiry, repeat_hours:kind === 'window' ? numeric(input.repeat_hours) : null, source:'manual', note:String(input.note || ''), used_percent:numeric(input.used_percent), group_id:input.group_id || null, created_at:numeric(input.created_at) || now, updated_at:now, reset_rule:kind === 'window' ? rule : null, reset_param:kind === 'window' ? numeric(input.reset_param) : null, purchase_at:numeric(input.purchase_at), archived_at:numeric(input.archived_at) };
  if (kind === 'window' && nextRoll(item, now) === null && item.archived_at === null) throw new Error('周期规则无效，请填写正数周期或有效的日历重置日。');
  if (item.expires_at > now) item.archived_at = null;
  return item;
}
class Store {
  constructor(directory) {
    this.dir = path.resolve(directory);
    fs.mkdirSync(this.dir, {recursive:true});
    const file = path.join(this.dir, 'state.json');
    this.state = {panelCollapsed:true,panelAutoCollapse:true,displayHorizonDays:40,dismissedAuto:[],resident:false};
    if (fs.existsSync(file)) Object.assign(this.state, JSON.parse(fs.readFileSync(file, 'utf8')));
    this.db = new DatabaseSync(path.join(this.dir,'data.sqlite'));
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;');
    this.db.exec(`CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY,name TEXT NOT NULL,vendor TEXT,kind TEXT,expires_at REAL,repeat_hours REAL,source TEXT,note TEXT,used_percent REAL,group_id TEXT,created_at REAL,updated_at REAL,reset_rule TEXT,reset_param INTEGER,purchase_at REAL,archived_at REAL);
      CREATE TABLE IF NOT EXISTS reminder_settings (item_id TEXT PRIMARY KEY NOT NULL,before_hours INTEGER NOT NULL CHECK(before_hours>0));
      CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT,ts REAL NOT NULL,action TEXT NOT NULL,item_id TEXT,summary TEXT);
      CREATE INDEX IF NOT EXISTS idx_items_group ON items(group_id); CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts);`);
    const names = new Set(this.db.prepare('PRAGMA table_info(items)').all().map(r => r.name));
    for (const [name,type] of [['reset_rule','TEXT'],['reset_param','INTEGER'],['purchase_at','REAL'],['archived_at','REAL']]) {
      if (!names.has(name)) this.db.exec(`ALTER TABLE items ADD COLUMN ${name} ${type}`);
    }
    if (this.items().length) this.backup('startup');
    this.migrateLegacy();
  }
  items() { return this.db.prepare('SELECT * FROM items ORDER BY expires_at').all().map(r => ({...r})); }
  item(id) { const r = this.db.prepare('SELECT * FROM items WHERE id=?').get(id); return r ? {...r} : null; }
  hours(id) { return this.db.prepare('SELECT before_hours FROM reminder_settings WHERE item_id=?').get(id)?.before_hours ?? 5; }
  reminderSettings() { return Object.fromEntries(this.db.prepare('SELECT * FROM reminder_settings').all().map(r => [r.item_id,r.before_hours])); }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = action(); this.db.exec('COMMIT'); return result; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  log(action, item, now = seconds()) { this.db.prepare('INSERT INTO history(ts,action,item_id,summary) VALUES(?,?,?,?)').run(now,action,item.id,item.name); }
  write(item, action) {
    this.db.prepare(`INSERT INTO items (${COLUMNS.join(',')}) VALUES (${COLUMNS.map(() => '?').join(',')}) ON CONFLICT(id) DO UPDATE SET ${COLUMNS.filter(c => c !== 'id' && c !== 'created_at').map(c => c + '=excluded.' + c).join(',')}`).run(...COLUMNS.map(c => item[c] ?? null));
    this.log(action,item);
  }
  save(input, now = seconds()) {
    const item = cleanItem(input,now), previous = this.item(item.id);
    this.transaction(() => {
      this.write(item, previous ? 'edit' : 'add');
      const companion = this.item('qreset:' + item.id);
      if (companion && item.kind === 'window') this.deleteRaw(companion.id);
      else if (companion && previous && (!companion.reset_rule || companion.reset_rule === 'rolling')) {
        companion.expires_at += item.expires_at - previous.expires_at;
        companion.updated_at = now;
        this.write(companion,'align');
      }
      const match = item.name.match(/·第(\d+)\/(\d+)周$/);
      if (item.group_id && match && previous && item.expires_at !== previous.expires_at) {
        const siblings = this.items().filter(r => r.group_id === item.group_id);
        const upper = Math.max(...siblings.map(r => r.id === item.id ? previous.expires_at : r.expires_at)) + WEEK;
        for (const sibling of siblings) {
          const index = sibling.name.match(/·第(\d+)\/(\d+)周$/);
          if (!index) throw new Error('同组记录的周序名称已改变，本次修改未保存。');
          if (+index[1] <= +match[1]) continue;
          const proposed = item.expires_at + (+index[1] - +match[1]) * WEEK;
          if (proposed >= upper) throw new Error('顺延超过订阅到期边界，本次修改未保存。');
          const old = sibling.expires_at;
          this.write({...sibling,expires_at:proposed,updated_at:now},'align_week');
          const reset = this.item('qreset:' + sibling.id);
          if (reset && (!reset.reset_rule || reset.reset_rule === 'rolling')) this.write({...reset,expires_at:reset.expires_at + proposed - old,updated_at:now},'align_week');
        }
      }
    });
    return item.id;
  }
  saveWeekly(input, first, now = seconds()) {
    const item = cleanItem({...input,kind:'subscription'},now), plan = weeklyPlan(item.expires_at, first, now), group = uid();
    if (input.id && this.item(input.id)) this.backup('before-weekly-conversion');
    return this.transaction(() => {
      const old = input.id && this.item(input.id);
      if (old?.group_id) this.deleteGroupRaw(old.group_id);
      else if (old) this.deleteRaw(old.id);
      const base = item.name.replace(/·第\d+\/\d+周$/,'');
      const members = plan.dates.map((date,index) => ({...item,id:uid(),name:`${base}·第${index+1}/${plan.dates.length}周`,group_id:group,expires_at:date,archived_at:null,note:`从首次重置起每 7 天，共 ${plan.dates.length} 轮。${plan.advice}${plan.dropped ? ` 跳过已过去的 ${plan.dropped} 轮。` : ''}`}));
      members.forEach(member => this.write(member,'add_week'));
      return members.map(r => r.id);
    });
  }
  deleteRaw(id) {
    for (const target of [id,'qreset:' + id]) {
      const item = this.item(target);
      if (item) { this.log('delete',item); this.db.prepare('DELETE FROM items WHERE id=?').run(target); }
      this.db.prepare('DELETE FROM reminder_settings WHERE item_id=?').run(target);
    }
  }
  deleteGroupRaw(group) { this.items().filter(r => r.group_id === group).forEach(r => this.deleteRaw(r.id)); }
  delete(id, group = false) {
    const item = this.item(id);
    if (!item) throw new Error('记录不存在或是官方记录。');
    this.backup('before-delete');
    this.transaction(() => group && item.group_id ? this.deleteGroupRaw(item.group_id) : this.deleteRaw(id));
  }
  setHours(id, hours, item) {
    if (hours === null) { this.db.prepare('DELETE FROM reminder_settings WHERE item_id=?').run(id); return; }
    if (!item || !timingAllowed(item,hours)) throw new Error('提前量必须为正数，且小于额度周期。');
    this.db.prepare('INSERT INTO reminder_settings VALUES(?,?) ON CONFLICT(item_id) DO UPDATE SET before_hours=excluded.before_hours').run(id,hours);
  }
  lifecycle(now = seconds()) {
    const items = this.items();
    const candidates = items.filter(item => (item.kind === 'window' && item.archived_at == null && item.expires_at <= now && nextRoll(item,now) !== null) || (item.archived_at == null && item.expires_at < now - 3 * DAY));
    const purge = items.filter(r => r.kind === 'subscription' && r.archived_at != null && r.archived_at < now - 30 * DAY);
    if (purge.length) this.backup('before-archive-purge');
    if (candidates.length || purge.length) this.transaction(() => {
      for (const item of candidates) {
        const next = nextRoll(item,now);
        if (next !== null) this.write({...item,expires_at:next,used_percent:null,updated_at:now},'roll');
        else {
          this.write({...item,archived_at:now,updated_at:now},'archive');
          const companion = this.item('qreset:' + item.id);
          if (companion) this.write({...companion,archived_at:now,updated_at:now},'archive');
        }
      }
      purge.forEach(item => this.deleteRaw(item.id));
    });
  }
  saveState(patch) {
    const allow = ['panelCollapsed','panelAutoCollapse','displayHorizonDays','dismissedAuto','resident','position'];
    if ('displayHorizonDays' in patch && (!Number.isInteger(patch.displayHorizonDays) || patch.displayHorizonDays < 1 || patch.displayHorizonDays > 3650)) throw new Error('展示范围应为 1 至 3650 天。');
    for (const [key,value] of Object.entries(patch)) if (allow.includes(key)) this.state[key] = value;
    const file = path.join(this.dir,'state.json'), temporary = file + '.tmp-' + uid();
    fs.writeFileSync(temporary,JSON.stringify(this.state,null,2),'utf8');
    fs.renameSync(temporary,file);
  }
  backup(reason = 'manual') {
    const dir = path.join(this.dir,'backups'); fs.mkdirSync(dir,{recursive:true});
    const file = path.join(dir,new Date().toISOString().replace(/[:.]/g,'-') + '-' + reason + '-' + uid().slice(0,8) + '.sqlite');
    this.db.prepare('VACUUM INTO ?').run(file);
    return file;
  }
  exportData() { return {format:'ai-expiry-reminder',version:1,exportedAt:new Date().toISOString(),items:this.items(),reminderSettings:this.reminderSettings()}; }
  importData(data) {
    if (!data || data.format !== 'ai-expiry-reminder' || !Array.isArray(data.items) || data.items.length > 20000) throw new Error('不是有效的 AI 到期提醒数据文件。');
    const items = data.items.map(item => cleanItem(item)), ids = new Set(items.map(r => r.id));
    if (ids.size !== items.length) throw new Error('导入文件含重复记录 ID。');
    for (const [id,hours] of Object.entries(data.reminderSettings || {})) {
      const item = items.find(r => r.id === id);
      if (item && !timingAllowed(item,hours)) throw new Error('导入文件含无效的提前提醒设置。');
    }
    this.backup('before-import');
    return this.transaction(() => {
      items.forEach(item => this.write(item,'import'));
      for (const [id,hours] of Object.entries(data.reminderSettings || {})) {
        if (ids.has(id)) this.setHours(id,hours,items.find(r => r.id === id));
      }
      return items.length;
    });
  }
  importSQLite(file) {
    if (path.resolve(file) === path.join(this.dir,'data.sqlite')) throw new Error('请选择备份数据库，而非正在使用的数据文件。');
    const db = new DatabaseSync(file,{readOnly:true});
    try {
      if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok') throw new Error('备份数据库不完整，导入未执行。');
      const items = db.prepare('SELECT * FROM items').all().filter(r => r.source === 'manual').map(r => ({...r}));
      let settings = {};
      if (db.prepare("SELECT name FROM sqlite_master WHERE name='reminder_settings'").get()) settings = Object.fromEntries(db.prepare('SELECT * FROM reminder_settings').all().map(r => [r.item_id,r.before_hours]));
      return this.importData({format:'ai-expiry-reminder',items,reminderSettings:settings});
    } finally { db.close(); }
  }
  migrateLegacy() {
    if (!Array.isArray(this.state.manualItems)) return;
    const source = this.state.manualItems, invalid = [];
    this.transaction(() => {
      for (const row of source) {
        try {
          const expires = typeof row.expiresAt === 'string' ? Date.parse(row.expiresAt)/1000 : numeric(row.expiresAt);
          const item = cleanItem({...row,expires_at:expires,repeat_hours:row.repeatHours,group_id:row.groupID,reset_rule:row.resetRule,reset_param:row.resetParam,purchase_at:row.purchaseAt,archived_at:row.archivedAt});
          if (!this.item(item.id)) this.write(item,'migrate');
        } catch { invalid.push(row); }
      }
    });
    if (invalid.length) this.state.manualItems = invalid; else delete this.state.manualItems;
    this.saveState({});
  }
  close() { this.db.close(); }
}
module.exports = {Store,seconds,numeric,uid,nextRoll,timingAllowed,isDisplayable,weeklyPlan,cleanItem,DAY,WEEK};
