import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {BudgetStore, feedback, modelBounds} from '../Resources/adaptive/policy.mjs';

const catalog = {models: [{slug: 'fixture', context_window: 160000,
  max_context_window: 240000, effective_context_window_percent: 95}]};
const bounds = modelBounds(catalog, 'fixture');
const execute = promisify(execFile);
const policyURL = new URL('../Resources/adaptive/policy.mjs', import.meta.url).href;
const worker = `
  const {BudgetStore} = await import(process.argv[1]);
  const {directory, updates} = JSON.parse(process.argv[2]);
  const store = new BudgetStore(directory);
  const results = [];
  for (const update of updates) results.push(await store.update(...update));
  process.stdout.write(JSON.stringify(results));
`;

function temporary(context) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'adaptive-downshift-'));
  context.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  return directory;
}

function state(budget, extra = {}) {
  return {budget, ambiguous: 0, revision: 'first', ...extra};
}

function sample(retained, extra = {}) {
  return {retained, successful: true, manual: false, ...extra};
}

function observe(current, samples, configured = bounds, retained = 0) {
  return feedback(configured, current, retained, true, false, samples);
}

function noLowRetention(current) {
  assert.equal(Object.hasOwn(current, 'lowRetention'), false);
}

async function promote(store, key, configured = bounds, target = configured.tiers.at(-1)) {
  let current = store.get(key, 'first', configured);
  while (current.budget < target)
    current = await store.update(key, 'first', configured, current.budget, true, false);
  return current;
}

async function inProcess(directory, updates) {
  const result = await execute(process.execPath,
    ['--input-type=module', '-e', worker, policyURL, JSON.stringify({directory, updates})],
    {timeout: 10000, maxBuffer: 65536});
  return JSON.parse(result.stdout);
}

for (const [budget, previous] of [[200000, 160000], [240000, 200000]]) {
  test(`${budget} drops to ${previous} only after two strictly low automatic samples`, () => {
    const cutoff = previous * bounds.thresholds.lower;
    const original = state(budget);
    const samples = [sample(cutoff - 1)];
    const first = observe(original, samples);
    assert.equal(first.budget, budget);
    assert.equal(first.lowRetention, 1);
    const second = observe(first, samples);
    assert.equal(second.budget, previous);
    assert.equal(second.ambiguous, 0);
    noLowRetention(second);
    assert.deepEqual(original, state(budget));
    assert.deepEqual(samples, [sample(cutoff - 1)]);
    assert.equal(first.lowRetention, 1);
  });

  for (const offset of [0, 1]) {
    test(`${budget}: previous-tier cutoff ${offset === 0 ? 'equality' : 'plus one'} resets the streak`, () => {
      const cutoff = previous * bounds.thresholds.lower;
      const reset = observe(state(budget, {lowRetention: 1}), [sample(cutoff + offset)]);
      assert.equal(reset.budget, budget);
      noLowRetention(reset);
      const restarted = observe(reset, [sample(cutoff - 1)]);
      assert.equal(restarted.budget, budget);
      assert.equal(restarted.lowRetention, 1);
    });
  }
}

test('top-tier cutoff uses the middle budget, independently of the completed-turn input', () => {
  const next = observe(state(240000), [sample(65000), sample(65000)], bounds, 100000);
  assert.equal(next.budget, 200000);
  noLowRetention(next);
  const tooLarge = observe(state(240000), [sample(75000), sample(75000)]);
  assert.equal(tooLarge.budget, 240000);
  noLowRetention(tooLarge);
  const noSamples = feedback(bounds, state(200000), 0, true, false);
  assert.equal(noSamples.budget, 200000);
  noLowRetention(noSamples);
});

