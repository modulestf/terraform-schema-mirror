#!/bin/bash
# Pick the provider versions to mirror, or build the schema bundle of one version.
# Run by schema-mirror.yml; see README.md.
#
#   build.sh select <namespace/name> <published tags file> [>=<minimum version>] [!<version>...]
#     Prints the versions to mirror, one per line, newest first: every stable version
#     (x.y.z, no pre-release) that the registry lists with plugin protocol 5 or 6, at or above the minimum when one is
#     given, not skipped with !<version>, whose tag <namespace>_<name>-v<version> is not a
#     line of the tags file.
#   build.sh build <namespace/name> <version> <output directory>
#     Installs that provider version with terraform init, which checks its signature and
#     checksums, and writes <output directory> with four files: the provider schema from
#     terraform providers schema -json as gzipped JSON, manifest.json, NOTICE and
#     SHA256SUMS. The output directory must not exist. On any failure it exits non-zero and
#     writes nothing: a partial build is never produced. On success it prints one line: the
#     number of resource schemas and of data source schemas.
#
# Environment: MIRROR_DELAY, seconds before each registry call (default 0.5);
# MIRROR_USER_AGENT, the User-Agent sent to the registry. terraform must be on PATH.
# Registry calls are made one at a time, over HTTPS only.
set -uo pipefail
set -f

NAME_RE='^[a-z0-9][a-z0-9-]{0,63}$'
VER_RE='^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$'
DELAY="${MIRROR_DELAY:-0.5}"
USER_AGENT="${MIRROR_USER_AGENT:-provider-schema-mirror}"

die() { echo "build.sh: $*" >&2; exit 1; }
[[ "$DELAY" =~ ^[0-9]{1,2}(\.[0-9]{1,3})?$ ]] || die "MIRROR_DELAY is not a number of seconds: $DELAY"
UA_RE='^[A-Za-z0-9][A-Za-z0-9 ./:+()_-]{0,99}$'
[[ "$USER_AGENT" =~ $UA_RE ]] || die "MIRROR_USER_AGENT has characters outside the allowed set"

