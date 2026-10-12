'use strict';
const $ = id => document.getElementById(id);
const view = new URLSearchParams(location.search).get('view');
let snapshot = null, editing = null, timingItem = null, collapseTimer, previewTimer, readyResolve;
window.uiReady = new Promise(resolve => { readyResolve = resolve; });
const localDate = seconds => { const date = new Date(seconds*1000); return new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16); };
const timestamp = input => new Date(input).getTime()/1000;
const absolute = seconds => new Date(seconds*1000).toLocaleString('zh-CN',{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});
function remaining(expiry, short = false) {
  const difference = expiry-Date.now()/1000, past = difference <= 0, hours = Math.floor(Math.abs(difference)/3600), minutes = Math.floor(Math.abs(difference)%3600/60);
  const label = hours >= 24 ? `${Math.floor(hours/24)}天${hours%24}${short ? '时' : '小时'}` : `${hours}${short ? '时' : '小时'}${minutes}分`;
  return past ? '已过期' + (short ? '' : label) : label;
}
function tone(item) { return item.used_percent >= 100 ? 'exhausted' : item.expires_at <= Date.now()/1000 ? 'expired' : item.expires_at-Date.now()/1000 < 86400 ? 'urgent' : 'safe'; }
function displayable(item) { return item.archived_at == null && (item.kind === 'window' && item.repeat_hours > 0 || item.expires_at > Date.now()/1000-3*86400); }
async function call(operation,payload) { const reply = await window.reminder.call(operation,payload); if (!reply.ok) throw new Error(reply.error); return reply.value; }
function notify(message,error = false) { $('notice').textContent = message; $('notice').className = error ? 'error' : ''; }
function button(label,action) { const b = document.createElement('button'); b.textContent = label; b.onclick = action; return b; }
function visible() { return snapshot.items.filter(item => displayable(item) && item.expires_at-Date.now()/1000 <= snapshot.state.displayHorizonDays*86400); }
function refreshCountdowns() {
  if (!snapshot) return;
  for (const element of document.querySelectorAll('[data-expiry]')) element.textContent = remaining(+element.dataset.expiry,element.dataset.short === 'true');
  const list = visible(), future = list.filter(item => item.expires_at > Date.now()/1000), nearest = future[0] || list[0];
  $('pill').textContent = nearest ? remaining(nearest.expires_at,true) : snapshot.items.some(r => r.archived_at == null) ? '待临近' : '暂无记录';
  $('pill').className = nearest ? tone(nearest) : '';
  $('pill').title = nearest ? `${nearest.name} · ${absolute(nearest.expires_at)}\n点击展开 · 拖动移动` : '点击展开，添加提醒';
  $('pill').style.fontSize = $('pill').textContent.length > 7 ? '8px' : '10px';
}
function render(event = null) {
  if (!snapshot) return;
  $('floating').hidden = view !== 'float'; $('management').hidden = view === 'float';
  document.body.classList.toggle('collapsed',snapshot.state.panelCollapsed !== false);
  $('pill').hidden = snapshot.state.panelCollapsed === false; $('expanded').hidden = snapshot.state.panelCollapsed !== false;
  $('auto-collapse').checked = snapshot.state.panelAutoCollapse !== false;
  $('resident').checked = Boolean(snapshot.state.resident);
  if (document.activeElement !== $('horizon')) $('horizon').value = snapshot.state.displayHorizonDays;
  $('version').textContent = 'v' + snapshot.version;
  $('sources').textContent = snapshot.statuses.join('\n');
  const near = visible();
  $('float-list').replaceChildren();
  for (const item of near) {
    const row = document.createElement('div'); row.className = 'float-row'; row.dataset.id = item.id;
    const line = document.createElement('div'); line.className = 'float-line';
    const name = document.createElement('span'); name.className = 'float-name'; name.textContent = item.name;
    const dot = document.createElement('span'); dot.className = 'dot ' + tone(item); name.prepend(dot);
    const countdown = document.createElement('span'); countdown.className = 'countdown ' + tone(item); countdown.dataset.expiry = item.expires_at;
    line.append(name,countdown);
    const sub = document.createElement('div'); sub.className = 'float-sub'; sub.textContent = `${item.vendor} · ${absolute(item.expires_at)} · ${item.source === 'manual' ? '手动' : item.note || '官方缓存'}`;
    row.append(line,sub);
    if (item.used_percent != null) { const bar = document.createElement('div'); bar.className = 'progress'; const fill = document.createElement('span'); fill.style.width = `${Math.max(0,Math.min(100,100-item.used_percent))}%`; bar.append(fill); row.append(bar); }
    row.onclick = () => safe(() => call('manage',{event:{type:item.source === 'manual' ? 'edit' : 'timing',id:item.id}}));
    row.oncontextmenu = e => { e.preventDefault(); safe(() => call('context',{id:item.id})); };
    $('float-list').append(row);
  }
  if (!near.length) { const empty = document.createElement('p'); empty.className = 'float-sub'; empty.textContent = snapshot.items.some(r => r.archived_at == null) ? '当前展示范围内没有到期项' : '点 ＋ 添加第一条提醒'; $('float-list').append(empty); }
  $('records').replaceChildren();
  const records = snapshot.items.filter(item => item.archived_at != null || item.expires_at-Date.now()/1000 <= snapshot.state.displayHorizonDays*86400);
  records.sort((a,b) => Boolean(a.archived_at)-Boolean(b.archived_at) || a.expires_at-b.expires_at);
  for (const item of records) {
    const row = document.createElement('tr'); row.dataset.id = item.id; if (item.archived_at != null) row.className = 'archived';
    for (const text of [item.name+(item.archived_at != null ? '（已归档）' : ''),item.vendor,absolute(item.expires_at),'']) { const td = document.createElement('td'); td.textContent = text; row.append(td); }
    row.children[3].dataset.expiry = item.expires_at; row.children[3].dataset.short = 'true'; row.children[3].className = tone(item);
    const actions = document.createElement('td');
    if (item.source === 'manual') { actions.append(button('编辑',() => openEditor(item)),button('删除',() => safe(() => remove(item)))); }
    else { const badge = document.createElement('span'); badge.textContent = '官方 · '; actions.append(badge); }
    const timing = button('提醒',() => openTiming(item)); timing.className = 'timing-button'; actions.append(timing); row.append(actions);
    row.ondblclick = () => item.source === 'manual' ? openEditor(item) : openTiming(item);
    $('records').append(row);
  }
  $('empty').hidden = records.length > 0;
  const outside = snapshot.items.filter(item => item.archived_at == null && item.expires_at-Date.now()/1000 > snapshot.state.displayHorizonDays*86400).length;
  $('outside').textContent = `手动记录共 ${snapshot.items.filter(r => r.source === 'manual').length} 条。` + (outside ? `另有 ${outside} 条距到期超过 ${snapshot.state.displayHorizonDays} 天，已保存在数据库。` : '');
  refreshCountdowns();
  if (event) { const item = snapshot.items.find(r => r.id === event.id); if (event.type === 'add') openEditor(); else if (item) { if (event.type === 'edit') openEditor(item); if (event.type === 'timing') openTiming(item); if (event.type === 'delete') safe(() => remove(item)); } }
}
async function safe(action) { try { return await action(); } catch (e) { notify(e.message,true); } }
function typeChanged() {
  const kind = $('kind').value;
  $('first-row').hidden = kind !== 'weekly'; $('period-row').hidden = kind !== 'window'; $('plan').hidden = kind !== 'weekly';
  $('expiry-label').textContent = kind === 'window' ? '本轮额度重置时间' : '订阅到期时间';
  $('hours-row').hidden = $('rule').value !== 'rolling'; $('param-row').hidden = $('rule').value === 'rolling';
  $('param').max = $('rule').value === 'calendarWeek' ? '7' : '31';
  $('param-help').textContent = $('rule').value === 'calendarWeek' ? '星期：1 为周一，7 为周日。' : '日期：1 至 31；小月自动按月末重置。';
  previewPlan();
}
function openEditor(item = null) {
  editing = item ? {...item} : null;
  $('edit-title').textContent = item ? '编辑提醒' : '添加提醒';
  $('name').value = item?.name || ''; $('vendor').value = item?.vendor || ''; $('kind').value = item?.kind || 'subscription';
  $('expiry').value = localDate(item?.expires_at || Date.now()/1000+30*86400); $('first').value = $('expiry').value;
  $('period').value = item?.repeat_hours || 168; $('rule').value = item?.reset_rule || 'rolling'; $('param').value = item?.reset_param || 1;
  $('note').value = item?.note || ''; $('edit-error').textContent = ''; typeChanged();
  if (!$('editor').open) $('editor').showModal(); $('name').focus();
}
async function previewPlan() {
  clearTimeout(previewTimer);
  if ($('kind').value !== 'weekly') return;
  previewTimer = setTimeout(async () => {
    try { const plan = await call('plan',{expiry:timestamp($('expiry').value),first:timestamp($('first').value)}); $('plan').textContent = `${plan.dates.length} 轮，每 7 天重置：\n${plan.dates.map(absolute).join('\n')}\n${plan.advice}${plan.dropped ? `\n跳过已过去的 ${plan.dropped} 轮。` : ''}`; }
    catch (e) { $('plan').textContent = e.message; }
  },150);
}
function openTiming(item) {
  timingItem = item; const hours = snapshot.reminderHours[item.id] ?? 5;
  $('timing-name').textContent = item.name; $('days').value = Math.floor(hours/24); $('hours').value = hours%24;
  $('timing-error').textContent = ''; timingPreview(); if (!$('timing').open) $('timing').showModal();
}
function timingPreview() { const hours = +$('days').value*24 + +$('hours').value; $('timing-preview').textContent = timingItem ? `预计提醒：${absolute(timingItem.expires_at-hours*3600)}` : ''; }
async function remove(item) {
  let group = false;
  if (item.group_id) group = window.confirm('确定：删除整组周记录。\n取消：只删除当前这条，随后仍会确认。');
  const deleted = await call('delete',{id:item.id,group}); if (deleted) notify('已删除，删除前的备份保存在数据文件夹。');
}
$('edit-form').onsubmit = async event => {
  event.preventDefault(); $('save').disabled = true; $('edit-error').textContent = '';
  try {
    const kind = $('kind').value;
    const item = {...(editing || {}),name:$('name').value,vendor:$('vendor').value,kind:kind === 'weekly' ? 'subscription' : kind,expires_at:timestamp($('expiry').value),repeat_hours:kind === 'window' ? +$('period').value : null,reset_rule:kind === 'window' ? $('rule').value : null,reset_param:kind === 'window' && $('rule').value !== 'rolling' ? +$('param').value : null,note:$('note').value};
    await call('save',{item,weekly:kind === 'weekly',first:timestamp($('first').value)});
    $('editor').close(); notify('已保存。');
  } catch (e) { $('edit-error').textContent = e.message; }
  finally { $('save').disabled = false; }
};
$('timing-form').onsubmit = async event => {
  event.preventDefault(); $('timing-error').textContent = '';
  try { const days = +$('days').value, hours = +$('hours').value; if (!Number.isInteger(days) || !Number.isInteger(hours) || days < 0 || days > 3650 || hours < 0 || hours > 23) throw new Error('天数应为 0–3650，小时应为 0–23。'); await call('timing',{id:timingItem.id,hours:days*24+hours}); $('timing').close(); notify('提前提醒已保存。'); }
  catch (e) { $('timing-error').textContent = e.message; }
};
$('default-timing').onclick = () => safe(async () => { await call('timing',{id:timingItem.id,hours:null}); $('timing').close(); notify('已恢复默认提前 5 小时。'); });
$('cancel-edit').onclick = () => $('editor').close(); $('cancel-timing').onclick = () => $('timing').close();
for (const id of ['kind','rule']) $(id).onchange = typeChanged;
for (const id of ['expiry','first']) $(id).oninput = previewPlan;
for (const id of ['days','hours']) $(id).oninput = timingPreview;
$('add').onclick = () => openEditor();
$('float-add').onclick = () => safe(() => call('manage',{event:{type:'add'}}));
for (const id of ['float-manage','float-settings']) $(id).onclick = () => safe(() => call('manage'));
for (const id of ['refresh','float-refresh','restore-official']) $(id).onclick = () => safe(async () => { $(id).disabled = true; try { await call('refresh'); notify('已启动本地数据刷新。'); } finally { $(id).disabled = false; } });
for (const id of ['collapse','float-collapse']) $(id).onclick = () => safe(() => call('expand',{value:false}));
$('pill').onclick = () => { if (!dragged) safe(() => call('expand',{value:true})); };
$('float-home').onclick = () => safe(() => call('home')); $('float-hide').onclick = () => safe(() => call('hide'));
$('auto-collapse').onchange = () => safe(() => call('settings',{panelAutoCollapse:$('auto-collapse').checked}));
$('resident').onchange = () => safe(() => call('settings',{resident:$('resident').checked}));
$('apply-horizon').onclick = () => safe(async () => { await call('settings',{displayHorizonDays:Number($('horizon').value)}); notify('展示范围已保存。'); });
$('folder').onclick = () => safe(() => call('folder'));
$('backup').onclick = () => safe(async () => { const file = await call('backup'); notify('已保留备份：' + file); });
$('export').onclick = () => safe(async () => { const file = await call('export'); if (file) notify('已导出：' + file); });
$('import').onclick = () => safe(async () => { const count = await call('import'); if (count !== null) notify(`已合并导入 ${count} 条记录。`); });
document.addEventListener('keydown',event => { if ((event.ctrlKey || event.metaKey) && event.key === ',') { event.preventDefault(); safe(() => call('manage')); } });
document.body.addEventListener('mouseenter',() => clearTimeout(collapseTimer));
document.body.addEventListener('mouseleave',() => { if (view === 'float' && snapshot?.state.panelAutoCollapse !== false) collapseTimer = setTimeout(() => safe(() => call('expand',{value:false})),8000); });
let pointer = null, dragged = false;
let ignorePadding = false;
document.addEventListener('mousemove',event => {
  if (view !== 'float' || pointer || !snapshot) return;
  const ignore = snapshot.state.panelCollapsed !== false && event.clientY >= 18;
  if (ignore !== ignorePadding) { ignorePadding = ignore; safe(() => call('pointer-ignore',{ignore})); }
});
for (const element of [$('pill'),$('drag-handle')]) {
  element.onpointerdown = e => { if (e.button !== 0) return; dragged = false; pointer = {x:e.screenX,y:e.screenY}; element.setPointerCapture(e.pointerId); };
  element.onpointermove = e => { if (!pointer || !e.buttons) return; const x = e.screenX-pointer.x, y = e.screenY-pointer.y; if (dragged || Math.hypot(x,y) > 4) { dragged = true; pointer = {x:e.screenX,y:e.screenY}; safe(() => call('move',{x,y})); } };
  element.onpointerup = () => { pointer = null; };
}
window.reminder.onUpdate(value => { snapshot = value; render(value.event); });
call('snapshot').then(value => { snapshot = value; render(); readyResolve(); }).catch(error => { document.body.textContent = error.message; });
setInterval(refreshCountdowns,1000);
window.runSmoke = async () => {
  const checks = [], expect = (value,label) => { if (!value) throw new Error(label); checks.push(label); };
  const settle = async predicate => { for (let i=0;i<100;i++) { if (predicate()) return; await new Promise(r => setTimeout(r,20)); } throw new Error('UI state did not settle'); };
  $('add').click(); expect($('editor').open,'add opens editor');
  $('name').value = '验收订阅'; $('vendor').value = '测试供应商'; $('expiry').value = '';
  $('save').click(); expect($('editor').open,'invalid date keeps editor open'); expect(snapshot.items.length === 0,'invalid form does not persist');
  $('expiry').value = localDate(Date.now()/1000+30*86400); $('save').click(); await settle(() => !$('editor').open && snapshot.items.length === 1);
  expect($('records').querySelectorAll('tr').length === 1,'saved item appears in table');
  $('records').querySelector('button').click(); $('name').value = '取消的改动'; $('cancel-edit').click();
  expect(snapshot.items[0].name === '验收订阅','edit cancel preserves name');
  $('records').querySelector('.timing-button').click(); $('days').value = '2'; $('hours').value = '3'; $('save-timing').click();
  await settle(() => !$('timing').open && snapshot.reminderHours[snapshot.items[0].id] === 51);
  expect(true,'day/hour reminder saves through renderer');
  $('horizon').value = '0'; $('apply-horizon').click(); await settle(() => $('notice').textContent.includes('1 至 3650'));
  expect(snapshot.state.displayHorizonDays === 40,'invalid display horizon leaves state unchanged');
  await call('expand',{value:false}); expect(true,'renderer collapse action completes');
  return checks;
};