test('custom lower 40 percent follows arbitrary configured tiers and exact cutoffs', () => {
  const configured = modelBounds(catalog, 'fixture',
    {lower_percent: 40, upper_percent: 60, tiers: [90001, 137777, 231111]});
  for (const [budget, previous] of [[137777, 90001], [231111, 137777]]) {
    const cutoff = previous * configured.thresholds.lower;
    const low = Math.floor(cutoff);
    assert.ok(low < cutoff);
    assert.equal(observe(state(budget), [sample(low), sample(low)], configured).budget, previous);
    const above = observe(state(budget, {lowRetention: 1}), [sample(Math.ceil(cutoff))], configured);
    assert.equal(above.budget, budget);
    noLowRetention(above);
  }
  const exact = modelBounds(catalog, 'fixture',
    {lower_percent: 40, upper_percent: 60, tiers: [100000, 150000, 230000]});
  for (const [budget, cutoff] of [[150000, 40000], [230000, 60000]]) {
    assert.equal(observe(state(budget), [sample(cutoff - 1), sample(cutoff - 1)], exact).budget,
      exact.tiers[exact.tiers.indexOf(budget) - 1]);
    noLowRetention(observe(state(budget, {lowRetention: 1}), [sample(cutoff)], exact));
  }
});

test('minimum, collapsed tiers and zero lower threshold never descend below the first tier', () => {
  for (const configured of [bounds, modelBounds(catalog, 'fixture', {tiers: [160000, 160000, 160000]})]) {
    const next = observe(state(configured.tiers[0], {lowRetention: 1}), [sample(0), sample(0)], configured);
    assert.equal(next.budget, configured.tiers[0]);
    noLowRetention(next);
  }
  const zero = modelBounds(catalog, 'fixture', {lower_percent: 0});
  const next = observe(state(240000, {lowRetention: 1}), [sample(0), sample(0)], zero);
  assert.equal(next.budget, 240000);
  noLowRetention(next);
});

test('two tier reductions require separate rounds; surplus samples do not carry across a reduction', () => {
  const next = observe(state(240000), Array.from({length: 8}, () => sample(0)));
  assert.equal(next.budget, 200000);
  noLowRetention(next);
  const first = observe(next, [sample(0)]);
  assert.equal(first.budget, 200000);
  assert.equal(first.lowRetention, 1);
  const second = observe(first, [sample(0)]);
  assert.equal(second.budget, 160000);
  noLowRetention(second);
});

test('a pre-existing streak plus many same-round samples still drops only one tier', () => {
  const next = observe(state(240000, {lowRetention: 1, ambiguous: 1}),
    [sample(0), sample(0), sample(0), sample(0)]);
  assert.equal(next.budget, 200000);
  assert.equal(next.ambiguous, 0);
  noLowRetention(next);
});

const interruptions = [
  ['equal', sample(70000)], ['above', sample(70001)],
  ['unknown', sample(null)], ['missing', sample(undefined)],
  ['NaN', sample(NaN)], ['infinity', sample(Infinity)],
  ['negative', sample(-1)], ['fractional', sample(0.5)],
  ['unsafe integer', sample(Number.MAX_SAFE_INTEGER + 1)],
  ['string', sample('0')], ['manual', sample(0, {manual: true})],
  ['failed', sample(0, {successful: false})]
];

for (const [name, interrupted] of interruptions) {
  test(`${name} observation clears the streak and does not count as a low sample`, () => {
    const reset = observe(state(240000, {lowRetention: 1}), [interrupted]);
    assert.equal(reset.budget, 240000);
    noLowRetention(reset);
    const restarted = observe(reset, [sample(0)]);
    assert.equal(restarted.budget, 240000);
    assert.equal(restarted.lowRetention, 1);
    const sameRound = observe(state(240000), [sample(0), interrupted, sample(0)]);
    assert.equal(sameRound.budget, 240000);
    assert.equal(sameRound.lowRetention, 1);
    assert.equal(observe(sameRound, [sample(0)]).budget, 200000);
  });
}

test('a completed compaction without observable samples clears an unfinished low streak', () => {
  const next = observe(state(240000, {lowRetention: 1}), []);
  assert.equal(next.budget, 240000);
  noLowRetention(next);
});

test('failed, manual or unknown completed-turn feedback resets low counts', () => {
  for (const args of [[0, false, false], [0, true, true], [null, true, false],
    [undefined, true, false], [NaN, true, false], [-1, true, false]]) {
    const next = feedback(bounds, state(240000, {lowRetention: 1}), ...args, [sample(0), sample(0)]);
    assert.equal(next.budget, 240000);
    noLowRetention(next);
  }
});

