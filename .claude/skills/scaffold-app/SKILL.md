---
name: scaffold-app
description: Scaffold a new ABP application with LinkHub-grade infra/CI/devops overlays. Asks for an app description, recommends an ABP solution shape, lets the operator confirm or tweak, then runs scaffold.sh.
---

# /scaffold-app — one-command ABP project scaffold

This skill drives the recommendation engine + per-knob confirmation
flow, then hands off to the scaffold tool's `scaffold.sh`. Execute the
seven steps below IN ORDER. Each step is an explicit instruction —
do not skip, summarize, or reorder.

The scaffold tool source tree lives in the same directory as this
SKILL.md's grandparent (`../../..`). Throughout this skill,
`<scaffold-tool-path>` resolves to that directory (the one containing
`scaffold.sh`, `lib/`, `recommendation-prompt.md`, etc.).

## Step 1 — Capture the app description

Call `AskUserQuestion` with the question:

> "Describe the app you want to build in 1-3 sentences (target users,
> key entities, scale expectations)."

Use a single option `["I'll describe my app"]` plus an explicit "Other"
free-text fallback. The operator's free-text answer (delivered via the
"Other" path) is captured into the variable `APP_DESCRIPTION`.

If `APP_DESCRIPTION` is empty or fewer than 20 characters, re-ask once
with the additional instruction: "Please include enough detail (~20+
characters) for the recommendation engine to make sensible guesses."

If the second attempt is still too short, surface an error to the
operator and exit the skill.

## Step 2 — Invoke the recommendation engine

Read `<scaffold-tool-path>/recommendation-prompt.md` with the `Read`
tool. Send a model invocation whose system / instruction block is the
recommendation-prompt body verbatim, and whose user message is
`APP_DESCRIPTION`.

Parse the model's response with this strategy, in order:

1. Look for the first ` ```json … ``` ` fenced block in the response
   and extract its contents.
2. If no fence, fall back to extracting the first balanced `{ … }`
   substring.
3. Run the extracted string through `jq .` (via the `Bash` tool) to
   confirm it parses as JSON.
4. Convert JSON → YAML via `yq -P`, then backfill the schema-required
   fields the recommendation engine does NOT supply
   (`project_name`, `github_owner`, `infra.cloudflare_zone`) with
   placeholder values, and run the result through
   `bash <scaffold-tool-path>/lib/validate-config.sh /dev/stdin`. The
   placeholders are operator-confirmed in Step 4 and need only satisfy
   the schema's `required: true` gate here.

If any step fails, re-invoke the model with the original prompt PLUS an
appended message: "Your previous response failed validation: <error>.
Return ONLY the JSON object inside a single ```json fence, no prose."

Retry **up to 3 total attempts**. After the third failure, surface a
clear error to the operator and exit the skill. **DO NOT** write the
partial config file when all three attempts fail.

## Step 3 — Present the recommendation

Render the parsed JSON as a markdown table with one row per knob:

| Knob | Recommended | Reasoning |
| --- | --- | --- |
| `abp.template` | `app` | (from `reasoning["abp.template"]` if present; else "(default)") |
| `abp.ui` | `angular` | … |
| … | … | … |

Then call `AskUserQuestion` with three options:

1. **Accept recommended config** (default)
2. **Tweak each knob** — proceeds to Step 4.
3. **Start over with a different description** — jump back to Step 1.

## Step 4 — Per-knob tweak loop (only if the operator chose "Tweak each knob")

For each knob in the recommended config, call `AskUserQuestion` with:

- **Question text:** "<knob name> (recommended: <value>, because:
  <reasoning>)"
- **Options:** the recommended value FIRST, then the other valid enum
  values from `scaffold-config-schema.yml`, then "Other" for free-text
  overrides (use the "Other" path for `optional_modules` to accept a
  comma-separated list).

Walk the knobs in this order:

1. `abp.template`
2. `abp.ui`
3. `abp.db_provider`
4. `abp.dbms` (skip if `db_provider=mongodb`)
5. `abp.multi_tenancy`
6. `abp.tiered`
7. `abp.default_culture`
8. `abp.optional_modules`

After the recommended knobs, always ask the three operator-confirmed
fields (they are schema-required and NOT derivable from the
recommendation engine):

- `project_name` — default to the recommendation's `project_name` if
  present, otherwise free-text.
- `github_owner` — free-text.
- `infra.cloudflare_zone` — free-text; default `REPLACE_ME` is allowed
  for first-scaffold runs.

## Step 5 — Write the confirmed config

Build the final YAML from the recommendation merged with the operator's
tweaks. Write it to `/tmp/scaffold-config-$(date +%s).yml`.

Echo the path back to the operator with:

> "Wrote config: <path>"

## Step 6 — Spawn `scaffold.sh`

Run the scaffold tool via the `Bash` tool with output streamed to
stdout:

```bash
bash <scaffold-tool-path>/scaffold.sh --config <tmp-config-path>
```

Surface the command's exit code to the operator. On non-zero exit,
instruct the operator to read the `[FAIL]` line(s) from the streamed
output for the next action.

## Step 7 — Operator handoff

On `scaffold.sh` exit code 0, print:

> "Scaffold complete. See `<target-dir>/README.md` for next steps.
> The full scaffold log is in your terminal scrollback. Future
> re-runs: edit `<config-path>` then re-invoke `/scaffold-app`."

This minimal handoff is replaced by the richer post-init banner in
unit-10; for unit-02 the brief message above is sufficient.
