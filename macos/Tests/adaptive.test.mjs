import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {BudgetStore, feedback, modelBounds} from '../Resources/adaptive/policy.mjs';
import {AdaptiveController} from '../Resources/adaptive/controller.mjs';
import {resumeSettings} from '../Resources/adaptive/resume-settings.mjs';

const catalog = {models: [{slug: 'fixture', context_window: 160000,
  max_context_window: 240000, effective_context_window_percent: 95}]};
const bounds = modelBounds(catalog, 'fixture');
const initial = {budget: 160000, ambiguous: 0, revision: 'first'};

function temporary(context) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'adaptive-unit-'));
  context.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  return directory;
}

function fixture(context, options = {}) {
  const home = temporary(context);
  const calls = [];
  const events = [];
  const sessions = new Map([['first', {cwd: '/project', model: 'fixture',
    modelProvider: 'openai', status: {type: 'idle'}}]]);
  const request = async (method, params) => {
    calls.push({method, params});
    const override = await options.request?.(method, params);
    if (override !== undefined) return override;
    if (method === 'config/read') return {config: {model: 'fixture', model_provider: 'openai'}};
    if (method === 'thread/read') return {thread: sessions.get(params.threadId)};
    if (method === 'thread/loaded/list') return {data: []};
    if (method === 'thread/resume') return {thread: sessions.get(params.threadId), model: 'fixture',
      modelProvider: 'openai', cwd: '/project', sandbox: {type: 'readOnly', networkAccess: false},
      approvalPolicy: 'never', approvalsReviewer: 'user', reasoningEffort: 'high', serviceTier: null};
    return {};
  };
  const controller = new AdaptiveController(request, {home, catalog: () => catalog,
    settings: options.settings ?? (async cwd => ({root: cwd, trusted: true, adaptive: true, revision: 'first'})),
    log: event => events.push(event)});
  controller.reply({method: 'thread/start', params: {config: options.configuration ?? {model_context_window: 160000}}},
    {result: {thread: {id: 'first', cwd: '/project'},
    model: 'fixture', modelProvider: 'openai'}});
  return {controller, calls, events, sessions};
}

function usage(controller, threadId, window = 152000, retained = 110000) {
  controller.observe({method: 'thread/tokenUsage/updated', params: {threadId,
    tokenUsage: {modelContextWindow: window, last: {inputTokens: retained}}}});
}

function compacted(controller, threadId, status = 'completed') {
  controller.observe({method: 'item/completed', params: {threadId, item: {type: 'contextCompaction'}}});
  controller.observe({method: 'turn/completed', params: {threadId, turn: {status}}});
}

const turn = {id: 7, method: 'turn/start', params: {threadId: 'first',
  input: [{type: 'text', text: 'Original user message'}], effort: 'high'}};

test('thread overrides isolate feedback and reset to project context', async context => {
  let override = true;
  const {controller} = fixture(context, {settings: async (cwd, threadID) => ({
    root: cwd, trusted: true, override: override && threadID === 'first',
    adaptive: override && threadID === 'first', effective_adaptive: false,
    revision: 'thread', project_revision: 'project'})});
  await controller.before(turn);
  usage(controller, 'first');
  compacted(controller, 'first');
  await controller.writes;
  assert.equal((await controller.context('/project', 'fixture', 'first')).budget, 200000);
  assert.equal((await controller.context('/project', 'fixture', 'second')).budget, null);
  override = false;
  assert.equal((await controller.context('/project', 'fixture', 'first')).budget, null);
});

test('model bounds follow metadata and never invent a maximum', () => {
  assert.deepEqual(bounds.tiers, [160000, 200000, 240000]);
  const changed = {models: [{slug: 'fixture', context_window: 180000, effective_context_window_percent: 90}]};
  assert.deepEqual(modelBounds(changed, 'fixture'), {model: 'fixture', tiers: [180000], percent: 90});
  assert.throws(() => modelBounds(catalog, 'missing'));
  assert.throws(() => modelBounds({models: [...catalog.models, ...catalog.models]}, 'fixture'));
  assert.throws(() => modelBounds({models: [{...catalog.models[0], max_context_window: 10}]}, 'fixture'));
});