test('legacy immediate and two-success promotion retain their boundaries and clear low counts', () => {
  const middle = state(200000, {lowRetention: 1});
  const immediate = feedback(bounds, middle, 110000, true, false, [sample(70000)]);
  assert.equal(immediate.budget, 240000);
  assert.equal(immediate.ambiguous, 0);
  noLowRetention(immediate);
  const first = feedback(bounds, state(200000), 70000, true, false, [sample(0)]);
  assert.equal(first.budget, 200000);
  assert.equal(first.ambiguous, 1);
  assert.equal(first.lowRetention, 1);
  const promoted = feedback(bounds, first, 109999, true, false, [sample(70000)]);
  assert.equal(promoted.budget, 240000);
  assert.equal(promoted.ambiguous, 0);
  noLowRetention(promoted);
  assert.equal(feedback(bounds, state(160000), 87999, true, false).budget, 160000);
  assert.equal(feedback(bounds, state(160000), 88000, true, false).budget, 200000);
  const noPromotion = feedback(bounds, state(160000), 0, true, false, [sample(140000)]);
  assert.equal(noPromotion.budget, 160000);
});

test('a low count survives store and process restarts, then both tiers can descend', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await promote(store, 'project');
  const first = await store.update('project', 'first', bounds, 0, true, false, [sample(0)], 240000);
  assert.equal(first.lowRetention, 1);
  assert.equal(new BudgetStore(directory).get('project', 'first', bounds).lowRetention, 1);
  const [middle] = await inProcess(directory,
    [['project', 'first', bounds, 0, true, false, [sample(0)], 240000]]);
  assert.equal(middle.budget, 200000);
  noLowRetention(middle);
  await new BudgetStore(directory).update('project', 'first', bounds, 0, true, false, [sample(0)], 200000);
  const [minimum] = await inProcess(directory,
    [['project', 'first', bounds, 0, true, false, [sample(0)], 200000]]);
  assert.equal(minimum.budget, 160000);
  noLowRetention(new BudgetStore(directory).get('project', 'first', bounds));
});

test('concurrent independent processes preserve same-key streaks and isolate different keys', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await promote(store, 'project-a');
  await promote(store, 'project-b', bounds, 200000);
  const results = await Promise.allSettled([
    inProcess(directory, [['project-a', 'first', bounds, 0, true, false, [sample(0)], 240000]]),
    inProcess(directory, [['project-a', 'first', bounds, 0, true, false, [sample(0)], 240000]]),
    inProcess(directory, [['project-b', 'first', bounds, 0, true, false, [sample(0)], 200000]])
  ]);
  for (const result of results) assert.equal(result.status, 'fulfilled', result.reason?.stack);
  const restored = new BudgetStore(directory);
  assert.equal(restored.get('project-a', 'first', bounds).budget, 200000);
  noLowRetention(restored.get('project-a', 'first', bounds));
  assert.equal(restored.get('project-b', 'first', bounds).budget, 200000);
  assert.equal(restored.get('project-b', 'first', bounds).lowRetention, 1);
  assert.deepEqual(restored.get('project-c', 'first', bounds), state(160000));
  assert.equal(fs.existsSync(store.lock), false);
});

test('revision changes reset to the first tier and discard persisted low counts', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await promote(store, 'project');
  await store.update('project', 'first', bounds, 0, true, false, [sample(0)], 240000);
  const configured = modelBounds(catalog, 'fixture',
    {lower_percent: 40, upper_percent: 60, tiers: [90000, 150000, 230000]});
  const expected = {budget: 90000, ambiguous: 0, revision: 'changed'};
  assert.deepEqual(new BudgetStore(directory).get('project', 'changed', configured), expected);
  const reset = await store.update('project', 'changed', configured, 0, true, false, [sample(0)], 90000);
  assert.deepEqual(reset, expected);
  assert.deepEqual(new BudgetStore(directory).get('project', 'changed', configured), expected);
  assert.deepEqual(JSON.parse(fs.readFileSync(store.file, 'utf8')).project, expected);
});

