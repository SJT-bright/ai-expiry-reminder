'use strict';
const {spawnSync} = require('node:child_process');
// electron-builder 26.15 的 ARM64 过滤器与安装时的 Nsis7z 解码器不兼容。
// 使用双方均支持的 BCJ，避免安装成功却漏掉 EXE/DLL。
// https://github.com/electron-userland/electron-builder/issues/9983
const result = spawnSync(process.execPath,[require.resolve('electron-builder/cli.js'),'--win',...process.argv.slice(2)],{stdio:'inherit',env:{...process.env,ELECTRON_BUILDER_7Z_FILTER:'BCJ'}});
if (result.error) { console.error(result.error.message); process.exit(1); }
process.exit(result.status ?? 1);
