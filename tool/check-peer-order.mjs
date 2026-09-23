#!/usr/bin/env node
/**
 * 播放端展示序守卫（阻塞）—— 钉住「**在播优先 → 类别 → 名称**」这条口径，
 * 并禁止任何文件绕过唯一实现。
 *
 * 背景（2026-09-24）：口径在客户端与 HA 卡片之间反复横跳，根因有两条：
 *   ① **两份实现各写一份**：流转页与切换器各自内联比较器，改了一处就漂移；
 *   ② **键序被调换**：把「类别」提到「在播」之前 = 变成「类别优先」——
 *      群组恒压过在播设备，用户已明确否掉（曾误当成定稿去落地）。
 * 两条都是「编译不报错、单看某端也说得通」的静默漂移，所以按**类别**钉死在 CI。
 *
 * 规则：
 *   R1 唯一实现文件必须存在；
 *   R2 比较器键序必须是 在播 → 类别 → 名称（键序即契约）；
 *   R3 类别权重必须 local=0 / group=1 / 其它=2；
 *   R4 lib/ 下除唯一实现外，任何 .dart 不得出现内联排序实现；
 *   R5 两个 UI 调用点必须真的调用共享实现（不能绕过）。
 *
 * 用法：node tool/check-peer-order.mjs
 */
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";
import { readdirSync, statSync } from "node:fs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const IMPL_REL = "lib/features/player/peer_display_order.dart";
const IMPL = join(root, IMPL_REL);

/** 注释会原样留在源码里，`//` 说明文字不该被当成「用法」判红 —— 先剥掉再判。 */
const stripComments = (t) =>
  t
    .split("\n")
    .map((line) => {
      const i = line.indexOf("//");
      return i < 0 ? line : line.slice(0, i);
    })
    .join("\n");

/** 取具名函数的函数体（含花括号，按深度配对）。 */
function bodyOf(text, signature) {
  const i = text.indexOf(signature);
  if (i < 0) return "";
  const start = text.indexOf("{", i);
  if (start < 0) return "";
  let depth = 0;
  for (let j = start; j < text.length; j++) {
    const c = text[j];
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return text.slice(start, j + 1);
    }
  }
  return text.slice(start);
}

/** 递归收集 lib/ 下的 .dart（跳过生成代码）。 */
function dartFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      if (name === "generated") continue;
      out.push(...dartFiles(p));
    } else if (name.endsWith(".dart")) {
      out.push(p);
    }
  }
  return out;
}

const results = [];
const record = (name, why, ok) => results.push({ name, why, ok });

if (!existsSync(IMPL)) {
  record(`R1 唯一实现存在:${IMPL_REL}`, "排序实现被删/挪走，两个调用点会各自内联副本", false);
} else {
  const implRaw = readFileSync(IMPL, "utf8");
  const impl = stripComments(implRaw);
  record(`R1 唯一实现存在:${IMPL_REL}`, "", /int\s+comparePeerDisplayOrder\s*\(/.test(impl));

  const cmp = bodyOf(impl, "int comparePeerDisplayOrder(");
  const iQueue = cmp.search(/queueActive\s*\?\s*0\s*:\s*1/);
  const iKind = cmp.includes("peerKindRank(") ? cmp.indexOf("peerKindRank(") : -1;
  const iName = cmp.includes("name.compareTo(") ? cmp.indexOf("name.compareTo(") : -1;
  record(
    "R2 比较器键序:在播 → 类别 → 名称",
    "键序被调换(例如把类别提到最前 = 「类别优先」)⇒ 群组恒压过在播设备，是已被用户否掉的口径",
    iQueue >= 0 && iKind > iQueue && iName > iKind,
  );

  const rank = bodyOf(impl, "int peerKindRank(");
  record(
    "R3 类别权重:本机 0 < 群组 1 < 独立播放器 2",
    "权重写错 ⇒ 群组/本机位置不对，且与 HA 卡片不同序",
    /isLocal\s*\)\s*return\s+0\s*;/.test(rank) &&
      /kind\s*==\s*'group'\s*\)\s*return\s+1\s*;/.test(rank) &&
      /return\s+2\s*;/.test(rank),
  );
}

// R4: 禁止内联副本 —— 这两种写法就是「自己实现了一遍排序」。
const INLINE_PATTERNS = [
  { re: /queueActive\s*\?\s*0\s*:\s*1/, what: "在播权重(queueActive ? 0 : 1)" },
  {
    re: /isLocal\s*\?\s*0\s*:\s*\(?\s*\w+\.kind\s*==\s*'group'\s*\?\s*1\s*:\s*2/,
    what: "类别权重(isLocal ? 0 : kind=='group' ? 1 : 2)",
  },
];
const offenders = [];
for (const file of dartFiles(join(root, "lib"))) {
  const rel = relative(root, file).split("\\").join("/");
  if (rel === IMPL_REL) continue;
  const txt = stripComments(readFileSync(file, "utf8"));
  for (const { re, what } of INLINE_PATTERNS) {
    if (re.test(txt)) offenders.push(`${rel} → ${what}`);
  }
}
record(
  "R4 禁止内联副本:排序只能有一处实现",
  `调用点自己写比较器 ⇒ 改一处漏一处(实测漂移来源)。违规:${offenders.join(" / ")}`,
  offenders.length === 0,
);

// R5: 两个 UI 调用点必须真的走共享实现。
const CALL_SITES = [
  "lib/features/player/pages/player_transfer_page.dart",
  "lib/features/player/widgets/player_switcher.dart",
];
const bypass = CALL_SITES.filter((rel) => {
  const p = join(root, rel);
  if (!existsSync(p)) return true;
  const txt = stripComments(readFileSync(p, "utf8"));
  return !/comparePeerDisplayOrder|sortPeersForDisplay/.test(txt);
});
record(
  "R5 两个调用点确实调用共享实现",
  `未调用 ⇒ 界面展示序绕过了唯一实现。遗漏:${bypass.join(" / ")}`,
  bypass.length === 0,
);

let failed = 0;
for (const r of results) {
  if (!r.ok) failed++;
  console.log(`[${r.ok ? "PASS" : "FAIL"}] ${r.name}`);
  if (!r.ok && r.why) console.log(`       why: ${r.why}`);
}
console.log(
  failed
    ? `\n播放端展示序守卫:${failed}/${results.length} 条不通过。`
    : `\n播放端展示序守卫:${results.length}/${results.length} 条通过。`,
);
process.exit(failed ? 1 : 0);
