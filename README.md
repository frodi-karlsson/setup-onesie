# setup-onesie

A GitHub Action that puts a verified [onesie](https://github.com/frodi-karlsson/onesie) binary on `PATH`. It downloads the release archive for the runner, checks its sha256 against the release's `checksums.txt`, checks its build provenance against onesie's release workflow, and refuses the archive when either check fails. It runs on Linux, macOS and Windows runners, on amd64 and arm64.

## Usage

```yaml
- uses: frodi-karlsson/setup-onesie@v1
  with:
    version: 0.12.0
- run: onesie -f moderation -i lines < comments.txt
  env:
    TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
```

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `version` | `latest` | A release such as `0.12.0` or `v0.12.0`, or `latest` |
| `verify-provenance` | `true` | Check the archive with `gh attestation verify`. Set it to `false` to skip the check |
| `release-base-url` | empty | Where the archives and `checksums.txt` live, for a mirror. Empty means the GitHub release of `version` |
| `token` | `${{ github.token }}` | Used to find the latest release and to verify provenance |

## Outputs

| Output | Meaning |
|---|---|
| `version` | The version installed, without the `v`, as `0.12.0` |

## Verification

Every archive is checked twice before it is unpacked:

1. Its sha256 must equal its line in the release's `checksums.txt`.
2. Its build provenance must come from onesie's release workflow. This is the command the Action runs, and you can run it yourself on a downloaded archive:

```sh
gh attestation verify onesie_0.12.0_linux_amd64.tar.gz \
  --repo frodi-karlsson/onesie \
  --signer-workflow frodi-karlsson/onesie/.github/workflows/release.yml
```

The provenance check needs `gh`, which GitHub hosted runners ship. On a runner without it, install `gh` or set `verify-provenance: false`.

After unpacking, `onesie --version` must report the version installed. The binary is kept in the runner's tool cache, so a self hosted runner reuses it on the next run.

## Mirrors

Set `release-base-url` to a folder that holds the archives and `checksums.txt` of one release, in the layout of a GitHub release. It must start with `https://` or `file://`. The provenance check still applies, since the attestation binds the archive's digest and not its location.

A mirror has no API to say which release is newest, so `latest` needs the GitHub API. With `release-base-url` set, pass a version such as `0.12.0`.

```yaml
- uses: frodi-karlsson/setup-onesie@v1
  with:
    version: 0.12.0
    release-base-url: https://mirror.example.com/onesie/v0.12.0
```

## GitHub Enterprise Server

On GitHub Enterprise Server, `github.token` does not reach github.com, where onesie's releases and attestations live. Pass a github.com token as `token`. Without one, pin `version` and set `verify-provenance: false`, and the sha256 check still applies.

## Pinning

`@v1` follows the newest `v1.x.y` release. For an Action that cannot change under you, pin a full commit sha and keep the version in a comment:

```yaml
- uses: frodi-karlsson/setup-onesie@<full commit sha> # v1.0.0
```

## License

MIT, see [LICENSE](LICENSE).
