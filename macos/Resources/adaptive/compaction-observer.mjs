import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const execute = promisify(execFile);
const script = fileURLToPath(new URL('../compaction_observations.py', import.meta.url));
const count = value => Number.isSafeInteger(value) && value >= 0 ? value : null;

export class CompactionObserver {
  constructor(controller, write, clock = Date.now) {
    this.controller = controller;
    this.clock = clock;
    this.usage = new Map();
    this.pending = new Map();
    this.writes = Promise.resolve();
    this.write = write ?? (row => execute(controller.python(), ['-B', script, 'record', JSON.stringify(row)],
      {env: {...process.env, CODEX_HOME: controller.home}, timeout: 3000, maxBuffer: 4096}));
  }

  observe(message) {
    try { this.capture(message); }
    catch { process.stderr.write('Compaction observations: malformed notification ignored; conversation unaffected\n'); }
  }

  capture(message) {
    const params = message.params ?? {};
    const thread = params.threadId;
    const session = this.controller.sessions.get(thread);
    if (!session || session.provider !== 'openai') return;
    if (message.method === 'thread/tokenUsage/updated') {
      const last = params.tokenUsage?.last;
      const usage = {input: count(last?.inputTokens), total: count(last?.totalTokens),
        window: count(params.tokenUsage?.modelContextWindow), model: session.model, at: this.clock()};
      this.usage.set(thread, usage);
      const pending = this.pending.get(thread);
      if (pending) pending.after = usage.total;
    }
    if (message.method === 'item/started' && params.item?.type === 'contextCompaction' && session.context
        && typeof params.item.id === 'string' && typeof params.turnId === 'string') {
      if (this.pending.get(thread)?.item === params.item.id) return;
      if (this.pending.has(thread)) this.finish(thread, 'incomplete');
      const context = session.context;
      const reported = this.usage.get(thread);
      const known = reported?.model === context.bounds.model && reported?.window === context.expected;
      this.pending.set(thread, {item: params.item.id, turn: params.turnId,
        start: this.clock(), after: null, row: {
          project: crypto.createHash('sha256').update(context.root).digest('hex'), thread,
          model: context.bounds.model, budget: context.budget ?? context.bounds.tiers[0],
          percent: context.effective_percent ?? null, scope: context.scope,
          target: known && context.effective_percent !== undefined ? context.expected : null,
          before_input: known ? reported.input : null, before_total: known ? reported.total : null,
          usage_age_ms: known ? this.clock() - reported.at : null, manual: session.manual === true,
        }});
    }
    if (message.method === 'item/completed' && params.item?.type === 'contextCompaction'
        && this.pending.get(thread)?.item === params.item.id) this.finish(thread, 'completed');
    if (message.method === 'turn/completed' && this.pending.has(thread))
      this.finish(thread, params.turn?.status === 'completed' ? 'incomplete' : 'failed');
  }

  finish(thread, status) {
    const pending = this.pending.get(thread);
    if (!pending) return;
    this.pending.delete(thread);
    const row = {...pending.row, id: crypto.createHash('sha256').update(JSON.stringify([thread, pending.turn, pending.item])).digest('hex'),
      status, at: pending.start, duration_ms: Math.max(0, this.clock() - pending.start), after_total: pending.after};
    this.writes = this.writes.then(() => this.write(row)).catch(() => {
      process.stderr.write('Compaction observations: local statistics could not be saved; conversation unaffected\n');
    });
  }

  close() {
    for (const thread of this.pending.keys()) this.finish(thread, 'incomplete');
    return this.writes;
  }
}
