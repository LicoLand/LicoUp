import { digestOf } from "../lib/canonical.mjs";
import { topologicalLayers } from "../lib/graph-model.mjs";
import { layeredSvg } from "../lib/render.mjs";
import { deliveryTasksForPackage } from "../../distribution/catalog/lib/lock.mjs";
import {
  HOST_PUBLISHED_CAPABILITIES,
  PRODUCT_CAPABILITY_OWNERSHIP,
} from "../../distribution/catalog/lib/product-capabilities.mjs";

/**
 * The fourth typed graph (C08): packages, profiles, providers and the delivery
 * traceability behind them.
 *
 * The architecture graph tool owns relation meaning and the first three views
 * (goal reference, port call, development order). This module adds only the
 * distribution projection it does not render: profile nodes next to the package
 * closure, provider/capability ownership, and the package -> module -> contract
 * -> task traceability. It reads a resolved `Graph`; it holds no second graph
 * model, never writes the graph documents, and never lowers a deployment
 * relation into a development wait.
 *
 * Rendering is deterministic: every collection is sorted before it is emitted,
 * so the same graph always produces the same bytes.
 */

function mermaidId(id) {
  return String(id).replaceAll(/[^A-Za-z0-9_]/gu, "_");
}

function compareNodes(left, right) {
  return `${left.type}\u0000${left.id}`.localeCompare(`${right.type}\u0000${right.id}`);
}

function contractIdsForModules(graph, moduleIds) {
  const contracts = new Set();
  for (const contract of graph.contracts.values()) {
    if (moduleIds.includes(contract.owner_module) || contract.consumers.some((id) => moduleIds.includes(id))) {
      contracts.add(contract.id);
    }
  }
  return [...contracts].sort();
}

export function buildFourthGraph(graph) {
  const hostPublished = new Set(HOST_PUBLISHED_CAPABILITIES.map((entry) => entry.capability));
  const ownership = new Map(PRODUCT_CAPABILITY_OWNERSHIP.map((row) => [row.capability, row]));

  const providerIds = new Map();
  for (const pkg of graph.packages.values()) {
    for (const capability of pkg.provides ?? []) {
      if (!providerIds.has(capability)) providerIds.set(capability, []);
      providerIds.get(capability).push(pkg.id);
    }
  }
  for (const providers of providerIds.values()) providers.sort();

  const nodes = [];
  for (const pkg of graph.packages.values()) {
    nodes.push({
      id: pkg.id,
      type: "package",
      optional: pkg.optional,
      activation: pkg.activation,
      artifact_status: pkg.artifact_status,
      measured_bytes: pkg.measured_bytes,
      provides: [...pkg.provides].sort(),
    });
  }
  for (const profile of graph.profiles.values()) nodes.push({ id: profile.id, type: "profile" });
  for (const capabilityId of [...new Set([...ownership.keys(), ...providerIds.keys()])].sort()) {
    const row = ownership.get(capabilityId) ?? null;
    nodes.push({
      id: capabilityId,
      type: "capability",
      default_owner: row?.owner ?? null,
      set: row?.set ?? null,
      host_published: hostPublished.has(capabilityId),
      providers: providerIds.get(capabilityId) ?? [],
    });
  }

  const edges = [];
  const push = (relation, source, target, relationClass) => edges.push({
    relation,
    source,
    target,
    class: relationClass,
    enters_development_dag: false,
  });

  for (const pkg of graph.packages.values()) {
    for (const dependency of pkg.requires_package) push("requires_package", pkg.id, dependency, "deployment-delivery");
    for (const moduleId of pkg.modules) push("package_ships_module", pkg.id, moduleId, "deployment-delivery");
    for (const capability of pkg.provides ?? []) push("package_provides_capability", pkg.id, capability, "deployment-delivery");
    for (const taskId of pkg.implementation_tasks) push("package_implementation_task", pkg.id, taskId, "deployment-delivery");
  }
  for (const profile of graph.profiles.values()) {
    for (const packageId of profile.selected_packages) push("profile_selects_package", profile.id, packageId, "deployment-delivery");
    for (const packageId of profile.forbidden_packages) push("profile_forbids_package", profile.id, packageId, "deployment-delivery");
  }
  for (const task of graph.tasks.values()) {
    for (const packageId of task.packages ?? []) push("task_delivers_package", task.id, packageId, "deployment-delivery");
  }

  const packageIds = [...graph.packages.keys()].sort();
  const packageModules = new Map(packageIds.map((id) => [id, [...graph.packages.get(id).modules].sort()]));
  const shippedModules = [...new Set(packageIds.flatMap((id) => packageModules.get(id)))].sort();
  for (const moduleId of shippedModules) nodes.push({ id: moduleId, type: "module" });
  const deliveryTasks = new Map(packageIds.map((id) => [id, deliveryTasksForPackage(graph, id)]));
  const deliveryTaskSet = [...new Set(packageIds.flatMap((id) => deliveryTasks.get(id)))].sort();
  for (const taskId of deliveryTaskSet) nodes.push({ id: taskId, type: "task" });
  const contractIds = contractIdsForModules(graph, shippedModules);
  for (const contractId of contractIds) nodes.push({ id: contractId, type: "contract" });
  for (const contractId of contractIds) {
    const contract = graph.contracts.get(contractId);
    if (shippedModules.includes(contract.owner_module)) {
      push("module_owns_contract", contract.owner_module, contractId, "impact-traceability");
    }
    for (const consumer of contract.consumers) {
      if (shippedModules.includes(consumer)) push("module_consumes_contract", consumer, contractId, "impact-traceability");
    }
  }
  edges.sort((left, right) => `${left.relation}\u0000${left.source}\u0000${left.target}`
    .localeCompare(`${right.relation}\u0000${right.source}\u0000${right.target}`));
  nodes.sort(compareNodes);

  const profiles = [...graph.profiles.values()].map((profile) => {
    const closure = [...graph.packageClosure(profile.selected_packages)].sort();
    return {
      id: profile.id,
      title: profile.title,
      selected_packages: [...profile.selected_packages].sort(),
      forbidden_packages: [...profile.forbidden_packages].sort(),
      closure,
      not_selected: packageIds.filter((packageId) => !closure.includes(packageId)),
      provider_coverage: PRODUCT_CAPABILITY_OWNERSHIP.map((row) => ({
        capability: row.capability,
        default_owner: row.owner,
        default_owner_in_closure: closure.includes(row.owner),
        providers_in_closure: closure.filter((packageId) => (graph.packages.get(packageId).provides ?? []).includes(row.capability)),
        host_published: hostPublished.has(row.capability),
      })),
      delivery_tasks: [...new Set(closure.flatMap((packageId) => deliveryTasks.get(packageId)))].sort(),
    };
  }).sort((left, right) => left.id.localeCompare(right.id));

  const traceability = {
    packages: packageIds.map((packageId) => ({
      id: packageId,
      modules: packageModules.get(packageId),
      contracts: contractIdsForModules(graph, packageModules.get(packageId)),
      capabilities: [...(graph.packages.get(packageId).provides ?? [])].sort(),
      implementation_tasks: [...graph.packages.get(packageId).implementation_tasks].sort(),
      delivery_tasks: deliveryTasks.get(packageId),
    })),
  };

  const document = {
    kind: "licoup-distribution-graph.v1",
    graph_digest: graph.graphDigest,
    graph_version: graph.graphVersion,
    core_package: graph.distribution.core_package,
    nodes,
    edges,
    profiles,
    traceability,
    non_claims: [
      "Declared target graph only: it is not an installed inventory, a built artifact list or a size measurement.",
      "Deployment and delivery relations never enter the development DAG; only task.depends_on schedules work.",
      "Artifact byte counts stay null here; real bytes and digests live in the install lock built from local build output.",
    ],
  };
  return { ...document, fourth_graph_digest: digestOf(document) };
}

