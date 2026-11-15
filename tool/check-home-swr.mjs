#!/usr/bin/env node
/**
 * 首页 SWR 缓存守卫（**阻塞**）——「凡是客户端首页可以显示的内容模块都必须要有
 * SWR 缓存」。
 *
 * 背景（2026-11，用户报「首屏先白一下再出内容」）：
 *   首页有 6~12 个内容区块，每个区块都是一次远程请求。不做 SWR 时首帧必然是
 *   骨架屏，网络稍慢就白成一片。SWR（cacheFirst）让「有缓存就当帧秒出、后台再
 *   拉新值」，是首屏观感的第一道地基。
 *
 * 为什么必须钉死在 CI（而不是靠 code review）：
 *   漏补 SWR **编译得过、功能也「对」** —— 只是白一帧。没有任何单测会红
 *   （断言「首帧 fetchCallCount == 0」的用例只覆盖已接上 SWR 的 provider，
 *   新加区块根本没人写用例）。唯一拦得住的是源码级静态断言 + 反向穷举扫描。
 *
 * 规则（先剥注释，再在**指定函数体**内判定 —— 全文件 grep 会被注释里的
 * 「批 D 之前这里是手写 try/catch」这类说明文字误伤）：
 *   R1 清单地基在位：每个 SWR 区块的 provider 定义存在、缓存 kind 常量存在
 *   R2 **反向穷举扫描**：扫 lib/features/discover/ 下所有
 *      `ref.watch(xxxProvider)` / `ref.read(xxxProvider...)`，凡是**异步
 *      provider（FutureProvider / AsyncNotifierProvider，即可能产出远程数据
 *      的那种）**必须在「SWR 清单」/「本地异步」/「豁免白名单」三者之一里，
 *      否则红 —— 这条是「以后新加首页区块忘补 SWR 会自动变红」的实现
 *   R3 SWR 接线四件套：每个 SWR provider 的函数体内必须有
 *      `fetchWithCacheFallback(` + `cacheFirst: true` + `cacheWrite:` +
 *      `cacheRead:`（缺任一条 = 有缓存路径但根本没接上，或反之）
 *   R4 豁免白名单合规：每条必须带**理由字符串**，且总数 ≤ 6
 *      （白名单是会腐烂的口子，超过 6 条说明大家在把规则当摆设）
 *   R5 缓存分支必须补拉新值：`fetchWithCacheFallback` 体内 cacheFirst 分支
 *      必须调度 `_scheduleBackgroundRefresh`（否则「秒出的是永久旧值」）
 *   R6 闸仍在两条路径上：`fetchWithCacheFallback` 与 `_scheduleBackgroundRefresh`
 *      体内都必须有 `gate.wait(`，且 `kConnectionGateBudget` ≤ 10s
 *   R7 反向探针自校验：grep 必然不存在的符号，命中数必须为 0 —— 证明本守卫
 *      不是恒绿（恒绿等于没守），此条失败同样阻断
 *
 * 用法：node tool/check-home-swr.mjs   （退出码非 0 即阻断）
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const FETCH_REL = "lib/providers/api/fetch_with_cache_fallback.dart";
const GATE_REL = "lib/providers/api/connection_gate.dart";
const CACHE_REPO_REL = "lib/data/repositories/recommend_cache_repository.dart";
const RECOMMEND_REL = "lib/providers/library/recommend_provider.dart";
const PLAYLIST_REL = "lib/providers/library/playlist_provider.dart";
const MUSIC_REL = "lib/providers/api/music_provider.dart";
const DISCOVER_DIR = "lib/features/discover";

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

/** 取 `final xxxProvider = ...(...) {` 这类声明对应的函数体（按深度配对）。 */
function bodyOfDeclaration(text, signature) {
  const i = text.indexOf(signature);
  if (i < 0) return "";
  return braceBodyFrom(text, text.indexOf("{", i));
}

