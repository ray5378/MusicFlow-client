#!/usr/bin/env node
// Flutter l10n 合规守卫(零依赖,node>=18):
//  1. app_zh.arb 与 app_en.arb 的键集合必须完全一致(缺/多/多余 key 即失败)。
//  2. lib/ 下(l10n/ 除外)不得有硬编码 CJK;默认只上报,加 --gate-cjk 才判失败
//     (供全量迁移完成后启用,避免基建期阻断)。
//  3. providers/ 内禁止 AppLocalizations.of(context)(必须走 l10nNow)。
// 运行: node tool/check-l10n.mjs [--gate-cjk]
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ARB_DIR = join(ROOT, 'lib', 'l10n');
const LIB_DIR = join(ROOT, 'lib');
const GATE_CJK = process.argv.includes('--gate-cjk');
const CJK = /[\u3400-\u9fff\u3040-\u30ff]/;

let failures = 0;
let cjkHits = 0;
const fail = (msg) => { failures++; console.error(`[l10n] FAIL: ${msg}`); };

// ---------- 1. ARB 键对齐 ----------
function readJson(p) { return JSON.parse(readFileSync(p, 'utf8')); }
function messageKeys(obj) {
  return Object.keys(obj).filter((k) => !k.startsWith('@')).sort();
}
(function checkKeyParity() {
  const zh = messageKeys(readJson(join(ARB_DIR, 'app_zh.arb')));
  const en = messageKeys(readJson(join(ARB_DIR, 'app_en.arb')));
  const zhSet = new Set(zh); const enSet = new Set(en);
  const missingEn = zh.filter((k) => !enSet.has(k));
  const missingZh = en.filter((k) => !zhSet.has(k));
  const extraEn = en.filter((k) => !zhSet.has(k));
  if (missingEn.length) fail(`app_en.arb 缺键: ${missingEn.join(', ')}`);
  if (missingZh.length) fail(`app_zh.arb 缺键(从 en 多出): ${missingZh.join(', ')}`);
  if (extraEn.length) fail(`app_en.arb 存在 zh 没有的键: ${extraEn.join(', ')}`);
  if (!failures) console.log(`[l10n] ARB keys ok (${zh.length} shared)`);
})();

// ---------- 2. 硬编码 CJK 扫描(剔除注释与不含 CJK 的字面量) ----------
const EXCLUDE_DIRS = new Set(['l10n']);
function stripCommentsAndStrings(src) {
  let s = src.replace(/\/\*[\s\S]*?\*\//g, '');
  s = s
    .split('\n')
    .map((line) => {
      let idx = line.indexOf('//');
      while (idx !== -1) {
        if (line[idx - 1] !== ':') return line.slice(0, idx);
        idx = line.indexOf('//', idx + 2);
      }
      return line;
    })
    .join('\n');
  // 去掉不含 CJK 的 Dart 字符串字面量(单/双引号、r''、``` )，保留含 CJK 的。
  s = s
    .split('\n')
    .map((line) => {
      if (!CJK.test(line)) return line;
      let out = '';
      let i = 0;
      const n = line.length;
      while (i < n) {
        const ch = line[i];
        if (ch === '"' || ch === "'" || ch === '`') {
          const quote = ch;
          if (quote === '`') {
            out += line; break;
          }
          let j = i + 1;
          while (j < n) {
            if (line[j] === '\\') { j += 2; continue; }
            if (line[j] === quote) { j++; break; }
            j++;
          }
          const literal = line.slice(i, j);
          if (!CJK.test(literal)) { i = j; continue; }
          out += literal; i = j; continue;
        }
        out += ch; i++;
      }
      return out;
    })
    .join('\n');
  return s;
}
function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    if (EXCLUDE_DIRS.has(name)) continue;
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) out.push(...walk(full));
    else if (extname(name) === '.dart') out.push(full);
  }
  return out;
}
(function scanHardcodedCjk() {
  for (const f of walk(LIB_DIR)) {
    const body = stripCommentsAndStrings(readFileSync(f, 'utf8'));
    body.split('\n').forEach((line, i) => {
      if (CJK.test(line)) {
        cjkHits++;
        console.error(`[l10n] ${f.replace(ROOT, '')}:${i + 1}  硬编码中文 → ${line.trim().slice(0, 80)}`);
      }
    });
  }
  if (cjkHits) {
    if (GATE_CJK) fail(`${cjkHits} 处硬编码中文未走翻译(--gate-cjk 生效,见上方行号)`);
    else console.error(`[l10n] WARN: 发现 ${cjkHits} 处硬编码中文(未启用 --gate-cjk,仅上报)`);
  } else {
    console.log('[l10n] no hardcoded CJK outside comments');
  }
})();

// ---------- 3. providers 禁用 AppLocalizations.of(context) ----------
const PROV_DIR = join(ROOT, 'lib', 'providers');
(function checkProvidersRule() {
  const re = /AppLocalizations\s*\.\s*of\s*\(/;
  let bad = 0;
  for (const f of walk(PROV_DIR)) {
    const raw = readFileSync(f, 'utf8');
    if (re.test(raw)) {
      bad++;
      console.error(`[l10n] ${f.replace(ROOT, '')}  用了 AppLocalizations.of(context)，providers 应改用 l10nNow`);
    }
  }
  if (bad) fail(`${bad} 处 providers 误用 AppLocalizations.of(context)`);
  else console.log('[l10n] providers 均符合 l10nNow 规范');
})();

if (failures > 0) {
  console.error(`\n[l10n] ${failures} 项不通过。`);
  process.exit(1);
}
process.exit(0);