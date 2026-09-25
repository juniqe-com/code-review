---
name: pi-review
description: Handle PR code review feedback — pull comments, reply, resolve threads, and re-request review until approved.
---

# Code Review

## Completion

The review is considered complete when an approval comment (e.g. "LGTM", "no issues found") is added to the PR.

## Loop

Before start: make sure CI is green and PR marked "ready"

Until completion:

0. Wait for the review workflow to finish.
1. Pull **both** sources of feedback:
   - **Inline review threads** via `reviewThreads` GraphQL — comments attached to specific lines.
   - **PR-level issue comments** via `gh api repos/{owner}/{repo}/issues/{n}/comments` — Pi Review (and other bots) post "outside diff context" or summary findings here, NOT as threads. These have no `resolveReviewThread` equivalent and are easy to miss if you only query `reviewThreads`. List them on every loop iteration and treat each finding as its own item.
2. Read each thread / PR-level finding. Assess whether the suggestion is valid.
3. Do **not** blindly implement suggestions — validate first, ask the human if unsure.
4. If the comment is useful, react with 👍. Otherwise react with 👎.
5. Accepted → apply fix, reply confirming. Rejected → reply explaining why.
   - Inline threads: reply via `/pulls/{n}/comments/{databaseId}/replies`.
   - PR-level comments: reply by posting a new issue comment that references the original (e.g. quote the finding heading).
6. After all threads / findings: commit, push.
7. Resolve addressed inline threads via `resolveReviewThread` mutation. PR-level comments cannot be resolved — the confirmation reply is the audit trail.
8. Re-request review.
