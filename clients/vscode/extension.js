// Development VS Code client for the PasTree LSP server.
//
// Deliberately minimal: everything interesting happens server-side, and this
// file should stay small enough that "is the bug in the client?" is
// answerable by reading it. Server stderr shows up in the "PasTree LSP"
// Output channel; the server's own file log is the deeper channel
// (pastree.logFile / PASTREE_LSP_TRACE=1).

const path = require('path');
const fs = require('fs');
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;

function activate(context) {
  const cfg = vscode.workspace.getConfiguration('pastree');

  let serverPath = cfg.get('serverPath') || '';
  if (!serverPath) {
    // Dev default: the build output two levels up from clients/vscode/.
    serverPath = path.join(__dirname, '..', '..', 'out', 'pastree-server.exe');
  }
  if (!fs.existsSync(serverPath)) {
    vscode.window.showErrorMessage(
      'pastree-server.exe not found: ' + serverPath +
      ' — set pastree.serverPath or run build.bat');
    return;
  }

  const serverOptions = {
    command: serverPath,
    args: [],
    options: { env: { ...process.env, PASTREE_LSP_TRACE: '1' } },
  };

  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'objectpascal' }],
    initializationOptions: {
      projectFile: cfg.get('projectFile') || '',
      platform: cfg.get('platform') || 'Win64',
      config: cfg.get('config') || '',
      logFile: cfg.get('logFile') || '',
      searchPaths: cfg.get('searchPaths') || [],
      defines: cfg.get('defines') || [],
    },
  };

  client = new LanguageClient(
    'pastree', 'PasTree LSP', serverOptions, clientOptions);
  client.start();
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
