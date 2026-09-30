import fs from 'node:fs';
import path from 'node:path';

export function modelBounds(catalog, model) {
  const matches = catalog.models?.filter(entry => entry.slug === model) ?? [];
  if (matches.length !== 1) throw new Error('Selected model has no unique official metadata');
  const entry = matches[0];
  const initial = entry.context_window;
  const maximum = entry.max_context_window ?? initial;
  const percent = entry.effective_context_window_percent;
  if (![initial, maximum, percent].every(Number.isSafeInteger) || initial <= 0 || maximum < initial || percent <= 0 || percent > 100)
    throw new Error('Selected model has invalid official context bounds');
  return {model, tiers: [...new Set([initial, Math.floor((initial + maximum) / 2), maximum])], percent};
}

export function feedback(bounds, state, retained, successful, manual) {
  const next = {...state};
  if (!successful || manual || !Number.isSafeInteger(retained) || retained < 0) return next;
  const ratio = retained / next.budget;
  if (ratio < 0.45) next.ambiguous = 0;
  else if (ratio >= 0.65 || (next.ambiguous = (next.ambiguous ?? 0) + 1) >= 2) {
    next.budget = bounds.tiers.find(tier => tier > next.budget) ?? next.budget;
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
    if (saved?.revision !== revision || !bounds.tiers.includes(saved.budget))
      return {budget: bounds.tiers[0], ambiguous: 0, revision};
    return saved;
  }

  async update(key, revision, bounds, retained, successful, manual) {
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
      }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (descriptor === undefined) throw new Error('Adaptive budget writer is busy');
    const temporary = `${this.file}.${process.pid}.tmp`;
    try {
      const document = this.read();
      const current = this.get(key, revision, bounds);
      const next = feedback(bounds, current, retained, successful, manual);
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
