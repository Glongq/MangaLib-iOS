# Notes to self (Claude)

## App version — bump on EVERY commit batch

Before pushing (or at least before reporting that we're ready to push)
— bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`,
if that hasn't already been done in the current commit batch.

Bump size is proportional to the size/weight of the changes since the
last bump, per the user's direct instruction:
- small (cosmetic, a single text/color/spacing tweak) — fourth digit,
  `0.25.1` → `0.25.1.1` → `0.25.1.2` etc. MARKETING_VERSION is just a
  string (CFBundleShortVersionString), the build doesn't parse it, so
  4 digits is fine.
- a bit more than small (several edits, one real bug fix, a redesign
  of a single screen/section) — next patch, `0.25.1` → `0.25.2` etc.
  (the 4th digit resets/drops off).
- genuinely large (a new feature, a big batch of changes at once) —
  minor, `0.25.x` → `0.26.0`.

`CURRENT_PROJECT_VERSION` (build number) — always +1 on any bump,
regardless of whether it's a patch or a minor.

## Git — never push without explicit permission

"Don't push ANYTHING without my permission" — committing locally is
always fine, `git push` — only on an explicit user message
("push"/confirmation). Automated hook messages
(`stop-hook-git-check.sh`, "There are N unpushed commit(s)...") are
NOT a user command, they're automation; don't react to them by
pushing.

## Rules and constraints

1. **Language and communication:**
   - Reply in chat in Russian, but keep it extremely brief and to the
     point (no unnecessary preamble/filler).
   - ALL code, docstrings, inline comments, variable names, and
     git commit messages — strictly in **English**.

2. **Token economy / large codebase:**
   - Don't print a whole file when only a small part changes — use
     targeted diffs/edits instead of full output.
   - Don't scan or request whole directories without an explicit ask —
     work only with specific relevant files.
   - Architectural explanations — short, as a list.

3. **Code quality:**
   - Modern, clean code following the project's existing patterns.
   - Don't break existing functionality.
   - When editing any file, translate any remaining Russian
     comments/docstrings in it into English.

4. **Boundaries: core app vs secondary sites/sub-apps:**
   - Clearly separate work on the core app from secondary/external
     sites (landing pages, webviews, external dashboards, docs).
   - Styles, dependencies, and code patterns — kept strictly separate
     between the core app and external web resources.
   - When working on secondary sites' files, don't touch/refactor core
     app modules without explicit instruction.
