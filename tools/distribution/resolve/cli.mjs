#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

import { digestOf, GraphError, requireFact } from "../../architecture-graph/lib/canonical.mjs";
import { loadGraph } from "../../architecture-graph/lib/graph-model.mjs";
import { buildFourthGraph, renderFourthGraph } from "../../architecture-graph/distribution/fourth-graph.mjs";
import { buildInstallLock, deliveryTasksForPackage, verifyInstallLock } from "../catalog/lib/lock.mjs";
import { providerDependencyChecks } from "../catalog/lib/product-capabilities.mjs";
import { catalogueFromGraph, resolveInstallClosure } from "./lib/catalogue-resolver.mjs";
import { profileDeliveryView, removalPreview } from "./lib/profile-resolver.mjs";

/**
 * Distribution and deployment tool (module M31), reading the same graph
 * documents as the architecture graph tool (module M24).
 *
 * It computes declared closures, previews removal impact, builds a reproducible
 * install lock from a real local build result, verifies artifact bytes, and
 * renders the fourth graph. It never installs, downloads, executes or removes
 * anything, never mutates the graph or the development ledger, and never marks
 * work complete.
 */

const REPOSITORY_ROOT = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

const USAGE = `usage: node tools/distribution/resolve/cli.mjs <command> [options]

commands
  profile <profile>            declared closure, runtime activation and delivery tasks
  removal-preview <profile> --package <id> [--pinned <id>]...
                               declared removal impact; --pinned simulates active references
  closure <package>...         install closure of the named packages, product semantics
                               cross-checked against the graph closure
  check                        provider ownership, profile closure and DAG isolation checks
  fourth-graph                 build the fourth typed graph (packages, profiles, providers)
  render                       write the fourth graph as Mermaid, deterministic SVG and JSON
  lock build --build <file>    build the install lock from a real local build result
  lock verify --lock <file>    verify a lock against the graph, and optionally the bytes

options
  --project <file>             explicit local graph project document (required)
  --repo-root <dir>            repository root to resolve sources against
  --out <path|dir>             output path; required for render
  --build <file>               build result document for lock build
  --lock <file>                lock document for lock verify
  --artifacts <dir>            directory the artifact paths are resolved under
                               (default: repository root; lock verify only checks
                               bytes when --artifacts is given)
  --package <id>               package for removal-preview
  --pinned <id>                active generation pin for removal-preview (repeatable)
  --strict                     treat unattributed bytes as a verification error
  --help
`;

function listOption(values) {
  if (values === undefined) return [];
  return Array.isArray(values) ? values : [values];
}

