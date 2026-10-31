// Parity tests for the Pages configurator (site/app.js).
//
// The configurator must not become a second, drifting generator:
// its output is compared with the PowerShell generator's output
// for the same inputs, whenever pwsh is available, and its pure
// functions are checked against the schema in every run.
//
// Run: node tests/test_configurator.mjs
// Exits 0 when every case passes (or is skipped for a stated
// reason), 1 otherwise. The PowerShell parity cases SKIP, not
// fail, when pwsh is not on PATH, because this test must also be
// runnable on a machine that only has Node.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const schema = JSON.parse(readFileSync(join(repoRoot, 'schema', 'wsb-schema.json'), 'utf8'));
const app = require(join(repoRoot, 'site', 'app.js'));
const appSource = readFileSync(join(repoRoot, 'site', 'app.js'), 'utf8');
const siteHtml = readFileSync(join(repoRoot, 'site', 'index.html'), 'utf8');
const siteCss = readFileSync(join(repoRoot, 'site', 'style.css'), 'utf8');

let passed = 0;
let failed = 0;
function check(name, condition, detail = '') {
  if (condition) { passed++; console.log(`PASS: ${name}`); }
  else { failed++; console.log(`FAIL: ${name} ${detail}`); }
}

// Extract a simple element's text from generated XML. Nested
// blocks (MappedFolders, LogonCommand) are checked by substring
// instead, so this helper only needs the flat option elements.
function element(xml, name) {
  const match = xml.match(new RegExp(`<${name}>([^<]*)</${name}>`));
  return match ? match[1] : null;
}

function elementOrder(xml) {
  return schema.elementOrder.filter((name) => xml.includes(`<${name}>`));
}

// 1. The page must read its values from the schema, not carry a
//    second copy: the generator function references the schema's
//    option values and element order, and the source contains no
//    hardcoded profile block.
check('app.js reads schema.optionValues and schema.elementOrder',
  appSource.includes('schema.optionValues') && appSource.includes('schema.elementOrder'));
check('app.js has no hardcoded profile values block',
  !appSource.includes('Untrusted":{"AudioInput"') && !appSource.includes('"DevTest":{"AudioInput"'));

// Theme: system theme must work without JS (CSS media query),
// a manual choice must be able to override it (data-theme
// rules after the media query), and the control must exist.
check('site is theme-aware without JS (prefers-color-scheme)',
  siteCss.includes('@media (prefers-color-scheme: dark)'));
check('site manual theme overrides system theme (data-theme after media query)',
  siteCss.includes('html[data-theme="dark"]')
  && siteCss.indexOf('html[data-theme="dark"]') > siteCss.indexOf('@media (prefers-color-scheme: dark)'));
check('site theme control exists and is remembered',
  siteHtml.includes('id="theme"')
  && appSource.includes("localStorage.getItem('wsb-theme')")
  && appSource.includes("setAttribute('data-theme'"));

