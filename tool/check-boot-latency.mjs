#!/usr/bin/env node
/**
 * 启动编排防回归守卫（阻塞）—— 钉住 v5.0.38 的三处「定时空转 → 事件驱动」修复。
 *
 * 背景（2026-10-01，用户反馈「启动客户端到可用要几秒」）：
 *   实测公网首连 186ms、连接复用后 3ms —— 网络本身不慢。耗时全在**客户端启动
 *   编排的三段定时空转**，最坏叠加 ≈ 6.9s：
 *     ① `fetchLocalQueueForRestore` 以 100ms 步长轮询等 `_localPeerId`（上限 4s）；
 *     ② `_registerSelf` 撞上「凭证未注入必 401」后固定 `Future.delayed(900ms)` 盲等；
 *     ③ `ensureActiveAddressProvider` 空转等活跃地址（上限 2s），且首屏**每个**
 *        请求都要先过这里。
 *   三处的共同形态是「**不管事情有没有发生，先睡够再说**」，因此修复形态统一为
 *   「**Completer 信号 + 预算上限超时**」：事情一发生即刻唤醒，只有异常路径才付
 *   预算上限。
 *
 * 为什么必须钉死在 CI（而不是靠 code review）：
 *   这三处回退**全都编译得过、单看也都说得通** —— 把 `.future.timeout(budget)`
 *   改回 `while (...) { await Future.delayed(...) }` 是最顺手的「调试/兜底」写法，
 *   而且回归后**没有任何单测会红**（功能结果完全一样，只是慢）。唯一能拦住它的
 *   是源码级静态断言：直接在**指定函数体**里判「有没有轮询 / 有没有接信号」。
 *
 * 规则（先剥注释，再在**指定函数体**内判定 —— 全文件 grep 会被注释里的
 * 「历史上是 100ms 轮询」这类说明文字误伤）：
 *   R1 关键符号在位：_localPeerIdReady / apiCredentialsReadyProvider / waitForActiveAddress
 *   R2 Fix-1 无轮询回退：_waitForLocalPeerId 体内不得 delayed/while/sleep，
 *                        必须 _ensurePeerIdReady + kPeerIdWaitBudget，且预算 ≤ 2000ms
 *   R3 Fix-1 接线未断：fetchLocalQueueForRestore 必须调用 _waitForLocalPeerId
 *   R4 Fix-2 无盲等回退：_registerSelf 体内不得 Duration(milliseconds: 900)，
 *                        必须调用 _waitForApiCredentialsReady
 *   R5 Fix-3 无空转回退：ensureActiveAddressProvider 必须调用 waitForActiveAddress，
 *                        且预算上界 ≤ 300ms（含 waitForActiveAddress 默认预算）
 *   R6 Fix-3 唤醒未断：address_pool 的 _setActiveAddress 必须 complete 掉
 *                        _activeAddressReady（否则等待方永远挂起 = 比空转更糟）
 *   R7 反向探针自校验：grep 必然不存在的符号，命中数必须为 0 —— 证明本守卫
 *                        不是恒绿（恒绿等于没守），此条失败同样阻断
 *
 * 用法：node tool/check-boot-latency.mjs   （退出码非 0 即阻断）
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const CAST_REL = "lib/providers/cast/cast_peer_provider.dart";
const API_REL = "lib/providers/api/api_provider.dart";
const POOL_REL = "lib/core/network/address_pool.dart";

/** 注释会原样留在源码里，`//` 说明文字不该被当成「用法」判红 —— 先剥掉再判。 */
const stripComments = (t) =>
  t
    .split("\n")
    .map((line) => {
      const i = line.indexOf("//");
      return i < 0 ? line : line.slice(0, i);
    })
    .join("\n");