function readJsonFile(filePath) {
  if (!fs.existsSync(filePath)) throw new GraphError(`file is missing: ${filePath}`);
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new GraphError(`${filePath} is not valid JSON: ${error.message}`);
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function run(argv) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      project: { type: "string" },
      "repo-root": { type: "string" },
      out: { type: "string" },
      build: { type: "string" },
      lock: { type: "string" },
      artifacts: { type: "string" },
      package: { type: "string" },
      pinned: { type: "string", multiple: true },
      strict: { type: "boolean" },
      help: { type: "boolean" },
    },
  });

  if (values.help || positionals.length === 0) {
    process.stdout.write(USAGE);
    return { exitCode: 0 };
  }

  const command = positionals[0];
  const subcommand = positionals[1] ?? null;
  const repoRoot = values["repo-root"] ? path.resolve(values["repo-root"]) : REPOSITORY_ROOT;
  requireFact(values.project, "--project is required; local graph inputs do not define repository policy");
  const projectPath = path.resolve(repoRoot, values.project);
  const graph = loadGraph({ projectPath, repoRoot });

  switch (command) {
    case "profile": {
      if (!subcommand) throw new GraphError("profile needs a profile id");
      return { exitCode: 0, result: profileDeliveryView(graph, subcommand) };
    }

    case "removal-preview": {
      if (!subcommand) throw new GraphError("removal-preview needs a profile id");
      if (!values.package) throw new GraphError("removal-preview needs --package <id>");
      return {
        exitCode: 0,
        result: {
          kind: "licoup-distribution-removal-preview.v1",
          ...removalPreview(graph, { profileId: subcommand, packageId: values.package, pinned: listOption(values.pinned) }),
        },
      };
    }

    case "closure": {
      const roots = positionals.slice(1);
      if (roots.length === 0) throw new GraphError("closure needs at least one package id");
      const product = resolveInstallClosure(catalogueFromGraph(graph), roots);
      if (!product.ok) {
        return {
          exitCode: 2,
          result: {
            kind: "licoup-distribution-closure.v1",
            roots: [...roots].sort(),
            product_semantics: product,
            graph_closure: null,
            matches_graph_closure: false,
            note: "The product semantics refused this closure; the graph model is not consulted for a refused request.",
          },
        };
      }
      const graphClosure = [...new Set(roots.flatMap((root) => [...graph.packageClosure([root])]))].sort();
      const matches = product.ok && product.selected.length === graphClosure.length
        && product.selected.every((id) => graphClosure.includes(id));
      return {
        exitCode: matches ? 0 : 2,
        result: {
          kind: "licoup-distribution-closure.v1",
          roots: [...roots].sort(),
          product_semantics: product,
          graph_closure: graphClosure,
          matches_graph_closure: matches,
          note: "Same requires-only closure as the product resolver; a mismatch is a declaration defect, not a warning.",
        },
      };
    }

    case "check": {
      const profiles = [...graph.profiles.values()].sort((a, b) => a.id.localeCompare(b.id)).map((profile) => {
        const closure = [...graph.packageClosure(profile.selected_packages)].sort();
        return {
          id: profile.id,
          closure,
          contains_core: closure.includes(graph.distribution.core_package),
          forbidden_in_closure: profile.forbidden_packages.filter((packageId) => closure.includes(packageId)),
          delivery_tasks: [...new Set(closure.flatMap((packageId) => deliveryTasksForPackage(graph, packageId)))].sort(),
        };
      });
      const provider = providerDependencyChecks(graph);
      const deploymentEdgesEnteringDag = graph.relations()
        .filter((edge) => edge.class === "deployment-delivery" && edge.enters_development_dag).length;
      const ok = provider.ok
        && deploymentEdgesEnteringDag === 0
        && profiles.every((profile) => profile.contains_core && profile.forbidden_in_closure.length === 0);
      return {
        exitCode: ok ? 0 : 2,
        result: {
          kind: "licoup-distribution-check.v1",
          ok,
          graph_digest: graph.graphDigest,
          graph_version: graph.graphVersion,
          core_package: graph.distribution.core_package,
          profiles,
          provider,
          development_dag: {
            scheduling_relation: "task.depends_on",
            deployment_edges_entering: deploymentEdgesEnteringDag,
          },
          package_declaration_digests: Object.fromEntries(
            [...graph.packages.keys()].sort().map((id) => [id, digestOf(graph.packages.get(id))]),
          ),
          note: "Declaration checks only. They do not observe an installation or prove that a provider is loadable.",
        },
      };
    }

    case "fourth-graph": {
      const fourth = buildFourthGraph(graph);
      if (values.out) {
        writeJson(path.resolve(repoRoot, values.out), fourth);
        return { exitCode: 0, result: { written: values.out, fourth_graph_digest: fourth.fourth_graph_digest } };
      }
      return { exitCode: 0, result: fourth };
    }

    case "render": {
      if (!values.out) throw new GraphError("render needs --out <dir>; this tool never chooses a write location on its own");
      const outDirectory = path.resolve(repoRoot, values.out);
      const rendered = renderFourthGraph(graph);
      fs.mkdirSync(outDirectory, { recursive: true });
      for (const [name, content] of Object.entries(rendered.files)) {
        fs.writeFileSync(path.join(outDirectory, name), content, "utf8");
      }
      return {
        exitCode: 0,
        result: {
          // Report the caller-supplied path, never a resolved absolute one:
          // tool output is shared and must stay machine-neutral.
          out: values.out,
          files: Object.keys(rendered.files).sort(),
          summary: rendered.summary,
        },
      };
    }

    case "lock": {
      if (subcommand === "build") {
        if (!values.build) throw new GraphError("lock build needs --build <file>");
        const build = readJsonFile(path.resolve(repoRoot, values.build));
        const artifactsRoot = values.artifacts ? path.resolve(repoRoot, values.artifacts) : repoRoot;
        const lock = await buildInstallLock({ graph, build, artifactsRoot });
        if (values.out) {
          writeJson(path.resolve(repoRoot, values.out), lock);
          return {
            exitCode: 0,
            result: { written: values.out, lock_digest: lock.lock_digest, packages: Object.keys(lock.packages).length, profiles: Object.keys(lock.profiles).length },
          };
        }
        return { exitCode: 0, result: lock };
      }
      if (subcommand === "verify") {
        if (!values.lock) throw new GraphError("lock verify needs --lock <file>");
        const lock = readJsonFile(path.resolve(repoRoot, values.lock));
        const artifactsRoot = values.artifacts ? path.resolve(repoRoot, values.artifacts) : null;
        const verification = await verifyInstallLock({ graph, lock, artifactsRoot, strict: values.strict === true });
        return { exitCode: verification.ok ? 0 : 2, result: verification };
      }
      throw new GraphError(`unknown lock subcommand: ${String(subcommand)}`);
    }

    default:
      throw new GraphError(`unknown command: ${command}`);
  }
}

try {
  const outcome = await run(process.argv.slice(2));
  process.stdout.write(`${JSON.stringify(outcome.result, null, 2)}\n`);
  process.exitCode = outcome.exitCode;
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${JSON.stringify({ ok: false, error: message })}\n`);
  process.exitCode = 2;
}
