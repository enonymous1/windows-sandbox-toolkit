// Windows Sandbox configurator: generates a .wsb file in the browser.
//
// This file contains no copy of the schema. Option values, allowed
// values, profiles, element order, the memory floor, and the sandbox
// desktop path all come from schema/wsb-schema.json, which the page
// fetches as schema.json. The Pages workflow copies that file into
// site/ at deploy time, so there is still exactly one source of
// truth; the PowerShell generator, the validator, the Python tests,
// and this page all read the same file.
//
// What this page deliberately cannot do: launch a sandbox, check
// the visitor's Windows edition or virtualization, enable the
// feature, or check that a mapped host folder exists on the target
// machine. The browser has no access to that machine's filesystem,
// and the file is often generated for a different machine anyway.
// Those checks are the PowerShell validator's job, on that machine.
//
// The pure functions below (escapeXml, isWindowsAbsolutePath,
// getFolderLeaf, buildConfiguration) have no DOM dependency, so
// tests/test_configurator.mjs can require this file in Node and
// compare its output with the PowerShell generator's output.

'use strict';

function escapeXml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

// Mirror of Test-WindowsAbsolutePath in scripts/SandboxSchema.psm1:
// drive paths (C:\...), UNC paths (\\server\share), and env-var
// paths (%USERPROFILE%\...) supported on Windows 11 23H2+.
function isWindowsAbsolutePath(path) {
  if (!path) { return false; }
  return /^[A-Za-z]:\\/.test(path) || /^\\\\/.test(path) || /^%[^%]+%[\\/]/.test(path);
}

// Mirror of Get-SandboxFolderLeaf: split on both separators, so a
// Windows path typed on any OS still yields its last segment.
function getFolderLeaf(hostFolder) {
  var segments = String(hostFolder).split(/[\\/]/).filter(function (s) { return s.length > 0; });
  if (segments.length === 0) { return 'shared'; }
  return segments[segments.length - 1];
}

function hasEnvVar(path) {
  return /%[^%]+%/.test(path);
}

// state: {
//   profile: 'Untrusted' | 'DevTest' | 'InstallerTest',
//   options: { vGPU: 'Enable', Networking: 'Disable', ... },
//   memoryInMB: number | string,
//   hostFolder: string, sandboxFolder: string,
//   mappingAccess: 'default' | 'readonly' | 'writable',
//   logonCommand: string
// }
// Returns { xml, warnings: [], errors: [] }. On errors, xml is ''.
function buildConfiguration(state, schema) {
  var warnings = [];
  var errors = [];
  var profile = schema.profiles[state.profile];
  if (!profile) {
    return { xml: '', warnings: warnings, errors: ['Unknown profile: ' + state.profile] };
  }

  // Options: a missing option falls back to the profile value, the
  // same way the PowerShell generator's Resolve-Option does. An
  // option outside the schema's allowed values is an error, not a
  // silent fallback, because a silently reverted option is exactly
  // how a generated file ends up more permissive than intended.
  var resolved = {};
  Object.keys(schema.optionValues).forEach(function (name) {
    var value = state.options && state.options[name] !== undefined ? state.options[name] : profile[name];
    if (schema.optionValues[name].indexOf(value) === -1) {
      errors.push('Invalid value for <' + name + '>: ' + value + '. Allowed: ' + schema.optionValues[name].join(', '));
    }
    resolved[name] = value;
  });

  var memory = parseInt(state.memoryInMB, 10);
  if (isNaN(memory)) {
    errors.push('MemoryInMB must be a number.');
    memory = profile.MemoryInMB;
  } else if (memory < schema.minMemoryInMB) {
    // Same as the PowerShell generator: raise, with a warning.
    warnings.push('MemoryInMB ' + memory + ' is below the ' + schema.minMemoryInMB + ' MB minimum and was raised to ' + schema.minMemoryInMB + '.');
    memory = schema.minMemoryInMB;
  }

  var mapping = null;
  if (state.hostFolder) {
    if (!isWindowsAbsolutePath(state.hostFolder)) {
      errors.push("HostFolder must be an absolute Windows path, for example 'C:\\Users\\Public\\Downloads\\untrusted'. Got: " + state.hostFolder);
    } else {
      var readOnly;
      if (state.mappingAccess === 'readonly') { readOnly = true; }
      else if (state.mappingAccess === 'writable') { readOnly = false; }
      else { readOnly = (state.profile === 'Untrusted'); }

      var sandboxFolder = state.sandboxFolder || (schema.sandboxDesktop + '\\' + getFolderLeaf(state.hostFolder));
      if (state.sandboxFolder && !isWindowsAbsolutePath(state.sandboxFolder)) {
        errors.push('SandboxFolder must be an absolute Windows path. Got: ' + state.sandboxFolder);
      } else {
        mapping = { hostFolder: state.hostFolder, sandboxFolder: sandboxFolder, readOnly: readOnly };
        if (readOnly === false) {
          warnings.push('Writable mapped folder ' + state.hostFolder + ' keeps its changes after the sandbox closes.');
        }
        // The browser cannot check this folder on the target
        // machine. Say so explicitly instead of implying a check
        // happened; the validator on that machine is the check.
        if (hasEnvVar(state.hostFolder)) {
          warnings.push('HostFolder uses an environment variable that cannot be checked here; Windows Sandbox supports env-var paths on Windows 11 23H2 and later. Check the folder exists on the target machine before launching.');
        } else {
          warnings.push('This page cannot check that the mapped host folder exists on the target machine. Windows Sandbox fails to start when it does not; run the validator on that machine first if you are unsure.');
        }
      }
    }
  } else if (state.sandboxFolder) {
    warnings.push('SandboxFolder is ignored without a HostFolder, matching the PowerShell generator.');
  }

  if (errors.length > 0) {
    return { xml: '', warnings: warnings, errors: errors };
  }

  // Build in the schema's element order, exactly as the PowerShell
  // generator does. Order does not change Sandbox behaviour, but
  // keeping it identical is what makes the parity test meaningful.
  var lines = ['<?xml version="1.0" encoding="utf-8"?>', '<Configuration>'];
  schema.elementOrder.forEach(function (name) {
    if (name === 'MappedFolders') {
      if (mapping) {
        lines.push('  <MappedFolders>');
        lines.push('    <MappedFolder>');
        lines.push('      <HostFolder>' + escapeXml(mapping.hostFolder) + '</HostFolder>');
        lines.push('      <SandboxFolder>' + escapeXml(mapping.sandboxFolder) + '</SandboxFolder>');
        lines.push('      <ReadOnly>' + (mapping.readOnly ? 'true' : 'false') + '</ReadOnly>');
        lines.push('    </MappedFolder>');
        lines.push('  </MappedFolders>');
      }
    } else if (name === 'LogonCommand') {
      if (state.logonCommand) {
        lines.push('  <LogonCommand>');
        lines.push('    <Command>' + escapeXml(state.logonCommand) + '</Command>');
        lines.push('  </LogonCommand>');
      }
    } else if (name === 'MemoryInMB') {
      lines.push('  <MemoryInMB>' + memory + '</MemoryInMB>');
    } else {
      lines.push('  <' + name + '>' + escapeXml(resolved[name]) + '</' + name + '>');
    }
  });
  lines.push('</Configuration>');
  return { xml: lines.join('\n') + '\n', warnings: warnings, errors: errors };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { escapeXml: escapeXml, isWindowsAbsolutePath: isWindowsAbsolutePath, getFolderLeaf: getFolderLeaf, buildConfiguration: buildConfiguration };
}

