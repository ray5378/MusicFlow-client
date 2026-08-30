#!/usr/bin/env python3
"""把 `flutter test --reporter json` 的输出汇总成 GitHub Job Summary。

设计要点（对应 SPEC §9.4「CI 失败不限制发版」）：
  · 本脚本只负责「把结果说清楚」，绝不决定成败——退出码恒为 0。
  · Markdown 报告写 stdout（由 workflow 追加到 $GITHUB_STEP_SUMMARY）。
  · 失败用例以 `::warning::` 写 stderr，在提交/PR 上生成黄色注解，
    既醒目又不阻断发版。

用法: python3 .github/scripts/summarize_tests.py <test-results.jsonl> [退出码]
"""

from __future__ import annotations

import json
import sys
from collections import OrderedDict

# 一个失败用例的完整堆栈可能有几百行，摘要里只保留首行，避免 Job Summary 被刷爆。
MAX_ERROR_LINES = 1
# 注解数量上限：GitHub 单个 job 的注解上限是 50 条，留足余量。
MAX_ANNOTATIONS = 40


def first_line(text: object) -> str:
    """取多行文本的第一行非空内容，并压成单行。"""
    if text is None:
        return ""
    for raw in str(text).splitlines():
        line = raw.strip()
        if line:
            return " ".join(line.split())
    return ""


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: summarize_tests.py <test-results.jsonl> [exit_code]", file=sys.stderr)
        return 0

    path = argv[1]
    raw_exit = argv[2] if len(argv) > 2 else ""
    try:
        exit_code = int(raw_exit)
    except (TypeError, ValueError):
        exit_code = -1

    names: "OrderedDict[int, str]" = OrderedDict()
    results: "OrderedDict[int, str]" = OrderedDict()
    errors: "OrderedDict[int, str]" = OrderedDict()
    done_success: bool | None = None
    parsed = 0

    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                parsed += 1
                kind = event.get("type")

                if kind == "testStart":
                    test = event.get("test") or {}
                    test_id = test.get("id")
                    if test_id is not None:
                        name = test.get("name") or ""
                        # suite 自身的 testStart 名字为空，跳过以免污染统计。
                        if name:
                            names[test_id] = name
                elif kind == "testDone":
                    test_id = event.get("testID")
                    if event.get("hidden"):
                        continue
                    if test_id is not None:
                        results[test_id] = event.get("result") or "unknown"
                elif kind == "error":
                    if not event.get("isFailure", False):
                        continue
                    test_id = event.get("testID")
                    if test_id is not None and test_id not in errors:
                        errors[test_id] = first_line(event.get("error"))
                elif kind == "done":
                    value = event.get("success")
                    if isinstance(value, bool):
                        done_success = value
    except OSError as err:
        print(f"::warning::无法读取测试结果文件 {path}: {err}")
        print(
            "## flutter test\n\n"
            ":x: 无法读取测试结果文件，测试可能根本没跑起来（环境问题而非用例失败）。\n"
        )
        return 0

    if parsed == 0:
        print("::warning::flutter test 未产出任何 JSON 事件，测试可能未真正执行")
        print(
            "## flutter test\n\n"
            ":x: **未产出任何测试结果**。\n\n"
            "测试进程可能未启动（Flutter 环境 / 依赖安装失败），请查看原始终端日志。\n"
        )
        return 0

    passed = [tid for tid, result in results.items() if result == "success"]
    failed = [tid for tid, result in results.items() if result in {"failure", "error"}]
    skipped = [tid for tid, result in results.items() if result == "skipped"]

    status_icon = ":white_check_mark:" if not failed else ":warning:"
    lines: list[str] = []
    lines.append("## flutter test（全量 · 非阻塞）")
    lines.append("")
    lines.append(f"{status_icon} 通过 **{len(passed)}** · 失败 **{len(failed)}** · 跳过 **{len(skipped)}**")
    lines.append("")
    lines.append(
        "> 按 SPEC §9.4，本流水线为质量观察哨，结果不构成发布门禁；"
        "下方失败项需在后续版本跟进，但不阻塞 tag 发版。"
    )
    lines.append("")

    if failed:
        lines.append("### 失败用例")
        lines.append("")
        lines.append("| 用例 | 错误摘要 |")
        lines.append("| --- | --- |")
        for test_id in failed:
            name = names.get(test_id, f"testID={test_id}")
            error = errors.get(test_id, "")
            escaped = name.replace("|", "\\|")
            escaped_error = error.replace("|", "\\|")
            lines.append(f"| `{escaped}` | {escaped_error or '_（无错误详情）_'} |")
        lines.append("")

    lines.append("### 运行信息")
    lines.append("")
    lines.append(f"- `flutter test` 退出码：`{exit_code}`")
    if done_success is not None:
        lines.append(f"- runner 汇总事件 success：`{done_success}`")
    lines.append(f"- 解析到的事件数：{parsed}")
    lines.append("")

    print("\n".join(lines))

    for test_id in failed[:MAX_ANNOTATIONS]:
        name = names.get(test_id, f"testID={test_id}")
        error = errors.get(test_id, "")
        message = f"测试失败: {name}" + (f" — {error}" if error else "")
        print(f"::warning::{message}", file=sys.stderr)
    overflow = len(failed) - MAX_ANNOTATIONS
    if overflow > 0:
        print(
            f"::warning::另有 {overflow} 个失败用例未在注解中列出，详见 Job Summary",
            file=sys.stderr,
        )

    # 恒为 0：本脚本永远不参与门禁判定。
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
