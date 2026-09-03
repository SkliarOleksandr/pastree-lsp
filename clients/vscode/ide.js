// RAD Studio discovery for the VS Code client - the environment the server
// cannot see and the RAD Studio package gets for free from ToolsAPI.
//
// Two things the .dproj alone does not give the server:
//   1. The IDE's Library paths (Tools > Options > Library > Browsing Path and
//      Search Path). The RTL/VCL SOURCE lives on the Browsing Path, not on any
//      project search path - so without this every `System.SysUtils` is an
//      F1027 "Unit not found" and no identifier from outside the project
//      resolves. Third-party libraries registered with the IDE live on the
//      Search Path, usually through the IDE's own $(macro) overrides
//      (Tools > Options > Environment Variables) that nothing outside the
//      IDE's registry hive knows.
//   2. The $(BDS)/$(BDSLIB)/... variables a .dproj's own search paths are
//      written in. The server expands them from the PROCESS environment (see
//      PasTree.DProj SeedEnv), which rsvars.bat sets for a build and nothing
//      sets for an editor launched from the Start menu.
//
// This is GetIDELibraryPaths from clients/rad-studio/PasTreeIdePlugin.
// LspSession.pas, rewritten over `reg query` because a Node process has no
// ToolsAPI: same registry values, same macro expansion order (Platform, the
// IDE's Environment Variables overrides, then the built-ins), same filtering
// (unexpanded macro = drop the entry; only existing directories; dedupe).
// Keep the two in step - a difference is a unit that resolves in one client
// and not the other, with F1027 as the only symptom.
//
// Windows-only by nature, like the server.

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HIVE = 'HKCU\\Software\\Embarcadero\\BDS';

// `reg query` output parsed into { values: {name: value}, subkeys: [name] }.
// Returns empty sets for a missing key rather than throwing: every key read
// here is optional configuration.
function regQuery(key) {
  const result = { values: {}, subkeys: [] };
  let out;
  try {
    out = execFileSync('reg', ['query', key], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true,
    });
  } catch (e) {
    return result;
  }
  for (const rawLine of out.split(/\r?\n/)) {
    const line = rawLine.replace(/\s+$/, '');
    if (!line) { continue; }
    if (/^HKEY_/i.test(line)) {
      if (line.toLowerCase() !== key.toLowerCase().replace(/^HKCU/i, 'HKEY_CURRENT_USER')
          .replace(/^HKLM/i, 'HKEY_LOCAL_MACHINE')) {
        result.subkeys.push(path.basename(line));
      }
      continue;
    }
    // "    Name    REG_SZ    value" - four-space separated; the value may be
    // empty, and names ("Search Path") contain single spaces.
    const m = /^\s{4}(.+?)\s{4}(REG_[A-Z_]+)(?:\s{4}(.*))?$/.exec(line);
    if (!m) { continue; }
    let value = m[3] || '';
    if (m[2] === 'REG_EXPAND_SZ') {
      value = value.replace(/%([^%]+)%/g, (all, name) => process.env[name] || all);
    }
    result.values[m[1]] = value;
  }
  return result;
}

function pickVersion(requested) {
  if (requested) { return requested; }
  const versions = regQuery(HIVE).subkeys
    .filter(v => /^\d+\.\d+$/.test(v))
    .sort((a, b) => parseFloat(b) - parseFloat(a));
  for (const v of versions) {
    if (regQuery(`${HIVE}\\${v}`).values.RootDir) { return v; }
  }
  return versions[0] || '';
}

