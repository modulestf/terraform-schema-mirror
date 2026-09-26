#!/bin/bash
# shellcheck disable=SC2319 # "$(rc=$?; ...)" passes the command's own status to check
# Offline check for the provider schema mirror: the publisher workflow
# (.github/workflows/schema-mirror.yml) as text, one named check per invariant, with a
# negative self-check that mutates temp copies and confirms the matching check fails on
# each; then a run of ci/mirror/build.sh with curl stubbed on fixture JSON. No network.
# Run: bash tests/schema-mirror-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
TPL="$SRC/.github/workflows/schema-mirror.yml"
BUILD="$SRC/ci/mirror/build.sh"
PROV="$SRC/ci/mirror/providers.txt"
README="$SRC/README.md"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/schema-mirror-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # name, command status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

for f in "$TPL" "$BUILD" "$PROV" "$README"; do
  [ -f "$f" ] || { echo "FAIL missing file: ${f#"$SRC"/}"; fails=$((fails + 1)); }
done
if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi

# Text helpers. Full-line comments are dropped first, because they configure nothing.
strip() { grep -v '^[[:space:]]*#' "$1"; }
step() { # extended regex; stdin -> every step whose first line matches it
  awk -v pat="$1" '/^      - / { on = ($0 ~ pat) } /^[^ ]|^  [^ ]|^    [^ ]/ { on = 0 } on'
}
runs() { # stdin -> the lines of every run: | block
  awk 'function ind(s) { match(s, /^ */); return RLENGTH }
    inr && ($0 ~ /^ *$/ || ind($0) > ri) { print; next }
    { inr = 0 }
    /^ +run: *\|/ { inr = 1; ri = ind($0) }'
}
job() { # job name; stdin -> the lines of that job
  awk -v j="$1" '$0 == "  " j ":" { on = 1; next } /^[^ ]|^  [^ ]/ { on = 0 } on'
}
reassign() { # variable name -> an extended regex for a line that sets it
  printf '%s' "(^|[^\$A-Za-z0-9_])$1(\\+?=|:)|(read|declare|typeset|export|local|unset|printf -v|mapfile)[^;|&]*[^\$A-Za-z0-9_]$1([^A-Za-z0-9_]|\$)"
}
page_re() { # file -> the SCHEMA_PAGE_RE value it sets, in YAML or shell form
  sed -nE "s/^ *SCHEMA_PAGE_RE[:=] *'(.*)' *$/\1/p" "$1"
}
readme_page_re() { # file -> the page_re value of the consumer example
  sed -nE "s/^page_re='(.*)'$/\1/p" "$1"
}

TOKEN_RE='github\.token|github\[|toJSON\( *github *\)|secrets\.|secrets\[|toJSON\( *secrets *\)|GH_TOKEN|GITHUB_TOKEN'
BRANCH_IF="    if: github.event_name == 'schedule' || github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
# The first lines of every build job step that reads a matrix value, in this order.
# shellcheck disable=SC2016 # shell text, not expanded here
MATRIX_ASSIGN='pr="$MATRIX_PROVIDER" ver="$MATRIX_VERSION" tag="$MATRIX_TAG"'
# shellcheck disable=SC2016 # shell text, not expanded here
MATRIX_CHECK='[[ "$pr" =~ ^[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}$ && "$ver" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ && "$tag" == "${pr/\//_}-v$ver" ]] || { echo "::error::the matrix entry is not a provider, a stable version and its tag"; exit 1; }'

