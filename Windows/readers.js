'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {numeric} = require('./core');
const {isMainThread,parentPort,workerData} = require('node:worker_threads');
async function json(file) {
  try { const stat = await fs.stat(file); if (stat.size > 1024*1024) return null; return JSON.parse(await fs.readFile(file,'utf8')); } catch { return null; }
}
async function newestFiles(root, limit) {
  const entries = [];
  async function visit(dir) {
    let children; try { children = await fs.readdir(dir,{withFileTypes:true}); } catch { return; }
    for (const child of children) {
      if (child.name.startsWith('.')) continue;
      const file = path.join(dir,child.name);
      if (child.isDirectory()) await visit(file);
      else if (child.isFile() && child.name.endsWith('.jsonl')) {
        try { const stat = await fs.stat(file); if (stat.size) entries.push({file,size:stat.size,mtime:stat.mtimeMs/1000}); } catch {}
      }
    }
  }
  await visit(root);
  return entries.sort((a,b) => b.mtime-a.mtime).slice(0,limit);
}
async function tail(file, maximum) {
  let handle;
  try {
    handle = await fs.open(file,'r');
    const {size} = await handle.stat(), take = Math.min(size,maximum), offset = size-take, data = Buffer.alloc(take);
    let total = 0;
    while (total < take) {
      const {bytesRead} = await handle.read(data,total,take-total,offset+total);
      if (!bytesRead) break; total += bytesRead;
    }
    const slice = data.subarray(0,total);
    const start = offset > 0 ? slice.indexOf(10)+1 : 0;
    if (offset > 0 && start === 0) return '';
    return slice.subarray(start).toString('utf8');
  } catch { return ''; } finally { if (handle) await handle.close(); }
}
function ratePools(text) {
  const pools = new Map();
  for (const line of text.split('\n')) {
    if (!line.includes('"rate_limits"')) continue;
    try {
      const entry = JSON.parse(line), limits = entry.rate_limits || entry.payload?.rate_limits;
      if (!limits || typeof limits !== 'object' || Array.isArray(limits)) continue;
      const windows = [];
      for (const slot of ['primary','secondary']) {
        const value = limits[slot], reset = numeric(value?.resets_at), minutes = numeric(value?.window_minutes);
        if (reset === null || reset <= 0 || minutes === null || minutes <= 0) continue;
        windows.push({slot,reset,minutes:Math.floor(minutes),used:numeric(value.used_percent)});
      }
      if (windows.length) {
        const id = typeof limits.limit_id === 'string' && limits.limit_id ? limits.limit_id : 'codex';
        pools.set(id,{id,name:typeof limits.limit_name === 'string' ? limits.limit_name : 'Codex 通用',windows});
      }
    } catch {}
  }
  return [...pools.values()];
}
function jwtClaims(token) {
  try {
    const segment = String(token).split('.')[1];
    if (!segment || !/^[\w-]+$/.test(segment)) return null;
    return JSON.parse(Buffer.from(segment,'base64url').toString('utf8'));
  } catch { return null; }
}
function windowLabel(minutes) {
  if (minutes === 300) return '5小时限额';
  if (minutes === 10080) return '每周限额';
  if (minutes >= 1440 && minutes % 1440 === 0) return minutes/1440 + '天限额';
  if (minutes >= 60 && minutes % 60 === 0) return minutes/60 + '小时限额';
  return minutes + '分钟限额';
}
async function readAll(home = os.homedir(), now = Date.now()/1000, codexHome = path.join(home,'.codex')) {
  const items = [], statuses = [];
  const auth = await json(path.join(codexHome,'auth.json'));
  if (auth) {
    const claim = jwtClaims(auth.tokens?.id_token)?.['https://api.openai.com/auth'];
    const expiry = Date.parse(claim?.chatgpt_subscription_active_until)/1000;
    if (Number.isFinite(expiry)) items.push({id:'auto:codex:subscription',name:`ChatGPT ${claim.chatgpt_plan_type || ''} 订阅`.replace('  ',' '),vendor:'OpenAI',kind:'subscription',expires_at:expiry,source:'codex',note:'官方 JWT 订阅声明（本地缓存）',archived_at:null});
    const files = await newestFiles(path.join(codexHome,'sessions'),4), merged = new Map();
    for (const {file} of files) for (const pool of ratePools(await tail(file,8*1024*1024))) if (!merged.has(pool.id)) merged.set(pool.id,pool);
    for (const pool of [...merged.values()].sort((a,b) => a.id === 'codex' ? -1 : b.id === 'codex' ? 1 : a.id.localeCompare(b.id))) for (const w of pool.windows) {
      const expired = w.reset <= now;
      items.push({id:`auto:codex:${pool.id}:${w.slot}:${w.minutes}`,name:`${pool.name || 'Codex 通用'}·${windowLabel(w.minutes)}`,vendor:'OpenAI',kind:'window',expires_at:w.reset,repeat_hours:w.minutes/60,source:'codex',used_percent:expired ? null : w.used,note:expired ? '窗口已到点，等待官方新窗口上报' : w.used === null ? '官方额度·已用未知' : `官方额度·剩余${Math.round(100-w.used)}%`,archived_at:null});
    }
    statuses.push('Codex：读取官方本地缓存；未上报的数据不会猜补。');
  } else statuses.push('Codex：未检测到本地登录，可手动添加。');
  const files = await newestFiles(path.join(home,'.claude','projects'),200);
  let start = null;
  for (const entry of files) {
    if (now-entry.mtime >= 5*3600) continue;
    const stamps = [];
    for (const line of (await tail(entry.file,4*1024*1024)).split('\n')) {
      try { const stamp = Date.parse(JSON.parse(line).timestamp)/1000; if (Number.isFinite(stamp)) stamps.push(stamp); } catch {}
    }
    const last = Math.max(...stamps);
    if (!Number.isFinite(last) || now-last >= 5*3600 || last > now+60) continue;
    const visible = stamps.filter(t => t >= last-5*3600 && t <= last);
    const first = Math.min(...visible);
    if (Number.isFinite(first) && (start === null || first < start)) start = first;
  }
  if (start !== null && start+5*3600 > now) items.push({id:'auto:claude:window5h',name:'Claude 5小时窗口(估算)',vendor:'Anthropic',kind:'window',expires_at:start+5*3600,repeat_hours:5,source:'claude',note:'本地会话活动估算，非官方重置时间',archived_at:null});
  statuses.push(start !== null ? 'Claude：按本地活动估算 5 小时窗口，非官方值。' : 'Claude：当前没有可估算的活动，订阅可手动添加。');
  statuses.push(await json(path.join(home,'.grok','auth.json')) ? 'Grok：已检测到登录，本地无到期数据，请手动添加。' : 'Grok：未检测到本地登录，可手动添加。');
  statuses.push(await json(path.join(home,'.zcode','v2','coding-plan-cache.json')) ? 'ZCode：检测到本地套餐缓存，到期时间请手动添加。' : 'ZCode：未检测到本地缓存，可手动添加。');
  return {items,statuses};
}
if (!isMainThread) readAll(workerData.home,workerData.now,workerData.codexHome).then(result => parentPort.postMessage(result)).catch(() => parentPort.postMessage({items:[],statuses:['本地数据读取失败，手动记录仍保留。']}));
module.exports = {ratePools,jwtClaims,windowLabel,readAll,tail,newestFiles};
