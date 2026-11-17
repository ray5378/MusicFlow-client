#!/usr/bin/env node
/**
 * 通知栏回归守卫（**阻塞**）—— 整个安卓媒体通知链路：图标 / 按钮排布 / 收藏双通道 /
 * 歌词落点 / 后台时钟 / 版本分叉。
 *
 * 背景（2026-11，v5.17.2 → v5.17.13 连续踩坑）：
 *   1. 歌词写 displayDescription，Android 11+ 零消费方 → 通知栏静默无歌词；
 *   2. 收藏只发 custom action，Android 10~12 的通知根本不带自定义按钮 → 永远不显示；
 *   3. 为了让它出现把「上一首」删了，老用户少了键；
 *   4. 心形线比参考 App 粗 4 倍，两次调小 strokeWidth 都没用 —— 真正原因是空心图标
 *      用了 Material 官方**带内孔**的路径，stroke 把内外轮廓各描一遍。
 *
 * 这四条的共同点：**编译得过、单测全绿、真机上不对**。纯函数测试锁不住「接错地方」
 * 与「资源本身错了」，所以必须再加一层源码级静态断言，把这些结论钉死在 CI 上。
 *
 * 规则（先剥注释再判定 —— 本文件的注释里大量出现被禁写法，全文件 grep 会自伤）：
 *   R1  图标资源在位：两个 drawable 存在且是 vector
 *   R2  空心图标是**单轮廓**：不含内孔子路径（`zM`），两条 pathData 完全相同
 *   R3  空心双色分层：白色在下层先画、深色在上层后画（浅色卡片只看到细黑线）
 *   R4  线宽锁：空心 1.6 / 1.3，实心 1.0；历史粗值 2.6 / 2.0 不许回来
 *   R5  双通道下发：notificationControls 两条通路都带 favoriteBridge
 *   R6  上一首取舍：旧通路（API<33）保留 skipToPrevious，新通路必须不发
 *   R7  折叠索引配套：旧通路 [1,2,3]，新通路 [0,1,2]
 *   R8  折叠索引唯一来源：lib/ 内不许再出现硬编码 `androidCompactActionIndices: const`
 *   R9  两条点击通道同一落点：customAction 与 fastForward 都转到 _toggleFavoriteFromNotification
 *   R10 两行布局主标题合并歌手：applyNotificationLyric 调用 notificationTitleFor
 *   R11 无歌词留空：写入 kNotificationEmptyLyric，不回落歌手
 *   R12 三行布局歌词进第三行：applyNotificationLyric 里出现 displayDescription
 *   R13 歌词从底稿派生：updateNotificationLyric 以 _baseMediaItem 为准
 *   R14 切歌清空：updateMediaItem 调用 resolvePreservedLyric
 *   R15 后台自持时钟：控制器有 300ms Timer.periodic + listen currentLyricsProvider + 锚点外推
 *   R16 版本分叉阈值：30（三行）/ 33（槽位通路），且都要求 sdkInt > 0
 *   R17 反向探针：读一批必然不存在的符号，命中数必须为 0（证明本守卫不是恒绿）
 *
 * 用法：node tool/check-notification-guard.mjs   （退出码非 0 即阻断）
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

const PATHS = {
  heartFull: "android/app/src/main/res/drawable/ic_notif_favorite.xml",
  heartBorder: "android/app/src/main/res/drawable/ic_notif_favorite_border.xml",
  handler: "lib/core/services/audio_handler_service.dart",
  platform: "lib/core/services/android_platform_info.dart",
  lyricsProvider: "lib/providers/media/notification_lyrics_provider.dart",
};

const results = [];
function report(name, ok, expected, actual, why) {
  results.push({ name, ok, expected, actual, why });
}
function assertEq(name, actual, expected, why) {
  report(name, JSON.stringify(actual) === JSON.stringify(expected), expected, actual, why);
}
function assertTrue(name, cond, expected, actual, why) {
  report(name, !!cond, expected, actual, why);
}
function assertContains(name, haystack, needle, why) {
  report(name, haystack.includes(needle), `包含 \`${needle}\``, haystack.includes(needle) ? "包含" : "缺失", why);
}
function assertAbsent(name, haystack, needle, why) {
  report(name, !haystack.includes(needle), `不含 \`${needle}\``, haystack.includes(needle) ? "仍然存在" : "不含", why);
}

function readText(rel) {
  const abs = join(ROOT, rel);
  if (!existsSync(abs)) return null;
  return readFileSync(abs, "utf8");
}

// ── 注释剥离 ────────────────────────────────────────────────
function stripDartComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((line) => {
      const idx = line.indexOf("//");
      if (idx < 0) return line;
      if (line.slice(0, idx).includes("://")) return line; // URL 别误伤
      return line.slice(0, idx);
    })
    .join("\n");
}
function stripXmlComments(src) {
  return src.replace(/<!--[\s\S]*?-->/g, "");
}

// ── 取函数体（跳过参数表里的花括号；支持 `=> expr;` 箭头函数）──
// 注意：不能直接用 indexOf(name+'(')，同一个文件里调用点往往出现在定义之前
// （updateMediaItem 里就调了 applyNotificationLyric），那样只会拿到一个没有
// 函数体的调用片段，断言全部空转。所以按「返回类型 + 名字」定位定义。
const RETURN_TYPES = [
  "Future<[^>]*>",
  "List<[^>]*>",
  "MediaItem\\??",
  "String\\??",
  "void",
  "Duration",
  "bool",
  "int",
];

function parseBodyAt(src, at, name) {
  let i = at + name.length;
  let depth = 0;
  let quote = null;
  for (; i < src.length; i++) {
    const ch = src[i];
    if (quote) {
      if (ch === quote && src[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") {
      depth--;
      if (depth === 0) {
        i++;
        break;
      }
    }
  }

  let j = i;
  while (j < src.length && /\s/.test(src[j])) j++;

  // 箭头函数：Future<void> fastForward() => _toggleFavoriteFromNotification();
  if (src.startsWith("=>", j)) {
    const semi = src.indexOf(";", j);
    return semi < 0 ? null : src.slice(j, semi + 1);
  }

  // 可能还有 async 之类的前缀
  if (src[j] !== "{") {
    const open = src.indexOf("{", j);
    if (open < 0) return null;
    // 只允许跳过很短的噪声（async / 换行），跨太远说明这不是函数体
    if (open - j > 20) return null;
    j = open;
  }

  let d = 0;
  quote = null;
  for (let p = j; p < src.length; p++) {
    const ch = src[p];
    if (quote) {
      if (ch === quote && src[p - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "{") d++;
    else if (ch === "}") {
      d--;
      if (d === 0) return src.slice(j, p + 1);
    }
  }
  return null;
}

function functionBody(src, name) {
  const patterns = RETURN_TYPES.map(
    (t) => new RegExp(`\\b(?:${t})\\s+${name}\\s*\\(`, "g"),
  );
  patterns.push(new RegExp(`^\\s*${name}\\s*\\(`, "gm"));

  for (const re of patterns) {
    let m;
    while ((m = re.exec(src)) !== null) {
      const at = src.indexOf(name, m.index);
      const body = parseBodyAt(src, at, name);
      if (body !== null) return body;
    }
  }
  return null;
}

function walkDart(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const abs = join(dir, entry);
    if (statSync(abs).isDirectory()) walkDart(abs, out);
    else if (entry.endsWith(".dart")) out.push(abs);
  }
  return out;
}

// ── 读文件 ─────────────────────────────────────────────────
const heartFullRaw = readText(PATHS.heartFull);
const heartBorderRaw = readText(PATHS.heartBorder);
const handlerRaw = readText(PATHS.handler);
const platformRaw = readText(PATHS.platform);
const lyricsProviderRaw = readText(PATHS.lyricsProvider);

for (const [label, raw] of [
  ["实心心形", heartFullRaw],
  ["空心心形", heartBorderRaw],
  ["音频 handler", handlerRaw],
  ["平台信息", platformRaw],
  ["歌词控制器", lyricsProviderRaw],
]) {
  assertTrue(
    `${label}文件可读`,
    raw !== null && raw.length > 100,
    "文件存在且非空",
    raw === null ? "文件不存在" : `${raw.length} 字节`,
    "读不到文件时后面的断言会全部空转，必须单独拦一次",
  );
}
if (!heartFullRaw || !heartBorderRaw || !handlerRaw || !platformRaw || !lyricsProviderRaw) {
  for (const r of results) {
    if (!r.ok) console.log(`[FAIL] ${r.name}\n       期望: ${r.expected}\n       实际: ${r.actual}`);
  }
  console.log("\n通知栏守卫：关键文件缺失，直接阻断。");
  process.exit(1);
}

const heartFull = stripXmlComments(heartFullRaw);
const heartBorder = stripXmlComments(heartBorderRaw);
const handler = stripDartComments(handlerRaw);
const platform = stripDartComments(platformRaw);
const lyricsProvider = stripDartComments(lyricsProviderRaw);

// ── R1 图标资源 ────────────────────────────────────────────
assertTrue(
  "R1 两个心形 drawable 都是 vector",
  heartFull.includes("<vector") && heartBorder.includes("<vector"),
  "两个文件都是 <vector>",
  `${heartFull.includes("<vector") ? "ok" : "no"} / ${heartBorder.includes("<vector") ? "ok" : "no"}`,
  "资源缺失时 SystemUI 只画一个空白方块，不报错不崩溃",
);

// ── R2 单轮廓 ──────────────────────────────────────────────
const borderPaths = [...heartBorder.matchAll(/android:pathData="([^"]+)"/g)].map((m) => m[1]);
assertAbsent(
  "R2a 空心图标不含内孔子路径",
  heartBorder,
  "zM",
  "带内孔的路径 + stroke = 内外各描一遍，视觉厚度 4.6 单位（粗 4 倍），这正是 v5.17.12 收 strokeWidth 无效的原因",
);
assertEq(
  "R2b 空心图标两条 pathData 是同一条外轮廓",
  borderPaths.length === 2 && borderPaths[0] === borderPaths[1] ? "same" : `len=${borderPaths.length}/diff`,
  "same",
  "白层与深色层必须描同一条轮廓，否则双层之间会出现一条错位的缝",
);

// ── R3 双色分层顺序 ────────────────────────────────────────
const borderStrokes = [...heartBorder.matchAll(/android:strokeColor="([^"]+)"/g)].map((m) => m[1]);
assertEq(
  "R3 白色在下层、深色在上层",
  borderStrokes,
  ["#FFFFFFFF", "#FF1A1A1A"],
  "反过来的话白色细线会压在黑线中间，在浅色卡片上形成一条灰缝，看起来比实际更粗",
);

// ── R4 线宽 ────────────────────────────────────────────────
assertTrue(
  "R4a 空心线宽 1.6 / 1.3",
  heartBorder.includes('android:strokeWidth="1.6"') && heartBorder.includes('android:strokeWidth="1.3"'),
  'strokeWidth="1.6" 与 "1.3"',
  [...heartBorder.matchAll(/android:strokeWidth="([^"]+)"/g)].map((m) => m[1]).join(" / "),
  "1.3 单位 ≈ 4px，参考实现实测 3.5px；这两个数是真机比对出来的",
);
assertTrue(
  "R4b 实心线宽 1.0",
  heartFull.includes('android:strokeWidth="1.0"'),
  'strokeWidth="1.0"',
  [...heartFull.matchAll(/android:strokeWidth="([^"]+)"/g)].map((m) => m[1]).join(" / "),
  "实心描边只负责勾轮廓，和空心 1.3 的视觉重量对齐",
);
for (const legacy of ["2.6", "2.0"]) {
  assertAbsent(
    `R4c 历史粗值 ${legacy} 不许回来`,
    heartBorder,
    `android:strokeWidth="${legacy}"`,
    "v5.17.11 / v5.17.12 用过的两个值，真机都判粗",
  );
}

// ── R5 / R6 / R7 按钮排布 ──────────────────────────────────
const controlsBody = functionBody(handler, "notificationControls");
assertTrue(
  "R5 notificationControls 函数体存在",
  controlsBody !== null,
  "能定位到函数体",
  controlsBody === null ? "没找到" : `${controlsBody.length} 字符`,
  "函数被改名/内联后，后面所有排布断言都会空转",
);
if (controlsBody) {
  const returned = controlsBody
    .split("return [")
    .slice(1)
    .map((chunk) => chunk.split("];")[0]);
  assertEq(
    "R5b 两条通路都下发 favoriteBridge",
    returned.map((r) => (r.includes("favoriteBridge") ? "y" : "n")).join(""),
    "yy",
    "老系统只认 nativeActions，没有 bridge 就永远看不到心形（v5.17.9 的真机结论）",
  );
  assertEq(
    "R6 旧路保留上一首、新路不发上一首",
    returned.map((r) => (r.includes("skipToPrevious") ? "prev" : "none")).join("|"),
    "prev|none",
    "新通路里上一首会占掉 A 槽，把 custom 心形挤到展开态",
  );
}

const indicesBody = functionBody(handler, "notificationCompactIndices");
assertTrue(
  "R7 折叠索引 [1,2,3] / [0,1,2]",
  indicesBody !== null &&
    indicesBody.includes("[1, 2, 3]") &&
    indicesBody.includes("[0, 1, 2]"),
  "[1,2,3] 与 [0,1,2]",
  indicesBody === null ? "函数不存在" : indicesBody.replace(/\s+/g, " ").slice(0, 80),
  "折叠态那三格决定用户手里第一个键是什么",
);

// ── R8 折叠索引无硬编码 ────────────────────────────────────
const dartFiles = walkDart(join(ROOT, "lib"));
const hardcoded = dartFiles.filter((f) =>
  stripDartComments(readFileSync(f, "utf8")).includes("androidCompactActionIndices: const"),
);
assertEq(
  "R8 lib/ 内没有硬编码的折叠索引",
  hardcoded.map((f) => relative(ROOT, f)),
  [],
  "硬编码会让两条通路的索引无法分叉（v5.17.11 之前就是 const [0,1,2]）",
);

// ── R9 两条点击通道同一落点 ────────────────────────────────
const customActionBody = functionBody(handler, "customAction");
const fastForwardBody = functionBody(handler, "fastForward");
assertContains(
  "R9a customAction 转到统一 toggle",
  customActionBody ?? "",
  "_toggleFavoriteFromNotification",
  "13+ 的心形走这条路，断了就只有图标没反应",
);
assertContains(
  "R9b fastForward 转到统一 toggle",
  fastForwardBody ?? "",
  "_toggleFavoriteFromNotification",
  "12 及以下的心形借标准快进键出现，点击只能落到这里",
);

// ── R10 ~ R12 歌词落点 ─────────────────────────────────────
const applyBody = functionBody(handler, "applyNotificationLyric");
assertContains(
  "R10 两行布局主标题合并歌手",
  applyBody ?? "",
  "notificationTitleFor(",
  "系统只给两行，歌手必须并进标题，否则歌手名彻底丢失",
);
assertContains(
  "R11 无歌词写空串",
  applyBody ?? "",
  "kNotificationEmptyLyric",
  "回落歌手会被当成「歌词已加载」，切歌空窗期给的是错信息",
);
assertContains(
  "R12 三行布局歌词进第三行",
  applyBody ?? "",
  "displayDescription",
  "API<30 才有 subText；30+ 写这里等于没写（v5.17.2 的根因）",
);

// ── R13 底稿派生 ──────────────────────────────────────────
const updateLyricBody = functionBody(handler, "updateNotificationLyric");
assertContains(
  "R13 歌词从 _baseMediaItem 派生",
  updateLyricBody ?? "",
  "_baseMediaItem",
  "拿上一轮已改写的 MediaItem 当底稿，标题会越接越长、歌手会丢",
);
assertAbsent(
  "R13b 不拿当前 mediaItem 当底稿",
  updateLyricBody ?? "",
  "base: mediaItem",
  "当前项已经是改写过的产物，只能作为 current 参数用来去重，绝不能当输入",
);

// ── R14 切歌清空 ──────────────────────────────────────────
const updateItemBody = functionBody(handler, "updateMediaItem");
assertContains(
  "R14 updateMediaItem 调用 resolvePreservedLyric",
  updateItemBody ?? "",
  "resolvePreservedLyric(",
  "交叉淡入/预加载会重复推同一首歌，没有这层就会把已显示的歌词打回空白",
);

// ── R15 后台时钟 ──────────────────────────────────────────
assertContains(
  "R15a 控制器自持 Timer.periodic",
  lyricsProvider,
  "Timer.periodic",
  "just_audio 的 positionStream 退后台会停摆，靠它才不会卡在某一句",
);
assertContains(
  "R15b 周期是 300ms",
  lyricsProvider,
  "Duration(milliseconds: 300)",
  "太快会空转重建通知，太慢歌词肉眼可见地顿",
);
assertContains(
  "R15c 监听 currentLyricsProvider",
  lyricsProvider,
  "currentLyricsProvider",
  "歌词表到达要立刻推一次，并让 provider 常驻（否则后台切歌拉不到新歌词）",
);
assertContains(
  "R15d 有锚点外推",
  lyricsProvider,
  "_resolvePosition",
  "真实进度停摆时用「锚点 + 经过时间」，这是后台歌词能继续走的唯一依据",
);

// ── R16 版本分叉阈值 ──────────────────────────────────────
assertContains(
  "R16a 三行布局阈值 30",
  platform,
  "kSystemUiMediaNotificationMinApi = 30",
  "Android 11 起 SystemUI 接管卡片，30 是分界线本身",
);
assertContains(
  "R16b 槽位通路阈值 33",
  platform,
  "kPlaybackStateActionSlotsMinApi = 33",
  "Android 13 起按钮槽位由系统固定，这是两条通路的分岔点",
);
assertTrue(
  "R16c 未知版本一律按新布局",
  /useLegacyThreeLineNotification\s*=>\s*[\s\S]{0,60}_sdkInt > 0 && _sdkInt </.test(platform) &&
    /usesNotificationActionSlots\s*=>\s*[\s\S]{0,80}_sdkInt > 0 && _sdkInt </.test(platform),
  "两个判据都要求 _sdkInt > 0（0 = 未知 → 新布局）",
  "判据里缺 `_sdkInt > 0` 时，未知版本会掉进老布局分支",
  "桌面/读取失败时 _sdkInt 是 0，按老布局会把歌词写进没人读的位置",
);

// ── R17 反向探针（本守卫必须能失败）────────────────────────
const probe = "__notificationGuardProbe_absent_symbol__";
const probeHits = dartFiles.filter((f) => readFileSync(f, "utf8").includes(probe)).length;
assertEq(
  "R17 反向探针命中数为 0",
  probeHits,
  0,
  "若这条也「通过」得莫名其妙（读不到文件），说明守卫在空转",
);

// ── 输出 ──────────────────────────────────────────────────
let failed = 0;
for (const r of results) {
  if (!r.ok) failed++;
  console.log(`[${r.ok ? "PASS" : "FAIL"}] ${r.name}`);
  if (!r.ok) {
    console.log(`       ❌ ${r.name}`);
    console.log(`          期望: ${JSON.stringify(r.expected)}`);
    console.log(`          实际: ${JSON.stringify(r.actual)}`);
    if (r.why) console.log(`          为什么钉死它: ${r.why}`);
  }
}
console.log(
  failed
    ? `\n通知栏守卫：${failed}/${results.length} 条不通过 —— 已阻断。`
    : `\n通知栏守卫：${results.length}/${results.length} 条通过。`,
);
process.exit(failed ? 1 : 0);
