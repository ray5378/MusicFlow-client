#!/usr/bin/env node
// ==================== 应用内更新「启动结算」回归守卫(5.16.0 重做) ====================
//
// 钉住应用内更新链路四个静默退化点 —— 被改坏后不报错、不崩,只表现为
// 「启动白删几十 MB 的包 / 结算结果灌不进 UI / 拖掉浮层把下载一起拖死」:
//
//   R1 结算顺序(update_artifacts_cleanup.dart):purgeUpdateArtifacts 里
//      **先** cleanupInstalledApks(**后** settlePendingDownload,顺序不能反:
//      反过来会把「刚下好、还没写旁车 meta」的新包当孤儿包删掉,用户白下几十 MB。
//      这是源码注释里明确标注的「顺序硬约束」。
//   R2 启动接线(main.dart):purgeUpdateArtifacts 必须在启动阶段被调用,
//      且结算结果经 onPendingSettled → restoreFromSettlement 灌进
//      updateDownloadControllerProvider(拿不到 widget 树 ref,必须显式持有 container)。
//   R3 浮层卸载语义(update_download_sheet.dart):dispose() 只允许报告
//      「视图关了」(setSheetVisible(false)),绝不允许 cancel 下载 —— 改造前的
//      bug 就是拖掉浮层 = 取消下载 + 删包。
//   R4 completed⇒非空 apkPath 不变式(update_download_provider.dart):
//      restoreFromSettlement 收到 completed 但 apkPath 为 null/空串时必须回落
//      idle(否则 UI 显示「已下载完成」,用户点安装必然失败)。
//
//   R5 atom 兜底补齐资源列表(update_checker.dart, 5.17.16):
//      api.github.com 限流 → 走 releases.atom → atom 没有 assets → 安卓端
//      没直链可下。必须用 releases/expanded_assets 补回来,且补失败不能
//      把整次检查判死。
//   R6 安卓绝不回退浏览器(update_checker 的下游两个消费点):
//      挑不到 apk 时旧代码 `_openInBrowser` ⇒ 安卓点「下载」蹦去 GitHub
//      发布页(那是 Windows 的姿势)。安装器改提示、设置页改走内置更新。
//
// 零依赖 node 脚本(与 tool/check-home-swr.mjs 同款),退出码非 0 = 违约。
"use strict";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const ROOT = process.cwd();

const failures = [];
let checks = 0;
function check(name, ok, detail) {
  checks += 1;
  if (ok) {
    console.log("  ✓ " + name);
  } else {
    failures.push(name + (detail ? " —— " + detail : ""));
    console.log("  ✗ " + name + (detail ? " —— " + detail : ""));
  }
}

