#!/usr/bin/env bash
# 本地复跑 CI「Desktop Lyric Guard」的 MSVC 语法检查（cl /Zs）。
#
# 为什么需要它：desktop_lyric.cpp / flutter_window.cpp 是原生代码，
# `flutter test` 与 `flutter analyze` 都不覆盖。CI 里由
# desktop-lyric-guard.yml 的 native-compile-check job 把关，但那只在
# push 之后才跑 —— 本地先跑一遍能避免「打完 tag 才发现编译不过」。
#
# 坑（已踩过）：
#  - Git Bash 的 `cmd //c` 会被路径转换搅乱参数，直接调 cl.exe 更稳。
#  - vcvars64.bat 设的 INCLUDE/LIB 在 Git Bash 子进程里不生效，
#    必须用 /I 显式传头文件路径（UCRT/um/shared 三个都要）。
#  - 输出含 UTF-16 空字节，管道里要 tr -d '\0'。
#
# 用法：bash tool/check_native_syntax.sh [额外源文件...]
set -euo pipefail
cd "$(dirname "$0")/.."

MSVC_VER="14.44.35207"
BT="/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools"
CL="$BT/VC/Tools/MSVC/$MSVC_VER/bin/Hostx64/x64/cl.exe"
BC="C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/$MSVC_VER/include"
SDK_VER="$(ls '/c/Program Files (x86)/Windows Kits/10/Include' | grep '^10\.' | sort -V | tail -1)"
K="C:/Program Files (x86)/Windows Kits/10/Include/$SDK_VER"

if [ ! -x "$CL" ]; then
  echo "SKIP: MSVC cl.exe 不存在（$CL）" >&2
  exit 0
fi

SOURCES=("windows/runner/desktop_lyric.cpp")
if [ "$#" -gt 0 ]; then SOURCES=("$@"); fi

FAIL=0
for src in "${SOURCES[@]}"; do
  echo "== cl /Zs $src"
  # shellcheck disable=SC2086
  if "$CL" /nologo /utf-8 /Zs /std:c++17 /W3 /EHsc \
      /I "$BC" /I "$K/ucrt" /I "$K/shared" /I "$K/um" \
      /I 'windows/runner' "$src" 2>&1 | tr -d '\0' | grep -v '^desktop_lyric\.cpp$\|^flutter_window\.cpp$'; then
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: 原生语法检查未通过" >&2
  exit 1
fi
echo "OK: 原生语法检查通过（$(printf '%s ' "${SOURCES[@]}")）"
