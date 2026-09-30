import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const directory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../Resources/adaptive');

test('production adaptive runtime has no network clients, listeners or credential-file access', () => {
  for (const name of fs.readdirSync(directory).filter(name => name.endsWith('.mjs'))) {
    const source = fs.readFileSync(path.join(directory, name), 'utf8');
    assert.doesNotMatch(source, /node:(?:net|http|https|dgram|tls)|\bfetch\s*\(|WebSocket|https?:\/\//, name);
    assert.doesNotMatch(source, /auth\.json|\.ssh|OPENAI_API_KEY|CHATGPT_TOKEN|['"]\.env(?:['"]|\/)/, name);
    assert.doesNotMatch(source, /get_usage_limits|mcpServer\/tool\/call|CODEX_CONTEXT_DESKTOP_CHECK|desktopCheck/, name);
  }
  assert.equal(fs.existsSync(path.join(directory, 'desktop-check.mjs')), false);
});

test('controller-generated requests are limited to native configuration and thread lifecycle', () => {
  const source = fs.readFileSync(path.join(directory, 'controller.mjs'), 'utf8');
  const methods = [...source.matchAll(/this\.request\('([^']+)'/g)].map(match => match[1]);
  assert.ok(methods.length > 0);
  for (const method of methods)
    assert.ok(['thread/read', 'thread/resume', 'thread/unsubscribe', 'thread/loaded/list', 'config/read'].includes(method), method);
});