/**
 * 同上，但**先跳过参数列表再取函数体**。
 *
 * 必须这么做的理由：`Future<T> fetchWithCacheFallback<T>({...})` 的第一个
 * `{` 属于**命名可选参数列表**而不是函数体 —— 直接取会拿到 `{ ... }` 那段参数
 * 声明，于是「体内有没有 gate.wait」永远判成 0（守卫假红）。
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

/** 递归收集目录下的 .dart（跳过生成代码）。 */
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
  const re =
    /Duration\s*\(\s*(microseconds|milliseconds|seconds|minutes|hours)\s*:\s*(\d+)\s*\)/g;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    out.push({ raw: m[0], ms: Number(m[2]) * UNIT_MS[m[1]] });
  }
  return out;
}

// ─────────────────────────────────────────────────────────────
// 首页 SWR 显式清单：区块 key → provider → 缓存 kind → 落盘/读盘方法
// ─────────────────────────────────────────────────────────────
// 这份清单是「首页每一个能显示内容的数据源头」的**唯一名录**。
// 加新首页区块 ⇒ 必须在这里登记，否则 R2 会红。
const HOME_SWR = [
  {
    block: "固定推荐卡 / 为你推荐",
    provider: "homeRecommendSectionProvider",
    rel: RECOMMEND_REL,
    kind: "kindHomeRecommendSection",
    kindValue: "homeRecommendSection",
    wiring: ["saveHomeRecommendSection", "getHomeRecommendSection"],
  },
  {
    block: "首页推荐卡（旧版）",
    provider: "homeCardsProvider",
    rel: RECOMMEND_REL,
    kind: "kindHomeCards",
    kindValue: "home_cards",
    wiring: ["saveHomeCards", "getHomeCards"],
  },
  {
    block: "平台推荐频道（网易云/QQ…）",
    provider: "recommendChannelsProvider",
    rel: RECOMMEND_REL,
    kind: "kindRecommend",
    kindValue: "recommend",
    wiring: ["saveRecommendResult", "getRecommendResult"],
  },
  {
    block: "本地推荐歌单（按平台）",
    provider: "localRecommendChannelsProvider",
    rel: RECOMMEND_REL,
    kind: "kindLocalRecommend",
    kindValue: "local_recommend",
    wiring: ["saveLocalRecommendChannels", "getLocalRecommendChannels"],
  },
  {
    block: "首页分区清单",
    provider: "homeSectionsProvider",
    rel: RECOMMEND_REL,
    kind: "kindHomeSections",
    kindValue: "homeSections",
    wiring: ["saveHomeSections", "getHomeSections"],
  },
  {
    block: "首页歌单数（每日推荐 / 今日漫游）",
    provider: "homePlaylistCountProvider",
    rel: RECOMMEND_REL,
    kind: "kindHomePlaylistCount",
    kindValue: "homePlaylistCount",
    wiring: ["saveHomePlaylistCount", "getHomePlaylistCount"],
  },
  {
    block: "最近更新的歌单",
    provider: "recentPlaylistsProvider",
    rel: PLAYLIST_REL,
    kind: null,
    kindValue: null,
    wiring: null,
  },
  {
    block: "随机歌曲（今日漫游）",
    provider: "randomSongsProvider",
    rel: MUSIC_REL,
    kind: null,
    kindValue: null,
    wiring: null,
  },
];

// ─────────────────────────────────────────────────────────────
// 本地异步：是 FutureProvider，但数据源是**本地库 / 本地设置**，
// 根本不存在「网络请求」这件事，SWR 无从谈起。
// ─────────────────────────────────────────────────────────────
const LOCAL_ASYNC = [
  {
    provider: "homeSectionLayoutProvider",
    reason: "读本地 drift/prefs 的首页分区布局，零远程请求",
  },
  {
    provider: "navOrderProvider",
    reason: "读本地保存的导航顺序，零远程请求",
  },
  {
    provider: "searchHistoryProvider",
    reason: "本地搜索历史（StateNotifier + 本地存储）",
  },
  {
    provider: "localSongSearchProvider",
    reason: "本地库歌曲搜索（查 drift，不是远程搜索接口）",
  },
  {
    provider: "localAlbumSearchProvider",
    reason: "本地库专辑搜索（查 drift）",
  },
  {
    provider: "localArtistSearchProvider",
    reason: "本地库艺术家搜索（查 drift）",
  },
  {
    provider: "localPlaylistSearchProvider",
    reason: "本地库歌单搜索（查 drift）",
  },
];

