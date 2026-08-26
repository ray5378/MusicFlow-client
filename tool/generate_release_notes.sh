#!/usr/bin/env bash
# Generate Markdown release notes from conventional commits between the current
# version tag and the previous version tag.
#
# Usage:
#   tool/generate_release_notes.sh <current_tag> [-o <outfile>]
#
#   current_tag: the tag being released, e.g. "v0.4.0"
#   -o outfile:   (optional) write result to file (default stdout)
#
# Conventional commit categories:
#   feat:  → ### 新功能
#   fix:   → ### 修复
#   other (chore/docs/refactor/test/style/ci/build/perf/revert/merge) → ### 其他
set -euo pipefail

current_tag="${1:?missing current tag}"
outfile=""
if [ "${2:-}" = "-o" ]; then
  outfile="${3:?missing outfile path}"
fi

# Determine the previous version tag (largest v* tag < current), or fall back to
# the root commit so the first release covers the whole history.
prev_tag="$(git tag --sort=-version:refname \
  | grep -E '^v[0-9]' \
  | grep -Fxv "$current_tag" \
  | head -n1 || true)"
min="$(git rev-list --max-parents=0 "$current_tag" 2>/dev/null | tail -n1 || true)"
if [ -z "$prev_tag" ]; then
  prev_tag="$min"
fi
range="${prev_tag}..${current_tag}"

new_features="$(git log --pretty=format:%s --no-merges "$range" 2>/dev/null \
  | grep -E '^feat' | sed -E 's/^feat(\([^)]*\))?[!]?:[[:space:]]*/- /' || true)"
fixes="$(git log --pretty=format:%s --no-merges "$range" 2>/dev/null \
  | grep -E '^fix' | sed -E 's/^fix(\([^)]*\))?[!]?:[[:space:]]*/- /' || true)"
others="$(git log --pretty=format:%s --no-merges "$range" 2>/dev/null \
  | grep -Eiv '^(feat|fix|chore|docs|refactor|test|style|ci|build|perf|revert)(\(|:| )' \
  | sed -E 's/^/- /' || true)"

emit_notes() {
  printf '## MusicFlow Client %s\n\n' "${current_tag#v}"
  printf '### 新功能\n'
  if [ -n "$new_features" ]; then printf '%s\n' "$new_features"; else printf '%s\n' '- 无'; fi
  printf '\n### 修复\n'
  if [ -n "$fixes" ]; then printf '%s\n' "$fixes"; else printf '%s\n' '- 无'; fi
  printf '\n### 其他\n'
  if [ -n "$others" ]; then printf '%s\n' "$others"; else printf '%s\n' '- 无'; fi
}

if [ -n "$outfile" ]; then
  emit_notes > "$outfile"
else
  emit_notes
fi