/** 从 start 处的 `{` 起按花括号深度配对取函数体（含花括号）。 */
function braceBodyFrom(text, start) {
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

/** 取具名函数的函数体（含花括号，按深度配对）。签名请传**声明式全签名**。 */
function bodyOf(text, signature) {
  const i = text.indexOf(signature);
  if (i < 0) return "";
  return braceBodyFrom(text, text.indexOf("{", i));
}

/**
 * 同上，但**先跳过参数列表再取函数体**。
 * 必须这么做的理由：`_registerSelf({int attempt = 0})` 的第一个 `{` 属于命名
 * 可选参数列表而不是函数体 —— 直接取会拿到 `{int attempt = 0}` 这段参数，
 * 于是「体内有没有调用 _waitForApiCredentialsReady」永远判成 0（守卫假绿）。
 * 参数默认值里可能套 `Duration(...)`，故用**圆括号**深度配对找参数列表的收尾。
 */
function bodyOfAfterParams(text, signature) {
  const i = text.indexOf(signature);
  if (i < 0) return "";
  const p = text.indexOf("(", i + signature.length - 1);
  if (p < 0) return "";
  let depthP = 0;
  let end = p;
  for (let j = p; j < text.length; j++) {
    const c = text[j];
    if (c === "(") depthP++;
    else if (c === ")") {
      depthP--;
      if (depthP === 0) {
        end = j;
        break;
      }
    }
  }
  return braceBodyFrom(text, text.indexOf("{", end));
}

/** 读仓库内相对路径 → 剥注释后的代码；文件不存在返回 null。 */
function codeOf(rel) {
  const p = join(root, rel);
  if (!existsSync(p)) return null;
  return stripComments(readFileSync(p, "utf8"));
}

/** 计数（正则需带 g，避免 lastIndex 复用坑：每次新建）。 */
const countOf = (text, source, flags = "g") =>
  (text.match(new RegExp(source, flags)) || []).length;

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

const UNIT_MS = {
  microseconds: 1 / 1000,
  milliseconds: 1,
  seconds: 1000,
  minutes: 60000,
  hours: 3600000,
};

/** 抽出文本里所有 Duration(...) 字面量并折算成毫秒（返回 [{raw, ms}]）。 */
function durationsMs(text) {
  const re = /Duration\s*\(\s*(microseconds|milliseconds|seconds|minutes|hours)\s*:\s*(\d+)\s*\)/g;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    out.push({ raw: m[0], ms: Number(m[2]) * UNIT_MS[m[1]] });
  }
  return out;
}

const results = [];
/**
 * 记一条判定。
 * @param {string} name 规则编号 + 一句话描述
 * @param {string} why  失败时的「为什么要钉死它」
 * @param {boolean} ok  是否通过
 * @param {string} expected 期望
 * @param {string} actual 实际
 */
function record(name, why, ok, expected = "", actual = "") {
  results.push({ name, why, ok, expected, actual });
}

// ─────────────────────────────────────────────────────────────
// R1 关键符号在位（三处修复的地基：信号源/信号体/等待点，缺一个就整体退化成空转）
// ─────────────────────────────────────────────────────────────
const R1_SYMBOLS = [
  { rel: CAST_REL, symbol: "_localPeerIdReady", why: "Fix-1 的注册完成信号体被删 ⇒ 恢复流程只能退回轮询" },
  { rel: API_REL, symbol: "apiCredentialsReadyProvider", why: "Fix-2 的凭证就绪信号源被删 ⇒ _registerSelf 只能退回固定盲等" },
  { rel: POOL_REL, symbol: "waitForActiveAddress", why: "Fix-3 的事件驱动等待点被删 ⇒ ensureActiveAddressProvider 只能退回 2s 空转" },
];
const codeCache = {};
for (const { rel, symbol, why } of R1_SYMBOLS) {
  const code = codeOf(rel);
  codeCache[rel] = code;
  if (code === null) {
    record(
      `R1 关键符号在位:${rel} → ${symbol}`,
      `${why}（且文件本身不见了）`,
      false,
      "文件存在且符号 ≥ 1 处",
      "文件不存在",
    );
    continue;
  }
  const n = countOf(code, symbol.replace(/[$]/g, "\\$"));
  record(
    `R1 关键符号在位:${rel} → ${symbol}`,
    why,
    n >= 1,
    "≥ 1 处",
    `${n} 处`,
  );
}

const castCode = codeCache[CAST_REL] ?? "";
const apiCode = codeCache[API_REL] ?? "";
const poolCode = codeCache[POOL_REL] ?? "";

