# hyir.sh

> A single-file template and config generation engine for the shell. Describe where a file goes, fill it in from your environment, and reload whatever depends on it.

![Launcher: Bash](https://img.shields.io/badge/launcher-Bash-4EAA25?logo=gnubash&logoColor=white)
![Engine: Perl 5](https://img.shields.io/badge/engine-Perl%205-39457E?logo=perl&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-Bash%20%2B%20core%20Perl-blue)
[![License](https://img.shields.io/github/license/valkyrieAttr/hyir)](LICENSE)

`hyir.sh` keeps **one small template per output file**. Each template opens with a one-line **header** that says where the rendered file goes, which variables it needs, and what should run before or after it. The rest of the file is the **body**: plain text with `[::PLACEHOLDERS::]` that are filled in from environment variables.

It ships as **one file**: a Bash launcher that parses options and hands off to an embedded Perl engine. There is nothing to install beyond Bash and Perl 5's core modules.

### At a glance

`templates/colors.css.theme`

```text
$PATH:[::HOME::]/.config/myapp/colors.css|$REQUIRE:{ACCENT}|$RUN:{systemctl --user reload myapp.service}
:root {
  --accent:      [::ACCENT::];
  --accent-soft: [::ACCENT_rgba(0.25)::];
}
```

```bash
ACCENT='#ff8800' hyir.sh --allow-run -- templates/
```

writes `~/.config/myapp/colors.css`:

```css
:root {
  --accent:      #ff8800;
  --accent-soft: rgba(255,136,0,0.25);
}
```

Run it again with the same inputs and the file is left untouched.

---

## Table of contents

- [Why hyir?](#why-hyir)
- [Features](#features)
- [Focus and design goals](#focus-and-design-goals)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Template reference](#template-reference)
- [Command-line reference](#command-line-reference)
- [Recipes](#recipes)
- [Security model](#security-model)
- [Behavior notes](#behavior-notes)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

---

## Why hyir?

Keeping many config files consistent (one palette used by a dozen apps, an application name repeated across manifests, per-environment values) tends to end up as `sed` and `envsubst` scripts that mangle edge cases, leave half-written files behind, and trigger reloads nobody needed. hyir gives that job a small, predictable shape:

- **One source of truth**: environment variables, or files you `source`.
- **One self-describing template per output**: the header carries the target path(s), required variables and hooks.
- **One command**: `hyir.sh templates/` renders everything, writes only what changed, and runs the hooks you have explicitly allowed.

## Features

### Templating

- **One placeholder grammar**: `[::NAME::]`. `${VAR}`, `$VAR`, `<VAR>` and `{{ var }}` are left untouched, so shell scripts, Helm/Go templates and JavaScript template literals pass through verbatim.
- **Fallbacks**: `[::NAME:-default::]`. Fallbacks may themselves contain placeholders.
- **Modifier pipeline**: `json`, `yaml`, `base64`, `upper`, `lower`, `trim`, `indent(N)` and `nindent(N)`, chainable.
- **Color helper**: derive `rgba(r,g,b,a)` values from any hex or `rgb()` color variable.
- **Built-ins**: timestamps, UUIDs, position in the run, source path.
- **Partials**: `[::include(path)::]`, nested up to eight levels deep, with cycle detection.
- **Fan-out**: render one template to several targets with `$PATH:{a,b,c}`.
- **Required variables**: `$REQUIRE:{A,B}` validates up front and reports every missing name at once.
- **Inline mode**: `--header` renders a template given on the command line or on stdin, no file needed.
- **Directory scanning**: recursive discovery of `*.dcol` and `*.theme` files in natural sort order.

### Hooks

- `$PRE` hooks run before rendering and can export variables. `$RUN` hooks run after the file is written (reload a service, signal a process, and so on).
- Both are **off by default** and enabled with `--allow-pre` / `--allow-run`. `--dont-run` is a kill switch that always wins.
- Per-hook timeouts that kill the whole process tree, retries with back-off for `$PRE`, allow-list regexes, and a deferred `$RUN` queue (serial, N at a time, or detached).

### Safety and reliability

- **Atomic writes**: temp file, `fsync`, then `rename` in the target's own directory, with a fallback for cross-device targets.
- **Idempotent**: unchanged output is never rewritten, so file watchers and modification times are not disturbed.
- **Per-target locking** with stale-lock recovery, so overlapping runs cannot corrupt a file.
- **Refuses to run as root.**
- **Robust environment**: `HOME`, `USER`, `LOGNAME` and `HOSTNAME` are always defined (even under cron, systemd or minimal containers), and stray trailing carriage returns are stripped from environment values.
- **Strict modes** turn warnings into errors (`--allow-warn`) and stop the run at the first failure (`--fail-fast`).

### Performance

- `--proc N` / `--proc auto` renders in parallel worker processes. Output stays deterministic: templates that resolve to the same target are grouped onto one worker and processed in order.
- `--pre-scan` runs each unique `$PRE` hook once, up front, instead of once per worker.
- Fast startup: optional modules such as `Digest::SHA` are loaded only when needed.

### Observability

- `--allow-debug` reports every file written or skipped; `--allow-dry-run` previews a run.
- A JSON-lines **audit log** of every hook execution (secret values redacted), a **manifest** of every file written (with SHA-256), and a one-line **JSON run summary**.
- Structured, greppable diagnostics and documented exit codes.

## Focus and design goals

hyir is deliberately narrow. It aims to be:

1. **Predictable**: a single placeholder grammar, no conditionals or loops, deterministic ordering. What you see in the template is what you get.
2. **Safe by default**: hooks are opt-in, root is refused, and hook commands can be allow-listed and audited.
3. **Cheap to re-run**: idempotent and atomic, so it is safe to call from cron, systemd units, login scripts, file watchers or CI.
4. **Self-contained**: one file, Bash plus core Perl, no packages to install.
5. **Observable**: everything it does can be logged in a machine-readable form.

It is a good fit for theming and dotfile setups driven from a palette, per-environment application config, Kubernetes/Helm-style manifests and CI pipeline YAML, and any case where the same values must be rendered into several files.

hyir is **not** a programming language for templates (there are no loops, conditionals or expressions) and **not** a configuration-management or deployment system. It renders text files from variables and runs the commands you allow.

## Requirements

- **Bash** and **Perl 5**, using core modules only (`Digest::SHA`, used for `--manifest` checksums, is loaded on demand).
- An `env` that supports `-0` (GNU coreutils does). hyir uses it to capture the environment left behind by `$PRE` hooks.
- A Unix-like OS. The defaults assume Linux: lock files live in `$HYIR_RUNTIME_DIR/hyir`, else `$XDG_RUNTIME_DIR/hyir`, else `/run/user/<uid>/hyir`. Where none of those exist, set `HYIR_RUNTIME_DIR` to a writable directory.
- A regular (non-root) user account.

## Installation

```bash
git clone https://github.com/valkyrieAttr/hyir.git --depth 1
cd hyir
mkdir -p ~/.local/bin
install -m 0755 hyir.sh ~/.local/bin/hyir.sh
hyir.sh --help
```

Make sure `~/.local/bin` is on your `PATH`. For a system-wide install, copy the script to `/usr/local/bin` instead.

Messages adapt to the name the script is invoked as, so you may rename it to `hyir` if you prefer. This document uses `hyir.sh` throughout.

## Quick start

**1. Write a template.** The first line is the header; everything after it is the body.

```bash
mkdir -p templates
cat > templates/greeting.dcol <<'EOF'
$PATH:[::HOME::]/.config/demo/greeting.conf
# Generated by hyir from [::_SOURCE_BASENAME::] -- do not edit by hand
user     = [::USER::]
greeting = "Hello, [::NAME:-world::]!"
EOF
```

**2. Render it.** Placeholders are filled in from the environment.

```bash
NAME=Ada hyir.sh templates/
cat ~/.config/demo/greeting.conf
```

```text
# Generated by hyir from greeting.dcol -- do not edit by hand
user     = alice
greeting = "Hello, Ada!"
```

**3. Run it again.** Nothing changed, so nothing is rewritten. Add `--allow-debug` to see what hyir decided:

```bash
NAME=Ada hyir.sh --allow-debug templates/
```

```text
@[populate:write(false)]: Skipped changing /home/alice/.config/demo/greeting.conf <- templates/greeting.dcol
@[diagnostic:telemetry(On)]: Rendered 1 templates using 1 workers in 0.0026 seconds (all succeeded).
```

Successful runs are silent by default. Drop `NAME` and the fallback applies (`Hello, world!`); hyir then rewrites the file because its content changed.

## How it works

For each run, hyir does the following:

1. **Discover.** Every path you pass is either a template file or a directory. Directories are scanned recursively for `*.dcol` and `*.theme` files (both extensions are treated identically). All templates are sorted together in *natural* order: case-insensitive, with numbers compared numerically, so `9-base.dcol` is processed before `10-overrides.dcol`. The order of arguments on the command line does not matter.
2. **Parse the header.** `$PATH`, `$REQUIRE`, `$PRE` and `$RUN` are read from the top of each template. A template with no `$PATH` has no target and is skipped.
3. **Run `$PRE`** (only if allowed). The hook runs in a subshell and whatever it *exports* becomes available to placeholders.
4. **Check `$REQUIRE`.** If any required variable is missing, the template is skipped: nothing is written and no `$RUN` hook fires.
5. **Render.** Placeholders in the target path, in the hook text and in the body are substituted.
6. **Write.** Each target is written atomically under a per-target lock, but only if its content differs from what is already on disk.
7. **Run `$RUN`** (only if allowed), either immediately or, with `--defer-run`, after every template has been rendered.

With `--proc N`, steps 2 to 7 are spread across N worker processes. Templates that resolve to the same target are always handled by the same worker, in order.

## Template reference

> Coming from an earlier version? Placeholder and header syntax changed; see [MIGRATION.md](MIGRATION.md).

### Header

```text
$PATH:<target>|$REQUIRE:{VAR1,VAR2}|$PRE:{hook}|$RUN:{hook}
```

The header is the first line of the file. When a value is wrapped in `{ ... }` it may span several lines (braces are matched properly, including nested ones). Segments are separated by `|`. Only `$PATH` is required. Put `$RUN` **last**: it may itself contain `|` (for example a shell pipeline), so it absorbs everything after it.

| Tag | Purpose |
| --- | --- |
| `$PATH:target` | Output file. Parent directories are created. Placeholders in the path are expanded; `~` is **not** (use `[::HOME::]`). |
| `$PATH:{a,b,c}` | Fan-out: the same body is written to every listed target. |
| `$REQUIRE:{A,B}` | Variables that must be set (an empty value counts as set). Checked after `$PRE` runs. All missing names are reported together, and the template is not written. |
| `$PRE:{...}` | Shell snippet run before rendering. Variables it **exports** are visible to placeholders. Requires `--allow-pre`. |
| `$RUN:{...}` | Shell snippet run after the file is written, for example to reload a service. Requires `--allow-run`. |

Placeholders inside hook text are substituted before the hook runs. A multi-line header looks like this:

```text
$PATH:[::HOME::]/.config/app/settings.toml|$REQUIRE:{SHORT_HOST}|$PRE:{
  export SHORT_HOST=$(hostname -s)
  export BUILD_DATE=$(date +%Y-%m-%d)
}|$RUN:{
  systemctl --user reload app.service
}
host       = "[::SHORT_HOST::]"
build_date = "[::BUILD_DATE::]"
```

A file whose first line contains no recognized tag is treated as having no header, and is skipped because it has no target. A misspelled tag produces a warning.

### Placeholders

| Syntax | Meaning |
| --- | --- |
| `[::NAME::]` | Value of the environment variable `NAME`. |
| `[::NAME:-fallback::]` | `fallback` if `NAME` is **unset**. An empty value still counts as a value. The fallback may contain placeholders. |
| `[::modifier:NAME::]` | Apply one or more modifiers. Chain with `:`, applied right to left, so `[::json:upper:NAME::]` is `json(upper(NAME))`. |
| `[::NAME_rgba::]`, `[::NAME_rgba(0.5)::]` | Derived color (see [Color helper](#color-helper)). |
| `[::_NOW::]`, `[::_UUID::]`, ... | Built-ins (see below). |
| `[::include(path)::]` | Insert another file, rendered with the same variables. |

A placeholder that cannot be resolved is left in the output as literal text and a warning is printed. Use `$REQUIRE` for anything that must be present, or `--allow-warn` to make unresolved placeholders an error.

### Modifiers

| Modifier | Effect |
| --- | --- |
| `json` | Escape for a JSON string (quotes, backslashes, control characters). Does not add surrounding quotes. |
| `yaml` | Same escaping, suitable inside a double-quoted YAML scalar. |
| `base64` | Base64-encode, without line breaks. |
| `upper`, `lower` | Change case. |
| `trim` | Strip leading and trailing whitespace. |
| `indent(N)` | Prefix every line with N spaces. |
| `nindent(N)` | A newline followed by `indent(N)`. Same semantics as Helm/Sprig. |

An unknown modifier leaves the placeholder as-is with a warning (an error under `--allow-warn`).

### Built-ins

Built-ins are computed once per template, so repeated references within a file are consistent. They take precedence over environment variables of the same name.

| Name | Value |
| --- | --- |
| `_NOW` | Current UTC time, ISO 8601 (`2026-09-21T13:43:09Z`). |
| `_NOW_UNIX` | Current time as Unix seconds. |
| `_UUID` | A random UUID (version 4). |
| `_INDEX`, `_TOTAL` | 1-based position of this template in the run, and the number of templates. |
| `_SOURCE` | Path of the template being rendered. |
| `_SOURCE_BASENAME`, `_SOURCE_DIR` | File name and directory of the template. |

`_NOW` and `_UUID` change on every run, so a template that uses them is rewritten every time.

`HOME`, `USER`, `LOGNAME` and `HOSTNAME` are always defined: when the environment lacks them (cron, systemd units without `Environment=`, minimal containers), hyir fills them in from the account and host information.

### Color helper

If a variable holds a color as `#RGB`, `#RRGGBB`, `rgb(r,g,b)` or `rgba(r,g,b,a)`, hyir derives a companion `NAME_rgba` automatically. The argument in parentheses is the **alpha** channel:

| Placeholder (with `ACCENT=#ff8800`) | Result |
| --- | --- |
| `[::ACCENT_rgba::]` | `rgba(255,136,0,1)` |
| `[::ACCENT_rgba(0.25)::]` | `rgba(255,136,0,0.25)` |

### Includes

`[::include(partials/footer.txt)::]` inserts a file and renders it with the same variables. Relative paths are resolved from the directory of the template being rendered. Includes may nest up to eight levels deep; a cycle is an error. The included text is inserted as-is, including its trailing newline. Give partials an extension other than `.dcol` / `.theme` so directory scans do not pick them up as templates.

## Command-line reference

```text
hyir.sh [FLAGS] [--] <template-or-directory> [<template-or-directory> ...]
```

> [!IMPORTANT]
> **Flags must come before template paths.** Parsing stops at the first argument that is not a flag, and everything after it is treated as a path. The list-style flags (`--file`, `--env`, `--ignore-templates`, `--header`) consume every following argument until the next flag or `--`, so end them with `--`:
>
> ```bash
> hyir.sh --env S:values.env --allow-run -- templates/ extra/one-off.dcol
> ```

### Input

| Flag | Description |
| --- | --- |
| `--file PATH...` | Template files or directories to process. Equivalent to positional paths; repeatable. Files named explicitly are used whatever their extension. |
| `--ignore-templates NAME...` | File names (not paths) to skip during directory scans. Repeatable. |
| `--header FIELD...` | Override header fields or supply an inline template (see below). |
| `-h`, `--help` | Show the built-in help and exit. |

`--header` accepts these fields:

| Field | Effect |
| --- | --- |
| `T:<target>` | Force `$PATH` for **every** template in the run. |
| `P:<hook>` | Force `$PRE` for every template in the run. |
| `R:<hook>` | Force `$RUN` for every template in the run. |
| `B:<text>` | Add an inline template whose body is `<text>`. The escapes `\n`, `\t`, `\r`, `\0` and `\\` are interpreted. |
| `B:-` | Read the inline body from stdin. |

### Environment

| Flag | Description |
| --- | --- |
| `--env S:PATH...` | `source` one or more files before rendering. Variables they define are exported automatically. Bash executes these files, so treat them as code. |
| `--env E:NAME=value...` | Set variables. `S:` and `E:` items can be mixed and repeated. |
| `--sanitize-env-full` | After a `$PRE` hook changes the environment, trim leading and trailing whitespace from every variable. Off by default because it silently mangles intentionally padded values; a trailing carriage return is always stripped. Env: `HYIR_SANITIZE_ENV_FULL`. |

### Hooks and security

| Flag | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `--allow-pre` | `HYIR_ALLOW_PRE` | off | Allow `$PRE` hooks to run. |
| `--allow-run` | `HYIR_ALLOW_RUN` | off | Allow `$RUN` hooks to run. |
| `--dont-run` | `HYIR_FORCE_NO_RUN` | off | Force `$RUN` hooks off. Always wins over `--allow-run` and the environment. |
| `--pre-scan` | `HYIR_PRE_SCAN` | off | Run every unique `$PRE` hook once, up front, before forking workers. Requires `--allow-pre`. Recommended with `--proc` above 1 when hooks are not idempotent. |
| `--pre-allow-pattern REGEX` | `HYIR_PRE_ALLOW_PATTERN` | none | Refuse any `$PRE` hook whose text does not match. The template fails and is not written. |
| `--run-allow-pattern REGEX` | `HYIR_RUN_ALLOW_PATTERN` | none | Refuse any `$RUN` hook whose text does not match. The run is marked failed. |
| `--hook-timeout SECONDS` | `HYIR_HOOK_TIMEOUT` | unlimited | Kill a hook, and everything it spawned, after this long. Does not apply to detached hooks. |
| `--hook-retries N` | `HYIR_HOOK_RETRIES` | `0` | Retry a failed `$PRE` hook up to N more times with a short back-off. `$RUN` hooks are never retried, since they usually have side effects. |
| `--defer-run` | `HYIR_DEFER_RUN` | off | Queue all `$RUN` hooks until every template has been rendered. |
| `--run-concurrency N` | `HYIR_RUN_CONCURRENCY` | `1` | For deferred `$RUN` hooks: `0` runs them detached (output goes to `nohup.out` in the runtime directory), `1` runs them one at a time, and N above 1 runs up to N at once. |

Allow-patterns are Perl-compatible regular expressions matched against the hook text after placeholder substitution. They are **not anchored automatically**; anchor them yourself (see [Security model](#security-model)).

### Concurrency, locking and writing

| Flag | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `--proc N`, `--proc auto` | `HYIR_PROC` | `1` | Number of worker processes. `auto` (or `0`) uses the number of CPU cores. The environment variable takes a number only. |
| `--lock-timeout SECONDS` | `HYIR_LOCK_TIMEOUT` | `10` | How long to wait for a target's lock before failing. |
| `--lock-stale-after SECONDS` | `HYIR_LOCK_STALE_AFTER` | same as `--lock-timeout` | Age after which an unreleased lock is treated as abandoned and reclaimed. |
| `--no-atomic` | `HYIR_NO_ATOMIC` | off | Skip the `fsync` before the final rename. Faster, but a crash or power loss shortly after a run can leave the file incomplete. |

### Strictness and diagnostics

| Flag | Environment variable | Description |
| --- | --- | --- |
| `--allow-warn` | `HYIR_STRICT` | Treat warnings as errors: unbound variables, unknown modifiers and unrecognized header content. |
| `--ignore-unbound` | `HYIR_IGNORE_UNBOUND` | Leave unbound placeholders as literal text with no warning at all. Overridden by `--allow-warn`. |
| `--disable-fallback` | `HYIR_DISABLE_FALLBACK` | Reject any use of `:-` fallback syntax as an error. |
| `--fail-fast` | `HYIR_FAIL_FAST` | Stop taking on new work as soon as any template or hook fails, instead of finishing the batch. |
| `--allow-dry-run` | `HYIR_DRY_RUN` | Do not write files or run `$RUN` hooks. Combine with `--allow-debug` to see the report. `$PRE` hooks still execute, because their output feeds rendering. |
| `--allow-debug` | `HYIR_DEBUG` | Print a line for every file written or skipped, plus a run summary. |

### Output and auditing

| Flag | Environment variable | Description |
| --- | --- | --- |
| `--audit-log PATH` | `HYIR_AUDIT_LOG` | Append a JSON-lines record of every `$PRE` and `$RUN` execution: timestamp, pid, action, command (secrets redacted), exit code and duration. |
| `--secret-pattern REGEX` | `HYIR_SECRET_PATTERN` | Variable-name pattern treated as sensitive when redacting the audit log. The default matches names containing `SECRET`, `PASSWORD`, `PASSWD`, `TOKEN`, `API_KEY`, `APIKEY`, `PRIVATE_KEY` or `CREDENTIAL`, or ending in `_PAT` (case-insensitive). |
| `--manifest PATH` | `HYIR_MANIFEST` | Append a JSON-lines record (`target`, `source`, `sha256`) for every file actually written. |
| `--stats-json PATH` | `HYIR_STATS_JSON` | Write a one-line JSON summary on exit: `files`, `workers`, `elapsed_seconds`, `failed`. |

The parent directories of these files must already exist.

### Environment variables

Every flag with an entry in the tables above has a `HYIR_*` equivalent. Boolean variables are enabled by `1`, `true` or `yes` (case-insensitive). When both are given, the flag wins, except `--dont-run` / `HYIR_FORCE_NO_RUN`, which always wins. The list-style flags (`--file`, `--env`, `--ignore-templates`, `--header`) are command-line only.

One more variable is not tied to a flag:

| Variable | Description |
| --- | --- |
| `HYIR_RUNTIME_DIR` | Base directory for runtime state: locks, the deferred-run queue and the detached-hook log. hyir uses its `hyir/` subdirectory. Defaults to `$XDG_RUNTIME_DIR`, then `/run/user/<uid>`. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every template and hook succeeded. |
| `1` | At least one template or hook failed, or there was nothing to do (no valid paths, no templates found), or hyir was run as root. |
| `2` | Invalid command-line arguments. |

Fatal setup errors, such as a runtime directory that cannot be created, also exit non-zero. Warnings on their own (for example an unbound placeholder) do not change the exit code unless `--allow-warn` is set.

Successful runs print nothing. Warnings and errors go to stderr, prefixed with a structured tag such as `@[diagnostic:warn(true)]:` or `@[populate:error(true)]:`, which makes them easy to grep.

## Recipes

### Render one template to several targets

```text
$PATH:{[::HOME::]/nginx/conf.d/app.conf,[::HOME::]/backup/app.conf}|$REQUIRE:{APP_HOST,APP_PORT}
server {
    server_name [::APP_HOST::];
    location / { proxy_pass http://127.0.0.1:[::APP_PORT::]; }
}
```

```bash
APP_HOST=example.test APP_PORT=8080 hyir.sh -- templates/
```

Missing `APP_HOST` or `APP_PORT` aborts this template before anything is written.

### Kubernetes manifest with modifiers

`values.env`

```bash
APP_NAME=Demo
REPLICAS=3
DESCRIPTION='Demo "service"'
CONFIG_BLOCK=$'log_level: info\nretries: 3'
```

`templates/deployment.yaml.dcol`

```text
$PATH:out/deployment.yaml|$REQUIRE:{APP_NAME,REPLICAS}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: [::lower:APP_NAME::]
spec:
  replicas: [::REPLICAS::]
  template:
    metadata:
      annotations:
        description: "[::yaml:DESCRIPTION::]"
        config: |
[::indent(10):CONFIG_BLOCK::]
```

```bash
hyir.sh --env S:values.env -- templates/
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
spec:
  replicas: 3
  template:
    metadata:
      annotations:
        description: "Demo \"service\""
        config: |
          log_level: info
          retries: 3
```

### Theme a set of apps from one palette

```text
$PATH:[::HOME::]/.config/myapp/colors.css|$REQUIRE:{ACCENT,BACKGROUND}|$RUN:{systemctl --user reload myapp.service}
:root {
  --accent:      [::ACCENT::];
  --accent-soft: [::ACCENT_rgba(0.25)::];
  --accent-glow: [::ACCENT_rgba(0.60)::];
  --background:  [::BACKGROUND::];
}
```

```bash
ACCENT='#ff8800' BACKGROUND='#101418' hyir.sh --allow-run -- themes/
```

Keep the palette in an env file and load it with `--env S:palette.env` to switch themes with a single flag.

### Compute variables with a `$PRE` hook

See the multi-line header under [Header](#header). Remember that a `$PRE` hook must `export` what it wants placeholders to see, and that hooks need `--allow-pre`:

```bash
hyir.sh --allow-pre --allow-run -- templates/
```

### Render without a template file

```bash
hyir.sh --env E:NAME=Ada --header T:/tmp/hello.txt 'B:Hello, [::NAME::]!\nSecond line\n'
```

Or read the body from stdin:

```bash
printf 'from stdin: [::NAME::]\n' | hyir.sh --env E:NAME=Ada --header T:/tmp/stdin.txt B:-
```

### Strict, parallel CI run

```bash
hyir.sh --allow-warn --fail-fast --dont-run \
        --proc auto \
        --manifest build/manifest.jsonl \
        --stats-json build/stats.json \
        -- ci/templates/
```

Warnings become errors, the first failure stops the run, no `$RUN` hook can fire, and the manifest records a SHA-256 for every file written. The `build/` directory must exist before the run.

### Compose files in a fixed order

Templates are processed in natural sort order, and if two templates resolve to the same target, the **last one wins**. Numeric prefixes make the order explicit:

```text
templates/
  10-base.dcol        # $PATH:out/app.conf
  20-overrides.dcol   # $PATH:out/app.conf   (this one wins)
```

## Security model

> [!WARNING]
> Templates containing `$PRE` or `$RUN` run shell commands as your user, and files passed to `--env S:` are executed by Bash. Treat template directories like code: only render templates you trust, and keep them writable only by people you trust.

- **Hooks are opt-in.** Nothing runs unless you pass `--allow-pre` / `--allow-run` (or set the environment variables). `--dont-run` overrides everything else.
- **Placeholders are plain substitution.** Template bodies are never evaluated as code.
- **Narrow what hooks may do.** `--pre-allow-pattern` and `--run-allow-pattern` refuse any hook that does not match. Anchor the patterns with `^` and `$` and keep them strict; an unanchored pattern such as `touch` would also allow `rm -rf ~; touch x`.
- **Bound the damage.** `--hook-timeout` kills a runaway hook together with every process it spawned.
- **Keep a record.** `--audit-log` records every hook execution. Values of variables whose names match `--secret-pattern` are replaced with `***REDACTED***`.
- **No root.** hyir exits immediately if run as root.
- **Private by default.** Newly created target files get mode `0600`; existing targets keep their current permissions.

A hardened invocation might look like this:

```bash
mkdir -p ~/.local/state/hyir

hyir.sh --allow-run \
        --run-allow-pattern '^systemctl --user (reload|restart) [A-Za-z0-9@._-]+\.service$' \
        --hook-timeout 30 \
        --audit-log ~/.local/state/hyir/audit.jsonl \
        -- templates/
```

## Behavior notes

Things worth knowing before you rely on hyir:

- **Flag order matters.** Put flags first and end list-style flags with `--` (see [Command-line reference](#command-line-reference)).
- **`~` is not expanded** in `$PATH`. Use `[::HOME::]`.
- **Templates without a `$PATH` are skipped silently.** Run with `--allow-debug` to see them reported.
- **`$RUN` goes last** in the header.
- **`$PRE` hooks must `export`.** A plain `NAME=value` is not visible to placeholders. Variables exported by a `$PRE` hook stay in the environment for later templates handled by the same worker, so declare what each template needs in `$REQUIRE`.
- **`$RUN` hooks fire on every run**, whether or not the file changed, unless `$REQUIRE` failed. Keep them idempotent and cheap.
- **A failed `$PRE` hook does not stop rendering.** The template is still rendered, with anything the hook would have provided left unresolved, unless `$REQUIRE` catches the missing variables. The run exits with status 1 either way. Use `$REQUIRE` for anything mandatory.
- **Dry runs print only with `--allow-debug`**, and `$PRE` hooks still execute during a dry run.
- **Fallbacks apply to unset variables**, not empty ones. `$REQUIRE` also accepts an empty value.
- **Same target, last writer wins.** When several templates resolve to one target, the last in natural sort order is the one you get.
- **Inline bodies** (`--header B:`) interpret `\n`, `\t`, `\r`, `\0` and `\\`, and a body read from stdin loses its trailing newline.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `No valid file or directory paths given` | No readable path was passed, or a list-style flag swallowed it. Put `--` before your paths. |
| A flag seems to be ignored | Flags placed after the first path are treated as paths. Move flags before the paths. |
| A template produces no output | It has no `$PATH`. Run with `--allow-debug` to see `No target specified ... skipping`. |
| `Unbound variable [::X::] ... leaving as placeholder` | `X` is not in the environment (or a `$PRE` hook set it without `export`). Provide it, add a `:-` fallback, or add it to `$REQUIRE`. |
| `Skipping pre-hook (HYIR_ALLOW_PRE not enabled)` | Pass `--allow-pre`. |
| A `$RUN` hook never fires | It needs `--allow-run`. Also check `--dont-run` / `HYIR_FORCE_NO_RUN`, that `$RUN` is the last tag in the header, and that `$REQUIRE` did not fail. |
| `Timeout acquiring lock ...` | Another hyir process is writing the same target, or a lock was abandoned. Raise `--lock-timeout`, or lower `--lock-stale-after` so abandoned locks are reclaimed sooner. |
| `Cannot create locks dir ...` | The runtime directory is missing or unwritable (common on macOS and minimal containers). Set `HYIR_RUNTIME_DIR` to a writable directory. |
| `hyir.sh must not be run as root` | Run it as a regular user. |
| A directory literally named `~` appeared | `~` is not expanded in `$PATH`. Use `[::HOME::]`. |
| `--audit-log` or `--manifest` produced no file | Their parent directory must already exist. |
| A hidden temporary file sits next to a target | Left behind by an interrupted run. It is safe to delete. |

## Contributing

Issues and pull requests are welcome. Before opening a pull request:

```bash
# Lint the Bash launcher
shellcheck hyir.sh

# Syntax-check the embedded Perl engine
sed -n '/^exec perl - <<.HYIR_PERL_SCRIPT_EOF.$/,/^HYIR_PERL_SCRIPT_EOF$/p' hyir.sh \
  | sed '1d;$d' \
  | perl -c
```
