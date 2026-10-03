import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {BudgetStore, modelBounds, compactionPolicy} from './policy.mjs';
import {resumeSettings} from './resume-settings.mjs';

const execute = promisify(execFile);
const resources = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

export class AdaptiveController {
  constructor(request, options = {}) {
    this.request = request;
    this.home = options.home ?? process.env.CODEX_HOME ?? path.join(os.homedir(), '.codex');
    this.store = new BudgetStore(path.join(this.home, 'adaptive-context'));
    this.sessions = new Map();
    this.settings = options.settings ?? this.projectSettings.bind(this);
    this.catalog = options.catalog ?? (() => JSON.parse(fs.readFileSync(path.join(this.home, 'models_cache.json'), 'utf8')));
    this.log = options.log ?? (event => {
      const metadata = Object.fromEntries(Object.entries(event).filter(([key]) =>
        ['event', 'threadId', 'budget', 'adaptive', 'requested', 'observed', 'successful', 'manual'].includes(key)));
      process.stderr.write(`Adaptive context: ${JSON.stringify(metadata)}\n`);
      try {
        const directory = path.join(this.home, 'context-menu');
        fs.mkdirSync(directory, {recursive: true, mode: 0o700});
        const journal = path.join(directory, 'runtime-events.jsonl');
        if (fs.existsSync(journal) && fs.lstatSync(journal).isSymbolicLink()) return;
        if (fs.existsSync(journal) && fs.statSync(journal).size > 65536) fs.truncateSync(journal, 0);
        fs.appendFileSync(journal, JSON.stringify({time: new Date().toISOString(), pid: process.pid, ...metadata}) + '\n', {mode: 0o600});
      } catch { process.stderr.write('Adaptive context: runtime status recording unavailable\n'); }
    });
    this.writes = Promise.resolve();
  }

