#!/bin/bash
# proof.sh — measure what the README claims and write its Proof section.
#
# Usage:
#   scripts/proof.sh                 # aggregate this machine's usage log, time a dry run,
#                                    # save docs/proof/metrics.json, rewrite the README section
#   scripts/proof.sh --collect FILE  # aggregate the usage log into FILE (no timing, no README)
#   scripts/proof.sh --render        # print the README Proof section from docs/proof/metrics.json
#   scripts/proof.sh --validate FILE # fail when a metric has no value, unit, date, kind, or command
#
# Field data is the local, content-free usage log that each finished grind
# writes (TG_USAGE_LOG, default ~/.local/state/taskgrind/usage.jsonl): counts,
# seconds, the backend name, and the stop reason code. Nothing is uploaded.
# The machine label is a salted hash; the salt stays in
# ${XDG_STATE_HOME:-~/.local/state}/taskgrind/proof-salt.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METRICS="${TG_PROOF_METRICS:-$ROOT/docs/proof/metrics.json}"
README="${TG_PROOF_README:-$ROOT/README.md}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/taskgrind"
USAGE="${TG_USAGE_LOG:-$STATE/usage.jsonl}"
CMD="scripts/proof.sh"
# The day field recording shipped. A headline row with no field data names it.
RECORDING_SINCE="2026-10-27"

machine_label() {
  local salt_file="$STATE/proof-salt"
  if [ ! -s "$salt_file" ]; then
    mkdir -p "$(dirname "$salt_file")"
    (umask 077 && od -An -tx1 -N16 /dev/urandom | tr -d ' \n' >"$salt_file")
  fi
  printf 'm-%s' "$(printf '%s:%s' "$(cat "$salt_file")" "$(hostname)" | shasum -a 256 | cut -c1-10)"
}

# Median of 5 dry runs against a scratch repo, in ms (engineering health, not field data).
dry_run_ms() {
  local repo _ start end
  repo="$(mktemp -d "${TMPDIR:-/tmp}/proof-repo.XXXXXX")"
  git -C "$repo" init -q
  printf '# Tasks\n## P0\n- [ ] Proof task\n' >"$repo/TASKS.md"
  for _ in 1 2 3 4 5; do
    start="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    "$ROOT/bin/taskgrind" --dry-run 1 "$repo" >/dev/null 2>&1 || true
    end="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    echo $((end - start))
  done | sort -n | sed -n 3p
  rm -rf "$repo"
}

