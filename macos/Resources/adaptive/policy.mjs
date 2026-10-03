import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const defaults = JSON.parse(fs.readFileSync(new URL('./defaults.json', import.meta.url), 'utf8'));

export function modelBounds(catalog, model, options = {}) {
  const matches = catalog.models?.filter(entry => entry.slug === model) ?? [];
  if (matches.length !== 1) throw new Error('Selected model has no unique official metadata');
  const entry = matches[0];
  const initial = entry.context_window;
  const maximum = entry.max_context_window ?? initial;
  const percent = entry.effective_context_window_percent;
  if (![initial, maximum, percent].every(Number.isSafeInteger) || initial <= 0 || maximum < initial || percent <= 0 || percent > 100)
    throw new Error('Selected model has invalid official context bounds');
  const lower = options.lower_percent ?? defaults.lower_percent;
  const upper = options.upper_percent ?? defaults.upper_percent;
  if (![lower, upper].every(Number.isFinite) || lower < 0 || lower >= upper || upper > 100)
    throw new Error('Adaptive thresholds must satisfy 0 <= lower < upper <= 100');
  const provided = options.tiers ?? [null, null, null];
  if (!Array.isArray(provided) || provided.length !== 3) throw new Error('Adaptive policy requires three tiers');
  const bounded = (tier, fallback) => {
    if (tier === null) return fallback;
    if (!Number.isSafeInteger(tier) || tier <= 0) throw new Error('Adaptive tiers must be positive integers');
    return Math.min(tier, maximum);
  };
  const first = bounded(provided[0], initial);
  const last = bounded(provided[2], maximum);
  const tiers = [first, bounded(provided[1], Math.floor((first + last) / 2)), last];
  if (tiers.some((tier, index) => index > 0 && tier < tiers[index - 1]))
    throw new Error('Adaptive tiers must be ordered after applying official bounds');
  return {model, tiers: [...new Set(tiers)], maximum, percent, thresholds: {lower: lower / 100, upper: upper / 100}};
}

export function compactionPolicy(bounds, budget, percent, compact = null, scope = 'total') {
  const requested = Math.min(budget ?? bounds.tiers[0], bounds.maximum);
  const maximumPercent = Math.min(99, Math.floor(bounds.maximum * Math.min(90, bounds.percent) / requested));
  if (percent === null || percent === undefined)
    return {nativeBudget: budget, compact, scope, expected: Math.floor(requested * bounds.percent / 100), maximum_percent: maximumPercent, budget: requested};
  if (!Number.isSafeInteger(percent) || percent < 1 || percent > 99) throw new Error('压缩百分比请输入 1–99 的整数；留空跟随官方。');
  const effective = Math.min(percent, maximumPercent);
  const expected = Math.floor(requested * effective / 100);
  return {nativeBudget: Math.ceil(expected * 100 / bounds.percent),
    compact: Math.floor(bounds.maximum * bounds.percent / 100), scope: 'body_after_prefix', expected,
    maximum_percent: maximumPercent, budget: requested, effective_percent: effective};
}

export function feedback(bounds, state, retained, successful, manual, samples = []) {
  const next = {...state};
  if (!successful || manual || !Number.isSafeInteger(retained) || retained < 0) {
    delete next.lowRetention;
    return next;
  }
  const seen = new Set([next.lastCompactionId]);
  const observations = samples.filter(sample => {
    if (typeof sample.id !== 'string') return true;
    if (seen.has(sample.id)) return false;
    seen.add(sample.id);
    return true;
  });
  if (samples.length && !observations.length) return next;
  if (observations.at(-1)?.id) next.lastCompactionId = observations.at(-1).id;
  const previous = bounds.tiers[bounds.tiers.indexOf(next.budget) - 1];
  if (!previous || !observations.length) delete next.lowRetention;
  else for (const sample of observations) {
    if (!sample.successful || sample.manual || !Number.isSafeInteger(sample.retained) || sample.retained < 0
        || sample.retained >= previous * bounds.thresholds.lower) delete next.lowRetention;
    else next.lowRetention = (next.lowRetention ?? 0) + 1;
    if (next.lowRetention >= 2) {
      next.budget = previous;
      next.ambiguous = 0;
      delete next.lowRetention;
      return next;
    }
  }
  const ratio = retained / next.budget;
  if (ratio < bounds.thresholds.lower) next.ambiguous = 0;
  else if (ratio >= bounds.thresholds.upper || (next.ambiguous = (next.ambiguous ?? 0) + 1) >= 2) {
    const expanded = bounds.tiers.find(tier => tier > next.budget);
    if (expanded !== undefined) {
      next.budget = expanded;
      delete next.lowRetention;
    }
    next.ambiguous = 0;
  }
  return next;
}

