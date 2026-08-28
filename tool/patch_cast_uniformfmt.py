#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 连续流统一格式修复:
# 根因:纯 renderer(HiVi)把 /castStream 当单一 MPEG 流解。旧逻辑把所有 .mp3 都走剥头快通道,
#       但原生 mp3 保留原始采样率/声道;队列里混 44.1k 与 48k 的 mp3(或原生 mp3 紧挨 ffmpeg
#       转出的 44.1k 段)时,流内采样率突变,嵌入式解码器报错→两声嘟嘟→停播。
# 修复:只对「本地、MPEG1-Layer3、44.1kHz、非 mono」的 mp3 走快通道;其它一律 ffmpeg 重编码
#       为统一 44.1k/2ch 无头 mp3。保证整根流采样率/声道完全一致。
import io, re

SRC = "/root/mfserver/backend/src/routes/rest/index.ts"
content = io.open(SRC, encoding="utf-8").read()

def must(ok, msg):
    if not ok:
        raise SystemExit("FAILED: " + msg)

# 1) 移除 castQueueNeedsTranscode + CAST_TARGET_SUFFIX 常量
content, n = re.subn(
    r'const CAST_TARGET_SUFFIX = "mp3";\nfunction castQueueNeedsTranscode\(ordered: any\[\]\): boolean \{.*?\n\}\n',
    "", content, count=1, flags=re.S)
must(n == 1, "remove castQueueNeedsTranscode")

# 2) 替换 isMp3Song+remuxLocalMp3 整块为辅助函数(localMp3FilePath + mp3MatchesTarget)
NEW_HELPERS = (
'// 返回可剥头拼帧的本地 mp3 文件路径(web 有 cachePath / 本地非 webdav),否则 null。\n'
'function localMp3FilePath(song: any): string | null {\n'
'  if ((song.type || "local") === "web") {\n'
'    if (song.cachePath && fs.existsSync(song.cachePath)) return song.cachePath;\n'
'    return null;\n'
'  }\n'
'  const parsed = parseSongPath(song.path);\n'
'  if (parsed && parsed.type !== "w" && fs.existsSync(parsed.filePath)) return parsed.filePath;\n'
'  return null;\n'
'}\n'
'\n'
'// 探测本地文件首帧是否为 MPEG1-Layer3 44.1kHz 立体声(与重编码目标完全一致)。\n'
'// 只读前 64KB 同步到首个帧头即可,微秒级;匹配则走快通道,不匹配则重编码——\n'
'// 保证整根流采样率/声道完全一致,纯 renderer 跨曲/跨格式连播不再"嘟嘟"。\n'
'function mp3MatchesTarget(filePath: string): boolean {\n'
'  let fd: number;\n'
'  try { fd = fs.openSync(filePath, "r"); } catch { return false; }\n'
'  try {\n'
'    const size = fs.fstatSync(fd).size;\n'
'    if (size <= 4) return false;\n'
'    let offset = 0;\n'
'    // 跳过 ID3v2 头。\n'
'    {\n'
'      const b = Buffer.alloc(10);\n'
'      if (size >= 10 && fs.readSync(fd, b, 0, 10, 0) === 10 && b.toString("ascii", 0, 3) === "ID3") {\n'
'        const sz = ((b[6] & 0x7f) << 21) | ((b[7] & 0x7f) << 14) | ((b[8] & 0x7f) << 7) | (b[9] & 0x7f);\n'
'        offset = Math.min(10 + sz + ((b[5] & 0x10) ? 10 : 0), size);\n'
'      }\n'
'    }\n'
'    const buf = Buffer.alloc(65536);\n'
'    const n = fs.readSync(fd, buf, 0, buf.length, offset);\n'
'    // 找首个 0xFFE 帧同步:MPEG1(ver=3)+LayerIII(layer=1)+srIdx0(44.1k)+非 mono。\n'
'    for (let i = 0; i + 4 < n; i++) {\n'
'      if (buf[i] === 0xff && (buf[i + 1] & 0xe0) === 0xe0) {\n'
'        const verBits = (buf[i + 1] >> 3) & 0x03;\n'
'        const layerBits = (buf[i + 1] >> 1) & 0x03;\n'
'        const srIdx = (buf[i + 2] >> 2) & 0x03;\n'
'        const chMode = (buf[i + 3] >> 6) & 0x03;\n'
'        return verBits === 3 && layerBits === 1 && srIdx === 0 && chMode !== 3;\n'
'      }\n'
'    }\n'
'    return false;\n'
'  } finally { fs.closeSync(fd); }\n'
'}\n'
'\n'
)
start = content.index("function isMp3Song")
end = content.index("async function* remuxLocalFile", start)
content = content[:start] + NEW_HELPERS + content[end:]

# 3) renderCastQueueToFile:去掉 transcode 预判,generator 不再传 transcode
content, n = re.subn(
    r'  const transcode = castQueueNeedsTranscode\(ordered\);\n', "", content, count=1)
must(n == 1, "remove transcode line")
content, n = re.subn(
    r'Readable\.from\(castQueueGenerator\(ordered, transcode\) as AsyncGenerator<Uint8Array>\)',
    'Readable.from(castQueueGenerator(ordered) as AsyncGenerator<Uint8Array>)',
    content, count=1)
must(n == 1, "generator call")

# 4) castQueueGenerator 主体:按单首格式决策
NEW_GEN = (
'async function* castQueueGenerator(ordered: any[]): AsyncGenerator<Uint8Array> {\n'
'  for (const s of ordered) {\n'
'    try {\n'
'      const f = localMp3FilePath(s);\n'
'      // 仅当本地文件是 MPEG1-Layer3 44.1kHz 立体声时才走剥头快通道(零转码);\n'
'      // 其它(48k/22k、mono、非 mp3)一律重编码为统一 44.1k/2ch 无头 mp3。\n'
'      // 这是整根流采样率/声道完全一致的前提——纯 renderer 跨曲/跨格式连播不再"嘟嘟"。\n'
'      if (f && mp3MatchesTarget(f)) {\n'
'        yield* remuxLocalFile(f);\n'
'      } else {\n'
'        yield* transcodeSongToMp3(s);\n'
'      }\n'
'    } catch {\n'
'      // 单首不可播 → 跳过,不中断整段。\n'
'    }\n'
'  }\n'
'}\n'
)
gstart = content.index("async function* castQueueGenerator")
gend = content.index("// 每个 token 只整根渲染一次", gstart)
content = content[:gstart] + NEW_GEN + content[gend:]

io.open(SRC, "w", encoding="utf-8").write(content)
print("PATCH OK")