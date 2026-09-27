#!/bin/bash
# shellcheck disable=SC2319 # "$(rc=$?; ...)" passes the command's own status to check
# Offline check for the provider schema mirror: the publisher workflow
# (.github/workflows/schema-mirror.yml) as text, one named check per invariant, with a
# negative self-check that mutates temp copies and confirms the matching check fails on
# each; then a run of ci/mirror/build.sh with curl and terraform stubbed on fixture JSON.
# No network.
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
TOKEN_RE='github\.token|github\[|toJSON\( *github *\)|secrets\.|secrets\[|toJSON\( *secrets *\)|GH_TOKEN|GITHUB_TOKEN'
BRANCH_IF="    if: github.event_name == 'schedule' || github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
# The first lines of every build job step that reads a matrix value, in this order.
# shellcheck disable=SC2016 # shell text, not expanded here
MATRIX_ASSIGN='pr="$MATRIX_PROVIDER" ver="$MATRIX_VERSION" tag="$MATRIX_TAG"'
# shellcheck disable=SC2016 # shell text, not expanded here
MATRIX_CHECK='[[ "$pr" =~ ^[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}$ && "$ver" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ && "$tag" == "${pr/\//_}-v$ver" ]] || { echo "::error::the matrix entry is not a provider, a stable version and its tag"; exit 1; }'