// ─────────────────────────────────────────────────────────────
// 豁免白名单：**远程**数据，但刻意不做 SWR。每条必须写清为什么。
// 总数硬限 6 条（R4）—— 白名单是口子，口子一多规则就等于没有。
// ─────────────────────────────────────────────────────────────
const EXEMPT = [
  {
    provider: "remoteControlPeersProvider",
    reason:
      "「谁在线」不能缓存：把 30 秒前的设备列表当帧秒出，会让人直接点到" +
      "已经下线的设备上再报错 —— 这是**错**，不只是旧",
  },
  {
    provider: "playlistsProvider",
    reason:
      "「全部歌单」是发现页的完整长列表（生产上千张），缓存一份只会在切库 / " +
      "增删 / 导入后显示过期条目；该 provider 本身已有 fetchWithCacheFallback " +
      "的失败兜底，只是刻意不做 cacheFirst 秒出",
  },
  {
    provider: "currentLyricsProvider",
    reason:
      "歌词跟着当前歌曲与播放进度走，不是首页内容模块；缓存歌词没有「首屏秒出」" +
      "收益，只有串歌风险",
  },
  {
    provider: "hotSearchTermsProvider",
    reason:
      "热搜词是搜索页的辅助内容（不是首页首屏区块），且带 autoDispose 只在搜索页" +
      "存活，缓存收益接近 0",
  },
  {
    provider: "searchResultsProvider",
    reason:
      "搜索结果跟着用户输入的 query 走（family key 就是请求体），每次输入都是新" +
      "请求，缓存命中率极低且会显示与输入不匹配的结果",
  },
];

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

// 预读所有 lib/ 下的 dart（用于「provider 定义在哪、是不是异步 provider」）。
const libDir = join(root, "lib");
const libFiles = existsSync(libDir) ? dartFiles(libDir) : [];
const libCodeCache = new Map();
function libCodeOf(file) {
  if (!libCodeCache.has(file)) {
    libCodeCache.set(file, stripComments(readFileSync(file, "utf8")));
  }
  return libCodeCache.get(file);
}

/**
 * 找 provider 定义：返回 { rel, async } 或 null。
 * async = 定义里出现 FutureProvider / AsyncNotifierProvider
 *（只有这两种才可能「远程取数」；StateProvider / Provider / StateNotifier 是
 * 同步状态，不在本守卫范围内）。
 */
function findProviderDefinition(name) {
  const re = new RegExp(`^final\\s+${name}\\s*=`, "m");
  for (const file of libFiles) {
    const txt = libCodeOf(file);
    const m = re.exec(txt);
    if (!m) continue;
    // 只看「=」到构造器「(」之间那段类型表达式。
    // 直接切固定长度是错的：`final xLoadFailedProvider = StateProvider<bool>(...)`
    // 后面紧跟着就是下一个 provider（可能是 FutureProvider），固定长度会把
    // 邻居的类型吞进来 → 把 StateProvider 误判成异步。
    const rest = txt.slice(m.index + m[0].length);
    const paren = rest.indexOf("(");
    const decl = paren < 0 ? rest.slice(0, 200) : rest.slice(0, paren);
    return {
      rel: relative(root, file).split("\\").join("/"),
      decl: decl.trim().slice(0, 80),
      async: /FutureProvider|AsyncNotifierProvider/.test(decl),
    };
  }
  return null;
}

const fetchCode = codeOf(FETCH_REL) ?? "";
const gateCode = codeOf(GATE_REL) ?? "";
const cacheRepoCode = codeOf(CACHE_REPO_REL) ?? "";

