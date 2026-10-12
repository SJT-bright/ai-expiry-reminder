'use strict';
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const {spawn} = require('node:child_process');
if (process.platform !== 'win32') { console.log('Watchdog native acceptance requires Windows'); process.exit(0); }
const root = fs.mkdtempSync(path.join(os.tmpdir(),'AI-reminder-watchdog-'));
const marker = path.join(root,'pid.txt'), state = path.join(root,'state.json');
fs.writeFileSync(state,JSON.stringify({resident:true,panelCollapsed:true}));
const executable = process.argv[2], deadline = Date.now()+30000;
const wait = ms => new Promise(resolve => setTimeout(resolve,ms));
let oldPID, replacement;
async function awaitPID(excluded) {
  while (Date.now() < deadline) {
    const pid = fs.existsSync(marker) ? Number(fs.readFileSync(marker,'utf8')) : 0;
    if (pid > 0 && pid !== excluded) { try { process.kill(pid,0); return pid; } catch {} }
    await wait(200);
  }
  throw Error('Resident process did not become ready or restart');
}
(async () => {
  try {
    const child = spawn(executable,['--resident-acceptance-child','--disable-gpu'],{stdio:'ignore',windowsHide:true,env:{...process.env,AR_DATA_DIR:root,AR_ACCEPTANCE_PID_FILE:marker}});
    child.on('error',error => { console.error(error); });
    oldPID = await awaitPID(0);
    if (oldPID !== child.pid) throw Error('Unexpected process identity');
    await wait(1500);
    process.kill(oldPID,'SIGKILL');
    replacement = await awaitPID(oldPID);
    if (replacement === oldPID) throw Error('Process did not restart');
    await wait(1500);
    process.kill(replacement,0);
    const output = path.resolve('watchdog-smoke-results'); fs.mkdirSync(output,{recursive:true});
    fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify({platform:process.platform,arch:process.arch,previousPID:oldPID,replacementPID:replacement,checks:['isolated native executable identity','resident restarts after forced process termination','replacement process remains alive']},null,2));
    console.log(`Native watchdog ${process.arch}: restart verified`);
  } catch (error) {
    console.error('::error title=Resident acceptance::'+error.message); process.exitCode = 1;
  } finally {
    try { const data = JSON.parse(fs.readFileSync(state,'utf8')); data.resident = false; fs.writeFileSync(state,JSON.stringify(data)); } catch {}
    for (const pid of [replacement,oldPID]) if (pid) { try { process.kill(pid,'SIGKILL'); } catch {} }
    await wait(3000);
    fs.rmSync(root,{recursive:true,force:true});
  }
})();