run_checks() { # workflow, build script, providers file, README -> ok or FAIL line per invariant, with the reasons indented
  local t b p r pj bj
  # Always run in a command substitution. grep -q stops reading early, and under pipefail
  # the writer's SIGPIPE would fail a check at random, so pipefail is off in here.
  set +o pipefail
  t="$(strip "$1")"
  b="$(strip "$2")"
  pj="$(printf '%s\n' "$t" | job plan)"
  bj="$(printf '%s\n' "$t" | job build)"
  r() { # number, name, reasons (empty = holds)
    if [ -z "$3" ]; then echo "ok   $1 $2"; else echo "FAIL $1 $2"; printf '%s\n' "$3" | sed 's/^/       /'; fi
  }

  r 1 "triggers are schedule and workflow_dispatch only" "$(
    got="$(printf '%s\n' "$t" | awk '/^"?on"?:/ { on = 1; next } on && /^[^ ]/ { on = 0 } on' | sed -nE 's/^  ([A-Za-z_]+):.*/\1/p' | sort | tr '\n' ' ')"
    [ "$got" = "schedule workflow_dispatch " ] || echo "triggers: $got")"

  r 2 "plan runs only on the default branch; build only after plan, when it has work" "$(
    [ "$(printf '%s\n' "$t" | grep -cE '^    if:')" = 2 ] || echo "not exactly two job conditions"
    printf '%s\n' "$pj" | grep -qxF -- "$BRANCH_IF" || echo "the default branch condition of plan is missing"
    printf '%s\n' "$bj" | grep -qxF '    needs: plan' || echo "build does not need plan"
    printf '%s\n' "$bj" | grep -qxF "    if: needs.plan.outputs.count != '0'" || echo "the condition of build is not the plan count alone")"

  r 3 "permissions: none at the top, contents: write in the job, nothing else" "$(
    printf '%s\n' "$t" | grep -qxE 'permissions: *\{\} *' || echo "the top-level permissions are not {}"
    g="$(printf '%s\n' "$t" | sed 's/ #.*//' | grep -E ':[[:space:]]*"?(read|write|write-all|read-all)"?[[:space:]]*$')"
    [ "$g" = "$(printf '      contents: read\n      contents: write')" ] || printf 'grants:\n%s\n' "$g"
    printf '%s\n' "$pj" | grep -qxF '      contents: read' || echo "plan does not hold contents: read"
    printf '%s\n' "$bj" | grep -qxF '      contents: write' || echo "build does not hold contents: write")"

  r 4 "every action is pinned by a full SHA with a version comment" "$(
    printf '%s\n' "$t" | grep -E '^[ -]*uses:' | grep -vE 'uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]')"

  r 5 "every checkout sets persist-credentials: false" "$(
    c="$(printf '%s\n' "$t" | grep -cE 'uses: *actions/checkout@')"
    f="$(printf '%s\n' "$t" | grep -cE '^ +persist-credentials: *false *$')"
    [ "$c" -ge 1 ] && [ "$c" = "$f" ] || echo "$c checkouts, $f persist-credentials: false")"

  r 6 "GITHUB_TOKEN is the only secret and only the publish step gets it" "$(
    printf '%s\n' "$t" | grep -oE 'secrets\.[A-Za-z0-9_]+' | grep -vxF 'secrets.GITHUB_TOKEN'
    pub="$(printf '%s\n' "$t" | step '^      - name: Publish')"
    [ -n "$pub" ] || echo "no publish step"
    rest="$(printf '%s\n' "$t" | awk '/^      - / { on = ($0 !~ /^      - name: Publish/) } /^[^ ]|^  [^ ]|^    [^ ]/ { on = 1 } on')"
    printf '%s\n' "$rest" | grep -nE "$TOKEN_RE" | sed 's/^/token outside the publish step: /'
    printf '%s\n' "$pj" | grep -nE "$TOKEN_RE" | sed 's/^/token in the plan job: /')"

  r 7 "no model, id-token or cloud credential" "$(
    printf '%s\n' "$t" | grep -niE 'anthropic|claude|bedrock|openai|id-token|aws-actions|configure-aws|azure/login|google-github-actions/auth')"

  r 8 "no expression in a run block; inputs and matrix values only in env; max_versions checked" "$(
    printf '%s\n' "$t" | runs | grep -nF '${{'
    printf '%s\n' "$t" | grep -F 'inputs.' | grep -vE '^ +[A-Z_]+: \$\{\{ inputs\.[a-z_]+ ' | sed 's/^/input outside env: /'
    printf '%s\n' "$t" | grep -F 'matrix.' | grep -vE '^      MATRIX_[A-Z]+: \$\{\{ matrix\.[a-z]+ \}\} *$' | sed 's/^/matrix value outside the build job env: /'
    printf '%s\n' "$pj" | step '^      - name: Plan' | grep -qF '[[ "$MAX_VERSIONS" =~ ^[0-9]{1,3}$ ]] && [ "$MAX_VERSIONS" -ge 1 ] && [ "$MAX_VERSIONS" -le 250 ]' || echo "MAX_VERSIONS is not checked"
    printf '%s\n' "$pj" | step '^      - name: Plan' | grep -nE "$(reassign MAX_VERSIONS)" | sed 's/^/MAX_VERSIONS set in the plan step: /')"

  r 9 "one run at a time, never cancelled" "$(
    printf '%s\n' "$t" | grep -qxE 'concurrency: *' || echo "no workflow concurrency"
    printf '%s\n' "$t" | grep -qE '^  group: *[^ ]' || echo "no concurrency group"
    printf '%s\n' "$t" | grep -qE '^  cancel-in-progress: *false *$' || echo "cancel-in-progress is not false")"

  r 10 "every job has a timeout" "$(
    j="$(printf '%s\n' "$t" | grep -cE '^    runs-on:')"
    m="$(printf '%s\n' "$t" | grep -cE '^    timeout-minutes: *[0-9]+ *$')"
    [ "$j" -ge 2 ] && [ "$j" = "$m" ] || echo "$j jobs, $m timeouts")"

  r 11 "a release is a draft until its assets are uploaded, and deleted on failure" "$(
    pub="$(printf '%s\n' "$t" | step '^      - name: Publish')"
    d1="$(printf '%s\n' "$pub" | grep -nF -- '-F draft=true' | head -n 1 | cut -d: -f1)"
    up="$(printf '%s\n' "$pub" | grep -nF 'uploads.github.com' | head -n 1 | cut -d: -f1)"
    d2="$(printf '%s\n' "$pub" | grep -nF -- '-F draft=false -f make_latest=false' | head -n 1 | cut -d: -f1)"
    rb="$(printf '%s\n' "$pub" | grep -nF 'draft="$(gh api "repos/$GITHUB_REPOSITORY/releases/$id" --jq .draft)"' | head -n 1 | cut -d: -f1)"
    dl="$(printf '%s\n' "$pub" | grep -nE 'gh api -X DELETE "repos/\$GITHUB_REPOSITORY/releases/\$id"' | head -n 1 | cut -d: -f1)"
    [ -n "$d1" ] && [ -n "$up" ] && [ -n "$d2" ] && [ "$d1" -lt "$up" ] && [ "$up" -lt "$d2" ] || echo "not draft, upload, publish (not latest) in that order"
    printf '%s\n' "$pub" | grep -cF 'make_latest=false' | grep -qx 2 || echo "a release may become the latest"
    [ -n "$rb" ] && [ -n "$dl" ] && [ "$rb" -lt "$dl" ] || echo "a failed release is not read back and deleted"
    printf '%s\n' "$pub" | grep -qF 'if [ "$draft" = true ]; then' || echo "the delete is not limited to a draft"
    printf '%s\n' "$pub" | grep -qF 'sha256sum --strict --quiet -c SHA256SUMS' || echo "the checksums are not checked before upload")"

  r 12 "pages are built by ci/mirror/build.sh in the build step only; published tags are skipped" "$(
    printf '%s\n' "$t" | step '^      - name: Build' | grep -qF 'ci/mirror/build.sh build "$pr" "$ver" "$out/$tag"' || echo "the build step does not run build.sh build"
    printf '%s\n' "$t" | step '^      - name: Publish' | grep -nE 'build\.sh|(^|[^a-z])curl ' | sed 's/^/publish step: /'
    printf '%s\n' "$pj" | grep -nF 'build.sh build' | sed 's/^/plan job: /'
    printf '%s\n' "$pj" | grep -qF 'ci/mirror/build.sh select "$pr" "$tags" ' || echo "plan does not pass the tag list to select"
    printf '%s\n' "$b" | grep -qF -- '-v p="${ns}_${name}"' && printf '%s\n' "$b" | grep -qF '!((p "-v" $0) in t)' || echo "select does not skip a published tag"
    printf '%s\n' "$pj" | grep -qF 'tag="${pr/\//_}-v$ver"' || echo "the tag does not join namespace and name with _"
    printf '%s\n' "$t" | grep -qF 'tarball="${pr/\//_}-$ver.tar.gz"' || echo "the tarball name does not join namespace and name with _"
    printf '%s\n' "$b" | grep -qF 'tarball="${ns}_${name}-${ver}.tar.gz"' || echo "build.sh does not join namespace and name with _")"

  r 13 "SCHEMA_PAGE_RE in build.sh equals the README's consumer pattern, and the workflow's if it sets one" "$(
    a="$(page_re "$2")" m="$(readme_page_re "$4")" w="$(page_re "$1")"
    [ -n "$a" ] && [ "$(printf '%s\n' "$a" | wc -l)" = 1 ] || echo "build.sh does not set SCHEMA_PAGE_RE exactly once"
    [ -n "$m" ] && [ "$(printf '%s\n' "$m" | wc -l)" = 1 ] || echo "the README does not set page_re exactly once"
    [ "$a" = "$m" ] || echo "build.sh: $a; README: $m"
    [ -z "$w" ] || [ "$w" = "$a" ] || echo "build.sh: $a; workflow: $w"
    printf '%s\n' "$b" | grep -qE '\[\[ "\$p" =~ \$SCHEMA_PAGE_RE' || echo "no path is checked against SCHEMA_PAGE_RE")"

  r 14 "build.sh calls the registry over HTTPS only" "$(
    c="$(printf '%s\n' "$b" | grep -E '(^|[^a-z])curl ')"
    [ -n "$c" ] || echo "no curl call"
    printf '%s\n' "$c" | grep -vF -- "--proto '=https'" | sed 's/^/without --proto =https: /'
    printf '%s\n' "$c" | grep -vF '"https://registry.terraform.io/$1"' | sed 's/^/another host: /'
    printf '%s\n' "$c" | grep -vF -- '-A "$USER_AGENT"' | sed 's/^/without a User-Agent: /'
    printf '%s\n' "$b" | grep -nF 'http://' | sed 's/^/plain http: /')"

  r 15 "build.sh packs regular files only, from a checked list" "$(
    printf '%s\n' "$b" | grep -qF 'find "$stage" -mindepth 1 ! -type f ! -type d' || echo "no refusal of a link or special file"
    printf '%s\n' "$b" | grep -qF "find . -type f -printf '%P\\n'" || echo "the list is not regular files"
    printf '%s\n' "$b" | grep -E '^ *tar ' | grep -qE -- '--no-recursion .*-T "\$work/files"' || echo "tar is not limited to the list")"

  r 16 "globbing is off in build.sh and in every run block" "$(
    printf '%s\n' "$b" | grep -qxF 'set -f' || echo "build.sh"
    n="$(printf '%s\n' "$t" | grep -cE '^ +run: *\|')"
    s="$(printf '%s\n' "$t" | runs | grep -cxE ' +set -f')"
    [ "$n" = "$s" ] || echo "$n run blocks, $s with set -f")"

  r 17 "providers.txt lines are a provider name, at most one minimum, then versions to skip" "$(
    grep -v '^[[:space:]]*#' "$3" | sed 's/#.*//' | awk 'NF' | while read -r pr rest; do
      [[ "$pr" =~ ^[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}$ ]] || echo "bad provider: $pr"
      set -f
      # shellcheck disable=SC2086 # words of the line; globbing is off
      set -- $rest
      set +f
      [[ "${1:-}" == ">="* ]] && { [[ "$1" =~ ^\>=[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || echo "bad minimum: $1"; shift; }
      for v in "$@"; do [[ "$v" =~ ^![0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || echo "bad version to skip: $v"; done
    done)"

  r 18 "plain ASCII" "$(LC_ALL=C grep -nP '[^\x20-\x7e\t]' "$1" "$2" "$3" "$4")"

  r 19 "a job builds one version, reports its fetches and fails when it fails; a run is capped" "$(
    bs="$(printf '%s\n' "$bj" | step '^      - name: Build')"
    printf '%s\n' "$b" | grep -qF 'die() { [ -n "${fetched:-}" ] && echo "$fetched";' || echo "build.sh does not report fetches on failure"
    printf '%s\n' "$bs" | grep -qxF '          pages="$(ci/mirror/build.sh build "$pr" "$ver" "$out/$tag")"' || echo "pages is not build.sh's output"
    printf '%s\n' "$bs" | grep -A1 -F 'echo "::error::$tag was not built after' | tail -n 1 | grep -qxE ' +exit 1' || echo "a failed build does not fail the job"
    printf '%s\n' "$bj" | grep -qE "^      MIRROR_MAX_PAGES: *'?[0-9]+'? *$" || echo "no page cap in the build job"
    ps="$(printf '%s\n' "$pj" | step '^      - name: Plan')"
    printf '%s\n' "$ps" | grep -qE '\| head -n "\$MAX_VERSIONS" > "\$planned\.run"$' || echo "the versions of a run are not capped"
    printf '%s\n' "$ps" | grep -E '^ +jq ' | grep -qE '"\$planned\.run"$' || echo "the matrix is not the capped list")"

  r 20 "the publish step uploads exactly the files build.sh writes" "$(
    w="$(printf '%s\n' "$b" | grep -E '^ *mv -- "\$work/out/' | grep -oE '"\$work/out/[^"]+"' | sed -E 's|"\$work/out/(.*)"|\1|' | sort | tr '\n' ' ')"
    u="$(printf '%s\n' "$t" | step '^      - name: Publish' | sed -nE 's/^ *for f in (.*); do$/\1/p' | tr -d '"' | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"
    [ -n "$w" ] && [ "$w" = "$u" ] || echo "build.sh writes: $w; the publish step uploads: $u")"

  r 21 "the build step timeout fits a capped version and leaves time to publish under six hours" "$(
    tm="$(printf '%s\n' "$bj" | sed -nE 's/^    timeout-minutes: *([0-9]+) *$/\1/p')"
    st="$(printf '%s\n' "$bj" | step '^      - name: Build' | sed -nE 's/^        timeout-minutes: *([0-9]+) *$/\1/p')"
    mp="$(printf '%s\n' "$bj" | sed -nE "s/^ +MIRROR_MAX_PAGES: *'?([0-9]+)'? *$/\\1/p")"
    [ -n "$tm" ] && [ -n "$st" ] && [ -n "$mp" ] || echo "job timeout ${tm:-none}, build step timeout ${st:-none}, page cap ${mp:-none}"
    [ -n "$tm" ] && [ "$tm" -lt 360 ] || echo "the job timeout ${tm:-none} is not under six hours"
    [ -n "$tm" ] && [ -n "$st" ] && [ $((tm - st)) -ge 30 ] || echo "the build step timeout ${st:-none} is within 30 minutes of the job timeout ${tm:-none}"
    # One second per page, above the 0.8 s the pause and the call take.
    [ -n "$st" ] && [ -n "$mp" ] && [ "$mp" -le $((st * 60)) ] || echo "a version of ${mp:-none} pages does not fit ${st:-none} minutes")"

  r 22 "build runs the plan's matrix, fail-fast off, max-parallel bounded 1-6" "$(
    printf '%s\n' "$bj" | grep -qxF '        include: ${{ fromJSON(needs.plan.outputs.matrix) }}' || echo "the matrix is not the plan output"
    printf '%s\n' "$bj" | grep -qxF '      fail-fast: false' || echo "fail-fast is not false"
    printf '%s\n' "$bj" | grep -qxF '      max-parallel: ${{ fromJSON(needs.plan.outputs.max_parallel) }}' || echo "max-parallel is not the plan output"
    printf '%s\n' "$pj" | grep -qxF '      max_parallel: ${{ steps.plan.outputs.max_parallel }}' || echo "plan does not output max_parallel"
    ps="$(printf '%s\n' "$pj" | step '^      - name: Plan')"
    ck="$(printf '%s\n' "$ps" | grep -nxF '          [[ "$MAX_PARALLEL" =~ ^[1-6]$ ]] || { echo "::error::max_parallel must be a number from 1 to 6"; exit 1; }' | head -n 1 | cut -d: -f1)"
    wr="$(printf '%s\n' "$ps" | grep -nxF '            echo "max_parallel=$MAX_PARALLEL"' | head -n 1 | cut -d: -f1)"
    [ -n "$ck" ] && [ -n "$wr" ] && [ "$ck" -lt "$wr" ] || echo "max_parallel is not checked to 1-6 before it is output"
    printf '%s\n' "$ps" | grep -nE "$(reassign MAX_PARALLEL)" | sed 's/^/MAX_PARALLEL set in the plan step: /')"

  r 23 "every build job step that reads a matrix value checks it first" "$(
    n=0
    while IFS= read -r nm; do
      s="$(printf '%s\n' "$bj" | step "^      - name: $nm\$")"
      printf '%s\n' "$s" | grep -qF 'MATRIX_' || continue
      n=$((n + 1))
      first="$(printf '%s\n' "$s" | runs | sed 's/^ *//' | awk 'NF' | head -n 4)"
      want="$(printf '%s\n' 'set -uo pipefail' 'set -f' "$MATRIX_ASSIGN" "$MATRIX_CHECK")"
      [ "$first" = "$want" ] || echo "step $nm does not check the matrix values first"
    done <<< "$(printf '%s\n' "$bj" | sed -nE 's/^      - name: (.*)$/\1/p')"
    [ "$n" -ge 2 ] || echo "$n steps read matrix values")"

  r 24 "the plan interleaves providers by rank, then caps the run" "$(
    ps="$(printf '%s\n' "$pj" | step '^      - name: Plan')"
    printf '%s\n' "$ps" | grep -qxF '              printf '"'"'%s %s %s %s %s\n'"'"' "$rank" "$idx" "$tag" "$pr" "$ver" >> "$planned"' || echo "a planned line is not rank, provider index, tag, provider, version"
    sl="$(printf '%s\n' "$ps" | grep -E '^ +sort .*"\$planned\.run"$' | sed 's/^ *//')"
    [ -n "$sl" ] || echo "no sort of the planned list"
    # Run the template's own line on a fixture: provider 1 has four versions, provider 2 two.
    d="$(mktemp -d "$TMP/il.XXXXXX")"
    printf '%s\n' "1 1 a-v4 a 4" "2 1 a-v3 a 3" "3 1 a-v2 a 2" "4 1 a-v1 a 1" "1 2 b-v2 b 2" "2 2 b-v1 b 1" > "$d/p"
    got="$(cd "$d" && planned="$d/p" MAX_VERSIONS=5 bash -c "$sl" 2>&1 && tr '\n' ' ' < "$d/p.run")"
    [ "$got" = "a-v4 a 4 b-v2 b 2 a-v3 a 3 b-v1 b 1 a-v2 a 2 " ] || echo "interleaved and capped at 5: $got")"

  r 25 "select drops the versions to skip and refuses a malformed one" "$(
    printf '%s\n' "$b" | grep -qF 'index(skip, " " $0 " ") { next }' || echo "select does not drop a skipped version"
    printf '%s\n' "$b" | grep -qF '[[ "$a" =~ ^!([0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6})$ ]] || die "not a version to skip: $a"' || echo "a version to skip is not checked")"
}