// ─────────────────────────────────────────────────────────────
// R1 清单地基在位（provider 定义 + 缓存 kind 常量）
// ─────────────────────────────────────────────────────────────
for (const entry of HOME_SWR) {
  const code = codeOf(entry.rel);
  const declRe = new RegExp(`^final\\s+${entry.provider}\\s*=`, "m");
  const found = code !== null && declRe.test(code);
  record(
    `R1 清单地基在位:${entry.block} → ${entry.provider}`,
    "区块的 provider 被删/改名 ⇒ 守卫失去锚点，且首页这个区块确实没了内容来源",
    found,
    `在 ${entry.rel} 找到 final ${entry.provider} =`,
    code === null ? `${entry.rel} 不存在` : found ? "找到" : "未找到声明",
  );

  if (entry.kind === null) continue;
  const kindOk =
    cacheRepoCode.includes(`static const String ${entry.kind} =`) &&
    cacheRepoCode.includes(`'${entry.kindValue}'`);
  record(
    `R1 清单地基在位:${entry.block} → ${entry.kind} = '${entry.kindValue}'`,
    "缓存 kind 是落盘 scope 的前缀（`<kind>:<libraryId>`），被删/改值会让新缓存" +
      "写到一个读不到的地方 —— 表现为「有网却永远白一下」",
    kindOk,
    `${CACHE_REPO_REL} 有 ${entry.kind} = '${entry.kindValue}'`,
    kindOk ? "找到" : "未找到",
  );
}

// ─────────────────────────────────────────────────────────────
// R2 反向穷举扫描（新加首页区块忘补 SWR 自动变红）
// ─────────────────────────────────────────────────────────────
{
  const discoverDir = join(root, DISCOVER_DIR);
  const files = existsSync(discoverDir) ? dartFiles(discoverDir) : [];
  if (files.length === 0) {
    record(
      "R2 反向穷举扫描:lib/features/discover 存在",
      "扫描根目录不见了 ⇒ 守卫会「扫 0 个文件 ⇒ 全绿」，那是恒绿的假守卫",
      false,
      "目录存在且至少 1 个 .dart",
      "目录不存在或为空",
    );
  } else {
    const REF_RE =
      /ref\s*\.\s*(?:watch|read)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*Provider)\b/g;
    const referenced = new Map(); // name -> 第一个引用处
    for (const file of files) {
      const txt = libCodeOf(file);
      let m;
      REF_RE.lastIndex = 0;
      while ((m = REF_RE.exec(txt)) !== null) {
        const name = m[1];
        if (!referenced.has(name)) {
          referenced.set(name, relative(root, file).split("\\").join("/"));
        }
      }
    }

    const swrNames = new Set(HOME_SWR.map((e) => e.provider));
    const localNames = new Set(LOCAL_ASYNC.map((e) => e.provider));
    const exemptNames = new Map(EXEMPT.map((e) => [e.provider, e.reason]));

    const unknown = [];
    const missingReason = [];
    let asyncCount = 0;
    for (const [name, where] of referenced) {
      const def = findProviderDefinition(name);
      // 找不到定义：不是 provider（可能是局部名字），不计。
      if (def === null) continue;
      // 同步 provider（StateProvider / Provider / StateNotifier…）不产出远程数据。
      if (!def.async) continue;
      asyncCount += 1;
      if (swrNames.has(name) || localNames.has(name)) continue;
      if (exemptNames.has(name)) {
        if (!exemptNames.get(name) || exemptNames.get(name).trim().length < 8) {
          missingReason.push(name);
        }
        continue;
      }
      unknown.push(`${name}（${def.rel}，首次引用于 ${where}）`);
    }

    record(
      "R2a 反向穷举扫描:discover 下的异步 provider 全部有归属",
      "新加一个首页区块、忘了给它接 SWR ⇒ 首帧白一帧且**没有任何单测会红**。" +
        "这条就是那个「以后会忘」的唯一拦截点",
      unknown.length === 0,
      "0 个未归类异步 provider",
      asyncCount === 0
        ? "扫描到 0 个异步 provider（扫描器坏了？）"
        : unknown.length
          ? `未归类 ${unknown.length} 个：${unknown.join(" / ")}`
          : `${asyncCount} 个异步 provider 全部有归属`,
    );

    record(
      "R2b 反向穷举扫描:异步 provider 数量不能为 0",
      "扫到 0 个说明正则/目录被改坏，守卫等于关掉了（恒绿）",
      asyncCount > 0,
      "≥ 1",
      `${asyncCount}`,
    );

    record(
      "R2c 反向穷举扫描:白名单条目必须有理由",
      "没写理由的豁免三个月后没人敢删也没人知道为什么留着",
      missingReason.length === 0,
      "0 个缺理由",
      missingReason.length ? `缺理由：${missingReason.join(" / ")}` : "0 个",
    );
  }
}

