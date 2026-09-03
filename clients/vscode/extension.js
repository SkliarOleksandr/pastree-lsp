// Development VS Code client for the PasTree LSP server.
//
// Deliberately minimal: everything interesting happens server-side, and this
// file should stay small enough that "is the bug in the client?" is
// answerable by reading it. Server stderr shows up in the "PasTree LSP"
// Output channel; the server's own file log is the deeper channel
// (pastree.logFile / PASTREE_LSP_TRACE=1).
//
// The one thing this client adds beyond wiring is what the RAD Studio package
// gets from ToolsAPI and an editor has to fetch itself: the IDE's library
// paths and $(BDS) environment, read from the registry by ide.js. Without
// them the RTL is a wall of F1027 - see that file's header.

const path = require('path');
const fs = require('fs');
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');
const ide = require('./ide');

let client;

function activate(context) {
  const cfg = vscode.workspace.getConfiguration('pastree');
  const output = vscode.window.createOutputChannel('PasTree LSP');
  context.subscriptions.push(output);
  const ownVersion = (context.extension && context.extension.packageJSON.version) || '';

  let serverPath = cfg.get('serverPath') || '';
  if (!serverPath) {
    // Dev default: the build output two levels up from clients/vscode/.
    serverPath = path.join(__dirname, '..', '..', 'out', 'pastree-server.exe');
  }
  if (!fs.existsSync(serverPath)) {
    vscode.window.showErrorMessage(
      'pastree-server.exe not found: ' + serverPath +
      ' - set pastree.serverPath or run build.bat');
    return;
  }

  const folders = vscode.workspace.workspaceFolders || [];
  const rootFolder = folders.length ? folders[0].uri.fsPath : '';

  // A relative projectFile is relative to the first workspace folder, so a
  // workspace's own .vscode/settings.json can name it portably.
  let projectFile = cfg.get('projectFile') || '';
  if (projectFile && !path.isAbsolute(projectFile) && rootFolder) {
    projectFile = path.join(rootFolder, projectFile);
  }
  if (!projectFile) {
    // Without a project the open documents are the analysis roots and their
    // uses clauses do not resolve - every unit an F1027. When the workspace
    // plainly has a project, say so rather than let the diagnostics say it.
    vscode.workspace.findFiles('**/*.dproj', '**/{node_modules,__history,__recovery}/**', 20)
      .then(files => {
        if (!files.length) { return; }
        const names = files.slice(0, 3).map(f => path.basename(f.fsPath)).join(', ');
        vscode.window.showWarningMessage(
          'PasTree: pastree.projectFile is not set, so only the open files are ' +
          'analyzed and their uses clauses will not resolve. The workspace has ' +
          files.length + ' project file(s): ' + names + (files.length > 3 ? ', ...' : ''),
          'Open Settings').then(choice => {
            if (choice) {
              vscode.commands.executeCommand('workbench.action.openSettings', 'pastree.projectFile');
            }
          });
      });
  }

  const platform = cfg.get('platform') || 'Win64';
  let ideInfo = null;
  if (cfg.get('ideLibraryPaths') !== false) {
    try {
      ideInfo = ide.discover({
        platform, version: cfg.get('ideVersion') || '',
        log: line => output.appendLine(line),
      });
    } catch (e) {
      output.appendLine('RAD Studio discovery failed: ' + (e && e.message));
    }
    if (!ideInfo) {
      vscode.window.showWarningMessage(
        'PasTree: no RAD Studio installation found in the registry. RTL/VCL ' +
        'units will report F1027 unless pastree.searchPaths covers their source.');
    }
  }

  // rsvars.bat's variables for the server process, so a .dproj's own
  // $(BDS)-relative paths expand - without overriding a shell that set them.
  const env = { ...process.env, PASTREE_LSP_TRACE: '1' };
  if (ideInfo) {
    for (const [name, value] of Object.entries(ideInfo.env)) {
      if (!env[name]) { env[name] = value; }
    }
  }
  const idePaths = ideInfo ? ideInfo.paths : [];

  const serverOptions = {
    command: serverPath,
    args: [],
    options: { env },
  };

  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'objectpascal' }],
    outputChannel: output,
    // The server does not watch the file system itself (see its
    // HandleDidChangeWatchedFiles): an editor already knows about these
    // events, so the client forwards them as workspace/didChangeWatchedFiles
    // and the server decides whether a rebuild is due.
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher(
        '**/*.{pas,dpr,dpk,inc,dproj}'),
    },
    initializationOptions: {
      projectFile,
      platform,
      config: cfg.get('config') || '',
      logFile: cfg.get('logFile') || '',
      logUnits: cfg.get('logUnits') || false,
      // Default TRUE, unlike logUnits: the configuration block is what most
      // log-reading starts from, so it goes away only when asked.
      logDetail: cfg.get('logDetail') !== false,
      moduleRedoLimit: cfg.get('moduleRedoLimit') || 0,
      // The user's own extra paths first, the IDE's after - same order the
      // RAD Studio package sends, and the same double role for the IDE's:
      // as searchPaths "look here", as libraryPaths "not the user's to
      // rewrite" (rename refuses to touch them).
      searchPaths: (cfg.get('searchPaths') || []).concat(idePaths),
      libraryPaths: idePaths,
      defines: cfg.get('defines') || [],
      host: 'VS Code ' + vscode.version + ', pastree-vscode ' + ownVersion,
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
            // AFTER the edits are actually in the buffer, not merely after
            // this returns: a plain setTimeout(0) fired BEFORE VS Code
            // applied them, and the premature selection then rode the
            // insertion to the far side of the closer (live run,
            // 2026-08-31). The next change to this document IS the
            // application of these edits - hook it once, place the cursor,
            // and time-box the listener so a cancelled apply cannot leak it.
            const targetLine = position.line;
            const targetCol = indentEdit.newText.length;
            const sub = vscode.workspace.onDidChangeTextDocument(ev => {
              if (ev.document !== document) { return; }
              sub.dispose();
              setTimeout(() => {
                const editor = vscode.window.activeTextEditor;
                if (editor && editor.document === document) {
                  const target = new vscode.Position(targetLine, targetCol);
                  editor.selection = new vscode.Selection(target, target);
                }
              }, 0);
            });
            setTimeout(() => sub.dispose(), 1000);
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