/** 读文件为行数组;去掉纯注释行与块注释行(保留代码行的原始内容,字符串不动)。 */
function codeLines(rel) {
  const src = fs.readFileSync(path.join(ROOT, rel), "utf8");
  const noBlock = src.replace(/\/\*[\s\S]*?\*\//g, "");
  return noBlock
    .split(/\r?\n/)
    .filter((l) => !/^\s*\/\//.test(l) && l.trim().length > 0);
}

/** 提取 `NAME(` 起的大括号函数/方法体(行数组;用于 dispose 之类的局部契约)。 */
function bodyLines(ls, signatureNeedle) {  const start = ls.findIndex((l) => l.includes(signatureNeedle));
  if (start < 0) return null;
  let depth = 0;
  const out = [];
  for (let i = start; i < ls.length; i++) {
    const l = ls[i];
    out.push(l);
    for (const ch of l) {
      if (ch === "{") depth += 1;
      else if (ch === "}") depth -= 1;
    }
    if (depth <= 0 && out.length > 1) return out;
  }
  return out;
}

/**
 * 取 `startNeedle` 所在行 → `endNeedle` 所在行(不含)之间的行。
 *
 * bodyLines() 靠 `{`/`}` 计深度,**多行签名的函数会误判**:签名行与首行参数
 * 都不含 `{`,于是 depth 一直为 0,第二行就满足「depth<=0 && 长度>1」提前
 * 返回 —— 抓出来只有两行。命名参数 `{`/`}) async {` 又会让深度从 2 起算,
 * 一路吃到文件尾。所以跨多行签名的函数一律用本函数按「下一个函数定义」切。
 */
function sliceBetween(ls, startNeedle, endNeedle) {
  const s = ls.findIndex((l) => l.includes(startNeedle));
  if (s < 0) return null;
  const e = ls.findIndex((l, i) => i > s && l.includes(endNeedle));
  return ls.slice(s, e < 0 ? s + 40 : e);
}

const CLEANUP = "lib/core/services/update_artifacts_cleanup.dart";
const MAIN = "lib/main.dart";
const SHEET = "lib/features/settings/widgets/update_download_sheet.dart";
const PROVIDER = "lib/providers/settings/update_download_provider.dart";

// ---------------------------------------------------------------------------
console.log("R1 启动结算顺序(update_artifacts_cleanup.dart)");
// ---------------------------------------------------------------------------
const cleanupLines = codeLines(CLEANUP);
const cleanupIdx = cleanupLines.findIndex((l) => l.includes("await cleanupInstalledApks("));
const settleIdx = cleanupLines.findIndex((l) => l.includes("ApkDownloadService().settlePendingDownload("));
check("R1a cleanupInstalledApks 与 settlePendingDownload 两次调用都在",
  cleanupIdx >= 0 && settleIdx >= 0,
  "结算函数被改名/删除,启动结算链路断了");
check("R1b 先清已装成功的包,再结算 pending 下载(顺序硬约束)",
  cleanupIdx >= 0 && settleIdx >= 0 && cleanupIdx < settleIdx,
  `顺序反了会把刚下好、还没写旁车 meta 的新包当孤儿包删掉 (cleanup@${cleanupIdx} settle@${settleIdx})`);

// ---------------------------------------------------------------------------
console.log("R2 启动接线(main.dart)");
// ---------------------------------------------------------------------------
const mainLines = codeLines(MAIN);
check("R2a purgeUpdateArtifacts 在启动阶段被调用",
  mainLines.some((l) => l.includes("purgeUpdateArtifacts(")),
  "启动结算没接线 ⇒ 上次下载到一半的状态永远不被收尾");
check("R2b 结算结果经 restoreFromSettlement 灌进下载控制器",
  mainLines.some((l) => l.includes("restoreFromSettlement(")) &&
    mainLines.some((l) => l.includes("onPendingSettled:")),
  "onPendingSettled → restoreFromSettlement 接线缺失 ⇒ UI 不知道「上次已下好」");

// ---------------------------------------------------------------------------
console.log("R3 浮层卸载语义(update_download_sheet.dart)");
// ---------------------------------------------------------------------------
const sheetLines = codeLines(SHEET);
const dispose = bodyLines(sheetLines, "void dispose()");
check("R3a dispose() 本体存在",
  dispose !== null,
  "找不到 void dispose()");
check("R3b dispose() 只报告视图关闭(setSheetVisible(false)),不 cancel 下载",
  dispose !== null &&
    dispose.some((l) => l.includes("setSheetVisible(false)")) &&
    !dispose.some((l) => l.includes("cancel(")),
  "dispose 里出现 cancel ⇒ 拖掉浮层 = 取消下载 + 删包(5.16.0 前的 bug 回归)");
check("R3c dispose() 经微任务延迟置状态(不在 defunct 元素上同步写)",
  dispose !== null && dispose.some((l) => l.includes("Future<void>.microtask(")),
  "同步写状态会对已 defunct 的元素 markNeedsBuild(debug 断言/订阅泄漏)");

// ---------------------------------------------------------------------------
console.log("R4 completed⇒非空 apkPath 不变式(update_download_provider.dart)");
// ---------------------------------------------------------------------------
const providerLines = codeLines(PROVIDER);
const settle = bodyLines(providerLines, "void restoreFromSettlement(");
check("R4a restoreFromSettlement 本体存在",
  settle !== null,
  "启动结算灌入口被改名 ⇒ R2b 也会跟着红");
check("R4b completed 分支先判 apkPath 非空(hasApk)",
  settle !== null &&
    settle.some((l) => l.includes("apkPath != null && apkPath.isNotEmpty")),
  "apkPath 判空缺失 ⇒ 空路径进 completed,点安装必然失败");
check("R4c 空路径回落 idle",
  settle !== null && settle.some((l) => l.includes("if (!hasApk) {")),
  "缺回落分支 ⇒ UI 显示「已下载完成」但无包可装");

// ---------------------------------------------------------------------------
console.log("R5 atom 兜底必须补齐资源列表(update_checker.dart)");
// ---------------------------------------------------------------------------
// 历史 bug(v5.17.15 及之前):api.github.com 被匿名限流 → 走 releases.atom
// 兜底,而 atom 只有标题和链接、没有 assets ⇒ Android 内置更新挑不到 apk
// ⇒ 点「下载」直接跳去 GitHub 发布页。补在数据源,不要在消费点各打一次补丁。
const CHECKER = "lib/core/services/update_checker.dart";
const INSTALLER = "lib/core/services/app_update_installer.dart";
const SETTINGS = "lib/features/settings/pages/app_settings_page.dart";

const checkerLines = codeLines(CHECKER);
check("R5a expanded_assets 接口常量存在",
  checkerLines.some((l) => l.includes("releases/expanded_assets")),
  "补资源的入口没了 ⇒ atom 兜底又会退化成「assets 为空」");
const atomBody = sliceBetween(
  checkerLines,
  "Future<UpdateCheckResult> _checkViaAtom(",
  "static String _tagFromReleaseUrl(",
);
check("R5b _checkViaAtom 抓取资源并填进结果",
  atomBody !== null &&
    atomBody.some((l) => l.includes("_fetchExpandedAssets(")) &&
    atomBody.some((l) => l.includes("assets: assets")),
  "atom 兜底没补 assets ⇒ 安卓端没直链可下");
check("R5c parseExpandedAssets 从 releases/download 链接解析",
  checkerLines.some((l) => l.includes("parseExpandedAssets(String html)")) &&
    checkerLines.some((l) => l.includes("releases/download")),
  "解析函数被删/改名 ⇒ R5b 拿不到东西");
const fetchBody = bodyLines(checkerLines, "Future<List<ReleaseAsset>> _fetchExpandedAssets(");
check("R5d 补资源失败只回空列表,不把整次检查判死",
  fetchBody !== null &&
    fetchBody.some((l) => l.includes("catch (e)")) &&
    fetchBody.some((l) => l.includes("return const <ReleaseAsset>[]")),
  "这里抛出去会让设置页谎报「检查更新失败」—— 检查本身其实成功了");

// ---------------------------------------------------------------------------
console.log("R6 Android 绝不回退到打开浏览器(app_update_installer / app_settings_page)");
// ---------------------------------------------------------------------------
// 同一个 bug 的另一半:挑不到 apk 时旧代码 `_openInBrowser(browserUrl)`,
// 安卓上那个 URL 只能是 GitHub 发布页 —— 用户还在 App 里点下载,却被切到浏览器。
const installerLines = codeLines(INSTALLER);
const installBody = sliceBetween(
  installerLines,
  "static Future<void> install(",
  "static Future<void> schedulePostInstallRecheck(",
);
check("R6a 挑不到安装包时给出提示",
  installBody !== null &&
    installBody.some((l) => l.includes("settings_update_no_package")),
  "静默 return 会让用户以为点空了");
check("R6b 不再有「回落浏览器」分支",
  installBody !== null &&
    !installBody.some((l) => l.includes("no apk asset, falling back to browser")),
  "旧兜底文案还在 ⇒ 安卓又会蹦到 GitHub");
check("R6c _openInBrowser 只剩非 Android 那一处",
  installBody !== null &&
    installBody.filter((l) => l.includes("_openInBrowser(")).length === 1,
  "多出来的调用就是把安卓也送去浏览器");
const settingsLines = codeLines(SETTINGS);
const canBuiltIn = sliceBetween(
  settingsLines,
  "bool _canInstallBuiltIn(",
  "Future<void> _startBuiltInUpdate(",
);
check("R6d asset 为空也走内置更新(不再落到 releaseUrl 分支)",
  canBuiltIn !== null &&
    canBuiltIn.some((l) => l.includes("if (asset == null) return true")),
  "返回 false 就落到下面那条 `result.releaseUrl` ⇒ 打开系统浏览器");

// ---------------------------------------------------------------------------
if (failures.length > 0) {
  console.error(`\n✗ check-update-settle: ${failures.length}/${checks} 项不通过:`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`\n✓ check-update-settle: ${checks} 项全部通过`);