// ---- Browser wiring: only runs where there is a DOM. ----

if (typeof document !== 'undefined') {
  // Short, plain-language help for each option. These are display
  // text only; they carry no values and cannot drift the schema.
  var optionHelp = {
    vGPU: 'Share the host GPU into the sandbox. Off uses software rendering and shrinks the attack surface.',
    Networking: 'Let the sandbox reach the network. Off is the safe choice for software you do not trust.',
    AudioInput: 'Share the host microphone into the sandbox.',
    VideoInput: 'Share the host webcam into the sandbox.',
    ProtectedClient: 'Run the sandbox in AppContainer isolation. It can restrict copy/paste in and out.',
    PrinterRedirection: 'Share host printers into the sandbox.',
    ClipboardRedirection: 'Allow text and files to be pasted between host and sandbox.'
  };

  // Theme: Auto follows the system (CSS media query, so it works
  // even without JS). A manual Light/Dark choice sets data-theme
  // on <html>, overriding the media query, and is remembered in
  // localStorage under 'wsb-theme'. This runs independently of
  // the schema load, so the theme control works even if the
  // schema fails to load.
  var themeSelect = document.getElementById('theme');
  function applyTheme() {
    var stored = null;
    try { stored = localStorage.getItem('wsb-theme'); } catch (e) { stored = null; }
    if (stored === 'light' || stored === 'dark') {
      document.documentElement.setAttribute('data-theme', stored);
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
    if (themeSelect) { themeSelect.value = stored || 'auto'; }
  }
  if (themeSelect) {
    themeSelect.addEventListener('change', function () {
      try {
        if (themeSelect.value === 'auto') { localStorage.removeItem('wsb-theme'); }
        else { localStorage.setItem('wsb-theme', themeSelect.value); }
      } catch (e) { /* localStorage unavailable: apply for this visit only. */ }
      applyTheme();
    });
  }
  if (typeof window !== 'undefined' && window.matchMedia) {
    var darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
    // Re-apply on system-theme change; only matters for Auto,
    // because a manual choice sets data-theme and wins in CSS.
    if (darkQuery.addEventListener) { darkQuery.addEventListener('change', applyTheme); }
    else if (darkQuery.addListener) { darkQuery.addListener(applyTheme); }
  }
  applyTheme();

  var schema = null;
  var profileSelect = document.getElementById('profile');
  var optionsDiv = document.getElementById('options');
  var memoryInput = document.getElementById('memory');
  var hostInput = document.getElementById('hostFolder');
  var sandboxInput = document.getElementById('sandboxFolder');
  var sandboxHint = document.getElementById('sandboxHint');
  var accessSelect = document.getElementById('mappingAccess');
  var logonInput = document.getElementById('logonCommand');
  var filenameInput = document.getElementById('filename');
  var warningsList = document.getElementById('warnings');
  var errorsList = document.getElementById('errors');
  var preview = document.getElementById('preview');
  var downloadButton = document.getElementById('download');
  var copyButton = document.getElementById('copy');
  var schemaError = document.getElementById('schemaError');

  function readState() {
    var options = {};
    optionsDiv.querySelectorAll('select[data-option]').forEach(function (select) {
      options[select.getAttribute('data-option')] = select.value;
    });
    return {
      profile: profileSelect.value,
      options: options,
      memoryInMB: memoryInput.value,
      hostFolder: hostInput.value.trim(),
      sandboxFolder: sandboxInput.value.trim(),
      mappingAccess: accessSelect.value,
      logonCommand: logonInput.value.trim()
    };
  }

  function applyProfile() {
    var profile = schema.profiles[profileSelect.value];
    optionsDiv.querySelectorAll('select[data-option]').forEach(function (select) {
      select.value = profile[select.getAttribute('data-option')];
    });
    memoryInput.value = profile.MemoryInMB;
    render();
  }

  function render() {
    var state = readState();
    var result = buildConfiguration(state, schema);

    warningsList.innerHTML = '';
    result.warnings.forEach(function (warning) {
      var li = document.createElement('li');
      li.textContent = warning;
      warningsList.appendChild(li);
    });
    errorsList.innerHTML = '';
    result.errors.forEach(function (error) {
      var li = document.createElement('li');
      li.textContent = error;
      errorsList.appendChild(li);
    });

    if (state.hostFolder && !state.sandboxFolder) {
      sandboxHint.textContent = 'Will use: ' + schema.sandboxDesktop + '\\' + getFolderLeaf(state.hostFolder);
    } else {
      sandboxHint.textContent = '';
    }

    if (result.errors.length > 0) {
      preview.textContent = 'Fix the errors above to generate a .wsb file.';
      downloadButton.disabled = true;
      copyButton.disabled = true;
    } else {
      preview.textContent = result.xml;
      downloadButton.disabled = false;
      copyButton.disabled = false;
    }
  }

  function safeFilename() {
    var name = (filenameInput.value || 'sandbox.wsb').trim().replace(/[\\/]/g, '');
    if (!name) { name = 'sandbox.wsb'; }
    if (!/\.wsb$/i.test(name)) { name += '.wsb'; }
    return name;
  }

  downloadButton.addEventListener('click', function () {
    var blob = new Blob([preview.textContent], { type: 'application/xml;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var link = document.createElement('a');
    link.href = url;
    link.download = safeFilename();
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  });

  copyButton.addEventListener('click', function () {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(preview.textContent);
    } else {
      var area = document.createElement('textarea');
      area.value = preview.textContent;
      document.body.appendChild(area);
      area.select();
      document.execCommand('copy');
      area.remove();
    }
  });

  document.getElementById('configurator').addEventListener('input', render);
  profileSelect.addEventListener('change', applyProfile);
  document.getElementById('resetProfile').addEventListener('click', applyProfile);

  // Schema is the only source of values: profiles and option
  // selects are built from it, never typed into this page.
  fetch('schema.json').then(function (response) {
    if (!response.ok) { throw new Error('HTTP ' + response.status); }
    return response.json();
  }).then(function (loaded) {
    schema = loaded;
    Object.keys(schema.profiles).forEach(function (name) {
      var option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      profileSelect.appendChild(option);
    });
    // Untrusted is the safe default, matching the PowerShell
    // generator's default profile.
    profileSelect.value = schema.profiles.Untrusted ? 'Untrusted' : Object.keys(schema.profiles)[0];
    Object.keys(schema.optionValues).forEach(function (name) {
      var wrapper = document.createElement('div');
      wrapper.className = 'field';
      var label = document.createElement('label');
      label.textContent = name;
      var select = document.createElement('select');
      select.setAttribute('data-option', name);
      schema.optionValues[name].forEach(function (value) {
        var option = document.createElement('option');
        option.value = value;
        option.textContent = value;
        select.appendChild(option);
      });
      var help = document.createElement('p');
      help.className = 'help';
      help.textContent = optionHelp[name] || '';
      wrapper.appendChild(label);
      wrapper.appendChild(select);
      wrapper.appendChild(help);
      optionsDiv.appendChild(wrapper);
    });
    applyProfile();
  }).catch(function () {
    schemaError.hidden = false;
    schemaError.textContent = 'Could not load schema.json. This page needs its schema file: on GitHub Pages it is copied into site/ at deploy time; locally, copy schema/wsb-schema.json to site/schema.json and serve site/ over HTTP (for example: python3 -m http.server, from site/) instead of opening the file directly, because browsers block fetch() from file:// pages.';
  });
}
