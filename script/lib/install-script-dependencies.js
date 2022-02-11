'use strict';

const childProcess = require('child_process');

const CONFIG = require('../config');

// Recognised by '@electron/get', used by the 'electron-mksnapshot' and 'electron-chromedriver' dependencies
process.env.ELECTRON_CUSTOM_VERSION = CONFIG.appMetadata.electronVersion;

module.exports = function(ci, yarn) {
  console.log('Installing script dependencies using ' + (yarn ? 'yarn' : 'npm'));
  let pkgManager;
  if (yarn)
    pkgManager = process.platform === 'win32' ? 'yarn.cmd' : 'yarn';
  else
    pkgManager = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  childProcess.execFileSync(
    pkgManager,
    ['--loglevel=error', ci ? 'ci' : 'install'],
    { env: process.env, cwd: CONFIG.scriptRootPath }
  );
};
