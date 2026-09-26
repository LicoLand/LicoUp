export function localDate() {
  return new Intl.DateTimeFormat("sv-SE").format(new Date());
}

export function documentDate(source, today = localDate()) {
  const dates = [...source.matchAll(/^Updated: (\d{4}-\d{2}-\d{2})\s*$/gm)];
  if (dates.length !== 1) return "exactly one Updated: YYYY-MM-DD is required";
  const date = dates[0][1];
  const parsed = new Date(`${date}T00:00:00Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) {
    return "invalid calendar date";
  }
  if (date > today) return "document date is in the future";
  return null;
}

export function withoutDate(source) {
  return source.replace(/^Updated: \d{4}-\d{2}-\d{2}\r?\n\r?\n?/m, "");
}

export function markdownAnchors(source) {
  const anchors = new Set([...source.matchAll(/<a\s+(?:id|name)=["']([^"']+)["']/gu)].map((match) => match[1]));
  const seen = new Map();
  // Code examples are not document headings.
  const prose = source.replace(/^(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1\s*$/gm, "");
  for (const match of prose.matchAll(/^#{1,6}\s+(.+)$/gm)) {
    const slug = match[1].trim().toLowerCase().replace(/[^\p{L}\p{N}_\- ]/gu, "").replaceAll(" ", "-");
    const count = seen.get(slug) ?? 0;
    anchors.add(count ? `${slug}-${count}` : slug);
    seen.set(slug, count + 1);
  }
  return anchors;
}

// Regeneration does not make unchanged content appear freshly reviewed.
export function withContentDate(content, previous = "", today = localDate()) {
  const date = withoutDate(previous) === withoutDate(content) && !documentDate(previous, today)
    ? previous.match(/^Updated: (\d{4}-\d{2}-\d{2})/m)[1] : today;
  const clean = withoutDate(content);
  return clean.replace(/^(# [^\n]+\n)\n/, `$1\nUpdated: ${date}\n\n`);
}

export function validateModuleRoutes(modules, { exists, read, scripts, regressionIds }) {
  const failures = [];
  const ids = new Set();
  for (const entry of modules) {
    if (ids.has(entry.id)) failures.push(`duplicate module ${entry.id}`);
    ids.add(entry.id);
    if (!exists(entry.guide)) {
      failures.push(`${entry.id}: guide missing`);
      continue;
    }
    const source = read(entry.guide);
    const script = `verify:${entry.id}`;
    if (!scripts[script] || !source.includes(`npm run ${script}`)) failures.push(`${entry.id}: command route missing`);
    if (!entry.testRoots?.length) failures.push(`${entry.id}: test directory missing`);
    for (const directory of entry.testRoots ?? []) {
      if (!exists(directory) || !source.includes(directory)) failures.push(`${entry.id}: test directory route missing: ${directory}`);
    }
    for (const id of entry.regressionModules ?? []) {
      if (!regressionIds.has(id)) failures.push(`${entry.id}: unknown regression module ${id}`);
    }
  }
  return failures;
}