run_checks() { # workflow, build script, providers file, README -> ok or FAIL line per invariant, with the reasons indented
  local t b p r pj bj uj
  # Always run in a command substitution. grep -q stops reading early, and under pipefail
  # the writer's SIGPIPE would fail a check at random, so pipefail is off in here.
  set +o pipefail
  t="$(strip "$1")"
  b="$(strip "$2")"
  pj="$(printf '%s\n' "$t" | job plan)"
  bj="$(printf '%s\n' "$t" | job build)"
  uj="$(printf '%s\n' "$t" | job publish)"
  r() { # number, name, reasons (empty = holds)
    if [ -z "$3" ]; then echo "ok   $1 $2"; else echo "FAIL $1 $2"; printf '%s\n' "$3" | sed 's/^/       /'; fi
  }

  r 1 "triggers are schedule and workflow_dispatch only" "$(
    got="$(printf '%s\n' "$t" | awk '/^"?on"?:/ { on = 1; next } on && /^[^ ]/ { on = 0 } on' | sed -nE 's/^  ([A-Za-z_]+):.*/\1/p' | sort | tr '\n' ' ')"
    [ "$got" = "schedule workflow_dispatch " ] || echo "triggers: $got")"

  r 2 "plan runs only on the default branch; build and publish only after plan, when it has work" "$(
    [ "$(printf '%s\n' "$t" | grep -cE '^    if:')" = 3 ] || echo "not exactly three job conditions"
    printf '%s\n' "$pj" | grep -qxF -- "$BRANCH_IF" || echo "the default branch condition of plan is missing"
    printf '%s\n' "$bj" | grep -qxF '    needs: plan' || echo "build does not need plan"
    printf '%s\n' "$bj" | grep -qxF "    if: needs.plan.outputs.count != '0'" || echo "the condition of build is not the plan count alone"
    printf '%s\n' "$uj" | grep -qxF '    needs: [plan, build]' || echo "publish does not need plan and build"
    # shellcheck disable=SC2016 # workflow text, not shell
    printf '%s\n' "$uj" | grep -qxF '    if: ${{ !cancelled() && needs.plan.outputs.count != '"'0'"' }}' || echo "the condition of publish is not the plan count unless cancelled")"

  r 3 "permissions: none at the top, contents: read in plan and build, write in publish only" "$(
    printf '%s\n' "$t" | grep -qxE 'permissions: *\{\} *' || echo "the top-level permissions are not {}"
    g="$(printf '%s\n' "$t" | sed 's/ #.*//' | grep -E ':[[:space:]]*"?(read|write|write-all|read-all)"?[[:space:]]*$')"
    [ "$g" = "$(printf '      contents: read\n      contents: read\n      contents: write')" ] || printf 'grants:\n%s\n' "$g"
    printf '%s\n' "$pj" | grep -qxF '      contents: read' || echo "plan does not hold contents: read"
    printf '%s\n' "$bj" | grep -qxF '      contents: read' || echo "build does not hold contents: read"
    printf '%s\n' "$uj" | grep -qxF '      contents: write' || echo "publish does not hold contents: write")"

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

  r 12 "the schema is built by ci/mirror/build.sh in the build job only; published tags are skipped" "$(
    printf '%s\n' "$bj" | step '^      - name: Build' | grep -qF 'ci/mirror/build.sh build "$pr" "$ver" "$out/$tag"' || echo "the build step does not run build.sh build"
    printf '%s\n' "$t" | step '^      - name: Publish' | grep -nE 'build\.sh|(^|[^a-z])curl ' | sed 's/^/publish step: /'
    printf '%s\n' "$uj" | grep -nE 'build\.sh|setup-terraform|actions/checkout@' | sed 's/^/publish job: /'
    printf '%s\n' "$pj" | grep -nF 'build.sh build' | sed 's/^/plan job: /'
    printf '%s\n' "$pj" | grep -qF 'ci/mirror/build.sh select "$pr" "$tags" ' || echo "plan does not pass the tag list to select"
    printf '%s\n' "$b" | grep -qF -- '-v p="${ns}_${name}"' && printf '%s\n' "$b" | grep -qF '!((p "-v" $0) in t)' || echo "select does not skip a published tag"
    printf '%s\n' "$pj" | grep -qF 'tag="${pr/\//_}-v$ver"' || echo "the tag does not join namespace and name with _"
    printf '%s\n' "$t" | grep -qF 'file="${pr/\//_}-$ver.schema.json.gz"' || echo "the schema file name does not join namespace and name with _"
    printf '%s\n' "$b" | grep -qF 'file="${ns}_${name}-${ver}.schema.json.gz"' || echo "build.sh does not join namespace and name with _")"

  r 13 "build.sh pins the exact version and keeps only a schema of that one provider, not empty" "$(
    printf '%s\n' "$b" | grep -qF 'version = "= %s"' || echo "main.tf does not pin the exact version"
    printf '%s\n' "$b" | grep -qF 'key="registry.terraform.io/$ns/$name"' || echo "the provider key is not the registry address"
    printf '%s\n' "$b" | grep -qF '(.provider_schemas | keys == [$k])' || echo "the schema is not checked to hold exactly the provider"
    printf '%s\n' "$b" | grep -qF '((.provider_schemas[$k].data_source_schemas // {}) | length) > 0)' || echo "an empty schema is not refused")"

  r 14 "build.sh calls the registry over HTTPS only" "$(
    c="$(printf '%s\n' "$b" | grep -E '(^|[^a-z])curl ')"
    [ -n "$c" ] || echo "no curl call"
    printf '%s\n' "$c" | grep -vF -- "--proto '=https'" | sed 's/^/without --proto =https: /'
    printf '%s\n' "$c" | grep -vF '"https://registry.terraform.io/$1"' | sed 's/^/another host: /'
    printf '%s\n' "$c" | grep -vF -- '-A "$USER_AGENT"' | sed 's/^/without a User-Agent: /'
    printf '%s\n' "$b" | grep -nF 'http://' | sed 's/^/plain http: /')"

  r 15 "terraform runs with no CLI config file, and the schema is written reproducibly" "$(
    printf '%s\n' "$b" | grep -qF 'TF_CLI_CONFIG_FILE=/dev/null' || echo "terraform may read a CLI config file"
    printf '%s\n' "$b" | grep -qF 'CHECKPOINT_DISABLE=1' || echo "the checkpoint call is not disabled"
    printf '%s\n' "$b" | grep -qF 'jq -S -c . "$work/schema.json" | gzip -n -9 > "$work/out/$file"' || echo "the schema is not normalized and gzipped without name and time")"

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

  r 19 "a job builds one version and fails when it fails; a run is capped" "$(
    bs="$(printf '%s\n' "$bj" | step '^      - name: Build')"
    printf '%s\n' "$bs" | grep -qxF '          if counts="$(ci/mirror/build.sh build "$pr" "$ver" "$out/$tag")"; then' || echo "the build step does not test the status of build.sh"
    printf '%s\n' "$bs" | grep -A1 -F 'echo "::error::$tag was not built' | tail -n 1 | grep -qxE ' +exit 1' || echo "a failed build does not fail the job"
    ps="$(printf '%s\n' "$pj" | step '^      - name: Plan')"
    printf '%s\n' "$ps" | grep -qE "\\| awk -v n=\"\\\$MAX_VERSIONS\" 'NR <= n' > \"\\\$planned\\.run\"\$" || echo "the versions of a run are not capped"
    printf '%s\n' "$ps" | grep -E '^ +jq ' | grep -qE '"\$planned\.run"$' || echo "the matrix is not the capped list")"

  r 20 "the publish step uploads exactly the files build.sh writes" "$(
    w="$(printf '%s\n' "$b" | grep -E '^ *mv -- "\$work/out/' | grep -oE '"\$work/out/[^"]+"' | sed -E 's|"\$work/out/(.*)"|\1|' | sort | tr '\n' ' ')"
    u="$(printf '%s\n' "$t" | step '^      - name: Publish' | sed -nE 's/^ *for f in (.*); do$/\1/p' | tr -d '"' | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"
    [ -n "$w" ] && [ "$w" = "$u" ] || echo "build.sh writes: $w; the publish step uploads: $u"
    # shellcheck disable=SC2016 # workflow text, not shell
    for a in '          name: ${{ env.MATRIX_TAG }}' '          path: ${{ runner.temp }}/mirror-out/${{ env.MATRIX_TAG }}'; do
      printf '%s\n' "$bj" | grep -qxF -- "$a" && printf '%s\n' "$uj" | grep -qxF -- "$a" || echo "the artifact steps differ from:$a"
    done
    printf '%s\n' "$t" | step '^      - name: Publish' | grep -qxF '          d="$RUNNER_TEMP/mirror-out/$tag"' || echo "the publish step does not read the downloaded bundle")"

  r 21 "the build step timeout leaves time to upload within a build job timeout of an hour at most" "$(
    tm="$(printf '%s\n' "$bj" | sed -nE 's/^    timeout-minutes: *([0-9]+) *$/\1/p')"
    st="$(printf '%s\n' "$bj" | step '^      - name: Build' | sed -nE 's/^        timeout-minutes: *([0-9]+) *$/\1/p')"
    [ -n "$tm" ] && [ -n "$st" ] || echo "job timeout ${tm:-none}, build step timeout ${st:-none}"
    [ -n "$tm" ] && [ "$tm" -le 60 ] || echo "the build job timeout ${tm:-none} is over an hour"
    [ -n "$tm" ] && [ -n "$st" ] && [ $((tm - st)) -ge 5 ] || echo "the build step timeout ${st:-none} is within 5 minutes of the job timeout ${tm:-none}")"

  r 22 "build and publish run the plan's matrix, fail-fast off, max-parallel bounded 1-6" "$(
    for j in build publish; do
      jt="$(printf '%s\n' "$t" | job "$j")"
      printf '%s\n' "$jt" | grep -qxF '        include: ${{ fromJSON(needs.plan.outputs.matrix) }}' || echo "the $j matrix is not the plan output"
      printf '%s\n' "$jt" | grep -qxF '      fail-fast: false' || echo "fail-fast is not false in $j"
      printf '%s\n' "$jt" | grep -qxF '      max-parallel: ${{ fromJSON(needs.plan.outputs.max_parallel) }}' || echo "max-parallel is not the plan output in $j"
    done
    printf '%s\n' "$pj" | grep -qxF '      max_parallel: ${{ steps.plan.outputs.max_parallel }}' || echo "plan does not output max_parallel"
    ps="$(printf '%s\n' "$pj" | step '^      - name: Plan')"
    ck="$(printf '%s\n' "$ps" | grep -nxF '          [[ "$MAX_PARALLEL" =~ ^[1-6]$ ]] || { echo "::error::max_parallel must be a number from 1 to 6"; exit 1; }' | head -n 1 | cut -d: -f1)"
    wr="$(printf '%s\n' "$ps" | grep -nxF '            echo "max_parallel=$MAX_PARALLEL"' | head -n 1 | cut -d: -f1)"
    [ -n "$ck" ] && [ -n "$wr" ] && [ "$ck" -lt "$wr" ] || echo "max_parallel is not checked to 1-6 before it is output"
    printf '%s\n' "$ps" | grep -nE "$(reassign MAX_PARALLEL)" | sed 's/^/MAX_PARALLEL set in the plan step: /')"

  r 23 "every run step that reads a matrix value checks it first" "$(
    n=0
    for j in "$bj" "$uj"; do
      while IFS= read -r nm; do
        s="$(printf '%s\n' "$j" | step "^      - name: $nm\$")"
        printf '%s\n' "$s" | runs | grep -qF 'MATRIX_' || continue
        n=$((n + 1))
        first="$(printf '%s\n' "$s" | runs | sed 's/^ *//' | awk 'NF' | head -n 4)"
        want="$(printf '%s\n' 'set -uo pipefail' 'set -f' "$MATRIX_ASSIGN" "$MATRIX_CHECK")"
        [ "$first" = "$want" ] || echo "step $nm does not check the matrix values first"
      done <<< "$(printf '%s\n' "$j" | sed -nE 's/^      - name: (.*)$/\1/p')"
    done
    [ "$n" -ge 2 ] || echo "$n steps read matrix values")"

  r 24 "the plan interleaves providers by rank, then caps the run" "$(
    ps="$(printf '%s\n' "$pj" | step '^      - name: Plan')"
    printf '%s\n' "$ps" | grep -qxF '              printf '"'"'%s %s %s %s %s\n'"'"' "$rank" "$idx" "$tag" "$pr" "$ver" >> "$planned"' || echo "a planned line is not rank, provider index, tag, provider, version"
    sl="$(printf '%s\n' "$ps" | grep -E '^ +sort .*"\$planned\.run"$' | sed 's/^ *//')"
    [ -n "$sl" ] || echo "no sort of the planned list"
    # Run the template's own line on a fixture: provider 1 has four versions, provider 2 two,
    # provider 3 many more ranked past the cap. Under pipefail, as in the step, a cap that stops
    # reading early (head) breaks the pipe of the writer before it and fails the plan.
    d="$(mktemp -d "$TMP/il.XXXXXX")"
    printf '%s\n' "1 1 a-v4 a 4" "2 1 a-v3 a 3" "3 1 a-v2 a 2" "4 1 a-v1 a 1" "1 2 b-v2 b 2" "2 2 b-v1 b 1" > "$d/p"
    seq 20000 | awk '{ print 99, 3, "z-v" $1, "z", $1 }' >> "$d/p"
    got="$(cd "$d" && planned="$d/p" MAX_VERSIONS=5 bash -o pipefail -c "$sl" 2>&1 && tr '\n' ' ' < "$d/p.run")"
    [ "$got" = "a-v4 a 4 b-v2 b 2 a-v3 a 3 b-v1 b 1 a-v2 a 2 " ] || echo "interleaved and capped at 5: ${got:0:200}")"

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
# shellcheck disable=SC2016 # workflow text, not shell
no_proto() { sed "s/ --proto '=https'//"; }
other_host() { sed 's|"https://registry.terraform.io/$1"|"https://example.invalid/$1"|'; }
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
dash_file() { sed 's|file="${ns}_${name}-${ver}.schema.json.gz"|file="$ns-$name-$ver.schema.json.gz"|'; }
no_ua() { sed 's/ -A "\$USER_AGENT"//'; }
plan_write() { sed 's/^      contents: read$/      contents: write/'; }
build_always() { sed "s/^    if: needs.plan.outputs.count != '0'$/    if: always()/"; }
no_needs() { grep -vxF '    needs: plan'; }
# shellcheck disable=SC2016 # workflow text, not shell
token_in_plan() { awk '/^      - name: Plan/ { print; print "        env:"; print "          GH_TOKEN: ${{ github.token }}"; next } { print }'; }
failed_build_passes() { awk '/::error::\$tag was not built/ { print; getline; next } { print }'; }
no_run_cap() { sed "s/ | awk -v n=\"\\\$MAX_VERSIONS\" 'NR <= n'//"; }
fail_fast() { sed 's/fail-fast: false/fail-fast: true/'; }
wide_parallel() { sed 's/"\$MAX_PARALLEL" =~ ^\[1-6\]\$/"$MAX_PARALLEL" =~ ^[0-9]+$/'; }
# shellcheck disable=SC2016 # workflow text, not shell
other_matrix() { sed 's/include: \${{ fromJSON(needs.plan.outputs.matrix) }}/include: ${{ fromJSON(inputs.matrix) }}/'; }
no_recheck_build() { C="$MATRIX_CHECK" awk 'BEGIN { c = ENVIRON["C"] } ''$0 == "          " c && !done { done = 1; next } { print }'; }
no_recheck_publish() { C="$MATRIX_CHECK" awk 'BEGIN { c = ENVIRON["C"] } ''$0 == "          " c && ++n == 2 { next } { print }'; }
no_notice_upload() { sed 's/for f in "\$file" manifest.json NOTICE SHA256SUMS; do/for f in "$file" manifest.json SHA256SUMS; do/'; }
long_timeout() { sed -E 's/^    timeout-minutes: 30$/    timeout-minutes: 90/'; }
close_step_timeout() { sed -E 's/^        timeout-minutes: *[0-9]+$/        timeout-minutes: 28/'; }

