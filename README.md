# setup-onesie

Ask a System One model a question in your workflows, and get back an answer they can act on: a yes or no with a probability, one of your labels, or a rating. Gate a step on it, label something, or send a borderline case to a person. The answers come from [onesie](https://github.com/frodi-karlsson/onesie), a command line tool that asks System One models such as TypeSafe's Jev, with cuts you can calibrate on your own examples.

This Action installs onesie on any GitHub hosted runner, Linux, macOS or Windows, on amd64 or arm64. The download is checked against its release checksum and build provenance, and refused when either check fails. Given a question, it then asks it about one text and passes or fails the step on the answer, with no shell script.

## Usage

```yaml
- uses: frodi-karlsson/setup-onesie@v1
  env:
    TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
  with:
    file: moderation
    state: ${{ github.event.comment.body }}
```

This fails the step when the comment is hostile or spam, and warns when onesie is unsure. Without `file` or `questions`, the Action only installs onesie, as in [Calling onesie directly](#calling-onesie-directly).

## Run mode

Setting `file` or `questions` starts run mode. The Action asks the question about `state` and sets `result`, `exit-code` and `answer`.

- `file` takes a question file name or path, as `onesie -f` does. A bare name such as `pr-why` loads `.onesie/questions/pr-why.yaml` from the checkout, and onesie also ships the sets `moderation`, `personal-data`, `prompt-injection` and `shell-safety`.
- `questions` takes a question file's YAML inline. Set `file` or `questions`, not both.
- `state` is required in run mode, and an empty one is refused. It reaches onesie through the environment, never through a shell, so `${{ }}` is safe in it. An issue or pull request body can be empty, and run mode refuses an empty state, so join the body with its title or guard the step with `if:`.
- `result` is `pass` for exit 0, `fail` for 1, `unsure` for 7, and `no-answer` for any other exit, such as a missing key or a failed API call.

`on-fail` says what a clear no does to the step, and `on-unsure` the same for unsure. Each takes `error`, which fails the step with an error annotation, `warn`, which passes it with a warning, or `continue`, which passes it with no annotation. The defaults are `error` for `on-fail` and `warn` for `on-unsure`. A no answer always fails the step, whatever the two say, so a later step never acts on an answer that did not arrive.

### A plain gate

The defaults make a gate. This fails the job when the question in `.onesie/questions/pr-why.yaml` clearly fails, and leaves a warning when onesie is unsure:

```yaml
- uses: actions/checkout@v7
- uses: frodi-karlsson/setup-onesie@v1
  env:
    TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
  with:
    file: pr-why
    state: ${{ github.event.pull_request.body }}
```

### Acting on result

Set both policies to `continue` to decide in a later step. This labels an issue for a moderator unless the moderation set passes it:

```yaml
- uses: frodi-karlsson/setup-onesie@v1
  id: moderation
  env:
    TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
  with:
    file: moderation
    state: |
      ${{ github.event.issue.title }}

      ${{ github.event.issue.body }}
    on-fail: continue
    on-unsure: continue
- name: Ask a moderator to look
  if: steps.moderation.outputs.result != 'pass'
  env:
    GH_TOKEN: ${{ github.token }}
    ISSUE: ${{ github.event.issue.number }}
  run: gh issue edit "$ISSUE" --repo "$GITHUB_REPOSITORY" --add-label needs-moderation
```

### Reading a pick from answer

`answer` holds onesie's `-o json` line. Read a field with `fromJSON`. A pick's `value` is the option picked, and with a `fallback` set, its `decision` is that option, or the fallback when the confidence fell short of `min_confidence`:

```yaml
- uses: frodi-karlsson/setup-onesie@v1
  id: area
  env:
    TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
  with:
    questions: |
      area:
        ask: which part of the project does this change touch
        pick: [cli, api, docs]
        min_confidence: 0.7
        fallback: unsure
    state: ${{ github.event.pull_request.title }}
- run: echo "This change touches $AREA"
  env:
    AREA: ${{ fromJSON(steps.area.outputs.answer).area.decision }}
```

## API key

onesie asks an inference provider with your own key. Store the key as a repository secret, under Settings, Secrets and variables, Actions, and pass it to the step that runs onesie through `env`, as above. In run mode that is the `uses` step itself.

TypeSafe is the default, read from `TYPESAFE_API_KEY`. For another provider, set `ONESIE_PROVIDER` beside its key variable, as in `ONESIE_PROVIDER: openrouter` with `OPENROUTER_API_KEY`. onesie's reference lists [every provider and its key variable](https://github.com/frodi-karlsson/onesie/blob/main/REFERENCE.md#profiles-and-providers). A workflow needs no profile, since onesie reads the key variable when no profile exists.

### Your own server

`ONESIE_BASE_URL` points onesie at another server that speaks a provider's API, such as [ollaya](https://github.com/ollaya-dev/ollaya), and then no key is needed. A server that does want a key answers 401, which run mode reports as `no-answer`. This needs onesie 0.13.0 or later, so a step that pins `version` pins at least that.

A server run as a service container is reached at `http://localhost:PORT` when the job maps that port under `services` and runs on the runner itself, not in a container. Plain http to localhost is allowed, and plain http to any other host is refused.

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    services:
      decider:
        image: YOUR_SERVER_IMAGE
        ports: ['11435:11435']
    steps:
      - uses: frodi-karlsson/setup-onesie@v1
        env:
          ONESIE_BASE_URL: http://localhost:11435
        with:
          file: pr-why
          state: ${{ github.event.pull_request.body }}
```

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
        id: kind
        env:
          TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
        with:
          questions: |
            kind:
              ask: what kind of issue is this
              pick:
                bug: something is broken or behaves wrong
                feature: a request for new behaviour
                question: asking how to use it
                docs: a problem in the docs
              min_confidence: 0.7
              fallback: needs-triage
          state: |
            ${{ github.event.issue.title }}

            ${{ github.event.issue.body }}
      - name: Label the issue
        env:
          GH_TOKEN: ${{ github.token }}
          ISSUE: ${{ github.event.issue.number }}
          LABEL: ${{ fromJSON(steps.kind.outputs.answer).kind.decision }}
        run: gh issue edit "$ISSUE" --repo "$GITHUB_REPOSITORY" --add-label "$LABEL"
```

- The five labels must exist in the repository.
- The issue text reaches onesie through `with`, and the label reaches the shell through `env`, never through `${{ }}` inside `run`. onesie can only answer with one of the labels, so an issue written to trick the model can at most get the wrong label.
- When the API call fails, the step fails and the issue stays unlabelled.
- Anyone who can open an issue starts one API call on your key. On a busy repository, add a condition such as `if: contains(fromJSON('["OWNER","MEMBER","COLLABORATOR","CONTRIBUTOR"]'), github.event.issue.author_association)`.

## Example: check pull requests with your own calibrated question

Write the question once, measure it against pull requests you have already judged, and let CI ask it on every new one. This example checks that a pull request description says why the change is needed.

**1. Write the question** in `.onesie/questions/pr-why.yaml`, where `onesie -f pr-why` finds it:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/frodi-karlsson/onesie/main/schema/questions.json
assert: why.value >= 0.7
abstain_if: why.value >= 0.4
why:
  ask: does this pull request description explain why the change is needed
  yes_means: it names the problem, the need or the goal the change serves
  no_means: it only lists what changed, or it is empty or a template left unfilled
```

A description passes at 0.7 or above, fails below 0.4, and anything between goes to a person.

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
      - name: Ask whether the description says why
        uses: frodi-karlsson/setup-onesie@v1
        env:
          TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
        with:
          file: pr-why
          state: ${{ github.event.pull_request.body }}
```

- A clear no fails the step, and an unsure answer leaves a warning so a reviewer checks. A no answer fails the step instead of guessing.
- An empty description is refused as an empty `state`, so the step fails before any API call.

## Calling onesie directly

The binary stays on `PATH` for the rest of the job, in run mode or not, so a later step can call onesie with any flags, as to read a stream of records:

```yaml
- uses: frodi-karlsson/setup-onesie@v1
  with:
    version: 0.12.0
- run: onesie -f moderation -i lines < comments.txt
  env:
    TYPESAFE_API_KEY: ${{ secrets.TYPESAFE_API_KEY }}
```

onesie's exit codes are 0 when the question passed, 1 when it clearly failed and 7 when onesie is unsure. Any other exit means no answer arrived, so a script should fail instead of guessing. onesie's [reference](https://github.com/frodi-karlsson/onesie/blob/main/REFERENCE.md#exit-codes) lists them all.

## Inputs

`latest` installs the newest onesie release setup-onesie supports, 0.12.0 or later, and a `version` outside that range installs with a warning. The range only holds `latest` back from a breaking onesie release, so pin `version` to keep a workflow's own `run: onesie` steps working across one.

| Input | Default | Meaning |
|---|---|---|
| `version` | `latest` | A release such as `0.12.0` or `v0.12.0`, or `latest` for the newest supported release |
| `verify-provenance` | `true` | Check the archive with `gh attestation verify`. Set it to `false` to skip the check |
| `release-base-url` | empty | Where the archives and `checksums.txt` live, for a mirror. Empty means the GitHub release of `version` |
| `token` | `${{ github.token }}` | Used to find the latest release and to verify provenance |
| `file` | empty | Starts run mode with a question file name or path, as `onesie -f` takes it, such as `pr-why` or `moderation` |
| `questions` | empty | Starts run mode with a question file's YAML, inline |
| `state` | empty | The text to ask about. Required in run mode and refused outside it |
| `on-fail` | `error` | What a clear no does to the step in run mode: `error`, `warn` or `continue` |
| `on-unsure` | `warn` | What an unsure answer does to the step in run mode: `error`, `warn` or `continue` |

## Outputs

| Output | Example | Meaning |
|---|---|---|
| `version` | `0.12.0` | The version installed, without the `v` |
| `result` | `unsure` | In run mode, `pass` for exit 0, `fail` for 1, `unsure` for 7 and `no-answer` for any other exit |
| `exit-code` | `7` | In run mode, onesie's exit code |
| `answer` | `{"verdict":"unsure","model":"jev-latest","why":{"value":0.52}}` | In run mode, onesie's `-o json` line, for scores and picks |

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

After unpacking, `onesie version -o json` must report the version installed. The binary is kept in the runner's tool cache, so a self hosted runner reuses it on the next run.

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

## Maintenance

`lib.sh` holds the range: `min_version` is the oldest supported onesie release, and `below_version` is the first unsupported one, or empty for no upper bound. Keep the line under [Inputs](#inputs) in step with them.

A weekly workflow, `compat.yml`, installs onesie's newest release and runs the run mode cases against it. When the install or the cases fail, it opens an issue titled `onesie VERSION breaks setup-onesie` that names the failed step, unless an issue with that title exists, open or closed. A failed lookup of the newest release fails the run without an issue. Closing the issue acknowledges the break, and the check never reopens it for that version. Set `below_version` to that release's minor, such as `0.15.0`, and release setup-onesie, then clear it in a later release once run mode adapts. To check a release candidate before it ships, run the workflow by hand with its `version` input, such as `0.15.0-rc.1`.

GitHub disables a scheduled workflow after 60 days without activity in the repository. Enable it again from its page under Actions, or with `gh workflow enable compat.yml`.

## License

MIT, see [LICENSE](LICENSE).
