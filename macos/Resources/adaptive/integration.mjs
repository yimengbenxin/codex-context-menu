import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const resources = path.dirname(fileURLToPath(import.meta.url));
const support = path.join(os.homedir(), 'Library/Application Support/CodexContextTool');
const manifestPath = path.join(support, 'official-adaptive-runtime.json');
const statePath = path.join(support, 'official-adaptive-integration.json');
const backend = path.join(support, 'backend');
const binary = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex';
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const read = file => fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
const environmentKeys = ['CODEX_CLI_PATH', 'CODEX_APP_SERVER_FORCE_CLI', 'CODEX_MCP_NODE_PATH', 'CODEX_BROWSER_USE_NODE_PATH'];
const launchctl = args => execFileSync('/bin/launchctl', args, {encoding: 'utf8'}).trim();

function capability() {
  try {
    const manifest = read(manifestPath);
    const matched = manifest.accepted === true && manifest.officialSha256 === hash(binary)
      && manifest.nodeSha256 === hash('/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node')
      && ['boundary.mjs', 'controller.mjs', 'policy.mjs', 'resume-settings.mjs', 'integration.mjs', 'backend', '../context_config.py', '../thread_settings.py']
        .every(name => manifest.files?.[name])
      && Object.entries(manifest.files).every(([name, digest]) => hash(path.join(resources, name)) === digest);
    return {adaptive: matched, mechanism: 'official-round-boundary', integrationEnabled: read(statePath).enabled === true};
  } catch {
    return {adaptive: false, mechanism: 'official-round-boundary', integrationEnabled: false};
  }
}

function writeState(value) {
  const temporary = `${statePath}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), {mode: 0o600});
  fs.renameSync(temporary, statePath);
}

function activate() {
  launchctl(['setenv', 'CODEX_CLI_PATH', backend]);
  launchctl(['setenv', 'CODEX_APP_SERVER_FORCE_CLI', '1']);
  const node = '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node';
  for (const key of ['CODEX_MCP_NODE_PATH', 'CODEX_BROWSER_USE_NODE_PATH']) launchctl(['setenv', key, node]);
}

function restore(previous) {
  for (const key of environmentKeys) {
    const value = previous[key];
    launchctl(value ? ['setenv', key, value] : ['unsetenv', key]);
  }
}

try {
  const command = process.argv[2];
  const current = capability();
  const state = read(statePath);
  if (command === '--context-capability') process.stdout.write(JSON.stringify(current) + '\n');
  else if (command === '--validated') process.exit(current.adaptive ? 0 : 1);
  else if (command === '--enable-integration') {
    if (!current.adaptive) throw new Error('Official adaptive runtime changed or has not passed acceptance');
    fs.mkdirSync(support, {recursive: true, mode: 0o700});
    const previous = state.previous ?? Object.fromEntries(environmentKeys.map(key => [key, launchctl(['getenv', key])]));
    try { activate(); writeState({enabled: true, previous}); }
    catch (error) { restore(previous); throw error; }
    process.stdout.write(JSON.stringify({enabled: true, restartOnceForInitialActivation: true}) + '\n');
  } else if (command === '--restore-integration') {
    if (state.enabled && current.adaptive) activate();
    else if (state.enabled) restore(state.previous ?? {});
  } else if (command === '--restore-official') {
    if (state.enabled) restore(state.previous ?? {});
    writeState({...state, enabled: false});
  } else throw new Error('Unknown context integration action');
} catch (error) {
  process.stderr.write(error.message + '\n');
  process.exit(1);
}