build_write() { awk '/^  build:$/ { b = 1 } /^  publish:$/ { b = 0 } b && /^      contents: read$/ { print "      contents: write"; next } { print }'; }
publish_always() { sed "s/^    if: \${{ !cancelled() \&\& needs.plan.outputs.count != '0' }}$/    if: always()/"; }
publish_no_build() { sed 's/^    needs: \[plan, build\]$/    needs: plan/'; }
checkout_in_publish() { sed 's/^      - name: Download the bundle$/      - uses: actions\/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0\n        with:\n          persist-credentials: false\n&/'; }
other_artifact() { sed '0,/^          name: \${{ env.MATRIX_TAG }}$/s//          name: bundle/'; }
loose_version() { sed 's/version = "= %s"/version = ">= %s"/'; }
loose_key() { sed 's/(.provider_schemas | keys == \[\$k\])/(.provider_schemas | has($k))/'; }
empty_ok() { sed 's/data_source_schemas \/\/ {}) | length) > 0)/data_source_schemas \/\/ {}) | length) >= 0)/'; }
cli_config() { sed 's/ TF_CLI_CONFIG_FILE=\/dev\/null//'; }
unsorted() { sed 's/jq -S -c \. "\$work\/schema.json"/jq -c . "$work\/schema.json"/'; }

