#!/bin/bash
# lint-runner.sh — render the single shared path-aware wikilink report.
#
# Usage:
#   bash scripts/lint-runner.sh <kb-root>
#   bash scripts/lint-runner.sh <kb-root> --strict
#   bash scripts/lint-runner.sh <kb-root> --json
#   bash scripts/lint-runner.sh <kb-root> --strict --json
#
# Exit codes: 0 complete report; 1 tool/input failure; 2 strict report contains an error.

set -u

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
CLI="$SCRIPT_DIR/wiki-link-cli.js"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/lint-runner.sh <kb-root> [--strict] [--json]
USAGE
}

[ "$#" -ge 1 ] || {
  usage >&2
  exit 1
}

WIKI_ROOT="$1"
shift
STRICT=0
FORMAT=text
SEEN_STRICT=0
SEEN_JSON=0
for FLAG in "$@"; do
  case "$FLAG" in
    --strict)
      [ "$SEEN_STRICT" -eq 0 ] || { echo "ERROR: duplicate argument: --strict" >&2; exit 1; }
      STRICT=1
      SEEN_STRICT=1
      ;;
    --json)
      [ "$SEEN_JSON" -eq 0 ] || { echo "ERROR: duplicate argument: --json" >&2; exit 1; }
      FORMAT=json
      SEEN_JSON=1
      ;;
    *)
      echo "ERROR: unknown argument: $FLAG" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[ -d "$WIKI_ROOT/wiki" ] || {
  echo "ERROR: wiki directory does not exist: $WIKI_ROOT/wiki" >&2
  exit 1
}
[ -f "$WIKI_ROOT/index.md" ] || {
  echo "ERROR: index.md does not exist: $WIKI_ROOT/index.md" >&2
  exit 1
}
[ -f "$CLI" ] || {
  echo "ERROR: shared wikilink checker is missing: $CLI" >&2
  exit 1
}
command -v node >/dev/null 2>&1 || { echo "ERROR: node is required" >&2; exit 1; }

REPORT_FILE="$(mktemp -t llm-wiki-lint.XXXXXX)"
trap 'rm -f "$REPORT_FILE"' EXIT
if ! node "$CLI" check "$WIKI_ROOT" --json > "$REPORT_FILE"; then
  exit 1
fi

node - "$REPORT_FILE" "$WIKI_ROOT" "$FORMAT" <<'NODE'
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const [reportPath, kbRoot, format] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const targets = report.inventory.targets;
const targetPaths = new Set(targets.map((item) => item.path));
const metadata = new Map(report.source_metadata.map((item) => [item.source_path, item]));
const resolvedOccurrences = report.occurrences.filter((item) => (
  item.resolution && item.resolution.status === "resolved" && item.resolution.target_path
));
const incoming = new Map();
for (const occurrence of resolvedOccurrences) {
  const target = occurrence.resolution.target_path;
  if (target === occurrence.source_path) continue;
  if (!incoming.has(target)) incoming.set(target, new Set());
  incoming.get(target).add(occurrence.source_path);
}

const orphanPages = report.inventory.lintSources
  .filter((item) => ["entity", "topic", "source"].includes(item.graphType))
  .map((item) => item.path)
  .filter((item) => !incoming.has(item))
  .sort();

const indexOccurrences = report.occurrences.filter((item) => item.source_path === "index.md");
const indexResolvedTargetPaths = Array.from(new Set(indexOccurrences
  .filter((item) => item.resolution && item.resolution.status === "resolved")
  .map((item) => item.resolution.target_path)))
  .sort();
const indexMissingTargets = Array.from(new Set(indexOccurrences
  .filter((item) => item.resolution && item.resolution.status === "missing" && item.resolution.warning_code)
  .map((item) => item.resolution.target_key)))
  .sort();
const indexed = new Set(indexResolvedTargetPaths);
const indexUnlistedPaths = report.inventory.lintSources
  .filter((item) => ["entity", "topic", "source", "comparison", "synthesis"].includes(item.graphType))
  .map((item) => item.path)
  .filter((item) => !item.includes("/sessions/") && !indexed.has(item))
  .sort();