validate() {
  jq -e '
    (.metrics | length > 0) and
    ([.metrics | to_entries[] | select(
        (.value.value == null) or (.value.unit // "") == "" or (.value.date // "") == "" or
        (.value.kind // "") == "" or (.value.command // "") == "")] | length == 0)
  ' "$1" >/dev/null || {
    jq -r '.metrics | to_entries[] | . as $m | ["value","unit","date","kind","command"][]
      | select(($m.value[.] // "") == "") | "proof: metric \($m.key) has no \(.)"' "$1" 2>/dev/null
    echo "proof: $1 failed the check (each metric needs value, unit, date, kind, command)" >&2
    return 1
  }
}

collect() {
  local out="$1" dry="${2:-}" label today prev="{}" log
  label="$(machine_label)"
  today="$(date -u +%F)"
  [ -f "$out" ] && prev="$(cat "$out")"
  log="$USAGE"
  [ -f "$log" ] || log=/dev/null
  jq -s --arg label "$label" --arg today "$today" --arg cmd "$CMD" \
    --arg dry "$dry" --arg since "$RECORDING_SINCE" \
    --arg arch "$(uname -s | tr '[:upper:]' '[:lower:]') $(uname -m)" \
    --argjson prev "$prev" '
    def m($v; $unit; $detail; $kind; $name):
      { value: $v, unit: $unit, date: $today, kind: $kind, command: $cmd, detail: $detail,
        history: ((($prev.metrics[$name].history // []) | map(select(.date != $today))) + [{date: $today, value: $v}]) };
    def sum(f): map(f) | add // 0;
    map(select(type == "object" and .event == "grind" and (.ts | type) == "string")) | sort_by(.ts) as $all
    | (now - 30 * 86400 | todate) as $cut
    | [$all[] | select(.ts >= $cut)] as $g
    | ($g | length) as $n
    | ($g | sum(.sessions)) as $sessions
    | ($g | sum(.elapsed_s)) as $secs
    | (if $n == 0 then "none" else "\($g[0].ts[0:10]) to \($g[-1].ts[0:10])" end) as $range
    | ("local run, \($today), \($label) (\($arch))") as $local
    | {
        metrics: ({
          grinds_30d: m(if $n == 0 then null else $n end; "grinds"; "finished grinds, \($range)"; "real use"; "grinds_30d"),
          tasks_shipped_30d: m(if $n == 0 then null else ($g | sum(.shipped)) end; "tasks";
            "tasks removed from TASKS.md by a session, \($n) grinds, \($range)"; "real use"; "tasks_shipped_30d"),
          unattended_hours_30d: m(if $n == 0 then null else ($secs / 360 | floor) / 10 end; "h";
            "wall time of \($n) grinds, \($range)"; "real use"; "unattended_hours_30d"),
          tasks_per_hour: m(if $secs < 60 then null else (($g | sum(.shipped)) * 36000 / $secs | floor) / 10 end; "tasks/h";
            "tasks shipped / grind hours, \($range)"; "real use"; "tasks_per_hour"),
          grinds_ok_pct: m(if $n == 0 then null else (($g | map(select(.ok == true)) | length) * 100 / $n | floor) end; "%";
            "grinds that did not end in the failed phase, \($n) grinds"; "real use"; "grinds_ok_pct"),
          zero_ship_session_pct: m(if $sessions == 0 then null else (($g | sum(.zero_ship)) * 100 / $sessions | floor) end; "%";
            "sessions that shipped nothing, of \($sessions) sessions"; "real use"; "zero_ship_session_pct")
        } + (if $dry == "" then {} else {
          dry_run_ms: m(($dry | tonumber); "ms"; "median of 5 `taskgrind --dry-run` starts on a scratch repo";
            $local; "dry_run_ms") } end)
        | with_entries(select(.value.value != null))),
        charts: {
          shipped_by_day: ($g | group_by(.ts[0:10]) | map({day: .[0].ts[0:10], tasks: (map(.shipped) | add)}) | .[-14:]),
          stop_reasons_30d: ($g | group_by(.reason) | map({reason: .[0].reason, grinds: length}) | sort_by(-.grinds))
        },
        recording_since: $since,
        machines: (($prev.machines // {}) + { ($label): {
          date: $today, grinds_30d: $n, first_event: (($all[0].ts // "")[0:10]) } })
      }
  ' "$log" >"$out.tmp"
  mv "$out.tmp" "$out"
  validate "$out"
}

render() {
  jq -r '
    . as $f
    | ("not measured yet (field recording on since \($f.recording_since))") as $none
    | ([$f.machines[] | select(.grinds_30d > 0)] | length) as $n
    | def res(k): $f.metrics[k] as $x | if $x == null then $none else "\($x.value) \($x.unit) (\($x.detail))" end;
      def src(k): $f.metrics[k] as $x | if $x == null then "not measured yet" else "`docs/proof/metrics.json`, \($x.kind), n=\($n) machine(s)" end;
      def hist(k): ($f.metrics[k].history // []);
    "<!-- proof:start -->",
    "Every number below comes from `docs/proof/metrics.json`. `scripts/proof.sh` writes that file and this section.",
    "Headline rows are field outcomes from real grinds, never test numbers.",
    "Each finished grind appends one content-free line to a local usage log (`TG_USAGE_LOG`): counts, seconds, the backend, and the stop reason.",
    "",
    "Nothing is uploaded. Each machine aggregates its own log.",
    "",
    "| Claim | Theory | Metric | Result | Source |",
    "|---|---|---|---|---|",
    "| It works through `TASKS.md` unattended | Small batches that each end in a commit keep work flowing (Forsgren, Humble, Kim 2018, *Accelerate*) | tasks shipped, last 30 days | \(res("tasks_shipped_30d")) | \(src("tasks_shipped_30d")) |",
    "| It runs for hours without a person | A deadline plus guards replaces a person who restarts each session | grinds and their wall hours, last 30 days | \(if $f.metrics.grinds_30d == null then $none else "\(res("grinds_30d")); \(res("unattended_hours_30d"))" end) | \(src("unattended_hours_30d")) |",
    "| Sessions ship at a steady rate | Throughput is the outcome a work queue promises; it is the rate term in the Little law (Little 1961) | tasks shipped per grind hour | \(res("tasks_per_hour")) | \(src("tasks_per_hour")) |",
    "| Grinds end cleanly, not in a crash | Guards (stall, network, resume) turn failures into clean stops | grinds that did not end in the failed phase | \(res("grinds_ok_pct")) | \(src("grinds_ok_pct")) |",
    "| The stall guard limits wasted sessions | A run that ships nothing should stop early, not burn hours | sessions that shipped nothing | \(res("zero_ship_session_pct")) | \(src("zero_ship_session_pct")) |",
    "| Preflight catches setup errors before a long run | Fail fast: a check before launch is cheaper than a failed hour | preflight failures that a real grind would have hit | not measured yet (preflight writes no usage line; task `proof-preflight-field` in TASKS.md) | not measured yet |",
    "| `--resume` recovers an interrupted grind | Resume from the last commit keeps the deadline and counters | resumed grinds and their outcome | not measured yet (the usage line does not mark a resume; task `proof-resume-field` in TASKS.md) | not measured yet |",
    "",
    "Field data so far: \($n) machine(s) with grinds. Machines seen, each named by a salted hash: \(if ($f.machines | length) == 0 then "none" else ([$f.machines | to_entries[] | "`\(.key)` (\(.value.grinds_30d) grinds in 30 days, log since \(if .value.first_event == "" then "no event yet" else .value.first_event end), as of \(.value.date))"] | join("; ")) end).",
    "",
    "Engineering health (a local run, not field proof):",
    "",
    (if $f.metrics.dry_run_ms then "- `taskgrind --dry-run` start: \($f.metrics.dry_run_ms.value) ms (\($f.metrics.dry_run_ms.detail)); \($f.metrics.dry_run_ms.kind)" else "- `taskgrind --dry-run` start: not measured yet" end),
    "",
    (if ($f.charts.shipped_by_day | length) > 0 then
      ("Tasks shipped per day (real use):", "",
       "```mermaid", "xychart-beta", "  title \"Tasks shipped per day\"",
       "  x-axis [\($f.charts.shipped_by_day | map("\"" + .day[5:] + "\"") | join(", "))]",
       "  y-axis \"tasks\"",
       "  bar [\($f.charts.shipped_by_day | map(.tasks | tostring) | join(", "))]", "```", "",
       "How grinds stopped, last 30 days (real use):", "",
       "```mermaid", "pie title How grinds stopped, last 30 days",
       ($f.charts.stop_reasons_30d[] | "  \"\(.reason)\" : \(.grinds)"), "```")
    else
      ("No field chart yet: no grind has finished since recording started. The chart below is the dry-run start time per proof run (local run).", "",
       "```mermaid", "xychart-beta", "  title \"Dry-run start time (ms)\"",
       "  x-axis [\(hist("dry_run_ms") | map("\"" + .date[5:] + "\"") | join(", "))]",
       "  y-axis \"ms\"",
       "  line [\(hist("dry_run_ms") | map(.value | tostring) | join(", "))]", "```")
    end),
    "<!-- proof:end -->"
  ' "$METRICS"
}

write_readme() {
  local section tmp
  if ! grep -q '<!-- proof:start -->' "$README" || ! grep -q '<!-- proof:end -->' "$README"; then
    echo "proof: README needs both proof markers" >&2
    return 1
  fi
  section="$(render)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/proof-readme.XXXXXX")"
  SECTION="$section" awk '
    /<!-- proof:start -->/ { print ENVIRON["SECTION"]; skip = 1; next }
    /<!-- proof:end -->/ { skip = 0; next }
    !skip { print }
  ' "$README" >"$tmp"
  cat "$tmp" >"$README"
  rm -f "$tmp"
}

case "${1:-}" in
  --render) render ;;
  --validate) validate "${2:?usage: proof.sh --validate FILE}" ;;
  --collect) collect "${2:?usage: proof.sh --collect FILE}" ;;
  --help | -h) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" ;;
  "")
    mkdir -p "$(dirname "$METRICS")"
    collect "$METRICS" "$(dry_run_ms)"
    write_readme
    echo "proof: wrote docs/proof/metrics.json and the README Proof section"
    ;;
  *) echo "proof: unknown argument $1 (see --help)" >&2; exit 2 ;;
esac
