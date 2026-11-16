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
function bodyLines(ls, signatureNeedle) {
  const start = ls.findIndex((l) => l.includes(signatureNeedle));
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
if (failures.length > 0) {
  console.error(`\n✗ check-update-settle: ${failures.length}/${checks} 项不通过:`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`\n✓ check-update-settle: ${checks} 项全部通过`);
