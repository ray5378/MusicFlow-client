#!/usr/bin/env node
/**
 * 流转页「拖拽边缘自动滚动」契约守卫（阻塞）。
 *
 * 背景（2026-10-22，v5.9.0）：播放器多到一屏放不下时，必须能把圆拖到列表
 * 上下边缘让列表自动滚动，否则只能先把列表滚好再拖 —— 那条路在真机上根本
 * 走不通。这套逻辑的失败模式全是**静默**的：不报错、不崩溃，只是「滚不动」
 * 或「落到滚动前的旧目标」。手测极易当成"手抖/网络卡"。
 *
 * 规则（每条都对应一个曾经踩过或极易踩的坑）：
 *   R1 常量口径：热区 44px、速度 140–1100px/s、节拍 16ms —— 与 HA 卡片同一口径；
 *   R2 接线：Draggable.onDragUpdate 必须把**全局坐标**回传给页面（只传 localPosition
 *      会在列表滚动后整体偏移）；
 *   R3 逐帧判定：热区内连续滚、越靠边越快、到 maxScrollExtent 收敛、回收站内不滚；
 *   R4 收尾重判：发生过自动滚动时，松手必须按**指针实际坐标**重判落点（回收站
 *      优先），不能信 DragTarget 缓存下来的旧目标；
 *   R5 旧落点让位：DragTarget 的 onAccept（`_handleDrop` / `_handleDestroy`）在
 *      `_autoScrolled` 时必须早退，否则会与 R4 重复执行（双重流转 / 双重销毁）；
 *   R6 多指隔离：拖拽起手/更新/结束都按 peerId 比对当前会话，后起的手势不得覆盖前一路。
 *
 * 用法：node tool/check-transfer-autoscroll.mjs
 */
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const REL = "lib/features/player/pages/player_transfer_page.dart";
const FILE = join(root, REL);
const TEST_REL = "test/features/player/player_transfer_page_cov_test.dart";
const TEST = join(root, TEST_REL);

/** 注释里的示例代码不能当成实现 —— 先剥掉行注释再判。 */
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

const results = [];
const record = (name, why, ok) => results.push({ name, why, ok });