test('successful feedback expands one tier and respects the model maximum', () => {
  const middle = feedback(bounds, initial, 110000, true, false);
  assert.equal(middle.budget, 200000);
  const maximum = feedback(bounds, middle, 140000, true, false);
  assert.equal(maximum.budget, 240000);
  assert.equal(feedback(bounds, maximum, 200000, true, false).budget, 240000);
  assert.equal(initial.budget, 160000);
});

test('ambiguous feedback requires two successes and low retention resets it', () => {
  const first = feedback(bounds, initial, 80000, true, false);
  assert.equal(first.budget, 160000);
  assert.equal(feedback(bounds, first, 80000, true, false).budget, 200000);
  assert.equal(feedback(bounds, first, 10000, true, false).ambiguous, 0);
});

test('failed, manual and invalid feedback never expands', () => {
  for (const args of [[110000, false, false], [110000, true, true], [NaN, true, false], [-1, true, false]])
    assert.deepEqual(feedback(bounds, initial, ...args), initial);
});

test('state survives restart, isolates projects and resets when configuration changes', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await store.update('project-a', 'first', bounds, 110000, true, false);
  const restored = new BudgetStore(directory);
  assert.equal(restored.get('project-a', 'first', bounds).budget, 200000);
  assert.equal(restored.get('project-b', 'first', bounds).budget, 160000);
  assert.equal(restored.get('project-a', 'changed', bounds).budget, 160000);
  assert.equal(fs.statSync(store.file).mode & 0o777, 0o600);
});

test('a dead writer lock is recovered, symlink state is rejected', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  fs.writeFileSync(store.lock, '99999999');
  await store.update('project', 'first', bounds, 110000, true, false);
  fs.unlinkSync(store.file);
  fs.symlinkSync('/dev/null', store.file);
  assert.throws(() => store.read(), /symlink/);
});

test('default and untrusted project requests stay unchanged', async context => {
  for (const settings of [{trusted: true, adaptive: false}, {trusted: false, adaptive: true}]) {
    const {controller, calls} = fixture(context, {settings: async () => settings, configuration: {}});
    assert.strictEqual(await controller.before(turn), turn);
    assert.ok(!calls.some(call => call.method === 'thread/unsubscribe'));
  }
});

test('third-party provider start and turn stay unchanged', async context => {
  const {controller, calls} = fixture(context);
  const start = {method: 'thread/start', params: {cwd: '/project', model: 'fixture', modelProvider: 'third-party'}};
  assert.strictEqual(await controller.before(start), start);
  controller.sessions.get('first').provider = 'third-party';
  assert.strictEqual(await controller.before(turn), turn);
  assert.equal(calls.length, 0);
});

test('adaptive start uses official default and preserves model, effort and input', async context => {
  const {controller} = fixture(context);
  const start = {method: 'thread/start', params: {cwd: '/project', model: 'fixture',
    modelProvider: 'openai', effort: 'high', config: {web_search: 'disabled'}}};
  const result = await controller.before(start);
  assert.equal(result.params.config.model_context_window, 160000);
  assert.equal(result.params.config.web_search, 'disabled');
  assert.equal(result.params.model, 'fixture');
  assert.equal(result.params.effort, 'high');
  assert.equal(start.params.config.model_context_window, undefined);
});

test('automatic feedback reloads only the idle thread and waits for runtime confirmation', async context => {
  const {controller, calls, events} = fixture(context);
  assert.strictEqual(await controller.before(turn), turn);
  usage(controller, 'first');
  compacted(controller, 'first');
  await controller.writes;
  assert.strictEqual(await controller.before(turn), turn);
  const resumes = calls.filter(call => call.method === 'thread/resume');
  assert.equal(calls.filter(call => call.method === 'thread/unsubscribe').length, 1);
  assert.equal(resumes.length, 2);
  assert.equal(resumes[1].params.config.model_context_window, 200000);
  assert.equal(resumes[1].params.config.model_reasoning_effort, 'high');
  assert.equal(resumes[1].params.sandbox, 'read-only');
  assert.equal(resumes[1].params.approvalPolicy, 'never');
  assert.ok(!events.some(event => event.event === 'runtime_budget_confirmed'));
  usage(controller, 'first', 190000);
  assert.ok(events.some(event => event.event === 'runtime_budget_confirmed'));
  assert.deepEqual(turn.params.input, [{type: 'text', text: 'Original user message'}]);
});