out="$(run_checks "$TPL" "$BUILD" "$PROV" "$README")"
printf '%s\n' "$out"
fails=$((fails + $(printf '%s\n' "$out" | grep -c '^FAIL')))

mutate() { # name, check number, file to change (t, b, p or r), filter function applied to it
  local d="$TMP/mut.$2.$RANDOM" o
  mkdir -p "$d"
  cp "$TPL" "$d/t"; cp "$BUILD" "$d/b"; cp "$PROV" "$d/p"; cp "$README" "$d/r"
  "$4" < "$d/$3" > "$d/$3.new" && mv "$d/$3.new" "$d/$3"
  if cmp -s "$d/t" "$TPL" && cmp -s "$d/b" "$BUILD" && cmp -s "$d/p" "$PROV" && cmp -s "$d/r" "$README"; then
    check "self-check: $1 (the mutation changed nothing)" 1; return
  fi
  o="$(run_checks "$d/t" "$d/b" "$d/p" "$d/r")"
  printf '%s\n' "$o" | grep -q "^FAIL $2 "
  check "self-check: $1 fails check $2" "$?"
}
add_push() { awk '{ print } /^on:/ { print "  push:" }'; }
any_branch() { sed -E "s/^    if: .*/    if: always()/"; }
write_all() { sed -E 's/^permissions: *\{\} *$/permissions: write-all/'; }
id_token() { awk '{ print } /^      contents: write/ { print "      id-token: write" }'; }
unpin() { sed -E '0,/@[0-9a-f]{40}/s/@[0-9a-f]{40}/@v6/'; }
persist() { sed 's/persist-credentials: false/persist-credentials: true/'; }
# shellcheck disable=SC2016 # workflow text, not shell
token_in_build() { awk '/^      - name: Build/ { print; print "        env:"; print "          GH_TOKEN: ${{ github.token }}"; next } { print }'; }
# shellcheck disable=SC2016 # workflow text, not shell
other_secret() { sed 's/GH_TOKEN: \${{ github.token }}/GH_TOKEN: ${{ secrets.RELEASE_PAT }}/'; }
model() { cat; printf '      - uses: anthropics/claude-code-action@%s # v1\n' 0000000000000000000000000000000000000000; }
# shellcheck disable=SC2016 # workflow text, not shell
input_in_run() { sed 's/^          set -f$/          set -f\n          echo "${{ inputs.max_versions }}"/'; }
no_input_check() { grep -vF '[[ "$MAX_VERSIONS" =~'; }
# shellcheck disable=SC2016 # workflow text, not shell
matrix_outside_env() { sed 's/^  build:$/&\n    name: build ${{ matrix.tag }}/'; }
cancel() { sed 's/cancel-in-progress: false/cancel-in-progress: true/'; }
no_timeout() { grep -vE '^    timeout-minutes:'; }
no_draft() { sed 's/ -F draft=true//'; }
no_delete() { grep -vE 'gh api -X DELETE'; }
no_sums() { sed 's/sha256sum --strict --quiet -c SHA256SUMS/true/'; }
other_script() { sed 's|ci/mirror/build.sh build|./fetch.sh build|'; }
curl_in_publish() { awk '{ print } /^          ok=1$/ { print "          curl -fsS https://registry.terraform.io/v1/providers" }'; }
token_bracket() { sed "s/^      MATRIX_TAG: .*/&\\n      T: \${{ github['token'] }}/"; }
token_tojson() { sed "s/^      MATRIX_TAG: .*/&\\n      X: \${{ toJSON(github) }}/"; }
secrets_tojson() { sed "s/^      MATRIX_TAG: .*/&\\n      X: \${{ toJSON(secrets) }}/"; }
reassign_versions() { sed 's/^          \[\[ "\$MAX_VERSIONS" =~ .*/&\n          MAX_VERSIONS=999/'; }
reassign_parallel() { sed 's/^          \[\[ "\$MAX_PARALLEL" =~ .*/&\n          MAX_PARALLEL=9/'; }
no_interleave() { sed 's/sort -s -n -k1,1 -k2,2 "\$planned"/sort -s -n -k2,2 -k1,1 "$planned"/'; }
no_rank() { sed 's/"\$rank" "\$idx" "\$tag"/"1" "$idx" "$tag"/'; }
no_skip_drop() { grep -vF 'index(skip, " " $0 " ") { next }'; }
loose_skip() { sed 's/\^!(\[0-9\]{1,6}\\.\[0-9\]{1,6}\\.\[0-9\]{1,6})\$/^!(.*)$/'; }
bad_skip() { cat; echo "hashicorp/random >=1.0.0 !1.0"; }
skip_before_minimum() { cat; echo "hashicorp/random !1.0.0 >=1.0.0"; }
no_tag_skip() { sed 's/!((p "-v" \$0) in t)/1/'; }
build_in_plan() { awk '{ print } /^          : > "\$planned"$/ { print "          ci/mirror/build.sh build hashicorp/aws 6.0.0 x" }'; }
no_tags_to_select() { sed 's/build.sh select "\$pr" "\$tags" /build.sh select "$pr" \/dev\/null /'; }
loose_re() { sed '0,/{0,127}/s/{0,127}/{0,255}/'; }
# shellcheck disable=SC2016 # workflow text, not shell
tpl_page_re() { awk '/^jobs:/ { print "env:"; print "  SCHEMA_PAGE_RE: '"'"'^.*$'"'"'" } { print }'; }
readme_loose_re() { sed "0,/^page_re='/s/{0,127}/{0,255}/"; }
readme_two_re() { awk '{ print } /^page_re=/ { print }'; }
no_path_check() { grep -vF '[[ "$p" =~ $SCHEMA_PAGE_RE ]] || die'; }
no_proto() { sed "s/ --proto '=https'//"; }
other_host() { sed 's|"https://registry.terraform.io/$1"|"https://example.invalid/$1"|'; }
no_link_refusal() { grep -vF '! -type f ! -type d'; }
recursive_tar() { sed 's/ --no-recursion//'; }
no_set_f_build() { grep -vxF 'set -f'; }
no_set_f_tpl() { awk '/^          set -f$/ && !done { done = 1; next } { print }'; }
bad_provider() { cat; echo "Hashicorp/AWS"; }
bare_minimum() { cat; echo "hashicorp/random 1.0.0"; }
two_minimums() { cat; echo "hashicorp/random >=1.0.0 >=2.0.0"; }
non_ascii() { cat; printf '# a dash \xe2\x80\x94 here\n'; }
publish_latest() { sed 's/-F draft=false -f make_latest=false/-F draft=false/'; }
no_readback() { grep -vF -- '--jq .draft)"'; }
delete_any() { sed 's/if \[ "\$draft" = true \]; then/if true; then/'; }
dash_tag() { sed 's|tag="${pr/\\//_}-v$ver"|tag="${pr/\\//-}-v$ver"|'; }
dash_tarball() { sed 's|tarball="${ns}_${name}-${ver}.tar.gz"|tarball="$ns-$name-$ver.tar.gz"|'; }
no_ua() { sed 's/ -A "\$USER_AGENT"//'; }
plan_write() { sed 's/^      contents: read$/      contents: write/'; }
build_always() { sed "s/^    if: needs.plan.outputs.count != '0'$/    if: always()/"; }
no_needs() { grep -vxF '    needs: plan'; }
# shellcheck disable=SC2016 # workflow text, not shell
token_in_plan() { awk '/^      - name: Plan/ { print; print "        env:"; print "          GH_TOKEN: ${{ github.token }}"; next } { print }'; }
failed_build_passes() { awk '/::error::\$tag was not built after/ { print; getline; next } { print }'; }
no_run_cap() { sed 's/ | head -n "\$MAX_VERSIONS"//'; }
fail_fast() { sed 's/fail-fast: false/fail-fast: true/'; }
wide_parallel() { sed 's/"\$MAX_PARALLEL" =~ ^\[1-6\]\$/"$MAX_PARALLEL" =~ ^[0-9]+$/'; }
# shellcheck disable=SC2016 # workflow text, not shell
other_matrix() { sed 's/include: \${{ fromJSON(needs.plan.outputs.matrix) }}/include: ${{ fromJSON(inputs.matrix) }}/'; }
no_recheck_build() { awk -v c="$MATRIX_CHECK" '$0 == "          " c && !done { done = 1; next } { print }'; }
no_recheck_publish() { awk -v c="$MATRIX_CHECK" '$0 == "          " c && ++n == 2 { next } { print }'; }
no_notice_upload() { sed 's/for f in "\$tarball" manifest.json NOTICE SHA256SUMS; do/for f in "$tarball" manifest.json SHA256SUMS; do/'; }
long_timeout() { sed -E 's/^    timeout-minutes: 240$/    timeout-minutes: 400/'; }
close_step_timeout() { sed -E 's/^        timeout-minutes: *[0-9]+$/        timeout-minutes: 230/'; }
big_page_cap() { sed -E "s/^      MIRROR_MAX_PAGES: '[0-9]+'/      MIRROR_MAX_PAGES: '20000'/"; }
no_fetch_report() { sed 's/die() { \[ -n "${fetched:-}" \] \&\& echo "$fetched"; /die() { /'; }