if (!existsSync(FILE)) {
  record(`R1 实现文件存在:${REL}`, "流转页被删/挪走，自动滚动整体失去落点", false);
} else {
  const raw = readFileSync(FILE, "utf8");
  const src = stripComments(raw);

  // R1 常量口径
  const zone = /const double _kAutoScrollZone = 44;/.test(src);
  const min = /const double _kAutoScrollMinSpeed = 140;/.test(src);
  const max = /const double _kAutoScrollMaxSpeed = 1100;/.test(src);
  const tick = /const int _kAutoScrollTickMs = 16;/.test(src);
  record(
    "R1 常量口径:热区 44px / 速度 140–1100px/s / 节拍 16ms",
    `与 HA 卡片 .tp-scroll 同一口径，任一项改动都会让两端手感不一致。当前 zone=${zone} min=${min} max=${max} tick=${tick}`,
    zone && min && max && tick,
  );

  // R2 接线：全局坐标回传
  record(
    "R2 Draggable.onDragUpdate 回传全局坐标",
    "只回传 localPosition 时，列表滚动后坐标整体偏移 ⇒ 落点全错",
    /onDragUpdate:\s*\(details\)\s*=>\s*onDragUpdate\(details\.globalPosition\)/.test(src) &&
      /_dragGlobalPosition = globalPosition;/.test(src),
  );

  // R3 逐帧判定
  const tickBody = bodyOf(src, "void _autoScrollTick(");
  record(
    "R3 逐帧判定:热区调速 + 边界收敛 + 回收站/无滚动空间不滚",
    "缺任一条都会出现「滚不动」「越滚越飘」「拖到回收站还在滚」",
    tickBody.includes("_kAutoScrollZone") &&
      tickBody.includes("_kAutoScrollMaxSpeed - _kAutoScrollMinSpeed") &&
      /clamp\(0\.0, max\)/.test(tickBody) &&
      tickBody.includes("_pointInKey(_trashKey, pointer)") &&
      /max <= 0/.test(tickBody) &&
      /\n\s*_scroll\.jumpTo\(next\);/.test(tickBody) &&
      /\n\s*_autoScrolled = true;/.test(tickBody),
  );

  // R4 收尾重判
  const finishBody = bodyOf(src, "Future<void> _onDragFinished(");
  record(
    "R4 松手重判:发生过自动滚动时按指针实际坐标重判落点（回收站优先）",
    "相信 DragTarget 旧目标 ⇒ 滚完后落到滚动前的那个端，是 v5.9.0 之前的真实缺陷",
    /didAutoScroll/.test(finishBody) &&
      finishBody.includes("_pointInKey(_trashKey, pointer)") &&
      finishBody.includes("_peerAt(pointer)"),
  );

  // R5 旧落点让位
  const dropBody = bodyOf(src, "Future<void> _handleDrop(");
  const destroyBody = bodyOf(src, "Future<void> _handleDestroy(");
  record(
    "R5 DragTarget 旧落点让位:onAccept 在 _autoScrolled 时早退",
    "不让位 ⇒ 与 R4 重复执行，出现双重流转 / 双重销毁",
    /\n\s*if \(_autoScrolled\) return;/.test(dropBody) &&
      /\n\s*if \(_autoScrolled\) return;/.test(destroyBody),
  );

  // R6 多指隔离
  const startBody = bodyOf(src, "void _onDragStarted(");
  const updateBody = bodyOf(src, "void _onDragUpdate(");
  record(
    "R6 多指隔离:起手/更新/收尾都按当前会话 peerId 早退",
    "后起的手势覆盖先起会话 ⇒ 先松手那一路拿错源去流转",
    /if \(_draggingPeerId != null\) return;/.test(startBody) &&
      /if \(_draggingPeerId != peerId\) return;/.test(updateBody) &&
      /if \(_draggingPeerId != peerId\) return;/.test(finishBody),
  );

  // R8 系统取消
  record(
    "R8 系统取消:全局指针路由留取消标记 + 重判前让位",
    "自动滚动期间被系统取消时，onDragEnd 先到、PointerCancel 后到；" +
      "不识别取消就会按指针下方的圆误流转（v5.9.1 实锤缺陷）",
    src.includes("addGlobalRoute(_onGlobalPointerEvent)") &&
      src.includes("removeGlobalRoute(_onGlobalPointerEvent)") &&
      /void _onGlobalPointerEvent\(PointerEvent event\)/.test(src) &&
      /event is PointerCancelEvent/.test(src) &&
      // 取消事件到达时会话已被 onDragEnd 清空，必须靠「微任务窗口」标记认领。
      /_dragFinishing/.test(src) &&
      /_dragFinishing = true;/.test(finishBody) &&
      /_dragFinishing = false;/.test(finishBody) &&
      /await Future<void>\.microtask/.test(finishBody) &&
      /_dragCanceled/.test(finishBody) &&
      /_dragCanceled = false;/.test(startBody),
  );
}

// R7 行为用例必须存在：静态检查挡不住「调用点还在、行为坏了」。
if (!existsSync(TEST)) {
  record(`R7 行为用例存在:${TEST_REL}`, "缺少行为锁，静态守卫无法覆盖时序问题", false);
} else {
  const t = readFileSync(TEST, "utf8");
  const cases = [
    "拖到顶部热区",
    "离开热区立即停止滚动",
    "拖到底部热区",
    "拖到回收站",
    "没有滚动空间",
    "按指针实际坐标重判落点",
    "多指同时拖两个圆",
    "自动滚动后松手落在回收站",
    "拖拽被系统取消",
    "onDraggableCanceled 直达",
    "open(): 经根导航器弹出全屏流转页",
  ];
  const missing = cases.filter((c) => !t.includes(c));
  record(
    "R7 行为用例齐全(11 条)",
    `缺用例 ⇒ 回归无感。缺失:${missing.join(" / ")}`,
    missing.length === 0,
  );
}

let failed = 0;
for (const r of results) {
  if (!r.ok) failed++;
  console.log(`[${r.ok ? "PASS" : "FAIL"}] ${r.name}`);
  if (!r.ok && r.why) console.log(`       why: ${r.why}`);
}
console.log(
  failed
    ? `\n流转页自动滚动守卫:${failed}/${results.length} 条不通过。`
    : `\n流转页自动滚动守卫:${results.length}/${results.length} 条通过。`,
);
process.exit(failed ? 1 : 0);