test('old applied-budget feedback after either direction leaves pending state and counters untouched', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await promote(store, 'project');
  const middle = await store.update('project', 'first', bounds, 0, true, false,
    [sample(0), sample(0)], 240000);
  assert.equal(middle.budget, 200000);
  const once = await store.update('project', 'first', bounds, 0, true, false, [sample(0)], 200000);
  assert.equal(once.lowRetention, 1);
  const saved = fs.readFileSync(store.file, 'utf8');
  for (const [retained, samples] of [[0, [sample(0), sample(0)]], [200000, [sample(null)]]]) {
    const stale = await new BudgetStore(directory).update('project', 'first', bounds,
      retained, true, false, samples, 240000);
    assert.deepEqual(stale, once);
    assert.equal(fs.readFileSync(store.file, 'utf8'), saved);
  }
  const promoted = await store.update('project', 'first', bounds, 110000, true, false, [], 200000);
  assert.equal(promoted.budget, 240000);
  noLowRetention(promoted);
  const stale = await store.update('project', 'first', bounds, 200000, true, false,
    [sample(0), sample(0)], 200000);
  assert.deepEqual(stale, promoted);
});

test('concurrent stale applied-budget writers cannot cascade two reductions before a reload', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await promote(store, 'project');
  const results = await Promise.allSettled(Array.from({length: 4}, () => inProcess(directory,
    [['project', 'first', bounds, 0, true, false, [sample(0), sample(0)], 240000]])));
  for (const result of results) {
    assert.equal(result.status, 'fulfilled', result.reason?.stack);
    assert.equal(result.value[0].budget, 200000);
    noLowRetention(result.value[0]);
  }
  assert.equal(new BudgetStore(directory).get('project', 'first', bounds).budget, 200000);
  noLowRetention(store.get('project', 'first', bounds));
});

test('omitted appliedBudget remains compatible with legacy store promotion and new samples', async context => {
  const store = new BudgetStore(temporary(context));
  assert.equal((await store.update('project', 'first', bounds, 110000, true, false)).budget, 200000);
  const first = await store.update('project', 'first', bounds, 0, true, false, [sample(0)]);
  assert.equal(first.lowRetention, 1);
  const second = await store.update('project', 'first', bounds, 0, true, false, [sample(0)]);
  assert.equal(second.budget, 160000);
  noLowRetention(second);
});

test('one native compaction cannot count twice across processes', async context => {
  const directory = temporary(context);
  const store = new BudgetStore(directory);
  await promote(store, 'project', bounds, 200000);
  const firstSample = sample(0, {id: 'one-completed-compaction'});
  const first = await store.update('project', 'first', bounds, 0, true, false, [firstSample], 200000);
  const [duplicate] = await inProcess(directory,
    [['project', 'first', bounds, 0, true, false, [firstSample, firstSample], 200000]]);
  assert.deepEqual(duplicate, first);
  assert.equal(duplicate.lowRetention, 1);
  assert.equal((await store.update('project', 'first', bounds, 0, true, false,
    [sample(0, {id: 'next-completed-compaction'})], 200000)).budget, 160000);
});

test('an attempted promotion at the ceiling does not erase real low-compaction samples', () => {
  const first = observe(state(240000), [sample(0)], bounds, 200000);
  assert.equal(first.budget, 240000);
  assert.equal(first.lowRetention, 1);
  assert.equal(observe(first, [sample(0)], bounds, 200000).budget, 200000);
});

test('another writer releasing its lock during inspection does not drop feedback', async context => {
  const store = new BudgetStore(temporary(context));
  fs.writeFileSync(store.lock, String(process.pid));
  const original = fs.lstatSync;
  let released = false;
  context.after(() => { fs.lstatSync = original; });
  fs.lstatSync = (file, ...argumentsList) => {
    const result = original(file, ...argumentsList);
    if (file === store.lock && !released) {
      released = true;
      fs.unlinkSync(file);
    }
    return result;
  };
  const next = await store.update('project', 'first', bounds, 110000, true, false);
  assert.equal(released, true);
  assert.equal(next.budget, 200000);
  assert.equal(fs.existsSync(store.lock), false);
});