mutate "a push trigger" 1 t add_push
mutate "a job condition for any branch" 2 t any_branch
mutate "build run always" 2 t build_always
mutate "build without needs: plan" 2 t no_needs
mutate "publish run always" 2 t publish_always
mutate "publish not after build" 2 t publish_no_build
mutate "write-all at the top" 3 t write_all
mutate "id-token: write in the job" 3 t id_token
mutate "contents: write in plan" 3 t plan_write
mutate "contents: write in build" 3 t build_write
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
mutate "a schema file name joined with -" 12 b dash_file
mutate "a checkout in the publish job" 12 t checkout_in_publish
mutate "a version range in main.tf" 13 b loose_version
mutate "a schema with other providers kept" 13 b loose_key
mutate "an empty schema kept" 13 b empty_ok
mutate "curl without --proto =https" 14 b no_proto
mutate "curl to another host" 14 b other_host
mutate "curl without a User-Agent" 14 b no_ua
mutate "terraform with the runner's CLI config" 15 b cli_config
mutate "schema keys not sorted" 15 b unsorted
mutate "globbing on in build.sh" 16 b no_set_f_build
mutate "globbing on in a run block" 16 t no_set_f_tpl
mutate "a bad provider line" 17 p bad_provider
mutate "a minimum without >=" 17 p bare_minimum
mutate "two minimums on a line" 17 p two_minimums
mutate "a malformed version to skip" 17 p bad_skip
mutate "a version to skip before the minimum" 17 p skip_before_minimum
mutate "a non-ASCII character" 18 t non_ascii
mutate "a failed build that does not fail the job" 19 t failed_build_passes
mutate "the run version cap removed" 19 t no_run_cap
mutate "NOTICE dropped from the upload loop" 20 t no_notice_upload
mutate "an artifact name that is not the tag" 20 t other_artifact
mutate "a build job timeout over an hour" 21 t long_timeout
mutate "a build step timeout within 30 minutes of the job timeout" 21 t close_step_timeout
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
for v in 0.9.0 1.0.0 1.1.0 1.1.1 1.2.0 1.3.0-beta1 1.10.0 2.0.0 2.0.1 v2.1.0; do vs="$vs{\"version\":\"$v\",\"protocols\":[\"5.0\"]},"; done
# Protocol 4 only (Terraform 0.11): left out. 4 and 5, or 6 alone: kept.
vs="$vs{\"version\":\"0.1.0\",\"protocols\":[\"4.0\"]},{\"version\":\"0.2.0\",\"protocols\":[\"4\"]},{\"version\":\"0.8.0\",\"protocols\":[\"4.0\",\"5.0\"]},{\"version\":\"3.0.0\",\"protocols\":[\"6.0\"]},{\"version\":\"0.3.0\"}"
echo "{\"versions\":[$vs]}" > "$FIX/v1_providers_hashicorp_demo_versions.json"
: > "$TMP/tags0"
printf '%s\n' hashicorp_demo-v2.0.0 hashicorp_demo-v1.1.0 hashicorp_other-v1.0.0 hashicorp_demo-v1.2 > "$TMP/tags1"
reset
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" | tr '\n' ' ')"
check "select: every stable protocol 5 or 6 version, newest first; pre-releases, v-prefixed and protocol 4 only left out" "$([ "$sel" = "3.0.0 2.0.1 2.0.0 1.10.0 1.2.0 1.1.1 1.1.0 1.0.0 0.9.0 0.8.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags1" | tr '\n' ' ')"
check "select: a version whose tag exists is skipped, and only that provider's exact tag counts" "$([ "$sel" = "3.0.0 2.0.1 1.10.0 1.2.0 1.1.1 1.0.0 0.9.0 0.8.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" '>=1.2.0' | tr '\n' ' ')"
check "select: a minimum is inclusive and compares numerically" "$([ "$sel" = "3.0.0 2.0.1 2.0.0 1.10.0 1.2.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags1" '>=1.1.1' | tr '\n' ' ')"
check "select: a minimum and published tags together" "$([ "$sel" = "3.0.0 2.0.1 1.10.0 1.2.0 1.1.1 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" '>=9.0.0')"
check "select: a minimum above every version selects nothing and succeeds" "$(rc=$?; [ "$rc" = 0 ] && [ -z "$sel" ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags0" '>=1.0.0' '!2.0.0' '!1.2.0' '!9.9.9' | tr '\n' ' ')"
check "select: versions to skip are dropped after the minimum" "$([ "$sel" = "3.0.0 2.0.1 1.10.0 1.1.1 1.1.0 1.0.0 " ]; echo $?)"
sel="$("$BUILD" select hashicorp/demo "$TMP/tags1" '!0.9.0' | tr '\n' ' ')"
check "select: a version to skip without a minimum, with published tags" "$([ "$sel" = "3.0.0 2.0.1 1.10.0 1.2.0 1.1.1 1.0.0 0.8.0 " ]; echo $?)"
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

