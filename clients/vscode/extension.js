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
    // The server does not watch the file system itself (see its
    // HandleDidChangeWatchedFiles): an editor already knows about these
    // events, so the client forwards them as workspace/didChangeWatchedFiles
    // and the server decides whether a rebuild is due.
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher(
        '**/*.{pas,dpr,dpk,inc,dproj}'),
    },
    initializationOptions: {
      projectFile: cfg.get('projectFile') || '',
      platform: cfg.get('platform') || 'Win64',
      config: cfg.get('config') || '',
      logFile: cfg.get('logFile') || '',
      logUnits: cfg.get('logUnits') || false,
      moduleRedoLimit: cfg.get('moduleRedoLimit') || 0,
      searchPaths: cfg.get('searchPaths') || [],
      defines: cfg.get('defines') || [],
    },
    middleware: {
      // Block completion (onTypeFormatting after Enter): the server's plan
      // re-indents the caret line to the BODY indentation and inserts the
      // closer below - but where the cursor lands after those edits is up
      // to VS Code's marker anchoring, and live runs got all three
      // outcomes (stayed put mid-indent, rode past the closer, worked).
      // So the cursor is placed EXPLICITLY, the way the RAD plugin does:
      // the single-line edit on the caret's own line carries the body
      // indent, and its length is the column typing should resume at.
      provideOnTypeFormattingEdits: async (document, position, ch, options, token, next) => {
        const edits = await next(document, position, ch, options, token);
        if (edits && edits.length) {
          const indentEdit = edits.find(e =>
            e.range.start.line === position.line && !e.newText.includes('\n'));
          if (indentEdit) {
            // After VS Code applies the returned edits - hence the
            // deferral; applying happens right after this returns.
            setTimeout(() => {
              const editor = vscode.window.activeTextEditor;
              if (editor && editor.document === document) {
                const target = new vscode.Position(
                  position.line, indentEdit.newText.length);
                editor.selection = new vscode.Selection(target, target);
              }
            }, 0);
          }
        }
        return edits;
      },
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