mutate "a push trigger" 1 t add_push
mutate "a job condition for any branch" 2 t any_branch
mutate "build run always" 2 t build_always
mutate "build without needs: plan" 2 t no_needs
mutate "write-all at the top" 3 t write_all
mutate "id-token: write in the job" 3 t id_token
mutate "contents: write in plan" 3 t plan_write
mutate "an action pinned by tag" 4 t unpin
mutate "persist-credentials: true" 5 t persist
mutate "the token in the build step" 6 t token_in_build
mutate "the token in the plan job" 6 t token_in_plan
mutate "another secret in the publish step" 6 t other_secret
mutate "github['token'] in the build job env" 6 t token_bracket
mutate "toJSON(github) in the build job env" 6 t token_tojson
mutate "toJSON(secrets) in the build job env" 6 t secrets_tojson
mutate "a model action" 7 t model
mutate "an input expression in a run block" 8 t input_in_run
mutate "the max_versions check removed" 8 t no_input_check
mutate "a matrix value outside the env" 8 t matrix_outside_env
mutate "MAX_VERSIONS set again after its check" 8 t reassign_versions
mutate "cancel-in-progress: true" 9 t cancel
mutate "the timeout removed" 10 t no_timeout
mutate "the release not created as a draft" 11 t no_draft
mutate "a failed release not deleted" 11 t no_delete
mutate "the checksum check removed" 11 t no_sums
mutate "a publish that may become the latest release" 11 t publish_latest
mutate "a failed release deleted without reading it back" 11 t no_readback
mutate "a failed release deleted even when published" 11 t delete_any
mutate "another build script" 12 t other_script
mutate "a registry call in the publish step" 12 t curl_in_publish
mutate "a build in the plan job" 12 t build_in_plan
mutate "select not given the tag list" 12 t no_tags_to_select
mutate "a published tag not skipped by select" 12 b no_tag_skip
mutate "a tag joined with -" 12 t dash_tag
mutate "a tarball name joined with -" 12 b dash_tarball
mutate "a loosened SCHEMA_PAGE_RE in build.sh" 13 b loose_re
mutate "a loosened page_re in the README" 13 r readme_loose_re
mutate "page_re set twice in the README" 13 r readme_two_re
mutate "another SCHEMA_PAGE_RE in the workflow" 13 t tpl_page_re
mutate "the page path check removed" 13 b no_path_check
mutate "curl without --proto =https" 14 b no_proto
mutate "curl to another host" 14 b other_host
mutate "curl without a User-Agent" 14 b no_ua
mutate "the link refusal removed" 15 b no_link_refusal
mutate "tar recursing into directories" 15 b recursive_tar
mutate "globbing on in build.sh" 16 b no_set_f_build
mutate "globbing on in a run block" 16 t no_set_f_tpl
mutate "a bad provider line" 17 p bad_provider
mutate "a minimum without >=" 17 p bare_minimum
mutate "two minimums on a line" 17 p two_minimums
mutate "a malformed version to skip" 17 p bad_skip
mutate "a version to skip before the minimum" 17 p skip_before_minimum
mutate "a non-ASCII character" 18 t non_ascii
mutate "build.sh silent about fetches on failure" 19 b no_fetch_report
mutate "a failed build that does not fail the job" 19 t failed_build_passes
mutate "the run version cap removed" 19 t no_run_cap
mutate "NOTICE dropped from the upload loop" 20 t no_notice_upload
mutate "a job timeout over six hours" 21 t long_timeout
mutate "a build step timeout within 30 minutes of the job timeout" 21 t close_step_timeout
mutate "a page cap that does not fit the build step" 21 t big_page_cap
mutate "fail-fast: true" 22 t fail_fast
mutate "max_parallel not bounded to 6" 22 t wide_parallel
mutate "a matrix not from the plan output" 22 t other_matrix
mutate "MAX_PARALLEL set again after its check" 22 t reassign_parallel
mutate "no matrix check in the build step" 23 t no_recheck_build
mutate "no matrix check in the publish step" 23 t no_recheck_publish
mutate "providers ordered before rank" 24 t no_interleave
mutate "no rank in a planned line" 24 t no_rank
mutate "skipped versions not dropped" 25 b no_skip_drop
mutate "a version to skip not checked" 25 b loose_skip

