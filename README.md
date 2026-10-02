# terraform-schema-mirror

Terraform provider schemas, one release per provider version, ready to download without a token.

Each release holds the output of `terraform providers schema -json` for one provider version as gzipped JSON, with a checksum file, a manifest and a license notice. Every stable version is mirrored, so a tool finds the version a module pins without knowing it in advance. A provider release never changes, so each version is built once and kept forever. A nightly job adds new provider releases as they appear in the [Terraform registry](https://registry.terraform.io/) and continues the backfill of older ones, newest first.

Use it when a tool checks Terraform code against provider schemas, for example a code review agent: one download of well under 1 MB replaces a `terraform init` that fetches the whole provider binary.

## What is here

| Provider | Versions |
|----------|----------|
| `hashicorp/aws`, `hashicorp/random`, `hashicorp/null`, `hashicorp/local`, `hashicorp/external`, `hashicorp/archive`, `hashicorp/tls`, `hashicorp/time`, `hashicorp/http`, `hashicorp/cloudinit`, `hashicorp/helm`, `hashicorp/kubernetes`, `kreuzwerker/docker` | every stable version that speaks plugin protocol 5 or 6 |

Versions built only for plugin protocol 4 (Terraform 0.11) are left out, because current Terraform cannot load them. The full list of published versions is the [releases page](../../releases). The providers are in [ci/mirror/providers.txt](ci/mirror/providers.txt).

## Download a schema

No token and no GitHub API call, only HTTPS:

```sh
tag=hashicorp_aws-v6.0.0
file=hashicorp_aws-6.0.0.schema.json.gz
base="https://github.com/modulestf/terraform-schema-mirror/releases/download/$tag"

for f in "$file" manifest.json NOTICE SHA256SUMS; do
  curl -fsSL --proto '=https' -o "$f" "$base/$f" || exit 1
done
sha256sum --strict -c SHA256SUMS || exit 1

gzip -dc "$file" | jq '.provider_schemas["registry.terraform.io/hashicorp/aws"].resource_schemas.aws_s3_bucket.block.attributes | keys'
```

A version that is not published returns 404. Run `terraform providers schema -json` against it yourself instead.

Keep your own copy of this repository's name. Do not take it from the downloaded files or from untrusted input.

## What a release holds

The tag is `<namespace>_<name>-v<version>`, for example `hashicorp_aws-v6.0.0`. Each release has four assets:

| Asset | Content |
|-------|---------|
| `<namespace>_<name>-<version>.schema.json.gz` | The output of `terraform providers schema -json` for that one provider version, with sorted keys and no whitespace. |
| `manifest.json` | Provider, version, schema file name, the Terraform version that read it, the schema `format_version`, the number of resources, data sources, ephemeral resources and functions, the provider hashes from `.terraform.lock.hcl`, the registry source URL, the license and the build time. |
| `NOTICE` | The license of the provider and the registry source URL. |
| `SHA256SUMS` | SHA-256 of the schema file, `manifest.json` and `NOTICE`. |

The schema file holds exactly one provider, at `.provider_schemas["registry.terraform.io/<namespace>/<name>"]`, and at least one resource or data source. It is reproducible: the same schema always gives the same bytes, and the gzip header has no file name and no time.

The schema has what the provider declares: attribute names, types, required, optional and computed flags, nested blocks and their limits, sensitive and deprecated flags, and descriptions where the provider sets them. It has no examples, no import syntax and no validation rules such as allowed values, because the provider does not export them.

No release is marked as the latest, because several provider versions are published side by side.

## How it is built

[.github/workflows/schema-mirror.yml](.github/workflows/schema-mirror.yml) runs every night at 03:17 UTC and on a manual run. It uses [ci/mirror/build.sh](ci/mirror/build.sh) in three jobs:

1. `plan`, with read access only, lists the published tags and reads each provider's version list from the registry. It picks every stable version not yet published, newest first, above the provider's minimum and minus any skipped version. It interleaves providers so each provider's newest release comes first, and caps the run at 250 versions. Pre-releases are skipped.
2. `build`, one job per version, three at a time, with read access only and no token. It writes a `main.tf` that requires exactly that provider version, runs `terraform init`, which checks the provider's signature and checksums, and then `terraform providers schema -json`. It checks that the schema holds exactly that provider and is not empty, writes the four files and uploads them as a workflow artifact.
3. `publish`, the same versions, is the only job with write access. It downloads each artifact, creates a draft release, uploads the four assets, and publishes the release only when every upload succeeded.

The build job runs provider code downloaded from the registry, so it holds no write access and no token. The publish job runs no downloaded code.

A version whose build fails is not published and is retried the next night; one failed version never blocks the others. A partial release is never visible.

Each night costs one registry call per provider for the version list, plus one provider download per version built. A version builds in under a minute, so the first backfill of about 800 versions takes a few nights. After that, a night with no new provider release costs one tag listing and one version list call per provider.

The workflow has no secret beyond `GITHUB_TOKEN`, no cloud credential and no model. It never runs on a pull request.

## Trust

- The schema is read from the provider release that `terraform init` downloads and verifies, but this repository is one more party between you and the registry. Trust it as you would any mirror.
- `SHA256SUMS` catches a truncated or corrupted download. It does not protect against a compromised publisher: whoever can publish a release can publish matching checksums.
- The schema is public information about the provider. A wrong schema can mislead a tool that reads it, but it holds no secret.
- Published releases are immutable and tags are protected, so a published version cannot be changed afterwards.

## Add a provider

Open a pull request that adds a line to [ci/mirror/providers.txt](ci/mirror/providers.txt): `namespace/name`, optionally a minimum version and versions to skip, for example `hashicorp/google >=4.0.0` or `hashicorp/aws !3.12.0`. Skip a version only when its build fails on consecutive nights. Add a provider only if it is licensed under MPL-2.0, because every release states that license.

## Tests

Run `bash tests/schema-mirror-test.sh` from the repository root; it needs bash, jq, gzip and sha256sum, and makes no network call. It checks the publisher workflow's invariants (triggers, permissions per job, pinned actions, token scope, draft-then-publish releases, run caps) and mutates temp copies to confirm each check catches a break. Then it runs `ci/mirror/build.sh` with the registry and `terraform` stubbed and checks the bundle it writes. The same test runs on every pull request and push to `master`.

## License

Each provider belongs to its authors and is licensed with its source. For every provider listed here that is the [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/). This repository publishes the schema the provider reports, unmodified apart from key order and whitespace. Each release carries a `NOTICE` asset and a release body with the license and the registry source URL.