const imageIssues = [];
for (const [sourcePath, item] of metadata.entries()) {
  if (item.graph_type !== "source") continue;
  for (const imagePath of item._signals.imagePaths || []) {
    // 本 fork：image_paths 写的是相对 wiki/ 根的路径（assets/images/xxx.png），
    // 而 targetPaths 以 vault 根为基准（wiki/assets/images/xxx.png）。
    // 两者都试，任命中即视为存在，避免误报缺失。
    const normalized = imagePath.replace(/^\.\//, "");
    const withWikiPrefix = normalized.startsWith("wiki/") ? normalized : `wiki/${normalized}`;
    if (!targetPaths.has(normalized) && !targetPaths.has(withWikiPrefix)) {
      imageIssues.push({ source_path: sourcePath, image_path: imagePath });
    }
  }
}
imageIssues.sort((left, right) => `${left.source_path}\0${left.image_path}`.localeCompare(`${right.source_path}\0${right.image_path}`, "en"));

const sourceSignal = {
  applicable_total: 0,
  ok: 0,
  missing_sources: 0,
  empty_sources: 0,
  invalid_sources: 0,
  not_applicable: 0,
  pages: []
};
for (const item of report.source_metadata) {
  if (!item.graph_type) continue;
  const applicable = ["entity", "topic", "source", "comparison"].includes(item.graph_type);
  let reason;
  if (!applicable) reason = "not_applicable";
  else if (!item._signals.sourceFieldPresent) reason = "missing_sources";
  else if (!item._signals.sourceFieldParsed) reason = "invalid_sources";
  else if (!item._signals.sources.length) reason = "empty_sources";
  else reason = "ok";
  sourceSignal[reason] += 1;
  if (reason !== "not_applicable") sourceSignal.applicable_total += 1;
  sourceSignal.pages.push({ path: item.source_path, reason, source_count: item._signals.sources.length });
}
sourceSignal.pages.sort((left, right) => left.path.localeCompare(right.path, "en"));

const derived = {
  orphan_count: orphanPages.length,
  orphan_paths: orphanPages,
  broken_count: report.groups.filter((group) => group.code === "broken_wikilink")
    .reduce((sum, group) => sum + group.occurrence_count, 0),
  index_missing_count: indexMissingTargets.length,
  index_missing_targets: indexMissingTargets,
  index_unlisted_count: indexUnlistedPaths.length,
  index_unlisted_paths: indexUnlistedPaths,
  index_resolved_target_paths: indexResolvedTargetPaths,
  image_issue_count: imageIssues.length,
  image_issues: imageIssues,
  source_signal: sourceSignal
};
const output = {
  derived,
  stale_pending_wrappers: report.stale_pending_wrappers,
  warning_report: report
};

if (format === "json") {
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  process.exit(0);
}

function displayPage(relativePath) {
  return relativePath.replace(/^wiki\//, "").replace(/\.md$/, "");
}
function section(title, rows, emptyText) {
  console.log(`--- ${title} ---`);
  if (rows.length === 0) console.log(`  ${emptyText}`);
  else for (const row of rows) console.log(`  ${row}`);
  console.log("");
}
function warningRows(code) {
  const candidateSets = new Map(report.candidate_sets.map((item) => [item.candidate_set_id, item]));
  const rows = [];
  for (const group of report.groups.filter((item) => item.code === code)) {
    rows.push(`${group.target_key || group.id || group.warning_id}（${group.occurrence_count} 处）`);
    const candidateSet = candidateSets.get(group.candidate_set_id);
    if (candidateSet) {
      for (const candidate of candidateSet.candidates) rows.push(`  候选: ${candidate}`);
    }
    for (const occurrence of group.occurrences) {
      rows.push(`  ${occurrence.source_path}:${occurrence.line}:${occurrence.column} ${occurrence.raw_link}`);
    }
  }
  return rows;
}

console.log("=== llm-wiki lint 报告 ===");
const now = new Date();
const parts = new Intl.DateTimeFormat("sv-SE", {
  year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false
}).formatToParts(now).reduce((result, item) => ({ ...result, [item.type]: item.value }), {});
console.log(`时间：${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`);
console.log(`检查路径：${path.join(kbRoot, "wiki")}`);
console.log("");

section("孤立页面（没有被其他页面引用）", orphanPages.map((item) => `孤立: ${displayPage(item)}`), "（无孤立页面）");
section("断链（被链接但不存在的页面）", warningRows("broken_wikilink").map((item) => item.startsWith("  ") ? item : `断链: [[${item.replace(/（.*$/, "")}]]`), "（无断链）");
section("index 一致性（index.md 有记录但文件缺失）", indexMissingTargets.map((item) => `index 有但文件缺失: ${item}`), "（index 与文件一致）");
section("反向 index 一致性（文件存在但 index.md 未收录）", indexUnlistedPaths.map((item) => `未收录: ${displayPage(item)}`), "（所有页面均已收录）");
section("图片资产一致性（image_paths 声明但文件缺失）", imageIssues.map((item) => `缺失: ${path.posix.basename(item.source_path, ".md")} → ${item.image_path}`), "（无缺失图片）");

console.log("--- source-signal 覆盖情况 ---");
console.log(`  已参与：${sourceSignal.ok}`);
console.log(`  缺少 sources 字段：${sourceSignal.missing_sources}`);
console.log(`  sources 为空：${sourceSignal.empty_sources}`);
console.log(`  sources 格式无效：${sourceSignal.invalid_sources}`);
console.log(`  当前不参与：${sourceSignal.not_applicable}`);
for (const [reason, label] of [
  ["missing_sources", "缺少 sources 字段"],
  ["empty_sources", "sources 为空"],
  ["invalid_sources", "sources 格式无效"]
]) {
  const pages = sourceSignal.pages.filter((item) => item.reason === reason);
  if (!pages.length) continue;
  console.log("");
  console.log(`  ${label}：`);
  for (const page of pages) console.log(`  - ${page.path}`);
}
console.log("");

section("歧义链接（同名候选，未建边）", warningRows("ambiguous_wikilink"), "（无歧义链接）");
section("待创建链接（尚未建边）", warningRows("pending_wikilink"), "（无待创建链接）");
section("非规范路径链接（已按实际路径建边）", warningRows("noncanonical_wikilink"), "（无非规范路径链接）");
section("可移植路径冲突", warningRows("portable_path_collision"), "（无可移植路径冲突）");
section("待创建包装清理（目标现已存在）", report.stale_pending_wrappers.map((item) => `${item.source_path}: ${item.raw_link} → ${item.replacement}`), "（无待清理包装）");
console.log("=== 机械检查完成。矛盾检测、交叉引用、置信度抽查由 AI 继续执行 ===");
NODE
RENDER_STATUS=$?
[ "$RENDER_STATUS" -eq 0 ] || exit 1

if [ "$STRICT" -eq 1 ] && jq -e 'any(.groups[]; .severity == "error")' "$REPORT_FILE" > /dev/null 2>&1; then
  exit 2
fi
exit 0