// 2. Untrusted defaults, no folder.
{
  const state = { profile: 'Untrusted', options: { ...schema.profiles.Untrusted }, memoryInMB: 4096, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' };
  const result = app.buildConfiguration(state, schema);
  check('JS Untrusted defaults', result.errors.length === 0
    && element(result.xml, 'Networking') === 'Disable'
    && element(result.xml, 'ClipboardRedirection') === 'Disable'
    && element(result.xml, 'ProtectedClient') === 'Enable'
    && element(result.xml, 'MemoryInMB') === '4096'
    && !result.xml.includes('<MappedFolders>'));
}

// 3. Overrides apply, and element order follows the schema.
{
  const state = { profile: 'DevTest', options: { ...schema.profiles.DevTest, Networking: 'Disable', vGPU: 'Disable' }, memoryInMB: 8192, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: 'notepad.exe' };
  const result = app.buildConfiguration(state, schema);
  const order = elementOrder(result.xml);
  // No mapping in this case, so MappedFolders is correctly absent;
  // the remaining elements must still appear in schema order.
  const expectedOrder = schema.elementOrder.filter((name) => name !== 'MappedFolders');
  check('JS overrides apply in schema order', result.errors.length === 0
    && element(result.xml, 'Networking') === 'Disable'
    && element(result.xml, 'vGPU') === 'Disable'
    && element(result.xml, 'MemoryInMB') === '8192'
    && result.xml.includes('<Command>notepad.exe</Command>')
    && JSON.stringify(order) === JSON.stringify(expectedOrder));
}

// 4. Memory floor, with a warning, matching the PowerShell generator.
{
  const state = { profile: 'DevTest', options: { ...schema.profiles.DevTest }, memoryInMB: 1024, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' };
  const result = app.buildConfiguration(state, schema);
  check('JS memory floor', result.errors.length === 0
    && element(result.xml, 'MemoryInMB') === '2048'
    && result.warnings.join(' ').includes('2048'));
}

// 5. Mapping: Untrusted default is read-only with the derived
//    sandbox folder; writable mappings warn.
{
  const state = { profile: 'Untrusted', options: { ...schema.profiles.Untrusted }, memoryInMB: 4096, hostFolder: 'C:\\Users\\Public\\Downloads\\untrusted', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' };
  const result = app.buildConfiguration(state, schema);
  check('JS Untrusted mapping is read-only with default sandbox folder', result.errors.length === 0
    && result.xml.includes('<HostFolder>C:\\Users\\Public\\Downloads\\untrusted</HostFolder>')
    && result.xml.includes('<SandboxFolder>C:\\Users\\WDAGUtilityAccount\\Desktop\\untrusted</SandboxFolder>')
    && result.xml.includes('<ReadOnly>true</ReadOnly>'));
  const writable = app.buildConfiguration({ ...state, mappingAccess: 'writable' }, schema);
  check('JS writable mapping warns', writable.errors.length === 0
    && writable.xml.includes('<ReadOnly>false</ReadOnly>')
    && writable.warnings.join(' ').includes('keeps its changes'));
}

// 6. Invalid inputs are errors, not silent fallbacks.
{
  const relative = app.buildConfiguration({ profile: 'Untrusted', options: { ...schema.profiles.Untrusted }, memoryInMB: 4096, hostFolder: 'relative\\folder', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' }, schema);
  check('JS rejects relative host folder', relative.errors.length > 0 && relative.xml === '');
  const badValue = app.buildConfiguration({ profile: 'Untrusted', options: { ...schema.profiles.Untrusted, Networking: 'Maybe' }, memoryInMB: 4096, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' }, schema);
  check('JS rejects bad option value', badValue.errors.length > 0 && badValue.xml === '');
  const badMemory = app.buildConfiguration({ profile: 'Untrusted', options: { ...schema.profiles.Untrusted }, memoryInMB: 'abc', hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' }, schema);
  check('JS rejects non-numeric memory', badMemory.errors.length > 0 && badMemory.xml === '');
  const escaped = app.buildConfiguration({ profile: 'DevTest', options: { ...schema.profiles.DevTest }, memoryInMB: 4096, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: 'a<b>&c' }, schema);
  check('JS escapes logon command XML', escaped.errors.length === 0 && escaped.xml.includes('<Command>a&lt;b&gt;&amp;c</Command>'));
}

// 7. PowerShell parity: same inputs, same parsed values. SKIP
//    when pwsh is not on PATH; Windows-only mapping parity is
//    skipped on other platforms, like the PowerShell tests.
function findPwsh() {
  try { return execFileSync(process.platform === 'win32' ? 'where' : 'which', ['pwsh'], { encoding: 'utf8' }).trim().split(/\r?\n/)[0]; }
  catch { return null; }
}
const pwsh = findPwsh();
if (!pwsh) {
  console.log('SKIP: PowerShell parity cases need pwsh on PATH');
} else {
  const dir = mkdtempSync(join(tmpdir(), 'wsb-configurator-parity-'));
  try {
    const psPath = join(repoRoot, 'scripts', 'New-SandboxConfig.ps1');
    const cases = [
      { name: 'Untrusted defaults', args: ['-Profile', 'Untrusted'], js: { profile: 'Untrusted', options: { ...schema.profiles.Untrusted }, memoryInMB: 4096, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: '' } },
      { name: 'DevTest overrides', args: ['-Profile', 'DevTest', '-Networking', 'Disable', '-VGpu', 'Disable', '-MemoryInMB', '8192', '-LogonCommand', 'notepad.exe'], js: { profile: 'DevTest', options: { ...schema.profiles.DevTest, Networking: 'Disable', vGPU: 'Disable' }, memoryInMB: 8192, hostFolder: '', sandboxFolder: '', mappingAccess: 'default', logonCommand: 'notepad.exe' } },
    ];
    for (const c of cases) {
      const out = join(dir, 'ps.wsb');
      execFileSync(pwsh, ['-NoProfile', '-File', psPath, ...c.args, '-OutputPath', out, '-SkipValidation'], { encoding: 'utf8' });
      const psXml = readFileSync(out, 'utf8');
      const jsXml = app.buildConfiguration(c.js, schema).xml;
      const names = ['vGPU', 'Networking', 'AudioInput', 'VideoInput', 'ProtectedClient', 'PrinterRedirection', 'ClipboardRedirection', 'MemoryInMB'];
      check(`PS parity: ${c.name}`, names.every((n) => element(psXml, n) === element(jsXml, n))
        && (psXml.includes('<Command>') === jsXml.includes('<Command>')));
    }
    if (process.platform === 'win32') {
      const host = join(dir, 'host');
      execFileSync(pwsh, ['-NoProfile', '-Command', `New-Item -Path '${host}' -ItemType Directory -Force | Out-Null`], { encoding: 'utf8' });
      const out = join(dir, 'mapped.wsb');
      execFileSync(pwsh, ['-NoProfile', '-File', psPath, '-Profile', 'Untrusted', '-HostFolder', host, '-OutputPath', out, '-SkipValidation'], { encoding: 'utf8' });
      const psXml = readFileSync(out, 'utf8');
      const jsXml = app.buildConfiguration({ profile: 'Untrusted', options: { ...schema.profiles.Untrusted }, memoryInMB: 4096, hostFolder: host, sandboxFolder: '', mappingAccess: 'default', logonCommand: '' }, schema).xml;
      check('PS parity: Windows mapping', psXml.includes('<HostFolder>' + host + '</HostFolder>')
        && jsXml.includes('<HostFolder>' + host + '</HostFolder>')
        && psXml.includes('<ReadOnly>true</ReadOnly>')
        && jsXml.includes('<ReadOnly>true</ReadOnly>'));
    } else {
      console.log('SKIP: Windows mapping parity is Windows only');
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`test_configurator: ${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
