# Pi Code Review

AI-powered code review GitHub Action using [Pi](https://github.com/badlogic/pi-mono). Posts inline comments on pull request files, similar to CodeRabbit.

## Features

- **Full codebase access** — Pi runs inside your repo checkout and can read any file, not just the diff. It follows imports, checks tests, and understands context.
- **Inline PR comments** — Findings are posted as individual comments on the exact lines in the pull request diff.
- **No duplicate comments** — The action fetches all existing PR comments and review threads (both resolved and unresolved) and passes them to Pi so it never re-raises an issue that was already discussed.
- **Summary comment** — An optional overall summary with a verdict (approve / request changes / comment) is posted on the PR.
- **Findings outside the diff** — If Pi finds an issue on a line that isn't part of the diff, it's included in the summary table instead of being silently dropped.
- **Configurable model + thinking** — Use any provider/model supported by Pi and optionally choose a thinking level.
- **Multi-model A/B testing** — Supply a comma-separated list of models; one is picked per review. Selection is weighted by each model's 👍 / 👎 score from the grades issue, so better-performing models get more volume while unproven ones still get explored.
- **Comment grading** — Each inline comment includes a 👍 / 👎 prompt. A separate grades workflow aggregates reactions into per-model scores and maintains a stats issue in your repo.

## Quick start

### 1. Add the workflow

Create `.github/workflows/pi-review.yml`:

```yaml
name: Pi Review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: pi-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: your-org/code-review@main
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        with:
          model: openai/gpt-5.4
          thinking: xhigh
```

### 2. Add your API key

Go to **Settings → Secrets and variables → Actions** in your repository and add the API key for the provider you chose (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`).

### 3. Open a PR

The action runs automatically on every non-draft pull request.

## Model examples

You can optionally set `thinking` to control the reasoning level.

### GPT-5.4 with `xhigh`

```yaml
- uses: your-org/code-review@main
  env:
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
  with:
    model: openai/gpt-5.4
    thinking: xhigh
```

### Claude Sonnet with `high`

```yaml
- uses: your-org/code-review@main
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
  with:
    model: anthropic/claude-sonnet-4-20250514
    thinking: high
```

Available thinking levels: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`.

### Multi-model A/B testing

Pass a comma-separated list via `models` and one is chosen per run:

```yaml
- uses: your-org/code-review@main
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
  with:
    models: >-
      anthropic/claude-sonnet-4-20250514,
      openai/gpt-5.4
```

Combine with the [grades workflow](#comment-grading) to compare model quality.

#### Weighted selection

Once the grades workflow has run at least once, selection is weighted by each
model's 👍 / 👎 score from the stats issue — models with a higher helpful
ratio receive more reviews on average. Weights use Bayesian shrinkage
(α = 2) so noisy small-sample scores are pulled toward 50%, and every model
keeps a minimum weight of 10 so under-performing or brand-new models still
get explored. Each run logs the effective per-model share in the action log.

For weighting to work, the review workflow token needs `issues: read` in
addition to the default permissions. Without it (or before the first grades
run), selection transparently falls back to uniform random.

## Comment grading

Every inline review comment includes a rating prompt:

> Was this helpful? React with 👍 or 👎

A **separate workflow** collects these reactions and maintains a GitHub issue
in your repo with per-model performance stats.

### Setup

Create `.github/workflows/pi-grades.yml`:

```yaml
name: Pi Review Grades

on:
  schedule:
    - cron: "0 9 * * 1" # every Monday 9 AM UTC
  workflow_dispatch:

permissions:
  issues: write
  pull-requests: read

jobs:
  grades:
    runs-on: ubuntu-latest
    steps:
      - uses: your-org/code-review/grades@main
```

On the first run it creates a `pi-review-stats` labelled issue. Subsequent
runs update the same issue with the latest numbers:

| Model | 👍 Helpful | 👎 Not Helpful | Graded / Total | Score |
|-------|-----------|----------------|----------------|-------|
| `anthropic/claude-sonnet-4-20250514` | 23 | 5 | 28 / 40 | 82% |
| `openai/gpt-5.4` | 15 | 3 | 18 / 35 | 83% |

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `model` | no\* | — | Single model in `provider/model` format. Ignored when `models` is set. |
| `models` | no\* | — | Comma-separated list of models — one is picked at random per run. |
| `thinking` | no | `""` | Optional thinking level: `off`, `minimal`, `low`, `medium`, `high`, `xhigh` |

\* Either `model` or `models` must be provided.
| `github_token` | no | `${{ github.token }}` | Token for posting comments |
| `pi_version` | no | `latest` | Pi version to install |
| `review_prompt` | no | `""` | Extra review instructions appended to the default prompt |
| `max_diff_size` | no | `100000` | Max diff bytes before truncation |
| `post_summary` | no | `true` | Post an overall summary comment |
| `extra_env` | no | `""` | Extra env vars as `KEY=VALUE` lines |

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  GitHub Actions runner                                  │
│                                                         │
│  1. Checkout full repo (fetch-depth: 0)                 │
│  2. Install Pi                                          │
│  3. Fetch PR metadata via GraphQL:                      │
│     - title, description, author                        │
│     - conversation comments                             │
│     - review threads (resolved + unresolved)            │
│  4. Generate git diff (base...head)                     │
│  5. Build prompt with all context + diff                │
│  6. Run `pi -p` inside the repo                         │
│     → Pi can read ANY file in the codebase              │
│     → writes findings to /tmp/pi-review.json            │
│  7. Post each finding as an inline PR comment           │
│     (with 👍/👎 rating prompt + model tag)              │
│  8. Post overall summary comment                        │
└─────────────────────────────────────────────────────────┘

Grades workflow (separate):

```
┌─────────────────────────────────────────────────────────┐
│  Runs on schedule / manual dispatch                     │
│                                                         │
│  1. Scan all PR review comments for pi-review markers   │
│  2. Read 👍/👎 reaction counts per comment              │
│  3. Aggregate stats per model                           │
│  4. Create or update a pi-review-stats issue            │
└─────────────────────────────────────────────────────────┘
```
```

## Custom review instructions

Use the `review_prompt` input to add project-specific criteria:

```yaml
- uses: your-org/code-review@main
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
  with:
    model: anthropic/claude-sonnet-4-20250514
    review_prompt: |
      Also check for:
      - Compliance with our API design guidelines in docs/api-guidelines.md
      - Missing database migration files for schema changes
      - Test coverage for new public functions
```

## Output schema

Pi writes `/tmp/pi-review.json` with this structure:

```json
{
  "summary": "Markdown summary of the review",
  "verdict": "approve | request_changes | comment",
  "findings": [
    {
      "path": "src/handler.ts",
      "line": 42,
      "end_line": 45,
      "severity": "error | warning | suggestion",
      "title": "Short description",
      "body": "Detailed explanation in markdown"
    }
  ]
}
```

## Permissions

The workflow needs these GitHub token permissions:

| Permission | Level | Why |
|------------|-------|-----|
| `contents` | `read` | Read repo files and generate diffs |
| `pull-requests` | `write` | Post review comments and summary |
| `issues` | `read` | _Optional._ Read the grades stats issue to weight model selection. Falls back to uniform random when missing. |

The **grades workflow** needs:

| Permission | Level | Why |
|------------|-------|-----|
| `pull-requests` | `read` | Read review comment reactions |
| `issues` | `write` | Create / update the stats issue |

## License

MIT