export class BudgetStore {
  constructor(directory) {
    this.directory = directory;
    this.file = path.join(directory, 'budgets.json');
    this.lock = path.join(directory, 'writer.lock');
  }

  read() {
    if (!fs.existsSync(this.file)) return {};
    if (fs.lstatSync(this.file).isSymbolicLink()) throw new Error('Budget state cannot be a symlink');
    return JSON.parse(fs.readFileSync(this.file, 'utf8'));
  }

  get(key, revision, bounds) {
    const saved = this.read()[key];
    if (!saved || saved.revision !== revision || !bounds.tiers.includes(saved.budget))
      return {budget: bounds.tiers[0], ambiguous: 0, revision};
    return saved;
  }

  async update(key, revision, bounds, retained, successful, manual, samples = [], appliedBudget) {
    fs.mkdirSync(this.directory, {recursive: true, mode: 0o700});
    if (fs.lstatSync(this.directory).isSymbolicLink()) throw new Error('Budget directory cannot be a symlink');
    let descriptor;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      try {
        descriptor = fs.openSync(this.lock, 'wx', 0o600);
        fs.writeFileSync(descriptor, String(process.pid));
        break;
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        try {
          const stat = fs.lstatSync(this.lock);
          if (stat.isSymbolicLink()) throw new Error('Budget lock cannot be a symlink');
          const owner = Number(fs.readFileSync(this.lock, 'utf8'));
          if (Number.isSafeInteger(owner) && owner > 0) {
            try { process.kill(owner, 0); }
            catch (check) {
              if (check.code === 'ESRCH' && fs.existsSync(this.lock) && fs.lstatSync(this.lock).ino === stat.ino)
                fs.unlinkSync(this.lock);
            }
          }
        } catch (check) { if (check.code !== 'ENOENT') throw check; }
      }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (descriptor === undefined) throw new Error('Adaptive budget writer is busy');
    const temporary = `${this.file}.${process.pid}.tmp`;
    try {
      const document = this.read();
      const current = this.get(key, revision, bounds);
      if (appliedBudget !== undefined && current.budget !== appliedBudget) return current;
      const next = feedback(bounds, current, retained, successful, manual, samples);
      document[key] = next;
      fs.writeFileSync(temporary, JSON.stringify(document), {mode: 0o600});
      fs.renameSync(temporary, this.file);
      return next;
    } finally {
      fs.closeSync(descriptor);
      fs.unlinkSync(this.lock);
      if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
    }
  }
}

if (process.argv[1] && fs.existsSync(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)) && process.argv[2] === '--preview') {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const reference = modelBounds(input.catalog, input.model);
  const settings = input.settings ?? {};
  const request = input.request;
  const adaptive = request ? request.mode === 'adaptive' || (settings.scope === 'thread' && request.mode === 'default' && settings.effective_adaptive) : settings.override ? settings.adaptive : settings.effective_adaptive ?? settings.adaptive;
  const options = request?.options ?? settings.adaptive_options;
  const bounds = modelBounds(input.catalog, input.model, adaptive ? options : undefined);
  const revision = settings.override ? settings.budget_revision ?? settings.revision : settings.project_budget_revision ?? settings.budget_revision ?? settings.project_revision ?? settings.revision;
  const key = `${settings.root}\u0000${input.model}${settings.override ? `\u0000${settings.thread}` : ''}`;
  const state = new BudgetStore(path.join(process.env.CODEX_HOME ?? path.join(os.homedir(), '.codex'), 'adaptive-context')).get(key, revision, bounds);
  const policyOptions = value => JSON.stringify(Object.fromEntries(Object.entries(value ?? {}).filter(([key]) => key !== 'compaction_percent')));
  const unchanged = !request || (settings.adaptive === adaptive && policyOptions(request.options) === policyOptions(settings.adaptive_options));
  const inheritedWindow = settings.inherited?.at(-1)?.values?.model_context_window;
  const budget = adaptive ? unchanged ? state.budget : bounds.tiers[0] : request ? request.window ?? inheritedWindow ?? null : settings.window ?? inheritedWindow ?? null;
  const selected = request ? request.percent : settings.compaction_percent;
  const compaction = compactionPolicy(bounds, budget, selected);
  if (request && selected !== null && selected > compaction.maximum_percent)
    throw new Error(`当前预算最多允许 ${compaction.maximum_percent}%；压缩线不得超过模型原始上限的 90%。`);
  process.stdout.write(JSON.stringify({...reference, display_tiers: [reference.tiers[0], Math.floor((reference.tiers[0] + reference.maximum) / 2), reference.maximum], compaction}));
}