test('active thread never unloads despite project expansion', async context => {
  const {controller, sessions, calls} = fixture(context);
  await controller.before(turn);
  usage(controller, 'first');
  compacted(controller, 'first');
  await controller.writes;
  sessions.get('first').status = {type: 'active'};
  await controller.before(turn);
  assert.ok(!calls.some(call => call.method === 'thread/unsubscribe'));
});

test('idle reload delegates cache teardown to native resume without a client unload deadline', async context => {
  const {controller, calls, events} = fixture(context, {
    settings: async () => ({root: '/project', trusted: true, override: true, window: 210000, adaptive: false}),
    request: async method => {
      if (method === 'thread/loaded/list') throw new Error('Client polling must not decide native cache lifetime');
    }});
  usage(controller, 'first');
  assert.strictEqual(await controller.before(turn), turn);
  assert.deepEqual(calls.filter(call => call.method !== 'config/read' && call.method !== 'thread/read')
    .map(call => call.method), ['thread/resume', 'thread/unsubscribe', 'thread/resume']);
  assert.equal(calls.at(-1).params.config.model_context_window, 210000);
  assert.ok(events.some(event => event.event === 'round_boundary_reload_started'));
  assert.ok(!events.some(event => event.event === 'runtime_budget_confirmed'));
  usage(controller, 'first', 199500);
  assert.ok(events.some(event => event.event === 'runtime_budget_confirmed' && event.threadId === 'first'));
});

test('runtime journal contains bounded metadata and no input, output or credential fields', context => {
  const home = temporary(context);
  const controller = new AdaptiveController(async () => ({}), {home});
  controller.log({event: 'runtime_budget_confirmed', threadId: 'fixture', requested: 199500, observed: 199500,
    input: 'private input', output: 'private output', error: 'private error', token: 'private credential'});
  const journal = path.join(home, 'context-menu/runtime-events.jsonl');
  const metadata = JSON.parse(fs.readFileSync(journal, 'utf8'));
  assert.deepEqual(Object.keys(metadata).sort(), ['event', 'observed', 'pid', 'requested', 'threadId', 'time']);
  assert.equal(fs.statSync(journal).mode & 0o777, 0o600);
  fs.writeFileSync(journal, 'x'.repeat(65537));
  controller.log({event: 'round_boundary_reload_started'});
  assert.ok(fs.statSync(journal).size < 1024);
  fs.unlinkSync(journal);
  const other = path.join(home, 'unchanged');
  fs.writeFileSync(other, 'do not overwrite');
  fs.symlinkSync(other, journal);
  controller.log({event: 'round_boundary_reload_started'});
  assert.equal(fs.readFileSync(other, 'utf8'), 'do not overwrite');
});

test('failed resume restores previous budget without rewriting the user turn', async context => {
  const {controller, calls, events} = fixture(context, {request: async (method, params) => {
    if (method === 'thread/resume' && params.config?.model_context_window === 200000)
      throw new Error('Synthetic resume failure');
  }});
  await controller.before(turn);
  usage(controller, 'first');
  compacted(controller, 'first');
  await controller.writes;
  assert.strictEqual(await controller.before(turn), turn);
  assert.ok(calls.some(call => call.method === 'thread/resume' && call.params.config?.model_context_window === 160000));
  assert.ok(events.some(event => event.event === 'expansion_failed_restored_previous'));
});

test('resume translation preserves workspace permissions and declines unsupported policies', () => {
  const result = resumeSettings({model: 'fixture', sandbox: {type: 'workspaceWrite',
    writableRoots: ['/project'], networkAccess: false, excludeTmpdirEnvVar: true, excludeSlashTmp: true},
    reasoningEffort: 'high', approvalPolicy: 'never'}, {web_search: 'disabled'});
  assert.deepEqual(result.config.sandbox_workspace_write, {writable_roots: ['/project'],
    network_access: false, exclude_tmpdir_env_var: true, exclude_slash_tmp: true});
  assert.equal(result.config.web_search, 'disabled');
  assert.throws(() => resumeSettings({sandbox: {type: 'externalSandbox'}}));
});

