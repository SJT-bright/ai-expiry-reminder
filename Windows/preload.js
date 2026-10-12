'use strict';
const {contextBridge,ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('reminder', {
  call: (operation,payload) => ipcRenderer.invoke('reminder:action',operation,payload),
  onUpdate: listener => ipcRenderer.on('reminder:update',(_event,value) => listener(value))
});
