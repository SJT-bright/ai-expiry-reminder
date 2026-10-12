'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const output = path.resolve(process.env.AR_SMOKE_OUTPUT || 'smoke-results');
fs.mkdirSync(output,{recursive:true});
const data = fs.mkdtempSync(path.join(os.tmpdir(),'AI提醒-验收 # '));
const executable = process.argv[2] || require('electron');
const args = process.argv[2] ? ['--smoke-test'] : [path.resolve(__dirname,'..'),'--smoke-test'];
const receipt = path.join(output,'native-smoke-receipt.json');
const child = spawn(executable,[...args,'--disable-gpu'],{env:{...process.env,AR_DATA_DIR:data,AR_SMOKE_RECEIPT:receipt,AR_SMOKE_SCREENSHOT:path.join(output,'management.png')},stdio:['ignore','pipe','pipe']});
let log = '';
child.stdout.on('data',data => { log += data.toString(); }); child.stderr.on('data',data => { log += data.toString(); });
const timeout = setTimeout(() => { child.kill(); fs.writeFileSync(path.join(output,'native-smoke.log'),log+'\nTimed out'); process.exit(1); },90000);
child.on('error',error => { clearTimeout(timeout); fs.writeFileSync(path.join(output,'native-smoke.log'),String(error)); process.exit(1); });
child.on('exit',code => {
  clearTimeout(timeout); fs.writeFileSync(path.join(output,'native-smoke.log'),log);
  if (code !== 0 || !fs.existsSync(receipt)) { console.error(log); process.exit(1); }
  const result = JSON.parse(fs.readFileSync(receipt));
  if (result.error || !result.checks?.length) { console.error(result); process.exit(1); }
  console.log(`Native ${result.platform}/${result.arch}: ${result.checks.length} checks passed, Electron ${result.electron}`);
  fs.rmSync(data,{recursive:true,force:true});
});