# --- build.sh with curl stubbed ---------------------------------------------------------
# The stub serves fixture files keyed on the URL path, logs each call, and refuses a call
# without --proto =https or to another host. Nothing reaches the network.
FIX="$TMP/fix"
mkdir -p "$TMP/bin" "$FIX"
cat > "$TMP/bin/curl" <<STUB
#!/bin/bash
url="\${*: -1}"
echo "\$url" >> "$TMP/curl.log"
ua=none; prev=""
for a in "\$@"; do [ "\$prev" = -A ] && ua="\$a"; prev="\$a"; done
echo "ua \$ua" >> "$TMP/ua.log"
case " \$* " in *" --proto =https "*) ;; *) echo "no-proto \$url" >> "$TMP/curl.log"; exit 2 ;; esac
case "\$url" in https://registry.terraform.io/*) ;; *) echo "other-host \$url" >> "$TMP/curl.log"; exit 6 ;; esac
f="$FIX/\$(printf '%s' "\${url#https://registry.terraform.io/}" | tr '/' '_').json"
[ -f "\$f" ] || exit 22
cat "\$f"
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" MIRROR_DELAY=0
calls() { cat "$TMP/curl.log" 2>/dev/null; }
reset() { rm -f "$TMP/curl.log"; }

vs=""
for v in 0.9.0 1.0.0 1.1.0 1.1.1 1.2.0 1.3.0-beta1 1.10.0 2.0.0 2.0.1 v2.1.0; do vs="$vs{\"version\":\"$v\"},"; done
echo "{\"versions\":[${vs%,}]}" > "$FIX/v1_providers_hashicorp_demo_versions.json"
doc() { # id, title, slug, category, language
  printf '{"id":"%s","title":"%s","slug":"%s","category":"%s","language":"%s"}' "$@"
}
page() { # id, category, content -> the v2 document
  jq -n --arg id "$1" --arg c "$2" --arg t "$3" '{ data: { id: $id, type: "provider-docs", attributes: { category: $c, language: "hcl", content: $t } } }' > "$FIX/v2_provider-docs_$1.json"
}
{
  printf '{"docs":['
  doc 101 alpha alpha resources hcl; printf ,
  doc 102 beta beta resources hcl; printf ,
  doc 201 gamma gamma data-sources hcl; printf ,
  doc 103 alpha alpha resources python; printf ,
  doc 104 overview index overview hcl; printf ,
  doc 301 ../evil ../evil resources hcl; printf ,
  doc 302 a/b a/b resources hcl; printf ,
  doc 303 Upper Upper resources hcl; printf ,
  doc 304 x.md x.md data-sources hcl; printf ,
  doc 305 'link\n..\/..\/x' 'link\n..\/..\/x' resources hcl; printf ,
  doc 306 dup dup resources hcl; printf ,
  doc 307 dup dup resources hcl; printf ,
  doc 12a bad bad resources hcl; printf ,
  doc 308 other mismatch resources hcl; printf ,
  doc 105 delta delta resources hcl; printf ,
  doc 309 delta delta_v2 resources hcl; printf ,
  doc 106 delta delta resources python
  printf ']}\n'
} > "$FIX/v1_providers_hashicorp_demo_2.0.1.json"
jq -e . "$FIX/v1_providers_hashicorp_demo_2.0.1.json" > /dev/null || { echo "FAIL the fixture does not parse"; exit 1; }
page 101 resources $'# alpha\n'
page 102 resources $'# beta\n'
page 201 data-sources $'# gamma\n'
# 105 is valid on its own, but 309 shares its title, so the warm workflow could not look it
# up: neither is kept. 106 shares it too, in another language, which does not count.
for id in 301 302 303 304 305 306 307 308 105 309; do page "$id" resources hostile; done
# 1.2.0: the second page comes back with another id, so the version must not be built.
printf '{"docs":[%s,%s]}\n' "$(doc 101 alpha alpha resources hcl)" "$(doc 999 zeta zeta resources hcl)" > "$FIX/v1_providers_hashicorp_demo_1.2.0.json"
jq -n '{ data: { id: "998", attributes: { category: "resources", language: "hcl", content: "x" } } }' > "$FIX/v2_provider-docs_999.json"

: > "$TMP/tags0"
printf '%s\n' hashicorp_demo-v2.0.0 hashicorp_demo-v1.1.0 hashicorp_other-v1.0.0 hashicorp_demo-v1.2 > "$TMP/tags1"
reset
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" | tr '\n' ' ')"
check "select: every stable version, newest first, pre-releases and v-prefixed left out" "$([ "$sel" = "2.0.1 2.0.0 1.10.0 1.2.0 1.1.1 1.1.0 1.0.0 0.9.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags1" | tr '\n' ' ')"
check "select: a version whose tag exists is skipped, and only that provider's exact tag counts" "$([ "$sel" = "2.0.1 1.10.0 1.2.0 1.1.1 1.0.0 0.9.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" '>=1.2.0' | tr '\n' ' ')"
check "select: a minimum is inclusive and compares numerically" "$([ "$sel" = "2.0.1 2.0.0 1.10.0 1.2.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags1" '>=1.1.1' | tr '\n' ' ')"
check "select: a minimum and published tags together" "$([ "$sel" = "2.0.1 1.10.0 1.2.0 1.1.1 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" '>=9.0.0')"
check "select: a minimum above every version selects nothing and succeeds" "$(rc=$?; [ "$rc" = 0 ] && [ -z "$sel" ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" '>=1.0.0' '!2.0.0' '!1.2.0' '!9.9.9' | tr '\n' ' ')"
check "select: versions to skip are dropped after the minimum" "$([ "$sel" = "2.0.1 1.10.0 1.1.1 1.1.0 1.0.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags1" '!0.9.0' | tr '\n' ' ')"
check "select: a version to skip without a minimum, with published tags" "$([ "$sel" = "2.0.1 1.10.0 1.2.0 1.1.1 1.0.0 " ]; echo $?)"
# One argument each; a space inside one is part of it.
for bad in "1.0.0" ">=1.0" ">1.0.0" ">=1.0.0-beta1" "!1.0" "!v1.0.0" "!1.0.0-beta1" '!1.0.0;x' "!../x" "!" "!1.0.0 !2.0.0" ""; do
  reset
  "$BUILD" select hashicorp/demo "$TMP/tags0" "$bad" > /dev/null 2>&1
  check "select: refuses the argument '$bad' before any call" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(calls)" ]; echo $?)"
