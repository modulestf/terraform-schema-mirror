# terraform-schema-mirror

Terraform provider documentation, one release per provider version, ready to download without a token.

Every `resource` and `data source` page of a provider version is packed into one `.tar.gz` and published as a GitHub release asset, with a checksum file, a manifest and a license notice. A page at a provider version never changes, so each version is built once and kept forever. A nightly job adds new provider releases as they appear in the [Terraform registry](https://registry.terraform.io/).

Use it when a tool reads many provider pages, for example a code review agent that checks a module against the provider schema: one download replaces hundreds of registry calls, and the registry sees the load once instead of once per user.

## What is here

| Provider | Versions |
|----------|----------|
| `hashicorp/aws` | the newest patch of the latest three minor lines, plus `5.46.0` and `6.0.0` |

The full list of published versions is the [releases page](../../releases). The providers and their pinned versions are in [ci/mirror/providers.txt](ci/mirror/providers.txt).

## Download a bundle

No token and no GitHub API call, only HTTPS:

```sh
tag=hashicorp_aws-v6.0.0
tarball=hashicorp_aws-6.0.0.tar.gz
base="https://github.com/pofix/terraform-schema-mirror/releases/download/$tag"
page_re='^[a-z0-9][a-z0-9-]{0,63}/[a-z0-9][a-z0-9-]{0,63}/[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}/(resources|data-sources)/[a-z0-9][a-z0-9_]{0,127}\.md$'

for f in "$tarball" manifest.json NOTICE SHA256SUMS; do
  curl -fsSL --proto '=https' -o "$f" "$base/$f" || exit 1
done
sha256sum --strict -c SHA256SUMS || exit 1

# Check the listing before extracting: regular files only, every path a page path.
tar -tvzf "$tarball" | grep -v '^-' && exit 1
tar -tzf "$tarball" | grep -vE "$page_re" && exit 1
mkdir -p pages && tar -xzf "$tarball" -C pages --no-same-owner --no-same-permissions
```

A version that is not published returns 404. Fetch it from the registry instead.

Keep your own copy of the page pattern and of this repository's name. Do not take either from the downloaded files or from untrusted input.

## What a release holds

The tag is `<namespace>_<name>-v<version>`, for example `hashicorp_aws-v6.0.0`. Each release has four assets:

| Asset | Content |
|-------|---------|
| `<namespace>_<name>-<version>.tar.gz` | Every hcl resource and data source page of the version, one Markdown file per page. |
| `manifest.json` | Provider, version, page count, the registry document id, category and slug of each page, the registry source URL, the license and the build time. |
| `NOTICE` | The license of the pages and the registry source URL. |
| `SHA256SUMS` | SHA-256 of the tarball, `manifest.json` and `NOTICE`. |

Inside the tarball each page is at `<namespace>/<name>/<version>/<resources|data-sources>/<slug>.md`, for example `hashicorp/aws/6.0.0/resources/s3_bucket.md`. The content is the registry document, unchanged.

The tarball is reproducible: regular files only, sorted, mtime 0, owner 0, mode 0644. The same pages always give the same bytes. Guides, functions, ephemeral resources and documents in other languages are not included.

No release is marked as the latest, because several provider versions are published side by side.

## How it is built

[.github/workflows/schema-mirror.yml](.github/workflows/schema-mirror.yml) runs every night at 03:17 UTC and on a manual run. It runs [ci/mirror/build.sh](ci/mirror/build.sh) for each version that has no release yet:

1. Read the version list from the registry and pick the newest patch of the latest three minor lines, plus the floor versions in `providers.txt`. Pre-releases are skipped.
2. List the version's documents, keep each hcl resource and data source page whose path passes the page pattern and whose title is unique, and fetch each one, checking its id, category and language.
3. Pack the pages and write the manifest, the notice and the checksums.
4. Create a draft release, upload the four assets, and publish it only when every upload succeeded.

A version with any failed page is not published and is retried the next night. A partial release is never visible.

Registry calls go one at a time over HTTPS, with a 0.5 second pause and a User-Agent that names this repository. A run stops starting new versions after 12,000 page fetches or 240 minutes, so the first run of a large provider can take two nights. After that, a night with no new provider release costs one tag listing and one version list call per provider.

The job has `contents: write` to create releases and nothing else: no secret beyond `GITHUB_TOKEN`, no cloud credential and no model. It never runs on a pull request.

## Trust

- The pages come from the Terraform registry unchanged, but this repository is one more party between you and the registry. Trust it as you would any mirror.
- `SHA256SUMS` catches a truncated or corrupted download. It does not protect against a compromised publisher: whoever can publish a release can publish matching checksums.
- The pages are public documentation. A wrong page can mislead a tool that reads it, but it holds no secret.
- Published releases are immutable and tags are protected, so a published version cannot be changed afterwards.

## Add a provider

Open a pull request that adds a line to [ci/mirror/providers.txt](ci/mirror/providers.txt): `namespace/name`, then any floor versions to pin, for example `hashicorp/google 6.0.0`. Add a provider only if its documentation is licensed under MPL-2.0, because every release states that license.

## License

The provider documentation belongs to its authors and is licensed with the provider source. For the HashiCorp providers that is the [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/). This repository redistributes the pages unmodified. Each release carries a `NOTICE` asset and a release body with the license and the registry source URL.