// ─────────────────────────────────────────────────────────────
// R2 Fix-1 无轮询回退（_waitForLocalPeerId 必须走 timeout 信号，不是睡够再说）
// ─────────────────────────────────────────────────────────────
const WAIT_PEER_SIG = "Future<String?> _waitForLocalPeerId(";
const waitPeerBody = bodyOfAfterParams(castCode, WAIT_PEER_SIG);
if (waitPeerBody === "") {
  record(
    "R2 Fix-1 无轮询回退:_waitForLocalPeerId 函数体存在",
    "等待函数被删/改名 ⇒ fetchLocalQueueForRestore 只能内联旧的 100ms 轮询",
    false,
    `找到声明 ${WAIT_PEER_SIG}`,
    "未找到",
  );
} else {
  const POLL_PATTERNS = [
    { re: /Future\s*(?:<[^>]*>)?\s*\.\s*delayed/, what: "Future.delayed（按步长睡）" },
    { re: /while\s*\(/, what: "while 循环（按步长查表）" },
    { re: /sleep\s*\(/, what: "sleep（同步睡）" },
  ];
  const hits = POLL_PATTERNS.filter((p) => p.re.test(waitPeerBody)).map((p) => p.what);
  record(
    "R2a Fix-1 无轮询回退:_waitForLocalPeerId 体内不得出现 delayed/while/sleep",
    "出现即代表「不管注册有没有落地，先睡够再说」回来了 —— 最坏 4s 空转，且功能上完全等价，没有任何单测会红",
    hits.length === 0,
    "0 处轮询构造",
    hits.length ? `命中 ${hits.join(" / ")}` : "0 处",
  );

  const hasEnsure = /_ensurePeerIdReady\s*\(/.test(waitPeerBody);
  const hasBudget = /kPeerIdWaitBudget/.test(waitPeerBody);
  record(
    "R2b Fix-1 接线未断:_waitForLocalPeerId 必须 _ensurePeerIdReady + kPeerIdWaitBudget",
    "缺任一即代表等待没有挂在信号上（或没有预算上限）—— 要么永远挂起，要么是裸轮询",
    hasEnsure && hasBudget,
    "两者都出现",
    `_ensurePeerIdReady=${hasEnsure ? "有" : "无"} / kPeerIdWaitBudget=${hasBudget ? "有" : "无"}`,
  );
}

// R2c：预算常量本身的上界（防止有人把 1500ms 悄悄改回 4000ms）
{
  const at = castCode.indexOf("static const Duration kPeerIdWaitBudget");
  const decl = at < 0 ? "" : castCode.slice(at, at + 120);
  const ds = durationsMs(decl);
  const maxMs = ds.length ? Math.max(...ds.map((d) => d.ms)) : null;
  record(
    "R2c Fix-1 预算上界:kPeerIdWaitBudget ≤ 2000ms",
    "预算被改回 4s ⇒ 异常路径（服务端不可达/未登录）每次启动都要白付 4s，等于把 Fix-1 又还回去了",
    maxMs !== null && maxMs <= 2000,
    "≤ 2000ms",
    maxMs === null ? "未找到常量声明" : `${maxMs}ms（${ds.map((d) => d.raw).join(", ")}）`,
  );
}

// ─────────────────────────────────────────────────────────────
// R3 Fix-1 接线未断（调用方必须真的走事件驱动等待）
// ─────────────────────────────────────────────────────────────
{
  const RESTORE_SIG = "Future<Map<String, dynamic>?> fetchLocalQueueForRestore(";
  const restoreBody = bodyOfAfterParams(castCode, RESTORE_SIG);
  if (restoreBody === "") {
    record(
      "R3 Fix-1 接线未断:fetchLocalQueueForRestore 调用 _waitForLocalPeerId",
      "调用点被改回内联轮询（或方法被删）⇒ 启动恢复路径重新背上 4s 空转",
      false,
      `找到声明 ${RESTORE_SIG} 且体内调用 _waitForLocalPeerId`,
      "未找到方法声明",
    );
  } else {
    const n = countOf(restoreBody, "_waitForLocalPeerId\\s*\\(");
    const pollBack = /while\s*\(/.test(restoreBody) || /delayed\s*\(/.test(restoreBody);
    record(
      "R3 Fix-1 接线未断:fetchLocalQueueForRestore 调用 _waitForLocalPeerId",
      "信号实现了但没人调用 = 白修；同样的反模式是调用点自己内联一段 100ms 轮询",
      n >= 1 && !pollBack,
      "≥ 1 处调用且体内无轮询构造",
      `_waitForLocalPeerId 调用 ${n} 处 / 体内轮询构造 ${pollBack ? "有" : "无"}`,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// R4 Fix-2 无盲等回退（_registerSelf 不得再固定睡 900ms）
// ─────────────────────────────────────────────────────────────
{
  const REG_SIG = "Future<void> _registerSelf(";
  const regBody = bodyOfAfterParams(castCode, REG_SIG);
  if (regBody === "") {
    record(
      "R4 Fix-2 无盲等回退:_registerSelf 体内不得 Duration(milliseconds: 900)",
      "注册函数被删/改名 ⇒ 守卫失去锚点（且冷启动注册竞态会重新退化）",
      false,
      `找到声明 ${REG_SIG}`,
      "未找到",
    );
  } else {
    const blind = durationsMs(regBody).filter((d) => d.ms >= 900);
    record(
      "R4a Fix-2 无盲等回退:_registerSelf 体内不得出现 900ms 级固定延时",
      "固定 900ms 盲等 = 每次冷启动都必然白付 900ms（凭证注入通常几十 ms 就够了）",
      blind.length === 0,
      "体内无 ≥900ms 的 Duration 字面量",
      blind.length ? `命中 ${blind.map((d) => d.raw).join(" / ")}` : "0 处",
    );
    const n = countOf(regBody, "_waitForApiCredentialsReady\\s*\\(");
    record(
      "R4b Fix-2 接线未断:_registerSelf 必须调用 _waitForApiCredentialsReady",
      "不接凭证就绪信号 ⇒ 重试时机只能靠猜，盲等/不重试二选一，两条都是回归",
      n >= 1,
      "≥ 1 处调用",
      `${n} 处`,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// R5 Fix-3 无空转回退（ensureActiveAddressProvider 必须走事件驱动 + 短预算）
// ─────────────────────────────────────────────────────────────
const MAX_ADDRESS_BUDGET_MS = 300;
{
  const ENSURE_SIG = "final ensureActiveAddressProvider = FutureProvider<ServerAddress>(";
  const ensureBody = bodyOf(apiCode, ENSURE_SIG);
  if (ensureBody === "") {
    record(
      "R5 Fix-3 无空转回退:ensureActiveAddressProvider 调用 waitForActiveAddress",
      "provider 被删/改名 ⇒ 守卫失去锚点（且首屏请求会重新背上 2s 空转）",
      false,
      `找到声明 ${ENSURE_SIG}`,
      "未找到",
    );
  } else {
    const n = countOf(ensureBody, "waitForActiveAddress\\s*\\(");
    record(
      "R5a Fix-3 无空转回退:ensureActiveAddressProvider 必须调用 waitForActiveAddress",
      "不调用即代表回到了「循环 + Future.delayed 等活跃地址」；首屏每个请求都要先过这里，2s × N 直接变成用户可感的启动卡顿",
      n >= 1,
      "≥ 1 处调用",
      `${n} 处`,
    );

    const ds = durationsMs(ensureBody);
    const over = ds.filter((d) => d.ms > MAX_ADDRESS_BUDGET_MS);
    record(
      `R5b Fix-3 预算上界:ensureActiveAddressProvider 体内预算 ≤ ${MAX_ADDRESS_BUDGET_MS}ms`,
      "预算回到 2000ms 级 ⇒ 异常路径（恢复失败/首次启动）每个首屏请求都白付 2s，这正是本次要削掉的那 2s",
      ds.length > 0 && over.length === 0,
      `体内有 Duration 字面量且全部 ≤ ${MAX_ADDRESS_BUDGET_MS}ms`,
      ds.length
        ? `${ds.map((d) => `${d.raw}=${d.ms}ms`).join(", ")}${over.length ? " → 超限" : ""}`
        : "体内未找到预算常量（预算被外提则本条无法判定，需改判实际常量名）",
    );

    const spin = /while\s*\(/.test(ensureBody) || /delayed\s*\(/.test(ensureBody);
    record(
      "R5c Fix-3 无空转构造:ensureActiveAddressProvider 体内不得 while/delayed",
      "出现 while+delayed 即代表 200ms 一跳的空转轮询回来了（历史实现原样回归）",
      !spin,
      "体内无 while( / delayed(",
      spin ? "命中" : "0 处",
    );
  }
}

// R5d：waitForActiveAddress 的默认预算同样不得回到秒级
{
  const WAIT_ADDR_SIG = "Future<ServerAddress?> waitForActiveAddress(";
  const i = poolCode.indexOf(WAIT_ADDR_SIG);
  const declSlice = i < 0 ? "" : poolCode.slice(i, i + 320);
  const ds = durationsMs(declSlice);
  const over = ds.filter((d) => d.ms > MAX_ADDRESS_BUDGET_MS);
  record(
    `R5d Fix-3 默认预算:waitForActiveAddress 默认 timeout ≤ ${MAX_ADDRESS_BUDGET_MS}ms`,
    "默认预算被放宽到秒级 ⇒ 所有不传参的调用方都会被拖住，修复被从库内部悄悄抵消",
    ds.length > 0 && over.length === 0,
    `声明处有默认 Duration 且 ≤ ${MAX_ADDRESS_BUDGET_MS}ms`,
    ds.length
      ? `${ds.map((d) => `${d.raw}=${d.ms}ms`).join(", ")}${over.length ? " → 超限" : ""}`
      : "声明处未找到默认 Duration",
  );
}

// ─────────────────────────────────────────────────────────────
// R6 Fix-3 唤醒未断（信号必须真的会被 complete，否则等待方永远挂起）
// ─────────────────────────────────────────────────────────────
{
  const SET_SIG = "void _setActiveAddress(";
  const setBody = bodyOfAfterParams(poolCode, SET_SIG);
  if (setBody === "") {
    record(
      "R6 Fix-3 唤醒未断:_setActiveAddress 必须 complete(_activeAddressReady)",
      "激活路径被删/改名 ⇒ 等待方永远挂在信号上（比空转更糟：直接不返回）",
      false,
      `找到声明 ${SET_SIG}`,
      "未找到",
    );
  } else {
    const hasSignal = /_activeAddressReady/.test(setBody);
    const hasComplete = /\.complete\s*\(/.test(setBody);
    record(
      "R6 Fix-3 唤醒未断:_setActiveAddress 必须 complete(_activeAddressReady)",
      "只建信号不唤醒 ⇒ 事件驱动变成「永久挂起」，异常路径比原来的 2s 空转还慢（永不返回）",
      hasSignal && hasComplete,
      "体内出现 _activeAddressReady 且调用 complete(",
      `_activeAddressReady=${hasSignal ? "有" : "无"} / complete=${hasComplete ? "有" : "无"}`,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// R7 反向探针自校验（守卫必须能变红，否则它只是个装饰）
// ─────────────────────────────────────────────────────────────
{
  const PHANTOMS = [
    "kPeerIdPollIntervalMs",
    "kPeerIdPollStepMs",
    "kActiveAddressPollIntervalMs",
  ];
  const libDir = join(root, "lib");
  const files = existsSync(libDir) ? dartFiles(libDir) : [];
  const hits = [];
  for (const file of files) {
    const txt = stripComments(readFileSync(file, "utf8"));
    for (const sym of PHANTOMS) {
      const n = countOf(txt, sym);
      if (n > 0) {
        hits.push(`${relative(root, file).split("\\").join("/")} → ${sym} ×${n}`);
      }
    }
  }
  record(
    "R7 反向探针自校验:不存在的符号命中数必须为 0",
    "探针本该恒为 0；一旦命中说明「有人把轮询常量写回源码」或「守卫自己读错了文件/正则写坏了」。恒绿 = 没守，故此条红时同样阻断",
    hits.length === 0,
    `${PHANTOMS.join(" / ")} 各 0 处`,
    hits.length ? `命中 ${hits.join(" / ")}` : "各 0 处",
  );
}

// ─────────────────────────────────────────────────────────────
let failed = 0;
for (const r of results) {
  if (!r.ok) failed++;
  console.log(`[${r.ok ? "PASS" : "FAIL"}] ${r.name}`);
  if (!r.ok) {
    console.log(`       ❌ ${r.name}`);
    console.log(`          期望: ${r.expected}`);
    console.log(`          实际: ${r.actual}`);
    if (r.why) console.log(`          为什么钉死它: ${r.why}`);
  }
}
console.log(
  failed
    ? `\n启动编排守卫:${failed}/${results.length} 条不通过 —— 已阻断。`
    : `\n启动编排守卫:${results.length}/${results.length} 条通过。`,
);
process.exit(failed ? 1 : 0);
