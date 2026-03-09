# OpenCode Code Review

AI-powered code review GitHub Action using [OpenCode](https://opencode.ai). Posts inline comments on pull request files, similar to CodeRabbit.

## Features

- **Full codebase access** — OpenCode runs inside your repo checkout and can read any file, not just the diff. It follows imports, checks tests, and understands context.
- **Inline PR comments** — Findings are posted as individual comments on the exact lines in the pull request diff.
- **No duplicate comments** — The action fetches all existing PR comments and review threads (both resolved and unresolved) and passes them to OpenCode so it never re-raises an issue that was already discussed.
- **Summary comment** — An optional overall summary with a verdict (approve / request changes / comment) is posted on the PR.
- **Findings outside the diff** — If OpenCode finds an issue on a line that isn't part of the diff, it's included in the summary table instead of being silently dropped.
- **Configurable model** — Use any provider/model supported by OpenCode.

## Quick start

### 1. Add the workflow

Create `.github/workflows/opencode-review.yml`:

```yaml
name: OpenCode Review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: opencode-review-${{ github.event.pull_request.number }}
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
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        with:
          model: anthropic/claude-sonnet-4-20250514
```

### 2. Add your API key

Go to **Settings → Secrets and variables → Actions** in your repository and add the API key for the provider you chose (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`).

### 3. Open a PR

The action runs automatically on every non-draft pull request.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `model` | yes | — | Model in `provider/model` format |
| `github_token` | no | `${{ github.token }}` | Token for posting comments |
| `opencode_version` | no | `latest` | OpenCode version to install |
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
│  2. Install OpenCode                                    │
│  3. Fetch PR metadata via GraphQL:                      │
│     - title, description, author                        │
│     - conversation comments                             │
│     - review threads (resolved + unresolved)            │
│  4. Generate git diff (base...head)                     │
│  5. Build prompt with all context + diff                │
│  6. Run `opencode run` inside the repo                  │
│     → OpenCode can read ANY file in the codebase        │
│     → writes findings to /tmp/opencode-review.json      │
│  7. Post each finding as an inline PR comment           │
│  8. Post overall summary comment                        │
└─────────────────────────────────────────────────────────┘
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

OpenCode writes `/tmp/opencode-review.json` with this structure:

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

## License

MIT
