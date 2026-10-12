'use strict';
const {app,BrowserWindow,ipcMain,Menu,Tray,nativeImage,screen,dialog,shell} = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const {Worker} = require('node:worker_threads');
const {Store,seconds,nextRoll,timingAllowed,isDisplayable,weeklyPlan} = require('./core');
const smoke = process.argv.includes('--smoke-test');
const watchdogMode = process.argv.includes('--watchdog');
if (smoke && !process.env.AR_DATA_DIR) process.env.AR_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(),'ai-reminder-smoke-'));
const directory = process.env.AR_DATA_DIR || path.join(app.getPath('appData'),'AI到期提醒');
app.setPath('userData',path.join(directory,'desktop'));
if (smoke) app.setName('AI到期提醒 Windows 验收');
else app.setName('AI到期提醒');
let store, panel, manager, tray, watchdog, quitting = false, refreshing = false;
let official = [], statuses = [], manual = [], reminderHours = {}, lastAlert = new Set(), alertOpen = false;
const timerHandles = [];
function startArguments() { return app.isPackaged ? [] : [__dirname]; }
function startWatchdog() {
  if (smoke || process.platform !== 'win32' || !store.state.resident || watchdog) return;
  watchdog = spawn(process.execPath,[...startArguments(),'--watchdog',String(process.pid)],{detached:true,stdio:'ignore',windowsHide:true,env:{...process.env,AR_DATA_DIR:directory}});
  watchdog.unref();
  watchdog.on('exit',() => { watchdog = null; });
}
function stopWatchdog() { if (watchdog) { watchdog.kill(); watchdog = null; } }
function setResident(value) {
  if (typeof value !== 'boolean') throw new Error('常驻设置无效。');
  store.saveState({resident:value});
  if (process.platform === 'win32' && !smoke) app.setLoginItemSettings({openAtLogin:value,path:process.execPath,args:startArguments()});
  value ? startWatchdog() : stopWatchdog();
}
function contents() {
  const dismissed = new Set(store.state.dismissedAuto || []);
  const items = [...official.filter(r => !dismissed.has(r.id)),...manual].sort((a,b) => a.expires_at-b.expires_at);
  return {items,state:store.state,reminderHours,statuses,version:app.isPackaged ? app.getVersion() : require('./package.json').version};
}
function reload() { manual = store.items(); reminderHours = store.reminderSettings(); broadcast(); }
function broadcast(event = null) {
  const data = {...contents(),event};
  for (const window of [panel,manager]) if (window && !window.isDestroyed()) window.webContents.send('reminder:update',data);
  if (tray) tray.setToolTip('AI到期提醒 · ' + (manual.length ? `${manual.length} 条手动记录` : '点击添加记录'));
}
function workArea() { return screen.getDisplayMatching(panel?.getBounds() || screen.getPrimaryDisplay().workArea).workArea; }
function geometry(collapsed, preserve = true) {
  const area = workArea(), previous = panel?.getBounds();
  const count = contents().items.filter(r => isDisplayable(r) && r.expires_at-seconds() <= store.state.displayHorizonDays*86400).length;
  const width = collapsed ? 54 : 240, height = collapsed ? 18 : Math.min(area.height-32,112+Math.min(Math.max(count,1),8)*56);
  const x = preserve && previous ? previous.x+previous.width-width : area.x+area.width-width-10;
  const y = preserve && previous ? previous.y : area.y+10;
  return {x:Math.max(area.x,Math.min(x,area.x+area.width-width)),y:Math.max(area.y,Math.min(y,area.y+area.height-height)),width,height};
}
function expand(value) {
  store.saveState({panelCollapsed:!value});
  panel.setBounds(geometry(!value)); panel.show(); broadcast();
}
function makeWindow(options, view) {
  const window = new BrowserWindow({...options,icon:path.join(__dirname,'icon.png'),webPreferences:{preload:path.join(__dirname,'preload.js'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
  window.webContents.setWindowOpenHandler(() => ({action:'deny'}));
  window.webContents.on('will-navigate',event => event.preventDefault());
  window.loadFile(path.join(__dirname,'ui/index.html'),{query:{view}});
  return window;
}
function openManager(event = null) {
  if (!manager || manager.isDestroyed()) {
    manager = makeWindow({width:820,height:570,minWidth:650,minHeight:440,title:'AI到期提醒 · 管理记录',backgroundColor:'#101821',show:false},'manage');
    manager.once('ready-to-show',() => { manager.show(); broadcast(event); });
    manager.on('closed',() => { manager = null; });
  } else { manager.show(); manager.focus(); broadcast(event); }
}
function contextMenu(id) {
  const item = contents().items.find(r => r.id === id);
  if (!item) throw new Error('记录已不存在。');
  const entries = [
    {label:item.name,enabled:false},
    {label:'编辑记录…',enabled:item.source === 'manual',click:() => openManager({type:'edit',id})},
    {label:'提前提醒…',click:() => openManager({type:'timing',id})},
    {label:'隐藏此官方条目',visible:item.source !== 'manual',click:() => { store.saveState({dismissedAuto:[...new Set([...(store.state.dismissedAuto || []),id])]}); broadcast(); }},
    {label:'删除记录…',visible:item.source === 'manual',click:() => openManager({type:'delete',id})}
  ];
  Menu.buildFromTemplate(entries).popup({window:panel});
}
async function refreshOfficial() {
  if (refreshing || smoke) return;
  refreshing = true;
  const home = os.homedir(), worker = new Worker(path.join(__dirname,'readers.js'),{workerData:{home,now:seconds(),codexHome:process.env.CODEX_HOME || path.join(home,'.codex')}});
  const deadline = setTimeout(() => { worker.terminate(); refreshing = false; statuses = ['读取本地缓存超时，已有记录保留。']; broadcast(); },30000);
  worker.once('message',result => { clearTimeout(deadline); official = result.items; statuses = result.statuses; refreshing = false; broadcast(); });
  worker.once('error',() => { clearTimeout(deadline); refreshing = false; statuses = ['读取本地缓存失败，手动记录仍保留。']; broadcast(); });
}
async function tick() {
  const now = seconds();
  if (manual.some(item => item.archived_at == null && ((item.kind === 'window' && item.expires_at <= now && nextRoll(item,now) !== null) || item.expires_at < now-3*86400)) || manual.some(r => r.kind === 'subscription' && r.archived_at != null && r.archived_at < now-30*86400)) {
    try { store.lifecycle(now); reload(); } catch (e) { statuses = ['记录处理失败：' + e.message]; broadcast(); }
  }
  if (smoke || alertOpen) return;
  const due = contents().items.filter(item => {
    const hours = reminderHours[item.id] ?? 5, key = item.id + '@' + item.expires_at;
    return item.archived_at == null && item.expires_at > now && item.expires_at-now <= hours*3600 && timingAllowed(item,hours) && !lastAlert.has(key);
  });
  if (!due.length) return;
  due.forEach(r => lastAlert.add(r.id + '@' + r.expires_at));
  alertOpen = true;
  try { await dialog.showMessageBox(panel,{type:'info',title:'AI 到期提醒',message:'这些记录即将到期',detail:due.map(r => `${r.name} · ${new Date(r.expires_at*1000).toLocaleString()} · 提前 ${reminderHours[r.id] ?? 5} 小时`).join('\n'),buttons:['知道了']}); }
  finally { alertOpen = false; }
}
async function action(operation, payload = {}) {
  switch (operation) {
    case 'snapshot': return contents();
    case 'expand': expand(Boolean(payload.value)); break;
    case 'home': store.saveState({position:null,panelCollapsed:true}); panel.setBounds(geometry(true,false)); panel.show(); broadcast(); break;
    case 'hide': panel.hide(); break;
    case 'manage': openManager(payload.event || null); break;
    case 'context': contextMenu(payload.id); break;
    case 'refresh': store.saveState({dismissedAuto:[]}); await refreshOfficial(); broadcast(); break;
    case 'plan': return weeklyPlan(payload.expiry,payload.first);
    case 'save': {
      const id = payload.weekly ? store.saveWeekly(payload.item,payload.first) : store.save(payload.item);
      reload(); return id;
    }
    case 'delete': {
      const item = store.item(payload.id);
      if (!item) throw new Error('记录已不存在。');
      const result = await dialog.showMessageBox(manager || panel,{type:'question',title:'删除提醒记录',message:payload.group ? `删除“${item.name}”所在的整组记录？` : `删除“${item.name}”？`,detail:'删除前会在数据文件夹保留数据库备份，可从导入入口恢复。',buttons:['取消','删除'],defaultId:0,cancelId:0});
      if (result.response === 1) { store.delete(payload.id,Boolean(payload.group)); reload(); }
      return result.response === 1;
    }
    case 'timing': {
      const item = contents().items.find(r => r.id === payload.id);
      store.setHours(payload.id,payload.hours,item); reload(); break;
    }
    case 'settings': {
      if ('resident' in payload) setResident(payload.resident);
      store.saveState(payload); broadcast(); break;
    }
    case 'folder': return shell.openPath(directory);
    case 'backup': return store.backup();
    case 'export': {
      const result = await dialog.showSaveDialog(manager || panel,{title:'导出提醒记录',defaultPath:'AI到期提醒备份.json',filters:[{name:'提醒记录',extensions:['json']}]});
      if (!result.canceled) { fs.writeFileSync(result.filePath,JSON.stringify(store.exportData(),null,2),'utf8'); return result.filePath; }
      return null;
    }
    case 'import': {
      const result = await dialog.showOpenDialog(manager || panel,{title:'导入记录或 Mac 数据库备份',properties:['openFile'],filters:[{name:'提醒记录与数据库备份',extensions:['json','sqlite','db']}]});
      if (result.canceled) return null;
      const file = result.filePaths[0], confirmation = await dialog.showMessageBox(manager || panel,{type:'question',title:'合并导入',message:'将所选文件的手动记录合并到当前数据？',detail:'相同 ID 会更新到所选文件的值；导入前会保留当前数据库备份。',buttons:['取消','导入'],defaultId:0,cancelId:0});
      if (confirmation.response !== 1) return null;
      const stat = fs.statSync(file); if (stat.size > 50*1024*1024) throw new Error('导入文件超过 50 MB。');
      const count = /\.(sqlite|db)$/i.test(file) ? store.importSQLite(file) : store.importData(JSON.parse(fs.readFileSync(file,'utf8')));
      reload(); return count;
    }
    case 'move': {
      if (!Number.isFinite(payload.x) || !Number.isFinite(payload.y)) throw new Error('无效窗口坐标。');
      const bounds = panel.getBounds();
      panel.setPosition(Math.round(bounds.x+payload.x),Math.round(bounds.y+payload.y));
      store.saveState({position:panel.getPosition()}); break;
    }
    case 'quit': quitting = true; stopWatchdog(); app.quit(); break;
    default: throw new Error('未知操作。');
  }
  return true;
}
async function runSmoke() {
  const assert = require('node:assert/strict');
  const evidence = {platform:process.platform,arch:process.arch,electron:process.versions.electron,node:process.versions.node,checks:[]};
  const check = (condition,label) => { assert.ok(condition,label); evidence.checks.push(label); };
  await panel.webContents.executeJavaScript('window.uiReady');
  openManager();
  await new Promise((resolve,reject) => { manager.webContents.once('did-finish-load',resolve); manager.webContents.once('did-fail-load',reject); });
  await manager.webContents.executeJavaScript('window.uiReady');
  const result = await manager.webContents.executeJavaScript('window.runSmoke()');
  evidence.checks.push(...result);
  check(store.items().length === 1,'renderer add persists in SQLite');
  const saved = store.items()[0];
  check(store.hours(saved.id) === 51,'renderer timing persists');
  store.close(); store = new Store(directory); reload();
  check(store.items()[0].name === '验收订阅' && store.hours(saved.id) === 51,'reopen preserves items and reminder timing');
  const exportData = store.exportData();
  store.delete(saved.id); check(store.items().length === 0,'delete removes only selected record');
  store.importData(exportData); reload(); check(store.items().length === 1,'backup import restores deleted item');
  for (let i = 0; i < 40 && (panel.getBounds().width !== 54 || panel.getBounds().height !== 18); i++) await new Promise(resolve => setTimeout(resolve,50));
  evidence.collapsedBounds = panel.getBounds();
  check(evidence.collapsedBounds.width === 54 && evidence.collapsedBounds.height === 18,'native collapsed window is 54×18: ' + JSON.stringify(evidence.collapsedBounds));
  expand(true);
  for (let i = 0; i < 40 && panel.getBounds().width !== 240; i++) await new Promise(resolve => setTimeout(resolve,50));
  evidence.expandedBounds = panel.getBounds();
  check(evidence.expandedBounds.width === 240,'native expanded window width is 240: ' + JSON.stringify(evidence.expandedBounds));
  openManager();
  await new Promise((resolve,reject) => { if (manager.webContents.isLoading()) { manager.webContents.once('did-finish-load',resolve); manager.webContents.once('did-fail-load',reject); } else resolve(); });
  await manager.webContents.executeJavaScript('window.uiReady');
  const rows = await manager.webContents.executeJavaScript('document.querySelectorAll("#records tr[data-id]").length');
  check(rows === 1,'native management window renders persisted record');
  check(store.db.prepare('PRAGMA integrity_check').get().integrity_check === 'ok','SQLite integrity check');
  fs.writeFileSync(path.join(directory,'native-smoke-receipt.json'),JSON.stringify(evidence,null,2));
  if (process.env.AR_SMOKE_RECEIPT) fs.copyFileSync(path.join(directory,'native-smoke-receipt.json'),process.env.AR_SMOKE_RECEIPT);
  if (process.env.AR_SMOKE_SCREENSHOT) fs.writeFileSync(process.env.AR_SMOKE_SCREENSHOT,(await manager.webContents.capturePage()).toPNG());
  quitting = true; app.exit(0);
}
if (watchdogMode) {
  app.whenReady().then(() => {
    const parent = Number(process.argv.at(-1));
    if (!Number.isInteger(parent) || parent <= 0 || process.platform !== 'win32') return app.quit();
    setInterval(() => {
      try { process.kill(parent,0); }
      catch {
        try {
          const state = JSON.parse(fs.readFileSync(path.join(directory,'state.json'),'utf8'));
          if (state.resident) { const child = spawn(process.execPath,startArguments(),{detached:true,stdio:'ignore',windowsHide:true,env:{...process.env,AR_DATA_DIR:directory}}); child.unref(); }
        } finally { app.quit(); }
      }
    },2000);
  });
} else if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance',() => { if (panel) expand(true); });
  app.whenReady().then(async () => {
    try {
      store = new Store(directory); store.lifecycle(); manual = store.items(); reminderHours = store.reminderSettings();
      panel = makeWindow({width:54,height:18,minWidth:54,minHeight:18,frame:false,transparent:true,backgroundColor:'#00000000',resizable:false,skipTaskbar:true,alwaysOnTop:true,show:false},'float');
      panel.setAlwaysOnTop(true,'screen-saver');
      panel.setVisibleOnAllWorkspaces(true,{visibleOnFullScreen:true});
      if (process.platform === 'win32') panel.setBackgroundMaterial('acrylic');
      panel.setBounds(geometry(store.state.panelCollapsed !== false,false));
      if (Array.isArray(store.state.position) && store.state.position.length === 2 && store.state.position.every(Number.isFinite)) {
        const area = screen.getDisplayNearestPoint({x:store.state.position[0],y:store.state.position[1]}).workArea;
        const size = panel.getBounds(); panel.setPosition(Math.max(area.x,Math.min(store.state.position[0],area.x+area.width-size.width)),Math.max(area.y,Math.min(store.state.position[1],area.y+area.height-size.height)));
      }
      panel.on('close',event => { if (!quitting) { event.preventDefault(); panel.hide(); } });
      panel.once('ready-to-show',() => { panel.show(); broadcast(); });
      const icon = nativeImage.createFromPath(path.join(__dirname,'icon.png')).resize({width:20,height:20});
      tray = new Tray(icon);
      tray.setContextMenu(Menu.buildFromTemplate([{label:'展开悬浮窗',click:() => expand(true)},{label:'管理记录',click:() => openManager()},{label:'立即刷新本地数据',click:refreshOfficial},{label:'悬浮窗归位',click:() => action('home')},{label:'打开数据文件夹',click:() => shell.openPath(directory)},{type:'separator'},{label:'彻底退出',click:() => { quitting = true; stopWatchdog(); app.quit(); }}]));
      tray.on('click',() => expand(true));
      ipcMain.handle('reminder:action',async (event,operation,payload) => {
        if (![panel,manager].some(w => w && !w.isDestroyed() && w.webContents === event.sender)) return {ok:false,error:'无效请求来源。'};
        try { return {ok:true,value:await action(operation,payload)}; } catch (e) { return {ok:false,error:e.message}; }
      });
      if (smoke) {
        await new Promise((resolve,reject) => { panel.webContents.once('did-finish-load',resolve); panel.webContents.once('did-fail-load',reject); });
        await runSmoke();
      } else {
        startWatchdog(); refreshOfficial();
        timerHandles.push(setInterval(refreshOfficial,60000),setInterval(tick,1000));
      }
    } catch (e) {
      if (smoke) { if (process.env.AR_SMOKE_RECEIPT) fs.writeFileSync(process.env.AR_SMOKE_RECEIPT,JSON.stringify({error:e.stack})); app.exit(1); }
      else { await dialog.showMessageBox({type:'error',title:'AI 到期提醒无法启动',message:e.message,detail:'现有数据已保留，请从备份恢复或检查数据文件夹。'}); quitting = true; app.quit(); }
    }
  });
  app.on('window-all-closed',() => {});
  app.on('activate',() => { if (panel) expand(true); });
  app.on('before-quit',() => { quitting = true; stopWatchdog(); timerHandles.forEach(clearInterval); });
  app.on('will-quit',() => { store?.close(); });
}
