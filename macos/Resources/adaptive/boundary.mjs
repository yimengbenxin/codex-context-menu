import {spawn} from 'node:child_process';
import readline from 'node:readline';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {AdaptiveController} from './controller.mjs';

const binary = process.env.CODEX_CONTEXT_OFFICIAL_BINARY ?? JSON.parse(fs.readFileSync(
  path.join(os.homedir(), 'Library/Application Support/CodexContextTool/official-adaptive-runtime.json'), 'utf8')).binary;
const argumentsList = process.argv.slice(2);
const appServer = argumentsList.includes('app-server') && !argumentsList.some(argument => argument.startsWith('generate-'));
const child = spawn(binary, argumentsList,
  {stdio: appServer ? ['pipe', 'pipe', 'inherit'] : 'inherit'});
let controller;

if (appServer) {
  const pending = new Map();
  const forwarded = new Map();
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = `context-controller-${crypto.randomUUID()}`;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Official API timed out: ${method}`)); }, 120000);
    pending.set(id, {resolve, reject, timer});
    child.stdin.write(JSON.stringify({id, method, params}) + '\n');
  });
  controller = new AdaptiveController(request);
  readline.createInterface({input: child.stdout}).on('line', line => {
    let message;
    try { message = JSON.parse(line); }
    catch { process.stdout.write(line + '\n'); return; }
    const waiting = pending.get(message.id);
    if (waiting && ('result' in message || 'error' in message)) {
      pending.delete(message.id);
      clearTimeout(waiting.timer);
      if (message.error) waiting.reject(new Error(message.error.message));
      else waiting.resolve(message.result);
      return;
    }
    if ('result' in message || 'error' in message) {
      const original = forwarded.get(message.id);
      controller.reply(original, message);
      forwarded.delete(message.id);
    } else controller.observe(message);
    process.stdout.write(line + '\n');
  });
  let sequence = Promise.resolve();
  readline.createInterface({input: process.stdin}).on('line', line => {
    let message;
    try { message = JSON.parse(line); }
    catch { child.stdin.write(line + '\n'); return; }
    if (!message.method) { child.stdin.write(line + '\n'); return; }
    sequence = sequence.then(async () => {
      let outbound = message;
      try { outbound = await controller.before(message); }
      catch (error) { process.stderr.write(`Adaptive context request preparation failed: ${error.message}\n`); }
      if ('id' in message) forwarded.set(message.id, outbound);
      child.stdin.write(JSON.stringify(outbound) + '\n');
    }).catch(error => process.stderr.write(`Adaptive context transport failed: ${error.message}\n`));
  }).on('close', () => sequence.finally(() => child.stdin.end()));
  child.on('exit', () => {
    for (const waiting of pending.values()) {
      clearTimeout(waiting.timer);
      waiting.reject(new Error('Official app-server exited'));
    }
  });
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('error', error => { process.stderr.write(error.message + '\n'); process.exit(1); });
child.on('exit', async code => {
  await controller?.writes;
  process.exit(code ?? 1);
});