test('manual compaction and failed turns do not upgrade project state', async context => {
  for (const manual of [true, false]) {
    const {controller} = fixture(context);
    await controller.before(turn);
    usage(controller, 'first');
    if (manual) await controller.before({method: 'thread/compact/start', params: {threadId: 'first'}});
    compacted(controller, 'first', manual ? 'completed' : 'failed');
    await controller.writes;
    assert.equal((await controller.context('/project', 'fixture')).state.budget, 160000);
  }
});

test('custom and default switch at the next idle turn and discard stale overrides', async context => {
  let window = 210000;
  let compact = 100000;
  const {controller, calls} = fixture(context, {settings: async () => ({trusted: true, adaptive: false}),
    request: async method => method === 'config/read' ? {config: {
      model_context_window: window, model_auto_compact_token_limit: compact}} : undefined});
  usage(controller, 'first');
  await controller.before(turn);
  const first = calls.filter(call => call.method === 'thread/resume').at(-1);
  assert.equal(first.params.config.model_context_window, 210000);
  assert.equal(first.params.config.model_auto_compact_token_limit, 100000);
  usage(controller, 'first', 199500);
  window = null;
  compact = null;
  await controller.before(turn);
  const restored = calls.filter(call => call.method === 'thread/resume').at(-1);
  assert.ok(!('model_context_window' in restored.params.config));
  assert.ok(!('model_auto_compact_token_limit' in restored.params.config));
  assert.equal(restored.params.config.model_reasoning_effort, 'high');
  usage(controller, 'first');
  compacted(controller, 'first');
  await controller.writes;
  assert.ok(!fs.existsSync(controller.store.file));
  const count = calls.length;
  await controller.before(turn);
  assert.ok(!calls.slice(count).some(call => call.method === 'thread/unsubscribe'));
});

test('default inherits native merged values and custom is clipped to official maximum', async context => {
  const {controller} = fixture(context, {settings: async () => ({trusted: true, adaptive: false}),
    request: async method => method === 'config/read' ? {config: {model_context_window: 300000}} : undefined});
  const contextSettings = await controller.context('/project', 'fixture');
  assert.equal(contextSettings.budget, 300000);
  assert.equal(contextSettings.expected, 228000);
  assert.equal(controller.configuration(contextSettings).model_context_window, 300000);
});

test('compaction-only changes reload even if the context length is unchanged', async context => {
  const {controller, calls} = fixture(context, {settings: async () => ({trusted: true, adaptive: false}),
    configuration: {model_context_window: 160000, model_auto_compact_token_limit: 100000},
    request: async method => method === 'config/read' ? {config: {model_context_window: 160000}} : undefined});
  usage(controller, 'first');
  await controller.before(turn);
  assert.equal(calls.filter(call => call.method === 'thread/unsubscribe').length, 1);
  assert.ok(!('model_auto_compact_token_limit' in controller.sessions.get('first').configuration));
});

test('failed switch to default restores the old running window and retries next turn', async context => {
  let rejectDefault = true;
  const {controller, calls} = fixture(context, {settings: async () => ({trusted: true, adaptive: false}),
    request: async (method, params) => {
      if (method === 'thread/resume' && params.config && !('model_context_window' in params.config) && rejectDefault)
        throw new Error('Synthetic default failure');
    }});
  controller.sessions.get('first').configuration.model_context_window = 210000;
  controller.sessions.get('first').applied = JSON.stringify([210000, null]);
  usage(controller, 'first', 199500);
  await controller.before(turn);
  assert.equal(calls.filter(call => call.method === 'thread/resume').at(-1).params.config.model_context_window, 210000);
  rejectDefault = false;
  await controller.before(turn);
  assert.equal(controller.sessions.get('first').applied, JSON.stringify([null, null]));
});