export function renderFourthGraph(graph) {
  const fourth = buildFourthGraph(graph);
  const packageIds = [...graph.packages.keys()].sort();
  const label = new Map();
  packageIds.forEach((id, index) => label.set(id, `K${index}`));
  const profileIds = [...graph.profiles.keys()].sort();
  profileIds.forEach((id, index) => label.set(id, `P${index}`));
  const capabilityIds = fourth.nodes.filter((node) => node.type === "capability").map((node) => node.id).sort();
  capabilityIds.forEach((id, index) => label.set(id, `C${index}`));

  const mermaid = ["flowchart LR"];
  for (const id of profileIds) mermaid.push(`  ${label.get(id)}["profile ${id}"]`);
  for (const id of packageIds) mermaid.push(`  ${label.get(id)}["${id}"]`);
  for (const id of capabilityIds) mermaid.push(`  ${label.get(id)}["${id}"]`);
  for (const edge of fourth.edges) {
    if (!label.has(edge.source) || !label.has(edge.target)) continue;
    const arrow = edge.relation === "profile_forbids_package" ? "-.->" : "-->";
    mermaid.push(`  ${label.get(edge.source)} ${arrow}|${edge.relation}| ${label.get(edge.target)}`);
  }
  mermaid.push("");

  const layers = topologicalLayers(
    packageIds,
    packageIds.flatMap((id) => graph.packages.get(id).requires_package.map((dependency) => [id, dependency])),
  );
  const svg = layeredSvg({
    nodes: graph.packages,
    nodeLayers: layers,
    edges: packageIds.flatMap((id) => graph.packages.get(id).requires_package.map((dependency) => [id, dependency])),
    label: "部署：包到必需依赖（不含profile与任务等待）",
    note: "Install closure only; never a development prerequisite.",
  });

  const traceability = [
    "# 第四图交付追踪（由 resolved graph 生成，请勿手工编辑）",
    "",
    `图摘要：\`${fourth.graph_digest}\`；第四图摘要：\`${fourth.fourth_graph_digest}\``,
    "",
    "| 包 | 模块 | 合同 | 能力 | 交付任务 |",
    "|---|---|---|---|---|",
  ];
  for (const entry of fourth.traceability.packages) {
    traceability.push(`| ${entry.id} | ${entry.modules.join(", ") || "—"} | ${entry.contracts.join(", ") || "—"} | ${entry.capabilities.join(", ") || "—"} | ${entry.delivery_tasks.join(", ") || "—"} |`);
  }
  traceability.push("", "包、模块与合同只说明交付归属，不进入开发DAG等待。", "");

  return {
    files: {
      "distribution.fourth.mmd": `${mermaid.join("\n")}\n`,
      "distribution.fourth.svg": svg,
      "distribution.traceability.md": traceability.join("\n"),
      "distribution.fourth.json": `${JSON.stringify(fourth, null, 2)}\n`,
    },
    summary: {
      nodes: fourth.nodes.length,
      edges: fourth.edges.length,
      packages: packageIds.length,
      profiles: profileIds.length,
      capabilities: capabilityIds.length,
      entered_development_dag_edges: fourth.edges.filter((edge) => edge.enters_development_dag).length,
    },
  };
}