done
# Several arguments, split on spaces: each word is valid alone, the order or count is not.
for bad in "!1.0.0 >=1.0.0" ">=1.0.0 >=2.0.0" ">=1.0.0 1.0.0"; do
  reset
  read -r -a words <<< "$bad"
  "$BUILD" select hashicorp/demo "$TMP/tags0" "${words[@]}" > /dev/null 2>&1
  check "select: refuses the arguments '$bad' before any call" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(calls)" ]; echo $?)"
done
reset
"$BUILD" select hashicorp/demo "$TMP/no-such-file" > /dev/null 2>&1
check "select: refuses a missing tags file before any call" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(calls)" ]; echo $?)"

reset
o1="$TMP/out1"
n="$("$BUILD" build hashicorp/demo 2.0.1 "$o1" 2> "$TMP/b1.err")"
check "build: succeeds with 3 pages" "$([ "$n" = 3 ]; echo $?)"
tb="$o1/hashicorp_demo-2.0.1.tar.gz"
check "build: the output holds exactly the tar, manifest.json, NOTICE and SHA256SUMS" "$([ "$(ls "$o1" | tr '\n' ' ')" = "NOTICE SHA256SUMS hashicorp_demo-2.0.1.tar.gz manifest.json " ]; echo $?)"
check "build: NOTICE names the license, its URL and the registry source" "$(grep -qF 'Mozilla Public' "$o1/NOTICE" && grep -qF 'https://mozilla.org/MPL/2.0/' "$o1/NOTICE" \
  && grep -qxF 'https://registry.terraform.io/v1/providers/hashicorp/demo/2.0.1' "$o1/NOTICE"; echo $?)"