// ─────────────────────────────────────────────────────────────
// R3 SWR 接线四件套
// ─────────────────────────────────────────────────────────────
for (const entry of HOME_SWR) {
  const code = codeOf(entry.rel) ?? "";
  const body = bodyOfDeclaration(code, `final ${entry.provider} =`);
  if (body === "") {
    record(
      `R3 SWR 接线:${entry.block} → ${entry.provider} 函数体可定位`,
      "取不到函数体 ⇒ 后续三条断言全部判 0（假红或假绿都不可接受）",
      false,
      `找到 final ${entry.provider} = ... { ... }`,
      "未找到函数体",
    );
    continue;
  }
  const hasCall = /\bfetchWithCacheFallback\b[^;{}]{0,80}?\(/.test(body);
  const hasCacheFirst = /cacheFirst\s*:\s*true/.test(body);
  const hasWrite = /cacheWrite\s*:/.test(body);
  const hasRead = /cacheRead\s*:/.test(body);
  record(
    `R3a SWR 接线:${entry.block} → ${entry.provider} 有 fetchWithCacheFallback + cacheFirst/cacheWrite/cacheRead`,
    "四件套缺任一条都意味着「缓存路径没接上」：缺 cacheFirst = 首帧还是白一下；" +
      "缺 cacheWrite = 永远存不下来；缺 cacheRead = 存了也不读",
    hasCall && hasCacheFirst && hasWrite && hasRead,
    "四者齐全",
    `fetchWithCacheFallback=${hasCall ? "有" : "无"} / ` +
      `cacheFirst:true=${hasCacheFirst ? "有" : "无"} / ` +
      `cacheWrite=${hasWrite ? "有" : "无"} / cacheRead=${hasRead ? "有" : "无"}`,
  );

  if (entry.wiring) {
    const miss = entry.wiring.filter((w) => !body.includes(w));
    record(
      `R3b SWR 接线:${entry.block} → ${entry.provider} 落到 ${entry.kind}`,
      "provider 里 cacheWrite/cacheRead 必须真的调到对应 kind 的落盘/读盘方法，" +
        "否则「写进 A、读的是 B」，SWR 永远是 miss",
      miss.length === 0,
      `体内出现 ${entry.wiring.join(" + ")}`,
      miss.length ? `缺少 ${miss.join(" / ")}` : "齐全",
    );
  }
}

// ─────────────────────────────────────────────────────────────
// R4 豁免白名单合规（条数上限 + 理由非空）
// ─────────────────────────────────────────────────────────────
record(
  "R4a 豁免白名单:条数 ≤ 6",
  "白名单是规则的口子；口子一多，「首页必须有 SWR」就等于没有规则了",
  EXEMPT.length <= 6,
  "≤ 6 条",
  `${EXEMPT.length} 条`,
);
{
  const bad = EXEMPT.filter(
    (e) => typeof e.reason !== "string" || e.reason.trim().length < 8,
  ).map((e) => e.provider);
  record(
    "R4b 豁免白名单:每条都带理由",
    "没理由的豁免没人敢删、也没人知道为什么留着，半年后就是一堆噪声",
    bad.length === 0,
    "0 条缺理由",
    bad.length ? `缺理由：${bad.join(" / ")}` : "0 条",
  );
}
{
  const bad = LOCAL_ASYNC.filter(
    (e) => typeof e.reason !== "string" || e.reason.trim().length < 4,
  ).map((e) => e.provider);
  record(
    "R4c 本地异步清单:每条都带理由",
    "「本地异步」是「不用 SWR」的另一种说法，同样必须写清数据源确实是本地的",
    bad.length === 0 && LOCAL_ASYNC.length > 0,
    "≥1 条且全部带理由",
    bad.length ? `缺理由：${bad.join(" / ")}` : `${LOCAL_ASYNC.length} 条齐全`,
  );
}

// ─────────────────────────────────────────────────────────────
// R5 缓存分支必须补拉新值
// ─────────────────────────────────────────────────────────────
{
  const body = bodyOfAfterParams(
    fetchCode,
    "Future<T> fetchWithCacheFallback<T>({",
  );
  if (body === "") {
    record(
      "R5 cacheFirst 分支必须补拉新值:fetchWithCacheFallback 函数体可定位",
      "取不到函数体 ⇒ 守卫失去锚点（且 SWR 的「后台刷新」这半边彻底失守）",
      false,
      "找到 fetchWithCacheFallback<T>({...}) { ... }",
      "未找到",
    );
  } else {
    const n = countOf(body, "_scheduleBackgroundRefresh\\s*<");
    record(
      "R5 cacheFirst 分支必须补拉新值:fetchWithCacheFallback 体内调度 _scheduleBackgroundRefresh",
      "只吐缓存不补拉 = 用户永远看到第一次缓存到的旧数据（SWR 只剩 S，没有 W）",
      n >= 1,
      "≥ 1 处调度",
      `${n} 处`,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// R6 闸仍在两条路径上（首屏不抢跑），且预算有界
// ─────────────────────────────────────────────────────────────
{
  const fetchBody = bodyOfAfterParams(
    fetchCode,
    "Future<T> fetchWithCacheFallback<T>({",
  );
  const hasGateInFetch = /gate\s*\.\s*wait\s*\(/.test(fetchBody);
  record(
    "R6a 闸仍在:fetchWithCacheFallback 体内 gate.wait()",
    "首屏请求必须等连接就绪（最多 6s）再发出，否则又会抢在连接建立之前 → " +
      "必然失败 → 整屏报错，这是用户报的原始现象",
    hasGateInFetch,
    "体内有 gate.wait(",
    hasGateInFetch ? "有" : "无",
  );

  const bgBody = bodyOfAfterParams(
    fetchCode,
    "void _scheduleBackgroundRefresh<T>({",
  );
  const hasGateInBg =
    bgBody !== "" && /gate\s*\.\s*wait\s*\(/.test(bgBody);
  record(
    "R6b 闸仍在:后台刷新同样过闸",
    "后台刷新抢在连接暖场之前必然失败，白烧一次重试预算还吃令牌桶",
    hasGateInBg,
    "_scheduleBackgroundRefresh 体内有 gate.wait(",
    hasGateInBg ? "有" : "无",
  );

  const at = gateCode.indexOf("kConnectionGateBudget =");
  const decl = at < 0 ? "" : gateCode.slice(Math.max(0, at - 40), at + 120);
  const ds = durationsMs(decl);
  const maxMs = ds.length ? Math.max(...ds.map((d) => d.ms)) : null;
  record(
    "R6c 闸预算有界:kConnectionGateBudget ≤ 10s",
    "预算放宽到十几秒 ⇒ 冷启动每次都要等十几秒才发请求，闸从加速器变成减速器",
    maxMs !== null && maxMs <= 10000,
    "≤ 10000ms",
    maxMs === null ? "未找到常量声明" : `${maxMs}ms`,
  );
}

// ─────────────────────────────────────────────────────────────
// R7 反向探针自校验（守卫必须能变红，否则它只是个装饰）
// ─────────────────────────────────────────────────────────────
{
  const PHANTOMS = [
    "kHomeSwrDisabled",
    "skipHomeSwrCache",
    "kHomeCacheFirstOff",
  ];
  const hits = [];
  for (const file of libFiles) {
    const txt = libCodeOf(file);
    for (const sym of PHANTOMS) {
      const n = countOf(txt, sym);
      if (n > 0) {
        hits.push(`${relative(root, file).split("\\").join("/")} → ${sym} ×${n}`);
      }
    }
  }
  record(
    "R7 反向探针自校验:不存在的符号命中数必须为 0",
    "探针本该恒为 0；一旦命中说明「有人加了绕过 SWR 的开关」或「守卫自己读错了" +
      "文件/正则写坏了」。恒绿 = 没守，故此条红时同样阻断",
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
    ? `\n首页 SWR 守卫:${failed}/${results.length} 条不通过 —— 已阻断。`
    : `\n首页 SWR 守卫:${results.length}/${results.length} 条通过。`,
);
process.exit(failed ? 1 : 0);