  python() {
    const python = [process.env.CODEX_CONTEXT_PYTHON, '/opt/homebrew/bin/python3', '/usr/local/bin/python3',
      path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3')]
      .find(candidate => candidate && fs.existsSync(candidate));
    if (!python) throw new Error('Context configuration runtime is unavailable');
    return python;
  }

  async projectSettings(cwd, threadID) {
    const command = threadID ? ['thread-status', cwd, threadID] : ['status', cwd];
    const {stdout} = await execute(this.python(), ['-B', path.join(resources, 'context_config.py'), ...command],
      {timeout: 20000, maxBuffer: 1024 * 1024});
    return JSON.parse(stdout);
  }

  async context(cwd, model, threadID) {
    if (!cwd || !model) return null;
    const settings = await this.settings(cwd, threadID);
    if (!settings.trusted) return null;
    const key = `${settings.root}\u0000${model}${settings.override ? `\u0000${threadID}` : ''}`;
    const effective = await this.request('config/read', {cwd, includeLayers: false});
    const adaptive = settings.override ? settings.adaptive : settings.effective_adaptive ?? settings.adaptive;
    const bounds = modelBounds(this.catalog(), model, adaptive ? settings.adaptive_options : undefined);
    const revision = settings.override ? settings.budget_revision ?? settings.revision : settings.project_budget_revision ?? settings.budget_revision ?? settings.project_revision ?? settings.revision;
    const state = adaptive ? this.store.get(key, revision, bounds) : null;
    const budget = state?.budget ?? (settings.override ? settings.window : effective.config.model_context_window) ?? null;
    const compact = effective.config.model_auto_compact_token_limit ?? null;
    const compression = compactionPolicy(bounds, budget, settings.compaction_percent,
      compact, effective.config.model_auto_compact_token_limit_scope ?? 'total');
    return {key, root: settings.root, revision, bounds, state,
      ...compression, adaptive, budget, signature: JSON.stringify([compression.nativeBudget, compression.compact, compression.scope])};
  }

  configuration(context, previous = {}) {
    const config = {...previous};
    delete config.model_context_window;
    delete config.model_auto_compact_token_limit;
    delete config.model_auto_compact_token_limit_scope;
    if (context.nativeBudget !== null) config.model_context_window = context.nativeBudget;
    if (context.compact !== null) config.model_auto_compact_token_limit = context.compact;
    config.model_auto_compact_token_limit_scope = context.scope;
    return config;
  }

  async before(message) {
    const params = message.params ?? {};
    if (['thread/start', 'thread/resume', 'thread/fork'].includes(message.method)) {
      let cwd = params.cwd;
      let model = params.model;
      let provider = params.modelProvider ?? params.config?.model_provider;
      if (message.method !== 'thread/start') {
        const read = await this.request('thread/read', {threadId: params.threadId, includeTurns: false});
        cwd ??= read.thread.cwd;
        model ??= read.thread.model;
        provider ??= read.thread.modelProvider;
      }
      if ((!model || !provider) && cwd) {
        const config = await this.request('config/read', {cwd, includeLayers: false});
        model ??= config.config.model;
        provider ??= config.config.model_provider ?? 'openai';
      }
      if (provider !== 'openai') return message;
      const context = await this.context(cwd, model, message.method === 'thread/resume' ? params.threadId : undefined);
      if (context) return {...message, params: {...params,
        config: this.configuration(context, params.config)}};
    }
    if (message.method === 'thread/compact/start') {
      const session = this.sessions.get(params.threadId);
      if (session) session.manual = true;
    }
    const startsGoal = message.method === 'thread/goal/set' && (!params.status || params.status === 'active');
    if (!startsGoal && !['turn/start', 'thread/queue/start'].includes(message.method)) return message;
    await this.writes;
    let session = this.sessions.get(params.threadId);
    if (!session) {
      const read = await this.request('thread/read', {threadId: params.threadId, includeTurns: false});
      session = {cwd: read.thread.cwd, model: read.thread.model, provider: read.thread.modelProvider};
      this.sessions.set(params.threadId, session);
    }
    if (session.provider && session.provider !== 'openai') return message;
    const context = await this.context(params.cwd ?? session.cwd, params.model ?? session.model, params.threadId);
    if (!context) return message;
    const expected = context.expected;
    const status = await this.request('thread/read', {threadId: params.threadId, includeTurns: false});
    if (status.thread.status?.type === 'active') {
      if (session.applied !== context.signature)
        this.log({event: 'budget_deferred_active_turn', threadId: params.threadId, requested: expected, observed: session.window});
      return message;
    }
    if (session.applied !== context.signature || (session.window !== undefined && session.window !== expected)) {
      const previous = session.window ?? expected;
      let preserved;
      let released = false;
      try {
        const current = await this.request('thread/resume', {threadId: params.threadId, excludeTurns: true});
        preserved = resumeSettings(current, session.configuration);
        this.log({event: 'round_boundary_reload_started', threadId: params.threadId, budget: context.budget});
        await this.request('thread/unsubscribe', {threadId: params.threadId});
        released = true;
        const config = this.configuration(context, preserved.config);
        await this.request('thread/resume', {...preserved, threadId: params.threadId, config});
        session.configuration = config;
        session.applied = context.signature;
        session.context = context;
        session.requestedWindow = expected;
        this.log({event: 'round_boundary_budget_requested', threadId: params.threadId, budget: context.budget, adaptive: context.adaptive});
      } catch (error) {
        if (released) await this.request('thread/resume', {...preserved, threadId: params.threadId,
          config: {...preserved.config, model_context_window: Math.ceil(previous * 100 / context.bounds.percent)}});
        this.log({event: 'expansion_failed_restored_previous', threadId: params.threadId, error: error.message});
      }
    } else session.context = context;
    session.compacted = false;
    session.manual = false;
    session.compactionSamples = [];
    return message;
  }

  reply(original, response) {
    if (!response.result || !['thread/start', 'thread/resume', 'thread/fork'].includes(original?.method)) return;
    const result = response.result;
    const existing = this.sessions.get(result.thread.id) ?? {};
    this.sessions.set(result.thread.id, {...existing, cwd: result.cwd ?? result.thread.cwd,
      model: result.model, provider: result.modelProvider, configuration: original.params?.config,
      applied: JSON.stringify([original.params?.config?.model_context_window ?? null,
        original.params?.config?.model_auto_compact_token_limit ?? null, original.params?.config?.model_auto_compact_token_limit_scope ?? 'total'])});
  }

  observe(message) {
    const params = message.params ?? {};
    const session = this.sessions.get(params.threadId);
    if (!session) return;
    if (message.method === 'thread/tokenUsage/updated') {
      session.window = params.tokenUsage.modelContextWindow;
      session.retained = params.tokenUsage.last?.inputTokens;
      if (session.requestedWindow !== undefined && session.window === session.requestedWindow) {
        this.log({event: 'runtime_budget_confirmed', threadId: params.threadId, requested: session.requestedWindow, observed: session.window});
        delete session.requestedWindow;
      }
    }
    if (message.method === 'item/completed' && params.item?.type === 'contextCompaction') session.compacted = true;
    if (message.method !== 'turn/completed') return;
    if (session.requestedWindow !== undefined) {
      this.log({event: 'runtime_budget_mismatch', threadId: params.threadId, requested: session.requestedWindow, observed: session.window});
      delete session.requestedWindow;
    }
    if ((!session.compacted && !session.compactionSamples?.length) || !session.context?.adaptive) return;
    const context = session.context;
    const retained = session.retained;
    const successful = params.turn.status === 'completed';
    const manual = session.manual;
    const samples = session.compactionSamples ?? [];
    session.compactionSamples = [];
    session.compacted = false;
    this.writes = this.writes.then(async () => {
      const next = await this.store.update(context.key, context.revision, context.bounds, retained, successful, manual, samples, context.budget);
      this.log({event: 'compaction_feedback', threadId: params.threadId, budget: next.budget, successful, manual});
    }).catch(error => this.log({event: 'feedback_save_failed', error: error.message}));
  }
}
