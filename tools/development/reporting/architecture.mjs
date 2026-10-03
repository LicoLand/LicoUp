import { readFileSync } from "node:fs";
import path from "node:path";
import { parse as toml } from "smol-toml";
import { parse as yaml } from "yaml";
import { label } from "./page.mjs";

// View definitions select components and labels; package manifests alone own
// dependency edges. Change-impact consumers are deliberately not architecture.
export function architectureViews(root) {
  const views = JSON.parse(readFileSync(path.join(root, "tools/development/architecture-views.json"), "utf8"));
  const manifests = new Map();
  let workspace;
  for (const view of views) for (const component of view.components) {
    if (manifests.has(component.manifest)) continue;
    const file = path.join(root, component.manifest);
    const isRust = file.endsWith("Cargo.toml");
    const source = readFileSync(file, "utf8");
    const document = isRust ? toml(source) : yaml(source);
    const dependencies = [];
    const collect = (table, condition) => {
      for (const [alias, value] of Object.entries(table ?? {})) {
        let dependency = value, base = path.dirname(file);
        if (isRust && value.workspace) {
          workspace ??= toml(readFileSync(path.join(root, "Cargo.toml"), "utf8")).workspace.dependencies;
          dependency = workspace[alias]; base = root;
        }
        if (dependency?.path) dependencies.push({ directory: path.resolve(base, dependency.path), condition });
      }
    };
    collect(document.dependencies, null);
    if (isRust) for (const [condition, target] of Object.entries(document.target ?? {})) collect(target.dependencies, condition);
    manifests.set(component.manifest, { name: isRust ? document.package.name : document.name,
      directory: path.dirname(file), dependencies });
  }
  return views.map((view) => {
    const byDirectory = new Map(view.components.map((component) => [manifests.get(component.manifest).directory, component]));
    const nodes = view.components.map((component) => ({ code: component.manifest, title: label(component.title),
      detail: { title: label(component.title), description: manifests.get(component.manifest).name,
        sections: [{ title: "Dependency sources", items: [component.manifest] }],
        link: { label: "Component definition", href: `../../${component.manifest}` } },
    }));
    const edgeMap = new Map();
    for (const component of view.components) for (const dependency of manifests.get(component.manifest).dependencies) {
      const target = byDirectory.get(dependency.directory);
      if (!target) continue;
      const key = `${component.manifest}:${target.manifest}`;
      if (!edgeMap.has(key)) edgeMap.set(key, { from: component.manifest, to: target.manifest,
        detail: { title: `${label(component.title)} · ${label(target.title)}`,
          description: "Direct dependencies declared by the component definitions", sections: [{ title: "Applies to", items: [] }] } });
      edgeMap.get(key).detail.sections[0].items.push(dependency.condition ?? "universal");
    }
    return { title: label(view.title), nodes, edges: [...edgeMap.values()] };
  });
}