# --- build.sh with terraform stubbed -----------------------------------------------------
# The stub logs each call with the CLI config and checkpoint settings it sees, answers
# version, init and providers schema from fixtures, and writes a lock file on init.
# TF_STUB picks the case; TF_STUB_VERSION the version it reports.
cat > "$TMP/bin/terraform" <<STUB
#!/bin/bash
echo "\$1 cfg=\${TF_CLI_CONFIG_FILE:-unset} cp=\${CHECKPOINT_DISABLE:-unset}" >> "$TMP/tf.log"
case "\$1" in
version) printf '{"terraform_version":"%s"}\n' "\${TF_STUB_VERSION:-1.16.4}" ;;
init)
  cp main.tf "$TMP/main.tf"
  [ "\${TF_STUB:-ok}" = init-fails ] && exit 1
  if [ "\${TF_STUB:-ok}" = no-hash ]; then
    printf 'provider "registry.terraform.io/hashicorp/demo" {\n  hashes = [\n    "zh:0123abcd",\n  ]\n}\n' > .terraform.lock.hcl
  else
    printf 'provider "registry.terraform.io/hashicorp/demo" {\n  hashes = [\n    "h1:AAAA+/=",\n    "zh:0123abcd",\n  ]\n}\n' > .terraform.lock.hcl
  fi ;;
