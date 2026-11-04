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

## API key

onesie asks an inference provider with your own key. Store the key as a repository secret, under Settings, Secrets and variables, Actions, and pass it to the step that runs onesie through `env`, as above.

TypeSafe is the default, read from `TYPESAFE_API_KEY`. For another provider, set `ONESIE_PROVIDER` beside its key variable, as in `ONESIE_PROVIDER: openrouter` with `OPENROUTER_API_KEY`. onesie's reference lists [every provider and its key variable](https://github.com/frodi-karlsson/onesie/blob/main/REFERENCE.md#profiles-and-providers). Profiles keep a key in a desktop keychain, so a workflow needs none.

## Example: label new issues

This workflow labels each new issue as a bug, a feature request, a question or a docs problem. An issue onesie is unsure about gets `needs-triage`, so a person sorts it instead of a guess.

```yaml
name: Label new issues
on:
  issues:
    types: [opened]

permissions:
  issues: write

jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - uses: frodi-karlsson/setup-onesie@v1
      - name: Label the issue
        env:
          TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
          GH_TOKEN: ${{ github.token }}
          ISSUE: ${{ github.event.issue.number }}
          TITLE: ${{ github.event.issue.title }}
          BODY: ${{ github.event.issue.body }}
        run: |
          label="$(onesie --ask kind='what kind of issue is this' \
            --pick bug,feature,question,docs \
            --desc bug='something is broken or behaves wrong' \
            --desc feature='a request for new behaviour' \
            --desc question='asking how to use it' \
            --desc docs='a problem in the docs' \
            --min-confidence 0.7 --fallback needs-triage -r \
            --state "$TITLE"$'\n\n'"$BODY")"
          gh issue edit "$ISSUE" --repo "$GITHUB_REPOSITORY" --add-label "$label"
```

- The five labels must exist in the repository.
- The issue text reaches the shell through `env`, never through `${{ }}` inside `run`. onesie can only answer with one of the labels, so an issue written to trick the model can at most get the wrong label.
- Anyone who can open an issue starts one API call on your key. On a busy repository, add a condition such as `if: github.event.issue.author_association != 'NONE'`.

## Example: check pull requests with your own calibrated question

Write the question once, measure it against pull requests you have already judged, and let CI ask it on every new one. This example checks that a pull request description says why the change is needed.

**1. Write the question** in `.onesie/questions/pr-why.yaml`, where `onesie -f pr-why` finds it:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/frodi-karlsson/onesie/main/schema/questions.json
assert: why.value > 0.7
abstain_if: why.value > 0.4
why:
  ask: does this pull request description explain why the change is needed
  yes_means: it names the problem, the need or the goal the change serves
  no_means: it only lists what changed, or it is empty or a template left unfilled
```

A description passes above 0.7, fails at 0.4 or below, and anything between goes to a person.

**2. Calibrate the cuts** on 40 or so past descriptions you label yourself, one JSON line each, as `{"id": 12, "body": "...", "explains_why": true}`:

```sh
onesie calibrate -f pr-why -i jsonl --map .body --id .id --label why=.explains_why < labelled.jsonl
```

The report shows, for each cut, how many good descriptions it catches and how many bad ones it lets through. Move `assert` and `abstain_if` to the cuts you can live with, and commit the file.

**3. Ask it in CI:**

```yaml
name: Check the description
on:
  pull_request:
    types: [opened, edited, synchronize]

permissions:
  contents: read

jobs:
  description:
    # A pull request from a fork gets no secrets, so onesie would have no key.
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: frodi-karlsson/setup-onesie@v1
      - name: Ask whether the description says why
        env:
          TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
          BODY: ${{ github.event.pull_request.body }}
        run: |
          status=0
          onesie -f pr-why -q --state "$BODY" || status=$?
          case $status in
            0) ;;
            1) echo "::error::The description does not say why this change is needed."; exit 1 ;;
            7) echo "::warning::onesie is unsure whether the description says why. A reviewer should check." ;;
            *) echo "::error::onesie gave no answer, exit $status"; exit 1 ;;
          esac
```

- Exit 0 means the question passed, 1 that it clearly failed, and 7 that onesie is unsure. Any other exit means no answer arrived, so the step fails instead of guessing.

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
