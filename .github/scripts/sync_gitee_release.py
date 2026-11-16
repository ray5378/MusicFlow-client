#!/usr/bin/env python3
"""幂等地把一个 GitHub Release 镜像到 Gitee。

职责（由 GitHub Actions workflow `.github/workflows/sync-to-gitee.yml` 驱动）：
  1. 按 tag 查询 Gitee Release；已存在则复用（并刷新描述），不存在再创建。
  2. 把本地 artifacts 目录中的全部附件上传到该 Release；同名附件跳过。
  3. 失败时输出带 tag 与阶段的清晰错误；成功时把 Gitee Release URL 写入 GITHUB_OUTPUT。

安全约束：
  - token 只从环境变量 GITEE_TOKEN 读取，不进 argv、不落文件、不进日志。
  - 所有可能含 token 的错误文本都会经 `_redact` 脱敏后再打印。
  - 仅依赖 Python 标准库，无需 pip 安装。
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, List, Optional, Sequence, Tuple

API_BASE = "https://gitee.com/api/v5"
MAX_ATTEMPTS = 4
RETRYABLE_STATUSES = frozenset({429, 500, 502, 503, 504})
REQUEST_TIMEOUT_SECONDS = 180


class SyncError(RuntimeError):
    """携带足够上下文、可直接展示在 CI 日志中的同步错误。"""


class GiteeReleaseSync:
    """单个 Release 的 Gitee 镜像执行器。"""

    def __init__(
        self,
        *,
        token: str,
        owner: str,
        repo: str,
        tag: str,
        name: str,
        body: str,
        prerelease: bool,
        assets_dir: pathlib.Path,
        target_commitish: str = "main",
        api_base: str = API_BASE,
    ) -> None:
        self.token = token
        self.owner = owner
        self.repo = repo
        self.tag = tag
        self.name = name or tag
        self.body = body
        self.prerelease = prerelease
        self.assets_dir = assets_dir
        self.target_commitish = target_commitish or "main"
        self.api_base = api_base.rstrip("/")

    def _redact(self, text: str) -> str:
        """把 token 的所有出现替换为 ***，防止意外进入日志。"""
        if not self.token:
            return text
        return text.replace(self.token, "***")

    @staticmethod
    def _encode_multipart(
        fields: Sequence[Tuple[str, Any]],
    ) -> Tuple[bytes, str]:
        """构造 multipart/form-data 请求体。

        Args:
            fields: (字段名, 值) 序列；值为 (文件名, bytes) 元组时表示文件字段。

        Returns:
            (请求体字节, Content-Type 头)。
        """
        boundary = "----MusicFlowGiteeSync" + uuid.uuid4().hex
        buffer = bytearray()
        for field_name, value in fields:
            buffer.extend(f"--{boundary}\r\n".encode("utf-8"))
            if isinstance(value, tuple):
                filename, data = value
                safe_filename = (
                    str(filename)
                    .replace('"', "_")
                    .replace("\r", "_")
                    .replace("\n", "_")
                )
                header = (
                    f'Content-Disposition: form-data; name="{field_name}"; '
                    f'filename="{safe_filename}"\r\n'
                    "Content-Type: application/octet-stream\r\n\r\n"
                )
                buffer.extend(header.encode("utf-8"))
                buffer.extend(data)
                buffer.extend(b"\r\n")
            else:
                header = (
                    f'Content-Disposition: form-data; name="{field_name}"\r\n\r\n'
                    f"{value}\r\n"
                )
                buffer.extend(header.encode("utf-8"))
        buffer.extend(f"--{boundary}--\r\n".encode("utf-8"))
        return bytes(buffer), f"multipart/form-data; boundary={boundary}"

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: Optional[Dict[str, str]] = None,
        payload: Optional[Dict[str, Any]] = None,
        files: Optional[Sequence[Tuple[str, Any]]] = None,
    ) -> Any:
        """发起带重试的 Gitee API 请求，返回解析后的 JSON（可能为 None）。

        token 通过 query / JSON body / multipart 字段传入，始终在进程内部构造，
        绝不会出现在命令行参数中。日志里的目标标识只含 method + path。
        """
        url = f"{self.api_base}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)

        headers: Dict[str, str] = {"Accept": "application/json"}
        body: Optional[bytes] = None
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        elif files is not None:
            body, content_type = self._encode_multipart(files)
            headers["Content-Type"] = content_type

        target = f"{method} {path}"  # 刻意不含 query，避免 token 写进日志
        last_error = "未知错误"

        for attempt in range(1, MAX_ATTEMPTS + 1):
            request = urllib.request.Request(
                url, data=body, headers=headers, method=method
            )
            try:
                with urllib.request.urlopen(
                    request, timeout=REQUEST_TIMEOUT_SECONDS
                ) as response:
                    raw = response.read().decode("utf-8", errors="replace")
                if not raw.strip():
                    return None
                try:
                    return json.loads(raw)
                except json.JSONDecodeError as exc:
                    raise SyncError(
                        f"{target} 返回非 JSON 内容：{self._redact(raw[:300])}"
                    ) from exc
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="replace")
                status = exc.code
                if status == 404 and method == "GET":
                    return None
                last_error = f"HTTP {status}: {self._redact(detail[:400])}"
                if status not in RETRYABLE_STATUSES or attempt == MAX_ATTEMPTS:
                    raise SyncError(
                        f"{target} 失败（tag={self.tag}）：{last_error}"
                    ) from exc
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last_error = f"{type(exc).__name__}: {self._redact(str(exc))}"
                if attempt == MAX_ATTEMPTS:
                    raise SyncError(
                        f"{target} 网络失败（tag={self.tag}）：{last_error}"
                    ) from exc

            time.sleep(min(2 ** (attempt - 1), 8))

        raise SyncError(
            f"{target} 重试 {MAX_ATTEMPTS} 次仍失败（tag={self.tag}）：{last_error}"
        )

    def find_release(self) -> Optional[Dict[str, Any]]:
        """按 tag 查询 Gitee Release；不存在返回 None。"""
        encoded_tag = urllib.parse.quote(self.tag, safe="")
        path = f"/repos/{self.owner}/{self.repo}/releases/tags/{encoded_tag}"
        data = self._request("GET", path, query={"access_token": self.token})
        if isinstance(data, dict) and data.get("id") is not None:
            return data
        return None

    def create_release(self) -> Dict[str, Any]:
        """创建 Gitee Release；Gitee 要求 target_commitish，缺失会报错。"""
        path = f"/repos/{self.owner}/{self.repo}/releases"
        payload: Dict[str, Any] = {
            "access_token": self.token,
            "tag_name": self.tag,
            "name": self.name,
            "body": self.body,
            "target_commitish": self.target_commitish,
            "prerelease": self.prerelease,
        }
        data = self._request("POST", path, payload=payload)
        if not isinstance(data, dict) or data.get("id") is None:
            raise SyncError(
                f"创建 Gitee Release 未返回 id（tag={self.tag}）："
                f"{self._redact(str(data)[:300])}"
            )
        return data

    def update_release(self, release_id: Any) -> bool:
        """刷新已存在 Release 的标题/正文；Gitee 版本不支持时降级为警告。"""
        path = f"/repos/{self.owner}/{self.repo}/releases/{release_id}"
        payload: Dict[str, Any] = {
            "access_token": self.token,
            "tag_name": self.tag,
            "name": self.name,
            "body": self.body,
            "prerelease": self.prerelease,
        }
        try:
            self._request("PATCH", path, payload=payload)
            return True
        except SyncError as exc:
            print(f"::warning::Gitee Release 描述刷新失败（不影响同步）：{exc}")
            return False

    def upload_assets(self, release_id: Any, existing_names: Sequence[str]) -> None:
        """上传全部本地附件；同名附件跳过，网络重试前复查远端避免重复上传。"""
        if not self.assets_dir.is_dir():
            print(f"tag={self.tag}：附件目录不存在，跳过上传。")
            return

        candidates: List[pathlib.Path] = sorted(
            path
            for path in self.assets_dir.iterdir()
            if path.is_file() and not path.name.startswith(".")
        )
        if not candidates:
            print(f"tag={self.tag}：没有需要上传的附件。")
            return

        known = {str(name) for name in existing_names if name}
        path = f"/repos/{self.owner}/{self.repo}/releases/{release_id}/attach_files"

        for asset in candidates:
            if asset.name in known:
                print(f"tag={self.tag}：附件已存在，跳过 {asset.name}")
                continue

            data = asset.read_bytes()
            for attempt in range(1, MAX_ATTEMPTS + 1):
                # 每次尝试前复查远端，避免上次响应丢失造成的重复上传。
                current = self.find_release()
                if current is not None:
                    remote_names = {
                        str(item.get("name"))
                        for item in current.get("assets", [])
                        if isinstance(item, dict) and item.get("name")
                    }
                    if asset.name in remote_names:
                        print(f"tag={self.tag}：附件已存在，跳过 {asset.name}")
                        known.add(asset.name)
                        break

                try:
                    self._request(
                        "POST",
                        path,
                        files=[
                            ("access_token", self.token),
                            ("file", (asset.name, data)),
                        ],
                    )
                    print(
                        f"tag={self.tag}：已上传附件 {asset.name}"
                        f"（{len(data)} 字节）"
                    )
                    known.add(asset.name)
                    break
                except SyncError as exc:
                    if attempt == MAX_ATTEMPTS:
                        raise SyncError(
                            f"上传附件 {asset.name} 失败（tag={self.tag}）：{exc}"
                        ) from exc
                    time.sleep(2 ** (attempt - 1))

    def run(self) -> str:
        """执行完整同步，返回 Gitee Release 的网页 URL。"""
        existing = self.find_release()
        if existing is not None:
            release_id = existing["id"]
            asset_names = [
                str(item.get("name"))
                for item in existing.get("assets", [])
                if isinstance(item, dict) and item.get("name")
            ]
            print(f"Gitee 已存在 tag={self.tag} 的 Release（id={release_id}），复用。")
            self.update_release(release_id)
        else:
            created = self.create_release()
            release_id = created["id"]
            asset_names = []
            print(f"已创建 Gitee Release tag={self.tag}（id={release_id}）。")

        self.upload_assets(release_id, asset_names)
        encoded_tag = urllib.parse.quote(self.tag, safe="")
        return (
            f"https://gitee.com/{self.owner}/{self.repo}/releases/tag/{encoded_tag}"
        )


def _require_env(name: str) -> str:
    """读取必填环境变量，缺失时报出明确错误。"""
    value = os.environ.get(name, "")
    if not value:
        raise SyncError(f"环境变量 {name} 未配置或为空")
    return value


def _build_sync() -> GiteeReleaseSync:
    """从环境变量构造同步器。"""
    body_file = pathlib.Path(_require_env("RELEASE_BODY_FILE"))
    body = body_file.read_text(encoding="utf-8") if body_file.is_file() else ""
    return GiteeReleaseSync(
        token=_require_env("GITEE_TOKEN"),
        owner=_require_env("GITEE_OWNER"),
        repo=_require_env("GITEE_REPO"),
        tag=_require_env("TAG"),
        name=os.environ.get("RELEASE_NAME", ""),
        body=body,
        prerelease=os.environ.get("PRERELEASE", "false").strip().lower() == "true",
        assets_dir=pathlib.Path(_require_env("ARTIFACT_DIR")),
        target_commitish=os.environ.get("TARGET_COMMITISH", "main"),
        api_base=os.environ.get("GITEE_API_BASE", API_BASE),
    )


def main() -> int:
    """入口：成功返回 0，任何失败都打印带 tag 的 ::error:: 并返回 1。"""
    tag = os.environ.get("TAG", "<unknown>")
    token = os.environ.get("GITEE_TOKEN", "")
    try:
        sync = _build_sync()
        url = sync.run()
        print(f"Gitee Release 同步完成：{url}")
        output_path = os.environ.get("GITHUB_OUTPUT", "")
        if output_path:
            with pathlib.Path(output_path).open("a", encoding="utf-8") as handle:
                handle.write(f"gitee_release_url={url}\n")
        return 0
    except SyncError as exc:
        print(f"::error::Gitee 同步失败（tag={tag}）：{exc}")
        return 1
    except Exception as exc:  # noqa: BLE001 - 顶层兜底，保证 CI 一定拿到明确错误
        detail = str(exc).replace(token, "***") if token else str(exc)
        print(
            f"::error::Gitee 同步异常（tag={tag}）："
            f"{type(exc).__name__}: {detail}"
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
