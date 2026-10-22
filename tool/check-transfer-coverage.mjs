#!/usr/bin/env node
/**
 * 流转页**行覆盖率门禁**（阻塞）。
 *
 * 背景（2026-10-22）：流转页的自动滚动/取消收尾全是「时序 + 坐标」逻辑，
 * 静态守卫（check-transfer-autoscroll.mjs）只能钉住结构，钉不住「分支到底跑没跑」。
 * 这里读 `flutter test --coverage` 产出的 lcov，对本文件设行覆盖下限：
 *   · 低于阈值 → 非零退出，CI 标红；
 *   · lcov 里找不到本文件 → 也视为失败（说明测试没跑、--coverage 没开或文件被挪走）。
 *
 * 为什么只盯这一个文件：行为锁只跑流转页的两个测试文件，覆盖率数据里本文件是
 * 主角；全仓覆盖率会被大量未测模块稀释，起不到门禁作用。
 *
 * 用法：node tool/check-transfer-coverage.mjs [--min=97]
 */
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const LCOV = join(root, "coverage/lcov.info");
const TARGET = "lib/features/player/pages/player_transfer_page.dart";

const argMin = process.argv.find((a) => a.startsWith("--min="));
const MIN = argMin ? Number(argMin.slice(6)) : 97;

if (!existsSync(LCOV)) {
  console.error(`[FAIL] 找不到 ${LCOV}\n       先跑 flutter test --coverage 再执行本门禁。`);
  process.exit(1);
}

let cur = null;
let total = 0;
let hit = 0;
for (const line of readFileSync(LCOV, "utf8").split("\n")) {
  if (line.startsWith("SF:")) {
    cur = line.slice(3).trim().replace(/\\/g, "/");
    continue;
  }
  if (!cur || !cur.endsWith(TARGET)) continue;
  if (!line.startsWith("DA:")) continue;
  total++;
  const count = Number(line.slice(3).split(",")[1]);
  if (count > 0) hit++;
}

if (total === 0) {
  console.error(`[FAIL] lcov 里没有 ${TARGET} 的 DA 记录 —— 测试未跑 / --coverage 未开 / 文件被挪走`);
  process.exit(1);
}

const pct = (hit * 100) / total;
const ok = pct >= MIN;
console.log(
  `[${ok ? "PASS" : "FAIL"}] ${TARGET} 行覆盖 ${hit}/${total} = ${pct.toFixed(2)}%（阈值 ${MIN}%）`,
);
process.exit(ok ? 0 : 1);
