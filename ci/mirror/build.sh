#!/bin/bash
# Pick the provider versions to mirror, or build the schema page bundle of one version.
# Run by schema-mirror.yml.template; see README.md next to this file.
#
#   build.sh select <namespace/name> <minor lines> [<floor version>...]
#     Prints the versions to mirror, one per line: the newest patch of each of the latest
#     <minor lines> minor lines, plus each floor version that the registry lists. Stable
#     versions only.
#   build.sh build <namespace/name> <version> <output directory>
#     Fetches every hcl resource and data source page of that version from the Terraform
#     registry and writes <output directory> with four files: the tar.gz, manifest.json,
#     NOTICE and SHA256SUMS. The output directory must not exist. On any failure it exits
#     non-zero and writes nothing: a partial build is never produced. Either way it prints
#     one line, the number of pages it fetched from the registry, so the caller can count
#     the registry load of a failed build too.
#
# Environment: MIRROR_DELAY, seconds between registry calls (default 0.5); MIRROR_MAX_PAGES,
# the most pages one version may have (default 5000; a version with more is not built);
# MIRROR_USER_AGENT, the User-Agent sent to the registry.
# Registry calls are made one at a time, over HTTPS only, with the calls and checks of the
# warm workflow in ci/github/schema-cache.yml.template.
set -uo pipefail
set -f

# The same pattern as in ci/github/schema-cache.yml.template; tests/schema-mirror-test.sh
# keeps the two equal.
SCHEMA_PAGE_RE='^[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}/[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}/(resources|data-sources)/[a-z0-9][a-z0-9_]{0,127}\.md$'
NAME_RE='^[a-z0-9][a-z0-9-]{0,63}$'
VER_RE='^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$'
DELAY="${MIRROR_DELAY:-0.5}"
MAX_PAGES="${MIRROR_MAX_PAGES:-5000}"
USER_AGENT="${MIRROR_USER_AGENT:-provider-schema-mirror}"

# In build, fetched is set, and a failure still prints it on stdout (see the usage above).
die() { [ -n "${fetched:-}" ] && echo "$fetched"; echo "build.sh: $*" >&2; exit 1; }
[[ "$DELAY" =~ ^[0-9]{1,2}(\.[0-9]{1,3})?$ ]] || die "MIRROR_DELAY is not a number of seconds: $DELAY"
[[ "$MAX_PAGES" =~ ^[0-9]{1,6}$ ]] || die "MIRROR_MAX_PAGES is not a count: $MAX_PAGES"
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

select_versions() { # namespace/name, minor lines, floor versions
  local pr="$1" n="$2" all f
  provider "$pr"
  [[ "$n" =~ ^[0-9]{1,2}$ ]] && [ "$n" -ge 1 ] || die "not a count of minor lines: $n"
  shift 2
  all="$(reg "v1/providers/$ns/$name/versions" | jq -r '.versions[]?.version' | grep -E "$VER_RE" | sort -uV)"
  [ -n "$all" ] || die "no release list for $pr"
  {
    printf '%s\n' "$all" | awk -F. -v n="$n" '
      { k = $1 "." $2; if (!(k in last)) order[++m] = k; last[k] = $0 }
      END { for (i = m; i > m - n && i > 0; i--) print last[order[i]] }'
    for f in "$@"; do
      if [[ ! "$f" =~ $VER_RE ]]; then
        echo "::warning::the floor $f of $pr is not a stable version; skipped" >&2
      elif printf '%s\n' "$all" | grep -qxF -- "$f"; then
        echo "$f"
      else
        echo "::warning::the floor $f of $pr is not in the registry; skipped" >&2
      fi
    done
  } | sort -uV
}