reg() {
  sleep "$DELAY"
  curl -fsS -g --proto '=https' --max-time 30 --max-filesize 50000000 --retry 3 --retry-delay 5 -A "$USER_AGENT" "https://registry.terraform.io/$1"
}
provider() { # namespace/name -> sets ns and name, or exits
  ns="${1%%/*}" name="${1#*/}"
  [[ "$1" == */* && "$ns" =~ $NAME_RE && "$name" =~ $NAME_RE ]] || die "not a provider name: $1"
}

select_versions() { # namespace/name, file of published tags, optional ">=x.y.z", then "!x.y.z" skips
  local pr="$1" tags="$2" min="" skip=" " a all
  provider "$pr"
  [ -f "$tags" ] || die "not a tags file: $tags"
  shift 2
  if [[ "${1:-}" == ">="* ]]; then
    [[ "$1" =~ ^\>=([0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6})$ ]] || die "not a minimum version: $1"
    min="${BASH_REMATCH[1]}"
    shift
  fi
  for a in "$@"; do
    [[ "$a" =~ ^!([0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6})$ ]] || die "not a version to skip: $a"
    skip="$skip${BASH_REMATCH[1]} "
  done
  # Only versions that speak plugin protocol 5 or 6: current terraform cannot load one
  # built for protocol 4 (Terraform 0.11), so its schema cannot be read.
  all="$(reg "v1/providers/$ns/$name/versions" | jq -r '.versions[]? | select(any(.protocols[]?; test("^[56](\\.|$)"))) | .version' \
    | grep -E "$VER_RE" | sort -uV)"
  [ -n "$all" ] || die "no release list for $pr"
  # "_" joins namespace and name: neither may hold one, so a tag names one provider.
  # FILENAME, not NR == FNR: the tags file is empty before the first release.
  printf '%s\n' "$all" | awk -F. -v m="$min" -v p="${ns}_${name}" -v tf="$tags" -v skip="$skip" '
    BEGIN { split(m, a, ".") }
    FILENAME == tf { t[$0]; next }
    index(skip, " " $0 " ") { next }
    m != "" && ($1 + 0 < a[1] + 0 || ($1 + 0 == a[1] + 0 && ($2 + 0 < a[2] + 0 || ($2 + 0 == a[2] + 0 && $3 + 0 < a[3] + 0)))) { next }
    !((p "-v" $0) in t)' "$tags" - | sort -rV
}

build() { # namespace/name, version, output directory
  local pr="$1" ver="$2" out="$3" work key file tf h counts
  provider "$pr"
  [[ "$ver" =~ $VER_RE ]] || die "not a stable version: $ver"
  { [ -e "$out" ] || [ -L "$out" ]; } && die "the output directory exists: $out"
  work="$(mktemp -d)" || die "no temporary directory"
  # shellcheck disable=SC2064 # expand now: work is local
  trap "rm -rf -- '$work'" EXIT
  mkdir "$work/tf" "$work/out" || die "no working directory"
  key="registry.terraform.io/$ns/$name"
  # "_" joins namespace and name: neither may hold one, so the name is unambiguous.
  file="${ns}_${name}-${ver}.schema.json.gz"

  # One provider, one exact version, nothing else. No CLI config file, so no mirror or
  # override on the runner changes where the provider comes from.
  printf 'terraform {\n  required_providers {\n    mirrored = {\n      source  = "%s"\n      version = "= %s"\n    }\n  }\n}\n' \
    "$ns/$name" "$ver" > "$work/tf/main.tf" || die "no main.tf"
  tfx() { (cd "$work/tf" && CHECKPOINT_DISABLE=1 TF_IN_AUTOMATION=1 TF_CLI_CONFIG_FILE=/dev/null TF_CLI_ARGS='' terraform "$@"); }
  tf="$(tfx version -json | jq -r .terraform_version)" && [[ "$tf" =~ $VER_RE ]] || die "no terraform, or not a stable release: $tf"
  tfx init -backend=false -input=false -no-color >&2 || die "$pr $ver: terraform init failed"
  tfx providers schema -json > "$work/schema.json" || die "$pr $ver: terraform providers schema failed"
  jq -e --arg k "$key" '(.format_version | type == "string") and (.provider_schemas | keys == [$k])
    and (((.provider_schemas[$k].resource_schemas // {}) | length) + ((.provider_schemas[$k].data_source_schemas // {}) | length) > 0)' \
    "$work/schema.json" > /dev/null 2>&1 || die "$pr $ver: the schema is not one provider's, or it is empty"
  h="$(grep -oE '"(h1|zh):[A-Za-z0-9+/=]+"' "$work/tf/.terraform.lock.hcl" | tr -d '"' | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    && jq -e 'any(startswith("h1:"))' <<< "$h" > /dev/null || die "$pr $ver: no provider hash in the lock file"

  # Sorted keys, no whitespace, no gzip name or time: the same schema gives the same bytes.
  jq -S -c . "$work/schema.json" | gzip -n -9 > "$work/out/$file" || die "$pr $ver: cannot write the schema"
  jq -S --arg k "$key" --arg p "$pr" --arg v "$ver" --arg tf "$tf" --arg f "$file" --argjson h "$h" \
    --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.provider_schemas[$k] as $s |
    { format: 2, provider: $p, version: $v, file: $f, format_version: .format_version, terraform_version: $tf,
      source: ("https://registry.terraform.io/v1/providers/" + $p + "/" + $v), provider_hashes: $h,
      license: "MPL-2.0", built_at: $built,
      resources: (($s.resource_schemas // {}) | length), data_sources: (($s.data_source_schemas // {}) | length),
      ephemeral_resources: (($s.ephemeral_resource_schemas // {}) | length), functions: (($s.functions // {}) | length) }' \
    "$work/schema.json" > "$work/out/manifest.json" || die "$pr $ver: no manifest"
  counts="$(jq -r '"\(.resources) \(.data_sources)"' "$work/out/manifest.json")" || die "$pr $ver: no counts"
  printf '%s\n' \
    "The file $file is the schema of the Terraform provider $pr, version $ver," \
    "as printed by terraform providers schema -json (Terraform $tf) from the provider" \
    "release listed by the Terraform registry:" \
    "https://registry.terraform.io/v1/providers/$pr/$ver" \
    "" \
    "The provider is licensed by its authors under the Mozilla Public License 2.0" \
    "(MPL-2.0): https://mozilla.org/MPL/2.0/" \
    "Its source form is the provider's own source repository." > "$work/out/NOTICE" || die "$pr $ver: no notice"
  (cd "$work/out" && sha256sum -- "$file" manifest.json NOTICE > SHA256SUMS) || die "$pr $ver: no checksums"
  mkdir -- "$out" || die "$pr $ver: cannot create $out"
  mv -- "$work/out/$file" "$work/out/manifest.json" "$work/out/NOTICE" "$work/out/SHA256SUMS" "$out/" \
    || { rm -rf -- "$out"; die "$pr $ver: cannot write $out"; }
  echo "$counts"
}

case "${1:-}" in
select) [ "$#" -ge 3 ] || die "usage: build.sh select <namespace/name> <published tags file> [>=<minimum version>] [!<version>...]"; shift; select_versions "$@" ;;
build) [ "$#" = 4 ] || die "usage: build.sh build <namespace/name> <version> <output directory>"; shift; build "$@" ;;
*) die "usage: build.sh select|build ..." ;;
esac