check "build: registry calls carry the mirror's User-Agent" "$(grep -qxF 'ua provider-schema-mirror' "$TMP/ua.log" && [ "$(sort -u "$TMP/ua.log" | wc -l)" = 1 ]; echo $?)"
check "build: the tar holds the three pages at their page paths" "$([ "$(tar -tzf "$tb" | tr '\n' ' ')" = "hashicorp/demo/2.0.1/data-sources/gamma.md hashicorp/demo/2.0.1/resources/alpha.md hashicorp/demo/2.0.1/resources/beta.md " ]; echo $?)"
check "build: every tar entry is a regular file owned by 0/0 at mtime 0" "$([ -z "$(tar -tvzf "$tb" | grep -vE '^-rw-r--r-- 0/0 +[0-9]+ 1970-01-01 00:00 ')" ]; echo $?)"
check "build: a page holds the document content" "$([ "$(tar -xOzf "$tb" hashicorp/demo/2.0.1/resources/alpha.md)" = "# alpha" ]; echo $?)"
check "build: SHA256SUMS covers the tar, the manifest and NOTICE and verifies" "$(cd "$o1" && [ "$(awk '{ print $2 }' SHA256SUMS | tr '\n' ' ')" = "hashicorp_demo-2.0.1.tar.gz manifest.json NOTICE " ] && sha256sum --strict --quiet -c SHA256SUMS; echo $?)"
check "build: the manifest names the provider, version, pages, ids and source" "$(jq -e '.format == 1 and .provider == "hashicorp/demo" and .version == "2.0.1" and .pages == 3
  and ([.docs[].id] | sort) == ["101", "102", "201"] and .tarball == "hashicorp_demo-2.0.1.tar.gz" and .license == "MPL-2.0"
  and .source == "https://registry.terraform.io/v1/providers/hashicorp/demo/2.0.1" and (.built_at | test("^[0-9-]{10}T[0-9:]{8}Z$"))' "$o1/manifest.json" > /dev/null; echo $?)"