providers) cat "$FIX/schema-\${TF_STUB:-ok}.json" ;;
*) exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/terraform"
tfcalls() { cat "$TMP/tf.log" 2>/dev/null; }
tfreset() { rm -f "$TMP/tf.log" "$TMP/main.tf"; }
k=registry.terraform.io/hashicorp/demo
jq -n --arg k "$k" '{ provider_schemas: { ($k): { resource_schemas: { demo_b: { version: 0 }, demo_a: { version: 1 } },
  data_source_schemas: { demo_c: { version: 0 } }, functions: { f: {} }, provider: {} } }, format_version: "1.0" }' > "$FIX/schema-ok.json"
cp "$FIX/schema-ok.json" "$FIX/schema-no-hash.json"
jq -n '{ format_version: "1.0", provider_schemas: { "registry.terraform.io/hashicorp/other": { resource_schemas: { x: {} } } } }' > "$FIX/schema-wrong-key.json"
jq -n --arg k "$k" '{ format_version: "1.0", provider_schemas: { ($k): { resource_schemas: { x: {} } },
  "registry.terraform.io/hashicorp/other": { resource_schemas: { y: {} } } } }' > "$FIX/schema-two.json"
jq -n --arg k "$k" '{ format_version: "1.0", provider_schemas: { ($k): { resource_schemas: {}, data_source_schemas: {} } } }' > "$FIX/schema-empty.json"
printf '{"format_version":' > "$FIX/schema-broken.json"

