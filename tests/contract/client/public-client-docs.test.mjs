import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

const pairs = Object.freeze([
  ["README.md", "README.zh-CN.md"],
  ["CONTRIBUTING.md", "CONTRIBUTING.zh-CN.md"],
  ["SECURITY.md", "SECURITY.zh-CN.md"],
  ["docs/functionality/USER-GUIDE.md", "docs/functionality/USER-GUIDE.zh-CN.md"],
  ["docs/architecture/README.md", "docs/architecture/README.zh-CN.md"],
  ["docs/COMPATIBILITY.md", "docs/COMPATIBILITY.zh-CN.md"],
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

function compact(value) {
  return value.replace(/\s+/gu, " ");
}

test("public client documents keep matching English and Chinese entry points", async () => {
  for (const [englishPath, chinesePath] of pairs) {
    const [english, chinese] = await Promise.all([read(englishPath), read(chinesePath)]);
    assert.match(english, new RegExp(chinesePath.split("/").at(-1).replace(".", "\\."), "u"));
    assert.match(chinese, new RegExp(englishPath.split("/").at(-1).replace(".", "\\."), "u"));
  }
});

test("public client document links resolve inside the repository", async () => {
  for (const relativePath of pairs.flat()) {
    const source = await read(relativePath);
    for (const match of source.matchAll(/\[[^\]]+\]\(([^)]+)\)/gu)) {
      const target = match[1].split("#", 1)[0];
      if (target.length === 0 || /^[a-z][a-z0-9+.-]*:/iu.test(target)) continue;
      const resolved = path.resolve(repoRoot, path.dirname(relativePath), target);
      await assert.doesNotReject(fs.access(resolved), `${relativePath} has a missing link`);
    }
  }
});

test("public product language keeps the local-first and approved encrypted-peer boundary", async () => {
  const [readme, guide, architecture, security, chineseReadme, chineseGuide] = await Promise.all([
    read("README.md"),
    read("docs/functionality/USER-GUIDE.md"),
    read("docs/architecture/README.md"),
    read("SECURITY.md"),
    read("README.zh-CN.md"),
    read("docs/functionality/USER-GUIDE.zh-CN.md"),
  ]);

  assert.match(compact(readme), /Sensitive runtime data stays on the device/u);
  assert.match(compact(readme), /Default client scenarios do not upload local.*plaintext user content to a service/u);
  assert.match(compact(readme), /named external service can read that approved content/u);
  assert.match(compact(guide), /Approve that one transfer/u);
  assert.match(compact(guide), /Changing the peer or content requires a new approval/u);
  assert.match(compact(architecture), /sender encrypts before network I\/O/u);
  assert.match(compact(security), /relay is untrusted/u);
  assert.match(compact(security), /approved external MCP request is a different boundary/u);
  assert.match(compact(chineseReadme), /敏感运行时数据留在设备上/u);
  assert.match(compact(chineseGuide), /只批准这一次传输/u);
  assert.match(compact(chineseGuide), /更换目标或修改内容后，必须重新确认/u);
});

test("optional collaboration has an independent trust root and manual signed runner boundary", async () => {
  const [
    readme,
    guide,
    architecture,
    security,
    chineseReadme,
    chineseGuide,
    chineseArchitecture,
    chineseSecurity,
  ] = await Promise.all([
    read("README.md"),
    read("docs/functionality/USER-GUIDE.md"),
    read("docs/architecture/README.md"),
    read("SECURITY.md"),
    read("README.zh-CN.md"),
    read("docs/functionality/USER-GUIDE.zh-CN.md"),
    read("docs/architecture/README.zh-CN.md"),
    read("SECURITY.zh-CN.md"),
  ]);

  assert.match(compact(readme), /not loaded by the default client/u);
  assert.match(compact(readme), /immutable GitHub commit/u);
  assert.match(compact(readme), /does not bundle that server runner/u);
  assert.match(compact(guide), /Installation or enablement never grants continuing transfer permission/u);
  assert.match(compact(guide), /Assembly does not start the server automatically/u);
  assert.match(compact(architecture), /absent from default startup and navigation/u);
  assert.match(compact(architecture), /separate action.*never a trust root/u);
  assert.match(compact(architecture), /fixed signed external runner on loopback/u);
  assert.match(compact(security), /Plugin installation, enablement, startup, schedules, and agent requests never/u);
  assert.match(compact(security), /signing key is imported independently of the package download/u);
  assert.match(compact(chineseReadme), /默认客户端不会加载可选的 LicoMesh 协作能力/u);
  assert.match(compact(chineseReadme), /本仓库不捆绑该服务端运行器/u);
  assert.match(compact(chineseGuide), /组装不会自动启动服务端/u);
  assert.match(compact(chineseArchitecture), /默认启动和\s*导航不会加载/u);
  assert.match(compact(chineseArchitecture), /通过独立操作导入可信签名公钥/u);
  assert.match(compact(chineseSecurity), /普通客户端状态只能作为投影/u);
});

test("MCP external effects require fresh user presence and a one-shot preview claim", async () => {
  const [guide, architecture, security, chineseGuide, chineseArchitecture, chineseSecurity] =
    await Promise.all([
      read("docs/functionality/USER-GUIDE.md"),
      read("docs/architecture/README.md"),
      read("SECURITY.md"),
      read("docs/functionality/USER-GUIDE.zh-CN.md"),
      read("docs/architecture/README.zh-CN.md"),
      read("SECURITY.zh-CN.md"),
    ]);

  assert.match(compact(guide), /bridge first creates a non-transmitting preview/u);
  assert.match(compact(guide), /matching preview can be claimed exactly once/u);
  assert.match(compact(guide), /If protected platform authentication is unavailable, external transfer remains disabled/u);
  assert.match(compact(architecture), /bridge may stage an exact preview, but it performs no exchange and cannot approve it/u);
  assert.match(compact(architecture), /requests fresh platform user presence for the canonical digest/u);
  assert.match(compact(architecture), /atomically claims the matching short-lived preview exactly once/u);
  assert.match(compact(architecture), /Caller-supplied flags or ordinary state files are not proof of approval/u);
  assert.match(compact(security), /writable state file is not approval/u);
  assert.match(compact(security), /digest binds the direction, destination, purpose, protocol revision, session, and exact request body/u);
  assert.match(compact(chineseGuide), /bridge 会\s*先创建一份不发起传输的预览/u);
  assert.match(compact(chineseArchitecture), /调用方参数和普通状态文件都\s*不能证明用户已经批准/u);
  assert.match(compact(chineseArchitecture), /原生命令随后针对规范\s*摘要请求一次新的平台用户在场确认/u);
  assert.match(compact(chineseSecurity), /平台无法提供\s*用户在场保护时，对外传输保持禁用/u);
  for (const source of [guide, architecture, security, chineseGuide, chineseArchitecture, chineseSecurity]) {
    assert.doesNotMatch(compact(source), /authenticated client broker|native broker|客户端授权代理|原生授权代理/u);
  }
});