build() { # namespace/name, version, output directory
  local pr="$1" ver="$2" out="$3" work stage id cat slug title p n tarball fetched=0
  provider "$pr"
  [[ "$ver" =~ $VER_RE ]] || die "not a stable version: $ver"
  { [ -e "$out" ] || [ -L "$out" ]; } && die "the output directory exists: $out"
  work="$(mktemp -d)" || die "no temporary directory"
  # shellcheck disable=SC2064 # expand now: work is local
  trap "rm -rf -- '$work'" EXIT
  stage="$work/stage"
  mkdir "$stage" "$work/out" || die "no staging directory"

  reg "v1/providers/$ns/$name/$ver" > "$work/list.json" || die "no document list for $pr $ver"
  jq -e '.docs | type == "array"' "$work/list.json" > /dev/null 2>&1 || die "the document list of $pr $ver has no docs array"
  # One line per hcl resource or data source page: id, category, slug, title. @tsv escapes
  # a tab or newline, so a hostile value stays on its line and fails the path check below.
  jq -r '.docs[] | select(.language == "hcl" and (.category == "resources" or .category == "data-sources"))
    | [(.id | tostring), .category, (.slug | tostring), (.title | tostring)] | @tsv' "$work/list.json" > "$work/docs" \
    || die "the document list of $pr $ver does not parse"
  : > "$work/keep"
  : > "$work/skipped"
  # The warm workflow finds a page by title and uses it only when exactly one hcl document of
  # the category has that title. So a title that occurs more than once, counted over every
  # hcl document of the category, keeps none of its documents; and a page is kept only when
  # its title is its slug, so the path the warm workflow looks up is the path written here.
  awk -F'\t' 'NR == FNR { c[$2 "\t" $4]++; next } { print (c[$2 "\t" $4] == 1 ? "U" : "D") "\t" $0 }' \
    "$work/docs" "$work/docs" > "$work/counted"
  while IFS=$'\t' read -r u id cat slug title; do
    p="$ns/$name/$ver/$cat/$slug.md"
    if [[ "$u" == U && "$id" =~ ^[0-9]{1,12}$ && "$p" =~ $SCHEMA_PAGE_RE && "$title" == "$slug" ]]; then
      printf '%s\t%s\t%s\n' "$id" "$cat" "$slug" >> "$work/keep"
    else
      printf '%s\t%s\t%s\n' "$id" "$cat" "$slug" >> "$work/skipped"
    fi
  done < "$work/counted"
  [ -s "$work/skipped" ] && echo "::notice::$pr $ver: $(wc -l < "$work/skipped") documents skipped: bad id, path or title, or a title used twice" >&2
  n="$(wc -l < "$work/keep")"
  [ "$n" -gt 0 ] || die "$pr $ver has no resource or data source page"
  [ "$n" -le "$MAX_PAGES" ] || die "$pr $ver has $n pages, over the cap of $MAX_PAGES; not built"

  while IFS=$'\t' read -r id cat slug; do
    p="$ns/$name/$ver/$cat/$slug.md"
    fetched=$((fetched + 1))
    reg "v2/provider-docs/$id" > "$work/doc.json" || die "$pr $ver: the fetch of document $id failed"
    jq -e -j --arg id "$id" --arg c "$cat" '.data | select(.id == $id and .attributes.category == $c and .attributes.language == "hcl")
      | .attributes.content | select(type == "string" and length > 0)' "$work/doc.json" > "$work/page.md" \
      || die "$pr $ver: document $id failed its checks"
    [ -e "$stage/$p" ] && die "$pr $ver: two documents for $p"
    mkdir -p -- "$stage/${p%/*}" && mv -- "$work/page.md" "$stage/$p" || die "$pr $ver: cannot write $p"
  done < "$work/keep"

  # Pack regular files only, each path checked again, in a fixed order with a fixed mtime,
  # owner and mode, so the same pages give the same tar.
  [ -z "$(find "$stage" -mindepth 1 ! -type f ! -type d)" ] || die "$pr $ver: a staged entry is not a regular file"
  (cd "$stage" && find . -type f -printf '%P\n') | LC_ALL=C sort > "$work/files"
  while IFS= read -r p; do
    [[ "$p" =~ $SCHEMA_PAGE_RE ]] || die "$pr $ver: $p is not a page path"
  done < "$work/files"
  [ "$(wc -l < "$work/files")" = "$n" ] || die "$pr $ver: the staged page count is not $n"
  # "_" joins namespace and name: neither may hold one, so the name is unambiguous.
  tarball="${ns}_${name}-${ver}.tar.gz"
  tar -C "$stage" --no-recursion --verbatim-files-from -T "$work/files" --format=gnu \
    --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u=rw,go=r -cf - | gzip -n -9 > "$work/out/$tarball" \
    || die "$pr $ver: tar failed"
  jq -R -s --arg p "$pr" --arg v "$ver" --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tar "$tarball" '
    { format: 1, provider: $p, version: $v, tarball: $tar,
      source: ("https://registry.terraform.io/v1/providers/" + $p + "/" + $v),
      license: "MPL-2.0", built_at: $built,
      docs: [split("\n")[] | select(length > 0) | split("\t") | { id: .[0], category: .[1], slug: .[2] }] }
    | .pages = (.docs | length)' "$work/keep" > "$work/out/manifest.json" || die "$pr $ver: no manifest"
  printf '%s\n' \
    "The files in $tarball are the documentation pages of the Terraform provider $pr," \
    "version $ver, unmodified, as served by the Terraform registry:" \
    "https://registry.terraform.io/v1/providers/$pr/$ver" \
    "" \
    "The provider documentation is licensed by its authors under the Mozilla Public" \
    "License 2.0 (MPL-2.0): https://mozilla.org/MPL/2.0/" \
    "Its source form is the provider's own source repository." > "$work/out/NOTICE" || die "$pr $ver: no notice"
  (cd "$work/out" && sha256sum -- "$tarball" manifest.json NOTICE > SHA256SUMS) || die "$pr $ver: no checksums"
  mkdir -- "$out" || die "$pr $ver: cannot create $out"
  mv -- "$work/out/$tarball" "$work/out/manifest.json" "$work/out/NOTICE" "$work/out/SHA256SUMS" "$out/" \
    || { rm -rf -- "$out"; die "$pr $ver: cannot write $out"; }
  echo "$n"
}

case "${1:-}" in
select) [ "$#" -ge 3 ] || die "usage: build.sh select <namespace/name> <minor lines> [<floor version>...]"; shift; select_versions "$@" ;;
build) [ "$#" = 4 ] || die "usage: build.sh build <namespace/name> <version> <output directory>"; shift; build "$@" ;;
*) die "usage: build.sh select|build ..." ;;
esac