reset; tfreset
o1="$TMP/out1"
n="$("$BUILD" build hashicorp/demo 2.0.1 "$o1" 2> "$TMP/b1.err")"
check "build: succeeds and prints 2 resources and 1 data source" "$([ "$n" = "2 1" ]; echo $?)"
sf="$o1/hashicorp_demo-2.0.1.schema.json.gz"
check "build: the output holds exactly the schema, manifest.json, NOTICE and SHA256SUMS" "$([ "$(LC_ALL=C ls "$o1" | tr '\n' ' ')" = "NOTICE SHA256SUMS hashicorp_demo-2.0.1.schema.json.gz manifest.json " ]; echo $?)"
check "build: main.tf requires exactly one provider at exactly the version" "$(grep -qxF '      source  = "hashicorp/demo"' "$TMP/main.tf" \
  && grep -qxF '      version = "= 2.0.1"' "$TMP/main.tf" && [ "$(grep -c 'source' "$TMP/main.tf")" = 1 ]; echo $?)"
check "build: terraform runs with no CLI config file and the checkpoint off" "$([ "$(tfcalls | wc -l)" = 3 ] && [ -z "$(tfcalls | grep -v ' cfg=/dev/null cp=1$')" ]; echo $?)"
check "build: no registry call" "$([ -z "$(calls)" ]; echo $?)"
check "build: the schema is the fixture with sorted keys, compact" "$([ "$(gzip -dc "$sf")" = "$(jq -S -c . "$FIX/schema-ok.json")" ]; echo $?)"
check "build: the gzip header holds no name and no time" "$([ "$(od -An -tx1 -j3 -N5 "$sf" | tr -d ' \n')" = 0000000000 ]; echo $?)"
check "build: SHA256SUMS covers the schema, the manifest and NOTICE and verifies" "$(cd "$o1" && [ "$(awk '{ print $2 }' SHA256SUMS | tr '\n' ' ')" = "hashicorp_demo-2.0.1.schema.json.gz manifest.json NOTICE " ] && sha256sum --strict --quiet -c SHA256SUMS; echo $?)"
check "build: NOTICE names the license, its URL and the registry source" "$(grep -qF 'Mozilla Public' "$o1/NOTICE" && grep -qF 'https://mozilla.org/MPL/2.0/' "$o1/NOTICE" \
  && grep -qxF 'https://registry.terraform.io/v1/providers/hashicorp/demo/2.0.1' "$o1/NOTICE"; echo $?)"
