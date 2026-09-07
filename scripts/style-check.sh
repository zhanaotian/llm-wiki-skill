#!/usr/bin/env bash
# style-check.sh — 文体规则机器闸门（llm-wiki fork）
# 检查 wiki 知识库页面的文体违规：
#   ERROR = 指路式尾巴 / 导航元叙述（"见[[X]]、详见、本体见、承载这部分、收在…一节"等禁式）
#   WARN  = [[wiki/…]] 路径前缀链接（可能存在合法消歧用例，如 _index、与素材原文同名的裸名歧义）
# 用法: bash style-check.sh [vault 根目录]    默认取参数 1；不传则用 $PWD
#   传 vault 根目录时自动扫描「根/index.md + 根/wiki/**」；传子目录时只扫该目录。
# 退出码: 0 = 无 ERROR（WARN 允许存在，由人确认）; 1 = 有 ERROR 或参数错误
# 规则来源: SKILL.md「知识库格式规则（本 fork 定制）」细化 4/6。
# 只报告不修改：AI 审阅报告后修复，或对合法例外说明保留理由。

set -u
ROOT="${1:-$(pwd)}"
[ -d "$ROOT" ] || { echo "目录不存在: $ROOT" >&2; exit 1; }

# 构造扫描文件集：vault 根 -> index.md + wiki/；子目录 -> 该目录
if [ -d "$ROOT/wiki" ] && [ -f "$ROOT/index.md" ]; then
  SCAN_DIR="$ROOT/wiki"
  EXTRA="$ROOT/index.md"
else
  SCAN_DIR="$ROOT"
  EXTRA=""
fi

find_files() {
  find "$1" -type f -name '*.md' \
    -not -path '*/.git/*' -not -path '*/log.md' -not -path '*/raw/*' \
    -not -path '*/.wiki-tmp/*' | sort
}
if [ -n "$EXTRA" ]; then
  FILES="$EXTRA $(find_files "$SCAN_DIR")"
else
  FILES="$(find_files "$SCAN_DIR")"
fi

# ERROR 级：指路尾巴 / 导航元叙述
ERROR_PATS=(
  '见 \[\['
  '详见'
  '参见 \[\['
  '本体见'
  '详见上文|详见下文'
  '承载这部分|承载了这部分|承载该部分|承载此部分'
  '收在 \[\['
  '里接在'
  '记录于 \[\['
  '完整机制收在'
)
# WARN 级：wiki/ 路径前缀链接
WARN_PATS=('\[\[wiki/')

err=0; warn=0
for f in $FILES; do
  [ -f "$f" ] || continue
  for pat in "${ERROR_PATS[@]}"; do
    while IFS= read -r line; do
      ln=${line%%:*}; txt=${line#*:}
      [ -z "$txt" ] && continue
      printf 'ERROR  %s:%s  %s\n' "${f#"$ROOT"/}" "$ln" "$(echo "$txt" | sed 's/^[[:space:]]*//' | cut -c1-110)"
      err=$((err+1))
    done < <(grep -nE "$pat" "$f" 2>/dev/null)
  done
  for pat in "${WARN_PATS[@]}"; do
    while IFS= read -r line; do
      ln=${line%%:*}; txt=${line#*:}
      [ -z "$txt" ] && continue
      printf 'WARN   %s:%s  %s\n' "${f#"$ROOT"/}" "$ln" "$(echo "$txt" | sed 's/^[[:space:]]*//' | cut -c1-110)"
      warn=$((warn+1))
    done < <(grep -nE "$pat" "$f" 2>/dev/null)
  done
done

echo "----"
echo "style-check 完成: ERROR=$err  WARN=$warn"
if [ "$err" -gt 0 ]; then
  echo "存在 ERROR 级文体违规（指路尾巴/元叙述），先修复再交付。WARN 需人工确认是否为合法消歧。"
  exit 1
fi
echo "ERROR 级清零。WARN 为 [[wiki/ 前缀链接，逐一确认合法例外或织入化。"
exit 0
