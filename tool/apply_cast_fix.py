import io

F = "/root/mfserver/backend/src/routes/rest/index.ts"
src = io.open(F, "r", encoding="utf-8").read()

# ---- 1) imports ----
old_imp = 'import fs from "fs";\nimport { spawn } from "node:child_process";'
new_imp = ('import fs from "fs";\n'
           'import path from "node:path";\n'
           'import os from "node:os";\n'
           'import { Readable } from "node:stream";\n'
           'import { pipeline } from "node:stream/promises";\n'
           'import { spawn } from "node:child_process";')
assert old_imp in src, "import anchor missing"
src = src.replace(old_imp, new_imp, 1)

# ---- 2) token block + handler tail replacement ----
start = src.index("// 连续流「短令牌」表")
end_anchor = ('  return new Response(stream as any, {\n'
              '    status: 200,\n'
              '    headers: {\n'
              '      "Content-Type": "audio/mpeg",\n'
              '      "Cache-Control": "no-cache",\n'
              '    },\n'
              '  });\n'
              '});\n\n'
              '// ==================== Remote stream proxy')
idx_end = src.index(end_anchor)
old_block = src[start:idx_end + len("  });\n});\n")]

new_block = '''// 连续流「短令牌」表:客户端把整队列一次交给服务端存成短 token,纯 renderer 再用一个很短的
// URL(/rest/castStream?token=xxx)拉流;把「队列条数」与「renderer 现场 URL 长度」解耦。
// 原因:300 首 UUID 逗号拼出的 ~12KB 超长 URI 会被 HiVi 等嵌入式 renderer 截断/拒拉。
// token 仅内存驻留,插入时惰性清理过期项防无界增长。
const castStreamTokens = new Map<string, { ids: string[]; ts: number; file?: string; size?: number }>();
function newCastStreamToken(ids: string[]): string {
  const now = Date.now();
  if (castStreamTokens.size > 2000) {
    for (const [k, v] of castStreamTokens) {
      if (now - v.ts > 24 * 3600 * 1000) castStreamTokens.delete(k);
    }
    if (castStreamTokens.size > 2000) castStreamTokens.clear(); // 极端兜底
  }
  const token = "cs_" + now.toString(36) + "_" + Math.random().toString(36).slice(2, 10);
  castStreamTokens.set(token, { ids, ts: now });
  return token;
}

// 把整队列统一重编码为**一个**带 Content-Length、可 Range 的 mp3 文件,再按普通文件流
// (206/Range/Content-Length/Accept-Ranges)交给 renderer。原因:设备只对「有限大小、可探测
// 长度」的媒体稳定播放;旧的实时 chunked 无 Content-Length 连续流,会让 HiVi 等纯 renderer
// 在播放十几秒后自行停播并报错(两声嘟嘟)——与单曲 /stream 文件流能正常播放形成对照。
async function renderCastQueueToFile(ordered: any[]): Promise<{ file: string; size: number }> {
  const transcode = ordered.length !== 1 || castQueueNeedsTranscode(ordered);
  const file = path.join(os.tmpdir(), `mf-cast-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.mp3`);
  await pipeline(
    Readable.from(castQueueGenerator(ordered, transcode) as AsyncGenerator<Uint8Array>),
    fs.createWriteStream(file),
  );
  return { file, size: fs.statSync(file).size };
}

async function* castQueueGenerator(ordered: any[], transcode: boolean): AsyncGenerator<Uint8Array> {
  for (const s of ordered) {
    try {
      for await (const chunk of openCastSongForQueue(s, transcode)) yield chunk;
    } catch {
      // 单首不可播 → 跳过,不中断整段。
    }
  }
}

// 每个 token 只整根渲染一次;并发 Range/HEAD/GET 探针共享同一在途渲染,避免重复 ffmpeg。
const castRenderInflight = new Map<string, Promise<{ file: string; size?: number }>>();
async function ensureCastRender(
  rec: { file?: string; size?: number },
  ordered: any[],
  token: string,
): Promise<{ file: string; size: number }> {
  if (rec.file) return { file: rec.file, size: rec.size! };
  let p = castRenderInflight.get(token);
  if (!p) {
    p = (async () => {
      const r = await renderCastQueueToFile(ordered);
      rec.file = r.file;
      rec.size = r.size;
      return r;
    })();
    castRenderInflight.set(token, p);
    p.finally(() => castRenderInflight.delete(token)).catch(() => {});
  }
  const r = await p;
  return { file: r.file, size: r.size! };
}

function serveCastFile(c: any, file: string, size: number, rangeHeader: string | null) {
  if (rangeHeader) {
    const match = rangeHeader.match(/bytes=(\\d+)-(\\d*)/);
    if (match) {
      const start = parseInt(match[1]);
      const end = match[2] ? parseInt(match[2]) : size - 1;
      const chunkSize = end - start + 1;
      return new Response(fs.createReadStream(file, { start, end }) as any, {
        status: 206,
        headers: {
          "Content-Type": "audio/mpeg",
          "Content-Range": `bytes ${start}-${end}/${size}`,
          "Content-Length": String(chunkSize),
          "Accept-Ranges": "bytes",
          "Cache-Control": "no-cache",
        },
      });
    }
  }
  return new Response(fs.createReadStream(file) as any, {
    status: 200,
    headers: {
      "Content-Type": "audio/mpeg",
      "Content-Length": String(size),
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-cache",
    },
  });
}

restRoutes.get("/castStream", permMiddleware(PERM.LIBRARY_STREAM), async (c) => {
  const token = (getParam(c, "token") || "").trim();
  const create = getParam(c, "create") === "1";

  // 已有 token:renderer 现场拉流,按短链解析队列(不再依赖超长的 songs 列表)。
  let ordered: any[];
  if (token) {
    const rec = castStreamTokens.get(token);
    if (!rec) return c.json(fail(0, "Invalid or expired stream token"));
    const ids = rec.ids;
    const trows = db.select().from(songs).where(inArray(songs.id, ids)).all();
    ordered = ids.map(id => trows.find(r => r.id === id)).filter((r): r is any => !!r);
    if (ordered.length === 0) return c.json(fail(0, "No playable songs"));
  } else {
    const songIds = getParams(c, "songs").flatMap(s => s.split(",")).map(s => s.trim()).filter(Boolean);
    if (songIds.length === 0) return c.json(fail(0, "No songs specified"));
    const rows = db.select().from(songs).where(inArray(songs.id, songIds)).all();
    ordered = songIds.map(id => rows.find(r => r.id === id)).filter((r): r is any => !!r);
    if (ordered.length === 0) return c.json(fail(0, "No playable songs"));
  }

  if (create) {
    // 客户端一次性把队列交给服务端:先整根渲染为可 Range 的 mp3 文件,再返回短 token,
    // 保证 renderer 连接的瞬间文件已 ready(队列长度与现场 URL 长度同时解耦)。
    const t = newCastStreamToken(ordered.map(s => s.id));
    const rec = castStreamTokens.get(t)!;
    await ensureCastRender(rec, ordered, t);
    return c.json(ok({ stream: { token: t } }));
  }

  // 末尾:整队列统一重编码为单个可 Range 的 mp3 文件后,按普通文件流交给 renderer。
  const rec = token ? castStreamTokens.get(token)! : ({ file: undefined, size: undefined } as any);
  const { file, size } = await ensureCastRender(rec, ordered, token || `inline:${ordered[0]?.id}:${ordered.length}`);
  return serveCastFile(c, file, size, c.req.header("range"));
});
'''

assert old_block in src, "castStream block anchor mismatch"
src = src.replace(old_block, new_block, 1)

io.open(F, "w", encoding="utf-8").write(src)
print("OK: patched", F)