check "build: the manifest names the provider, version, counts, hashes and source" "$(jq -e '.format == 2 and .provider == "hashicorp/demo" and .version == "2.0.1"
  and .file == "hashicorp_demo-2.0.1.schema.json.gz" and .resources == 2 and .data_sources == 1 and .ephemeral_resources == 0 and .functions == 1
  and .terraform_version == "1.16.4" and .format_version == "1.0" and .provider_hashes == ["h1:AAAA+/=", "zh:0123abcd"] and .license == "MPL-2.0"
  and .source == "https://registry.terraform.io/v1/providers/hashicorp/demo/2.0.1" and (.built_at | test("^[0-9-]{10}T[0-9:]{8}Z$"))' "$o1/manifest.json" > /dev/null; echo $?)"
"$BUILD" build hashicorp/demo 2.0.1 "$TMP/out2" > /dev/null 2>&1
check "build: the same schema gives the same bytes" "$(cmp -s "$sf" "$TMP/out2/hashicorp_demo-2.0.1.schema.json.gz"; echo $?)"

for c in init-fails wrong-key two empty broken no-hash; do
  TF_STUB="$c" "$BUILD" build hashicorp/demo 2.0.1 "$TMP/out-$c" > /dev/null 2>&1
  check "build: case $c fails the version and writes nothing" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out-$c" ]; echo $?)"
done
tfreset
TF_STUB_VERSION=1.17.0-beta1 "$BUILD" build hashicorp/demo 2.0.1 "$TMP/out-beta" > /dev/null 2>&1
check "build: a terraform that is not a stable release is refused before init" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out-beta" ] && [ -z "$(tfcalls | grep '^init')" ]; echo $?)"

mkdir "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/linkout"
tfreset
"$BUILD" build hashicorp/demo 2.0.1 "$TMP/linkout" > /dev/null 2>&1
check "build: a symbolic link as the output directory is refused" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(ls -A "$TMP/elsewhere")" ] && [ -z "$(tfcalls)" ]; echo $?)"
"$BUILD" build hashicorp/demo 2.0.1 "$o1" > /dev/null 2>&1
check "build: an existing output directory is refused" "$([ $? != 0 ]; echo $?)"

for bad in "../demo 2.0.1" "hashicorp/../demo 2.0.1" "Hashicorp/demo 2.0.1" "hashicorp/demo/x 2.0.1" "hashicorp 2.0.1" \
  "hashicorp/demo 2.0.1/../../x" "hashicorp/demo 2.0.1-beta1" "hashicorp/demo v2.0.1" 'hashicorp/demo 2.0.1"' ; do
  tfreset
  read -r pr ver <<< "$bad"
  "$BUILD" build "$pr" "$ver" "$TMP/out-hostile" > /dev/null 2>&1
  check "build: refuses the hostile argument '$bad' before any terraform call" "$(rc=$?; [ "$rc" != 0 ] && [ ! -e "$TMP/out-hostile" ] && [ -z "$(tfcalls)" ]; echo $?)"
done
reset
"$BUILD" select ../demo "$TMP/tags0" > /dev/null 2>&1
check "select: refuses a hostile provider name before any call" "$(rc=$?; [ "$rc" != 0 ] && [ -z "$(calls)" ]; echo $?)"

if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