check "build: hostile, duplicate, mismatched and same-title documents are never fetched" "$([ -z "$(calls | grep -E 'provider-docs/(30[1-9]|12a|105)')" ]; echo $?)"
check "build: only the three pages are fetched, over HTTPS from the registry" "$([ "$(calls | grep -c 'provider-docs/')" = 3 ] && [ -z "$(calls | grep -E '^(no-proto|other-host)')" ]; echo $?)"
check "build: the eleven skipped documents are reported" "$(grep -q ': 11 documents skipped' "$TMP/b1.err"; echo $?)"
check "build: nothing is written outside the output directory" "$([ ! -e "$TMP/evil" ] && [ ! -e "$TMP/x" ] && [ ! -e "$TMP/out1/../evil.md" ]; echo $?)"
"$BUILD" build hashicorp/demo 2.0.1 "$TMP/out2" > /dev/null 2>&1
check "build: the same pages give the same tar" "$(cmp -s "$tb" "$TMP/out2/hashicorp_demo-2.0.1.tar.gz"; echo $?)"

reset
n="$("$BUILD" build hashicorp/demo 1.2.0 "$TMP/out3" 2> "$TMP/b3.err")"
check "build: a page that fails its checks fails the version and writes nothing" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out3" ]; echo $?)"
check "build: a failed build still reports the 2 pages it fetched" "$([ "$n" = 2 ]; echo $?)"
# 1.1.1: the third page's fetch itself fails (the stub has no document 777).
printf '{"docs":[%s,%s,%s]}\n' "$(doc 101 alpha alpha resources hcl)" "$(doc 102 beta beta resources hcl)" "$(doc 777 eta eta resources hcl)" \
  > "$FIX/v1_providers_hashicorp_demo_1.1.1.json"
reset
n="$("$BUILD" build hashicorp/demo 1.1.1 "$TMP/out6" 2> /dev/null)"
check "build: a failed page fetch fails the version and writes nothing" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out6" ]; echo $?)"
check "build: a failed fetch still reports the 3 fetches made, the failed one included" "$([ "$n" = 3 ] && [ "$(calls | grep -c 'provider-docs/')" = 3 ]; echo $?)"
reset
n="$(MIRROR_MAX_PAGES=2 "$BUILD" build hashicorp/demo 2.0.1 "$TMP/out4" 2> /dev/null)"
check "build: a version over the page cap is not built and no page is fetched" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out4" ] && [ -z "$(calls | grep provider-docs)" ] && [ "$n" = 0 ]; echo $?)"
"$BUILD" build hashicorp/demo 3.0.0 "$TMP/out5" > /dev/null 2>&1
check "build: a version with no document list is not built" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out5" ]; echo $?)"

mkdir "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/linkout"
reset
"$BUILD" build hashicorp/demo 2.0.1 "$TMP/linkout" > /dev/null 2>&1
check "build: a symbolic link as the output directory is refused" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(ls -A "$TMP/elsewhere")" ] && [ -z "$(calls)" ]; echo $?)"
"$BUILD" build hashicorp/demo 2.0.1 "$o1" > /dev/null 2>&1
check "build: an existing output directory is refused" "$([ $? != 0 ]; echo $?)"

for bad in "../demo 2.0.1" "hashicorp/../demo 2.0.1" "Hashicorp/demo 2.0.1" "hashicorp/demo/x 2.0.1" "hashicorp 2.0.1" \
  "hashicorp/demo 2.0.1/../../x" "hashicorp/demo 2.0.1-beta1" "hashicorp/demo v2.0.1"; do
  reset
  read -r pr ver <<< "$bad"
  "$BUILD" build "$pr" "$ver" "$TMP/out-hostile" > /dev/null 2>&1
  check "build: refuses the hostile argument '$bad' before any call" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out-hostile" ] && [ -z "$(calls)" ]; echo $?)"
done
reset
"$BUILD" select ../demo "$TMP/tags0" > /dev/null 2>&1
check "select: refuses a hostile provider name before any call" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(calls)" ]; echo $?)"

if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