// { version, rootDir, env, paths } or null when no IDE is registered.
// opts: { platform: 'Win32'|'Win64'|..., version: '' | '37.0', log: fn }
function discover(opts) {
  const log = (opts && opts.log) || (() => {});
  if (process.platform !== 'win32') { return null; }
  const platform = (opts && opts.platform) || 'Win32';
  const version = pickVersion(opts && opts.version);
  if (!version) { log('RAD Studio: no version under ' + HIVE); return null; }
  const base = `${HIVE}\\${version}`;
  let rootDir = regQuery(base).values.RootDir ||
    regQuery(base.replace(/^HKCU/, 'HKLM')).values.RootDir || '';
  if (!rootDir) { log(`RAD Studio ${version}: no RootDir`); return null; }
  rootDir = rootDir.replace(/[\\/]+$/, '');

  // Macros, in the order the IDE resolves them: the platform, the user's own
  // overrides, then the built-ins - an override may redefine a built-in
  // (BDSCOMMONDIR is a common one), so overrides win.
  const publicDocs = path.join(process.env.PUBLIC || 'C:\\Users\\Public', 'Documents');
  const userDocs = path.join(os.homedir(), 'Documents');
  const builtins = {
    BDS: rootDir,
    BDSLIB: path.join(rootDir, 'lib'),
    BDSINCLUDE: path.join(rootDir, 'include'),
    BDSBIN: path.join(rootDir, 'bin'),
    BDSCOMMONDIR: path.join(publicDocs, 'Embarcadero', 'Studio', version),
    BDSUSERDIR: path.join(userDocs, 'Embarcadero', 'Studio', version),
    BDSPROJECTSDIR: path.join(userDocs, 'Embarcadero', 'Studio', 'Projects'),
    LANGDIR: 'EN',
    PRODUCTVERSION: version,
  };
  const overrides = regQuery(`${base}\\Environment Variables`).values;
  const macros = Object.assign({}, builtins, overrides, { Platform: platform });
  const macroNames = Object.keys(macros);

  function expand(text) {
    let s = text;
    for (let pass = 0; pass < 4 && s.includes('$('); pass++) {
      for (const name of macroNames) {
        s = s.replace(new RegExp('\\$\\(' + name + '\\)', 'gi'), macros[name]);
      }
    }
    return s;
  }

  const seen = new Set();
  const paths = [];
  function addPathList(list) {
    for (const raw of (list || '').split(';')) {
      let p = raw.trim();
      if (!p) { continue; }
      p = expand(p);
      // An unexpanded macro is a variable nobody here can resolve; the server
      // would only look for a literal '$'.
      if (p.includes('$(')) { continue; }
      try {
        p = path.resolve(p).replace(/[\\/]+$/, '');
        if (!fs.statSync(p).isDirectory()) { continue; }
      } catch (e) {
        continue;   // junk accumulates in these lists; one bad entry costs itself
      }
      const key = p.toLowerCase();
      if (seen.has(key)) { continue; }
      seen.add(key);
      paths.push(p);
    }
  }

  // A platform never selected in the IDE has no Library key; Win32 always has.
  let lib = regQuery(`${base}\\Library\\${platform}`).values;
  if (!lib['Search Path'] && !lib['Browsing Path']) {
    lib = regQuery(`${base}\\Library\\Win32`).values;
  }
  // Browsing Path first: RTL/VCL/ToolsAPI source, the paths most lookups hit.
  addPathList(lib['Browsing Path']);
  addPathList(lib['Search Path']);

  // Last resort: the source tree under the IDE root, every subdirectory.
  if (paths.length === 0) {
    const src = path.join(rootDir, 'source');
    const walk = dir => {
      addPathList(dir);
      let entries = [];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
      for (const e of entries) {
        if (e.isDirectory()) { walk(path.join(dir, e.name)); }
      }
    };
    walk(src);
  }

  // The process environment rsvars.bat would have set, for the .dproj's own
  // $(BDS)-relative paths. Only the variables the server's SeedEnv reads.
  const env = {};
  for (const name of ['BDS', 'BDSLIB', 'BDSINCLUDE', 'BDSBIN', 'BDSCOMMONDIR',
    'BDSPROJECTSDIR', 'PRODUCTVERSION']) {
    env[name] = macros[name];
  }
  log(`RAD Studio ${version} at ${rootDir}: ${paths.length} library paths for ${platform}` +
    (Object.keys(overrides).length ? `, ${Object.keys(overrides).length} macro overrides` : ''));
  return { version, rootDir, env, paths };
}

module.exports = { discover, regQuery };
