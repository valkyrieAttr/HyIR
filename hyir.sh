#!/usr/bin/env bash
# hyir.sh -- template/config generation engine
#
# See --help for usage. See MIGRATION.md (shipped alongside this script)
# for the placeholder-syntax and header-syntax migration from previous
# versions.
set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
export SCRIPT_NAME

# Internal separator for multi-path environment variables (template file
# list, ignore list). ':' broke on any path containing a literal colon;
# NUL can't survive being passed through the environment at all. ASCII
# Unit Separator (0x1F) is not NUL, so it does survive export/exec, and it
# essentially never appears in a real file path.
SEP=$'\x1f'

print_help() {
    cat <<HELPEOF
${SCRIPT_NAME} -- template/config generation engine

USAGE:
  ${SCRIPT_NAME} [FLAGS] <path/to/template|path/to/dir> [more paths...]

TEMPLATE HEADER SYNTAX:
  Each .dcol/.theme file's first line (or first brace-spanning block) is a
  header describing where its rendered body goes and what runs around it:

      \$PATH:path/to/target|\$REQUIRE:{VAR1,VAR2}|\$PRE:{hooks}|\$RUN:{hooks}

  \$PATH is required; \$REQUIRE, \$PRE, and \$RUN are optional and may appear
  in any order. \$PATH:{a,b,c} fans the same rendered body out to multiple
  targets. A file with no \$PATH: tag has no defined target and is skipped
  entirely -- there is no untagged/bare-path fallback.

PLACEHOLDER SYNTAX:
  [::NAME::]                     simple substitution
  [::NAME:-fallback::]           fallback if NAME is unset
  [::name_rgba(r,g,b,a)::]       derive an rgba() string from a color value
  [::json:NAME::]                apply modifier(s), right-to-left, then substitute
  Modifiers: json, yaml, base64, upper, lower, trim, indent(N), nindent(N)
  Built-ins: _NOW, _NOW_UNIX, _UUID, _INDEX, _TOTAL, _SOURCE,
             _SOURCE_BASENAME, _SOURCE_DIR, include(path/to/partial)

  This is the only placeholder syntax this engine recognizes. 


FLAGS:
  --env [S:path|E:VAR=val..]         Load extra environment before rendering:
                                        S:<path>   source a file (repeatable)
                                        E:VAR=val  set one variable (repeatable)

  --proc              [N|auto]       Worker processes to use. 'auto' (or 0) detects the
  --file              [path..]       One or more template files or directories to scan
                                     (recursively, for *.dcol/*.theme). Repeatable.

  --header            [T:P:R:B = V]  Override header fields instead of reading a file:
                                        T:<target>   override/force \$PATH
                                        P:<pre>      override/force \$PRE
                                        R:<run>      override/force \$RUN
                                        B:<text|->   provide the whole template body
                                              (text inline, or '-' to read stdin)

  --ignore-templates  [name..]       Filenames to skip during directory scans. Repeatable.
                                     number of available cores. Default: 1.

  --lock-timeout      [N]            Seconds to wait for a lock before giving up. Default: 10.
  --lock-stale-after  [N]            Seconds before an unreleased lock is considered
                                     abandoned and eligible for reclaiming. Default: same as
                                     --lock-timeout.

  --run-concurrency   [N]            Deferred RUN hooks: 0 = fire-and-forget (detached,
                                     logged to \$XDG_RUNTIME_DIR/hyir/nohup.out), 1 = serial
                                     (default), >1 = run up to N at once.

  --hook-timeout      [N]            Kill a PRE or RUN hook (and everything it spawned) if it
                                     runs longer than N seconds. Default: unlimited.

  --hook-retries      [N]            Retry a failed PRE hook up to N additional times with a
                                     short backoff. Default: 0. (RUN hooks are not retried --
                                     they usually have side effects that shouldn't repeat.)

  --pre-allow-pattern [regex]        Refuse to run any PRE hook that doesn't match this regex.
  --run-allow-pattern [regex]        Refuse to run any RUN hook that doesn't match this regex.

  --secret-pattern    [regex]        Env var NAME pattern treated as sensitive for --audit-log redaction. 
                                     Default covers SECRET/PASSWORD/TOKEN/API_KEY/PRIVATE_KEY/CREDENTIAL/*_PAT.

  --audit-log         [path]        Append a JSON-lines record of every PRE/RUN hook
                                    execution (secret values redacted).

  --manifest          [path]        Append a JSON-lines record (target, source, sha256) for
                                    every file actually written.

  --stats-json        [path]        Write a one-line JSON run summary on exit.


  --allow-pre                       Allow \$PRE hooks to run (disabled by default).
  --allow-run                       Allow \$RUN hooks to run (disabled by default).

  --dont-run                        Force RUN hooks off, overriding --allow-run/env
                                    even if set elsewhere. Always wins.

  --pre-scan                        Run every unique \$PRE hook once, up front, before
                                    forking workers, instead of per-template. Requires
                                    --allow-pre. Strongly recommended whenever --proc > 1
                                    and your PRE hooks are not idempotent.

  --fail-fast                       Stop taking on new work as soon as any template, PRE
                                    hook, or RUN hook fails, instead of finishing the batch
                                    and reporting failures at the end.

  --allow-warn                      Treat things that are normally a warning (an unbound
                                    variable, an untagged header target, unrecognized
                                    header content) as a hard error instead.

  --ignore-unbound                  Leave unbound placeholders as literal text with no
                                    warning at all. Overridden by --allow-warn.

  --disable-fallback                Reject any use of :- fallback syntax as an error.
  --allow-dry-run                   Report what would change/run without writing anything
                                    or executing any RUN hook.

  --allow-debug                     Print a line for every hook run and file written/skipped.
  --defer-run                       Queue all RUN hooks until every template has been
                                    rendered, then run them (subject to --run-concurrency).

  --no-atomic                       Write target files directly instead of via a temp file +
                                    atomic rename. Faster, but a crash mid-write can leave a
                                    partial file.

  --sanitize-env-full               Trim all leading/trailing whitespace from every
                                    environment variable after a PRE hook changes the
                                    environment (the pre-1.x default). Off by default because
                                    it silently mangles intentionally-padded values; only a
                                    trailing \\r is stripped unconditionally.

  --help                            Show this help and exit.

ENVIRONMENT:
  Every flag above has a HYIR_* environment variable equivalent (e.g.
  --allow-run is HYIR_ALLOW_RUN=1); flags take precedence when both are set,
  except --dont-run, which always wins over any other RUN-enabling source.
HELPEOF
}

# --- locate a usable lock directory -----------------------------------------
if [[ -n "${HYIR_RUNTIME_DIR:-}" ]]; then
    HYIR_LOCK_DIR="${HYIR_RUNTIME_DIR}/hyir"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    HYIR_LOCK_DIR="${XDG_RUNTIME_DIR}/hyir"
else
    HYIR_LOCK_DIR="/run/user/$(id -u)/hyir"
fi
export HYIR_LOCK_DIR

# --- defaults ----------------------------------------------------------------
export HYIR_PROC="${HYIR_PROC:-1}"
export HYIR_LOCK_TIMEOUT="${HYIR_LOCK_TIMEOUT:-10}"
export HYIR_RUN_CONCURRENCY="${HYIR_RUN_CONCURRENCY:-1}"
export HYIR_HOOK_TIMEOUT="${HYIR_HOOK_TIMEOUT:-0}"
export HYIR_HOOK_RETRIES="${HYIR_HOOK_RETRIES:-0}"

TEMPLATE_FILES=()
FORCE_NO_RUN=0

die_arg() {
    printf "@[diagnostic:error:arg(true)]: %s\n" "$1" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --help | -h)
        print_help
        exit 0
        ;;
    --file)
        shift
        if [[ -z "${1:-}" ]]; then die_arg "--file requires at least one path"; fi
        while [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            TEMPLATE_FILES+=("$1")
            shift
        done
        continue
        ;;
    --ignore-templates)
        shift
        if [[ -z "${1:-}" ]]; then die_arg "--ignore-templates requires at least one filename"; fi
        while [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            if [[ -z "${HYIR_IGNORE_TEMPLATES:-}" ]]; then
                HYIR_IGNORE_TEMPLATES="$1"
            else
                HYIR_IGNORE_TEMPLATES="${HYIR_IGNORE_TEMPLATES}${SEP}$1"
            fi
            shift
        done
        export HYIR_IGNORE_TEMPLATES
        continue
        ;;
    --header)
        shift
        export HYIR_HEADER_INIT=1
        while [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            case "$1" in
            T:*) export HYIR_HEADER_TARGET="${1#T:}" ;;
            R:*) export HYIR_HEADER_RUN="${1#R:}" ;;
            P:*) export HYIR_HEADER_PRE="${1#P:}" ;;
            B:*)
                if [[ "${1#B:}" == "-" ]]; then
                    HYIR_HEADER_BUFFER="$(cat)"
                else
                    HYIR_HEADER_BUFFER="${1#B:}"
                fi
                export HYIR_HEADER_BUFFER
                ;;
            *)
                die_arg "Invalid --header argument: $1 (expected T:, P:, R:, or B:)"
                ;;
            esac
            shift
        done
        continue
        ;;
    --env)
        shift
        set -a
        env_mode=""
        while [[ "$#" -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            case "$1" in
            "E:") env_mode="E" ;;
            E:*)
                env_mode="E"
                val="${1#E:}"
                [[ "$val" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die_arg "--env E: value must look like NAME=value, got: $val"
                export "$val"
                ;;
            "S:") env_mode="S" ;;
            S:*)
                env_mode="S"
                path="${1#S:}"
                [[ -e "$path" && -n "$path" ]] || die_arg "--env S: file not found: $path"
                # shellcheck disable=SC1090
                source "$path"
                ;;
            *)
                if [[ "$env_mode" == "E" ]]; then
                    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die_arg "--env E: value must look like NAME=value, got: $1"
                    export "$1"
                elif [[ "$env_mode" == "S" ]]; then
                    [[ -e "$1" ]] || die_arg "--env S: file not found: $1"
                    # shellcheck disable=SC1090
                    source "$1"
                else
                    die_arg "--env values must begin with S: or E:"
                fi
                ;;
            esac
            shift
        done
        set +a
        continue
        ;;
    --proc)
        shift
        [[ -n "${1:-}" ]] || die_arg "--proc requires a value"
        if [[ "$1" == "auto" || "$1" == "0" ]]; then
            HYIR_PROC="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        elif [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
            HYIR_PROC="$1"
        else
            die_arg "--proc must be a positive integer, 0, or 'auto', got: $1"
        fi
        export HYIR_PROC
        ;;
    --lock-timeout)
        shift
        [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die_arg "--lock-timeout must be a non-negative number"
        export HYIR_LOCK_TIMEOUT="$1"
        ;;
    --lock-stale-after)
        shift
        [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die_arg "--lock-stale-after must be a non-negative number"
        export HYIR_LOCK_STALE_AFTER="$1"
        ;;
    --run-concurrency)
        shift
        [[ "${1:-}" =~ ^[0-9]+$ ]] || die_arg "--run-concurrency must be a non-negative integer"
        export HYIR_RUN_CONCURRENCY="$1"
        ;;
    --hook-timeout)
        shift
        [[ "${1:-}" =~ ^[0-9]+$ ]] || die_arg "--hook-timeout must be a non-negative integer (seconds)"
        export HYIR_HOOK_TIMEOUT="$1"
        ;;
    --hook-retries)
        shift
        [[ "${1:-}" =~ ^[0-9]+$ ]] || die_arg "--hook-retries must be a non-negative integer"
        export HYIR_HOOK_RETRIES="$1"
        ;;
    --pre-allow-pattern)
        shift
        [[ -n "${1:-}" ]] || die_arg "--pre-allow-pattern requires a regular expression"
        export HYIR_PRE_ALLOW_PATTERN="$1"
        ;;
    --run-allow-pattern)
        shift
        [[ -n "${1:-}" ]] || die_arg "--run-allow-pattern requires a regular expression"
        export HYIR_RUN_ALLOW_PATTERN="$1"
        ;;
    --secret-pattern)
        shift
        [[ -n "${1:-}" ]] || die_arg "--secret-pattern requires a regular expression"
        export HYIR_SECRET_PATTERN="$1"
        ;;
    --audit-log)
        shift
        [[ -n "${1:-}" ]] || die_arg "--audit-log requires a path"
        export HYIR_AUDIT_LOG="$1"
        ;;
    --manifest)
        shift
        [[ -n "${1:-}" ]] || die_arg "--manifest requires a path"
        export HYIR_MANIFEST="$1"
        ;;
    --stats-json)
        shift
        [[ -n "${1:-}" ]] || die_arg "--stats-json requires a path"
        export HYIR_STATS_JSON="$1"
        ;;
    --allow-pre) export HYIR_ALLOW_PRE=1 ;;
    --allow-run) export HYIR_ALLOW_RUN=1 ;;
    --dont-run) FORCE_NO_RUN=1 ;;
    --pre-scan) export HYIR_PRE_SCAN=1 ;;
    --fail-fast) export HYIR_FAIL_FAST=1 ;;
    --allow-warn) export HYIR_STRICT=1 ;;
    --ignore-unbound) export HYIR_IGNORE_UNBOUND=1 ;;
    --disable-fallback) export HYIR_DISABLE_FALLBACK=1 ;;
    --allow-dry-run) export HYIR_DRY_RUN=1 ;;
    --allow-debug) export HYIR_DEBUG=1 ;;
    --no-atomic) export HYIR_NO_ATOMIC=1 ;;
    --defer-run) export HYIR_DEFER_RUN=1 ;;
    --sanitize-env-full) export HYIR_SANITIZE_ENV_FULL=1 ;;
    --)
        shift
        break
        ;;
    -*)
        die_arg "Unknown flag: $1"
        ;;
    *)
        break
        ;;
    esac
    shift
done

# Any remaining positional args are more template files/dirs.
while [[ $# -gt 0 ]]; do
    TEMPLATE_FILES+=("$1")
    shift
done

if [[ "$FORCE_NO_RUN" == "1" ]]; then
    export HYIR_FORCE_NO_RUN=1
fi

if [[ ${#TEMPLATE_FILES[@]} -gt 0 ]]; then
    joined="$(printf "%s${SEP}" "${TEMPLATE_FILES[@]}")"
    export HYIR_TEMPLATE_FILE="${joined%"$SEP"}"
fi

if [[ -z "${HYIR_TEMPLATE_FILE:-}" && -z "${HYIR_HEADER_BUFFER:-}" ]]; then
    printf "@[arg:no_arg]: No valid file or directory paths given. %s --help for more information\n" "$SCRIPT_NAME"
    exit 1
fi

exec perl - <<'HYIR_PERL_SCRIPT_EOF'
use strict;
use warnings;
use File::Find     qw(find);
use File::Path     qw(make_path);
use File::Basename qw(basename dirname);
use File::Spec;
use Time::HiRes qw(gettimeofday tv_interval time sleep);
use Fcntl       qw(:DEFAULT);
use Errno       qw(EEXIST);
use IO::Handle;
use POSIX        qw(strftime);
use MIME::Base64 qw(encode_base64);

my $HAVE_SHA
    ; # lazily probed only if --manifest is actually used (Digest::SHA costs real startup time to load)

sub _sha256_hex {
    my ($content) = @_;
    unless ( defined $HAVE_SHA ) {
        $HAVE_SHA = eval {
            require Digest::SHA;
            Digest::SHA->import(qw(sha256_hex));
            1;
        }
            ? 1
            : 0;
        warn
            "@[diagnostic:warn(true)]: --manifest was given but Digest::SHA isn't available; manifest entries will omit checksums\n"
            unless $HAVE_SHA;
    }
    return $HAVE_SHA ? Digest::SHA::sha256_hex($content) : '';
}

my ( $LIB_DIR, $NPROC, $SCRIPT_NAME, $HOME_DIR );
my ( %REPLACE, %RGBA_BASE, %SKIP_SET, %made_dirs, @template_source,
    @INPUT_PATH, @files, %pids );
my ($raw,        $nl,         $header,      $body,
    $target,     $pre_script, $post_script, $post_is_run,
    $target_dir, $existing,   $found,       $n,
    $workers,    $chunk,      $res,         $queue_dir,
    $queue_fh
);

$LIB_DIR = $ENV{LIB_DIR} // '';
$NPROC
    = (    defined $ENV{HYIR_PROC}
        && $ENV{HYIR_PROC} =~ /^\d+$/
        && $ENV{HYIR_PROC} > 0 )
    ? $ENV{HYIR_PROC} + 0
    : 1;
$SCRIPT_NAME = $ENV{SCRIPT_NAME} // '';
$SCRIPT_NAME = basename($SCRIPT_NAME) if length $SCRIPT_NAME;

# Internal path-list separator. ':' historically, but that breaks on any
# filename that legitimately contains a colon. Use ASCII Unit Separator
# (0x1F) instead: it cannot appear in a real file path by convention and,
# unlike NUL, it survives being passed through the environment.
my $SEP = "\x1f";

@INPUT_PATH = split /\Q$SEP\E/, ( $ENV{HYIR_TEMPLATE_FILE} // '' );
$HOME_DIR   = $ENV{HOME} // '';

# ---------------------------------------------------------------------------
# Control flags
# ---------------------------------------------------------------------------

sub _flag_true {
    my ($v) = @_;
    return defined($v) && $v =~ /^(1|true|yes)$/i ? 1 : 0;
}

my $ALLOW_PRE = _flag_true( $ENV{HYIR_ALLOW_PRE} );

# RUN is opt-in (mirrors PRE). --dont-run / HYIR_FORCE_NO_RUN always wins.
my $ALLOW_RUN = _flag_true( $ENV{HYIR_ALLOW_RUN} )
    && !_flag_true( $ENV{HYIR_FORCE_NO_RUN} );
my $ALLOW_STRICT_WARNINGS = _flag_true( $ENV{HYIR_STRICT} );
my $DRY_RUN               = _flag_true( $ENV{HYIR_DRY_RUN} );
my $SPIT_DEBUG            = _flag_true( $ENV{HYIR_DEBUG} );
my $NO_ATOMIC             = _flag_true( $ENV{HYIR_NO_ATOMIC} );
my $ALLOW_PRE_SCAN        = _flag_true( $ENV{HYIR_PRE_SCAN} );
my $IGNORE_UNBOUND        = _flag_true( $ENV{HYIR_IGNORE_UNBOUND} )
    && !$ALLOW_STRICT_WARNINGS ? 1 : 0;
my $DISABLE_FALLBACK  = _flag_true( $ENV{HYIR_DISABLE_FALLBACK} );
my $DEFER_RUN         = _flag_true( $ENV{HYIR_DEFER_RUN} );
my $FAIL_FAST         = _flag_true( $ENV{HYIR_FAIL_FAST} );
my $SANITIZE_ENV_FULL = _flag_true( $ENV{HYIR_SANITIZE_ENV_FULL} );

my $RUN_CONCURRENCY
    = defined $ENV{HYIR_RUN_CONCURRENCY}
    && $ENV{HYIR_RUN_CONCURRENCY} =~ /^\d+$/
    ? int( $ENV{HYIR_RUN_CONCURRENCY} )
    : 1;

my $HOOK_TIMEOUT
    = ( defined $ENV{HYIR_HOOK_TIMEOUT}
        && $ENV{HYIR_HOOK_TIMEOUT} =~ /^\d+$/ )
    ? int( $ENV{HYIR_HOOK_TIMEOUT} )
    : 0;
my $HOOK_RETRIES
    = ( defined $ENV{HYIR_HOOK_RETRIES}
        && $ENV{HYIR_HOOK_RETRIES} =~ /^\d+$/ )
    ? int( $ENV{HYIR_HOOK_RETRIES} )
    : 0;

my $PRE_ALLOW_PATTERN = $ENV{HYIR_PRE_ALLOW_PATTERN};
my $RUN_ALLOW_PATTERN = $ENV{HYIR_RUN_ALLOW_PATTERN};

my $AUDIT_LOG          = $ENV{HYIR_AUDIT_LOG};
my $STATS_JSON         = $ENV{HYIR_STATS_JSON};
my $MANIFEST           = $ENV{HYIR_MANIFEST};
my $SECRET_PATTERN_STR = $ENV{HYIR_SECRET_PATTERN}
    // '(?:SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|CREDENTIAL|_PAT$)';
my $SECRET_PATTERN;
eval { $SECRET_PATTERN = qr/$SECRET_PATTERN_STR/i; 1 }
    or die
    "@[diagnostic:error(true)]: --secret-pattern is not a valid regular expression: $SECRET_PATTERN_STR\n";

for my $path (@INPUT_PATH) {
    if ( -f $path ) {
        push @files, $path;
        $found = 1;
    }
    elsif ( -d $path ) {
        push @template_source, $path;
    }
}

unless ( @files || @template_source || $ENV{HYIR_HEADER_BUFFER} ) {
    print
        "@[arg:no_arg]: No valid file or directory paths given. $SCRIPT_NAME --help for more information\n";
    exit(1);
}

if ( $> == 0 ) {
    printf( "@[root]: %s must not be run as root.\n", $SCRIPT_NAME );
    exit 1;
}

my $locks_base = $ENV{HYIR_LOCK_DIR}
    || (
    $ENV{XDG_CACHE_HOME}
    ? "$ENV{XDG_CACHE_HOME}/.tmq/locks"
    : "$ENV{HOME}/.cache/tmq/locks"
    );

my $LOCK_TIMEOUT
    = defined $ENV{HYIR_LOCK_TIMEOUT}
    && $ENV{HYIR_LOCK_TIMEOUT} =~ /^\d+(\.\d+)?$/
    ? $ENV{HYIR_LOCK_TIMEOUT} + 0
    : 10;

my $LOCK_STALE_AFTER
    = defined $ENV{HYIR_LOCK_STALE_AFTER}
    && $ENV{HYIR_LOCK_STALE_AFTER} =~ /^\d+(\.\d+)?$/
    ? $ENV{HYIR_LOCK_STALE_AFTER} + 0
    : $LOCK_TIMEOUT;

unless ( -d $locks_base ) {
    eval { make_path($locks_base); 1 }
        or die
        "@[diagnostic:error:populate:write(false)]: Cannot create locks dir $locks_base: $!";
}

# Abort flag for --fail-fast: any worker (or the parent, during pre-scan)
# that hits a fatal condition touches this file. Other workers check it
# between templates and stop taking on new work once it appears.
my $MAIN_PID   = $$;
my $abort_flag = File::Spec->catfile( $locks_base, "abort-$$" );
sub trip_abort { open my $fh, '>', $abort_flag or return; close $fh; }
sub aborted    { return -e $abort_flag; }

END {
 # Only the original parent process owns this file; a forked worker
 # hitting its own END block must never delete the shared coordination
 # flag out from under siblings that haven't noticed it yet.
    unlink $abort_flag
        if defined $MAIN_PID
        && $$ == $MAIN_PID
        && defined $abort_flag
        && -e $abort_flag;
}

if ($DEFER_RUN) {
    $queue_dir = File::Spec->catdir( $locks_base, "queue-$$" );
    eval { make_path($queue_dir); 1 }
        or die
        "@[diagnostic:error:populate:write(false)]: Cannot create queue dir $queue_dir: $!";
}

# ---------------------------------------------------------------------------
# Environment sanitization
#
# Historically this blanket-trimmed leading/trailing whitespace off every
# env var after a PRE hook ran. That's lossy: a value with intentional
# padding (a fixed-width field, a deliberately indented block) gets silently
# mangled, and it happened inconsistently (only post-PRE values were
# touched, never the vars a template started with). The one thing that
# *is* worth stripping unconditionally is a trailing carriage return, which
# shows up when a PRE hook sources CRLF-authored data (common when a script
# or file used by the hook was edited on Windows) and would otherwise bake
# an invisible \r into a path or config value. Full whitespace trimming is
# still available, opt-in, for anyone who relied on the old behavior.
# ---------------------------------------------------------------------------
sub sanitize_env {
    foreach my $key ( keys %ENV ) {
        my $value = $ENV{$key};
        next unless defined $value;
        $value =~ s/\r+$//;
        $value =~ s/\r+\n/\n/g;
        if ($SANITIZE_ENV_FULL) {
            $value =~ s/^\s+|\s+$//g;
        }
        $ENV{$key} = $value;
    }
}
sanitize_env();

# HOME/USER/LOGNAME/HOSTNAME are pervasively assumed to be set, but a
# surprising number of real invocation contexts don't reliably propagate
# them: systemd units without an explicit Environment=, cron, `sudo`
# without -E, some minimal containers. When that happens, [::HOME::] etc.
# silently become unbound rather than crashing loudly -- which looks
# exactly like "the header doesn't work" with no obvious cause. Back them
# off the OS's own account/host info (independent of what the shell that
# launched us happened to export) so these four in particular just work.
# This only fills in what's missing; anything already set is left alone.
{
    my @pw = eval { getpwuid($<) };
    if ( !defined $ENV{HOME} || !length $ENV{HOME} ) {
        $ENV{HOME} = $pw[7] if defined $pw[7] && length $pw[7];
    }
    if ( !defined $ENV{USER} || !length $ENV{USER} ) {
        $ENV{USER} = $pw[0] if defined $pw[0] && length $pw[0];
    }
    if ( !defined $ENV{LOGNAME} || !length $ENV{LOGNAME} ) {
        $ENV{LOGNAME} = $ENV{USER}
            if defined $ENV{USER} && length $ENV{USER};
    }
    if ( !defined $ENV{HOSTNAME} || !length $ENV{HOSTNAME} ) {
        my $host = eval {
            require Sys::Hostname;
            Sys::Hostname::hostname();
        };
        $ENV{HOSTNAME} = $host if defined $host && length $host;
    }
}

# ---------------------------------------------------------------------------
# Color parsing
#
# Accepts #RGB, #RGBA, #RRGGBB, #RRGGBBAA (leading # optional on all of
# these), and rgb()/rgba() function forms. Returns the "rgba(r,g,b," prefix
# used by the <name_rgba(...)> / [::name_rgba(...)::] placeholder form (the
# caller appends whatever the user wrote in the parens plus a closing
# paren), or undef if the value isn't a recognizable color.
# ---------------------------------------------------------------------------
sub parse_color_to_rgba_base {
    my ($v) = @_;
    return undef unless defined $v && length $v;

    if ( $v =~ /^#?([0-9A-Fa-f]{3})$/ ) {
        my ( $r, $g, $b ) = map { hex( $_ . $_ ) } split //, $1;
        return sprintf( 'rgba(%d,%d,%d,', $r, $g, $b );
    }
    if ( $v =~ /^#?([0-9A-Fa-f]{4})$/ ) {
        my @n = split //, $1;
        my ( $r, $g, $b, $a ) = map { hex( $_ . $_ ) } @n;
        return sprintf( 'rgba(%d,%d,%d,%s',
            $r, $g, $b, _fmt_alpha( $a / 255 ) );
    }
    if ( $v =~ /^#?([0-9A-Fa-f]{6})$/ ) {
        my $h = $1;
        my ( $r, $g, $b ) = (
            hex( substr( $h, 0, 2 ) ),
            hex( substr( $h, 2, 2 ) ),
            hex( substr( $h, 4, 2 ) )
        );
        return sprintf( 'rgba(%d,%d,%d,', $r, $g, $b );
    }
    if ( $v =~ /^#?([0-9A-Fa-f]{8})$/ ) {
        my $h = $1;
        my ( $r, $g, $b, $a ) = (
            hex( substr( $h, 0, 2 ) ),
            hex( substr( $h, 2, 2 ) ),
            hex( substr( $h, 4, 2 ) ),
            hex( substr( $h, 6, 2 ) )
        );
        return sprintf( 'rgba(%d,%d,%d,%s',
            $r, $g, $b, _fmt_alpha( $a / 255 ) );
    }
    if ( $v
        =~ /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*[\d.]+\s*)?\)$/
        )
    {
        return sprintf( 'rgba(%s,%s,%s,', $1, $2, $3 );
    }
    return undef;
}

sub _fmt_alpha {
    my ($a) = @_;
    my $s = sprintf( '%.4f', $a );
    $s =~ s/0+$//;
    $s =~ s/\.$//;
    return $s;
}

sub build_env_cache {
    %REPLACE = %RGBA_BASE = ();
    while ( my ( $k, $v ) = each %ENV ) {
        next unless defined $v;

        if (   $k =~ /_rgba$/
            && $v
            =~ /rgba\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,/ )
        {
            $RGBA_BASE{$k} = "rgba($1,$2,$3,";
            $REPLACE{$k}   = $v;
            next;
        }

        my $base = parse_color_to_rgba_base($v);
        if ( defined $base ) {
            my $rgba_key = $k . '_rgba';
            $RGBA_BASE{$rgba_key} = $base;
            $REPLACE{$rgba_key}   = "${base}1)";
        }

        $REPLACE{$k} = $v;
    }
}
build_env_cache();

my $current_lock;
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub {
    release_lock($current_lock) if defined $current_lock;
    trip_abort();
    exit 1;
};

sub fnv1a_hex {
    my ($str) = @_;
    my $hash = 0x811c9dc5;
    for my $byte ( unpack( 'C*', $str ) ) {
        $hash ^= $byte;
        $hash = ( $hash * 0x01000193 ) & 0xFFFFFFFF;
    }
    return sprintf( '%08x', $hash );
}

# ---------------------------------------------------------------------------
# Locking
#
# mkdir() is the primitive because it's atomic on every filesystem this
# tool is realistically pointed at, including NFSv3+. Two things the
# original implementation got wrong, both of which matter once you're
# actually running this from more than one pipeline/host at a time:
#
#  1. A failed mkdir() was always treated as "someone else holds the
#     lock" and retried in a spin-loop until the overall timeout elapsed.
#     If the *real* reason was EACCES/EROFS/ENOSPC/a missing parent dir,
#     that spin-loop just burns the whole timeout before dying with a
#     generic "timeout acquiring lock" message that hides the actual
#     cause. We check errno and fail immediately for anything but EEXIST.
#
#  2. Breaking a stale lock was "rmdir it, then loop back and mkdir a new
#     one" with no coordination between processes that reach that
#     decision at the same time. Two racing reapers can both decide a
#     lock is stale, both rmdir it, and now a THIRD process's freshly
#     created lock (that landed in the gap) gets removed by the second
#     reaper, who thinks it's still cleaning up the original. We instead
#     rename() the stale lock to a name unique to *this* attempt first;
#     rename() on a shared source path only ever succeeds for one racer
#     (the others get ENOENT), so exactly one process does the actual
#     reap, and nobody can ever remove a lock they didn't rename away
#     themselves.
#
# "How long to wait" and "how old before I consider it abandoned" are
# also split into two knobs (--lock-timeout / --lock-stale-after) instead
# of being the same number: a lock holder that's legitimately still
# working shouldn't get its lock yanked out from under it just because
# a *different* process's patience ran out at the same instant.
# ---------------------------------------------------------------------------
sub acquire_lock {
    my ($target_path) = @_;
    my $hash          = fnv1a_hex($target_path);
    my $lockdir = File::Spec->catfile( $locks_base, "$hash.lock" );
    my $start   = time();

    while (1) {
        if ( mkdir $lockdir ) {
            if ( open my $fh, '>', "$lockdir/owner" ) {
                print $fh "pid=$$ host=" . (
                    eval {
                        require Sys::Hostname;
                        Sys::Hostname::hostname();
                    } // '?'
                    )
                    . " time="
                    . strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime() )
                    . "\n";
                close $fh;
            }
            return $lockdir;
        }

        my $errno = $!;
        unless ( $errno == EEXIST ) {
            die
                "@[atomic:mkdir_failed(true)]: Could not create lock directory $lockdir: $errno\n";
        }

        if ( -d $lockdir ) {
            my $age = time() - ( ( stat($lockdir) )[9] || 0 );
            if ( $age > $LOCK_STALE_AFTER ) {
                my $reap_name
                    = "$lockdir.stale.$$." . int( rand(1e9) );
                if ( rename( $lockdir, $reap_name ) ) {
                    warn
                        "@[atomic:remove:stale_lock(true)]: Reaped stale lock for $target_path (age ${age}s)\n";
                    unless (
                        system( 'rm', '-rf', '--', $reap_name ) == 0 )
                    {
                        warn
                            "@[atomic:remove:stale_lock(false)]: Could not fully remove reaped lock dir $reap_name: $!\n";
                    }
                    next;
                }

                # Lost the race to reap it (or another process already
                # recreated it) -- fall through and try mkdir again.
            }
        }

        if ( time() - $start > $LOCK_TIMEOUT ) {
            die
                "@[atomic:timeout(true)]: Timeout acquiring lock for $target_path (waited ${LOCK_TIMEOUT}s)\n";
        }
        Time::HiRes::sleep(0.05);
    }
}

sub release_lock {
    my ($lockdir) = @_;
    return unless $lockdir;
    if ( -d $lockdir ) {
        unlink "$lockdir/owner" if -e "$lockdir/owner";
        rmdir $lockdir
            or warn
            "@[atomic:release_lock(false)]: Could not remove lock $lockdir: $!\n";
    }
}

sub fsync_or_warn {
    my ($fh) = @_;
    return unless defined $fh;
    if ( ref($fh) && $fh->can('sync') ) {
        eval { $fh->sync(); 1 }
            or warn "@[atomic:fsync(failed)]: sync failed: $!\n"
            if $SPIT_DEBUG;
        return;
    }
    if ( ref($fh) && $fh->can('flush') ) {
        eval { $fh->flush(); 1 }
            or warn "@[atomic:fsync(failed)]: flush failed: $!\n"
            if $SPIT_DEBUG;
        return;
    }
    warn
        "@[atomic:fsync_compatibility(unavailable)]: fsync/flush not available on this Perl build; durability not guaranteed\n"
        if $SPIT_DEBUG;
}

# Best-effort: is $dir on a network filesystem? Linux-only, best-effort,
# never fatal -- used only to decide whether to print an informational
# note about rename() atomicity guarantees being weaker on such mounts.
my %warned_netfs;

sub warn_if_networked {
    my ($dir) = @_;
    return unless -r '/proc/mounts';
    my $abs = eval { File::Spec->rel2abs($dir) } // $dir;
    return if $warned_netfs{$abs}++;
    open my $fh, '<', '/proc/mounts' or return;
    my $best;
    while ( my $line = <$fh> ) {
        my ( undef, $mnt, $fstype ) = split ' ', $line;
        next unless defined $mnt;
        next
            unless $abs eq $mnt
            || index( $abs . '/', $mnt . '/' ) == 0;
        if ( !defined $best || length($mnt) > length( $best->[0] ) ) {
            $best = [ $mnt, $fstype ];
        }
    }
    close $fh;
    if (   $best
        && $best->[1] =~ /^(nfs\d?|cifs|smb\d?|9p|afs|glusterfs)$/i )
    {
        warn
            "@[diagnostic:warn(true)]: $dir is on a $best->[1] mount; rename()/mkdir() atomicity guarantees can be weaker on network filesystems than on local ones\n";
    }
}

sub write_temp_file {
    my ( $t_dir, $content ) = @_;
    make_path($t_dir) unless -d $t_dir;

    my ( $fh, $tmp_path );
    my $attempts = 0;
    while (1) {
        $attempts++;
        my $candidate = File::Spec->catfile(
            $t_dir,
            sprintf(
                '.tmq_tmp.%d.%d.%d',
                $$, time(), int( rand(1e9) )
            )
        );
        if (sysopen(
                $fh, $candidate, O_CREAT | O_EXCL | O_RDWR, 0600
            )
            )
        {
            $tmp_path = $candidate;
            last;
        }
        die
            "Could not create a temp file in $t_dir after $attempts attempts: $!"
            if $attempts >= 100;
    }

    binmode $fh;
    print $fh $content;
    $fh->flush;
    fsync_or_warn($fh) unless $NO_ATOMIC;
    close $fh or die "Failed closing tmp file $tmp_path: $!";
    return $tmp_path;
}

# rename() is atomic *when it succeeds*, but that's not the same claim as
# "always usable": it fails with EXDEV if the temp file and target ended
# up on different filesystems/devices (shouldn't normally happen here
# since the temp file is created in the target's own directory, but a
# bind-mount, overlay, or a target path that changed underneath us can
# still produce it), and its atomicity is a local-filesystem guarantee --
# NFS clients can observe a rename mid-flight less cleanly than ext4/xfs
# do, particularly across a crash. We handle EXDEV with a non-atomic
# copy+fsync+unlink fallback (clearly logged, since it trades away the
# atomicity guarantee) rather than just dying, and we surface a one-time
# note when the target directory looks like it's on a network mount.
sub rename_tmp_to_target {
    my ( $tmp_path, $target ) = @_;

    if ( -f $target ) {
        my $mode = ( stat($target) )[2] & 07777;
        chmod $mode, $tmp_path;
    }

    return if rename $tmp_path, $target;

    if ( $! == &Errno::EXDEV ) {
        warn
            "@[atomic:rename_status(cross_device)]: $target is on a different filesystem/device than the temp file; falling back to non-atomic copy+replace\n";
        eval {
            open my $in, '<', $tmp_path
                or die "open tmp for read: $!";
            binmode $in;
            open my $out, '>', $target
                or die "open target for write: $!";
            binmode $out;
            local $/;
            print {$out} <$in>;
            $out->flush;
            fsync_or_warn($out) unless $NO_ATOMIC;
            close $out or die "close target: $!";
            close $in;
            unlink $tmp_path;
            1;
        } or do {
            my $err = $@ || 'unknown error';
            unlink $tmp_path if -f $tmp_path;
            die
                "@[atomic:rename_status(failure)]: Cross-device fallback write failed for $target: $err";
        };
        return;
    }

    my $err = $!;
    unlink $tmp_path if -f $tmp_path;
    die
        "@[atomic:rename_status(failure)]: Atomic rename failed for $target: $err";
}

sub direct_write_to_target {
    my ( $target, $content ) = @_;
    my $t_dir = dirname($target);
    make_path($t_dir) unless -d $t_dir;
    my $tmp = write_temp_file( $t_dir, $content );
    rename_tmp_to_target( $tmp, $target );
}

sub decode_escapes {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\\([nrt0\\])/
        $1 eq 'n' ? "\n" :
        $1 eq 'r' ? "\r" :
        $1 eq 't' ? "\t" :
        $1 eq '0' ? "\0" :
        $1
    /ge;
    return $str;
}

%SKIP_SET = map { $_ => 1 } (
    $ENV{HYIR_IGNORE_TEMPLATES}
    ? split /\Q$SEP\E/,
        $ENV{HYIR_IGNORE_TEMPLATES}
    : ()
);

# ---------------------------------------------------------------------------
# Placeholder syntax
#
# [::NAME::], [::NAME:-fallback::], [::name_rgba(args)::] is the only
# syntax this engine recognizes. There is deliberately no compatibility
# layer for anything else (no <NAME>, no ${NAME}) -- maintaining several
# parallel placeholder grammars (and the cross-syntax collision guards
# that implies) is a standing maintenance cost with no runtime benefit
# once nothing depends on the old ones. "::" essentially never appears by
# accident in real config/code text, which is why this syntax doesn't
# need the collision workarounds an angle-bracket syntax would.
# ---------------------------------------------------------------------------
my $ph_inner_atom      = qr/ (?: \[::[^\[\]]*?::\] | [^\[\]] ) /x;
my $NEW_PLACEHOLDER_RE = qr/\[::\s*($ph_inner_atom+?)\s*::\]/xs;

# ---------------------------------------------------------------------------
# Modifier pipeline (new syntax only): [::json:upper:NAME::] etc.
# Applied right-to-left -- closest to the core value first -- so
# "json:upper:NAME" reads as json(upper(NAME)): uppercase, then escape.
# indent/nindent match Helm/Sprig's well-known semantics on purpose, since
# "reindent a multi-line value to embed under a YAML key" is one of the
# single most common templating pain points for exactly the use cases this
# tool targets (Helm charts, K8s manifests, CI pipeline YAML).
# ---------------------------------------------------------------------------
sub _json_escape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return $s;
}

sub _apply_indent {
    my ( $n, $s ) = @_;
    $n = 0 + $n;
    my $pad = ' ' x ( $n > 0 ? $n : 0 );
    return join( "\n", map {"$pad$_"} split /\n/, $s, -1 );
}
my %MODIFIERS = (
    json => sub { _json_escape( $_[0] ) },
    yaml => sub {
        _json_escape( $_[0] );
    }, # valid JSON string escaping is valid inside a YAML double-quoted scalar
    upper  => sub { uc( $_[0] ) },
    lower  => sub { lc( $_[0] ) },
    trim   => sub { ( my $s = $_[0] ) =~ s/^\s+|\s+$//g; return $s; },
    base64 => sub { encode_base64( $_[0], '' ) },
);
my %MODIFIERS_ARG = (
    indent  => sub { _apply_indent( $_[0], $_[1] ) },
    nindent => sub { "\n" . _apply_indent( $_[0], $_[1] ) },
);

sub apply_modifier_pipeline {
    my ( $steps, $value ) = @_;
    for my $step ( reverse @$steps ) {
        if ( $step =~ /^(\w+)\(\s*(.*?)\s*\)$/
            && exists $MODIFIERS_ARG{$1} )
        {
            $value = $MODIFIERS_ARG{$1}->( $2, $value );
        }
        elsif ( exists $MODIFIERS{$step} ) {
            $value = $MODIFIERS{$step}->($value);
        }
        else {
            return ( undef, $step );    # unknown modifier
        }
    }
    return ( $value, undef );
}

# ---------------------------------------------------------------------------
# Built-in dynamic placeholders and include(). Computed once per file (so
# repeated references within one file are consistent) and checked ahead of
# %REPLACE so ordinary env vars can never accidentally shadow them.
# ---------------------------------------------------------------------------
my %BUILTINS;
my @INCLUDE_STACK;
my $MAX_INCLUDE_DEPTH = 8;

sub reset_builtins_for_file {
    my ( $template_file, $index, $total ) = @_;
    my $now = time();
    %BUILTINS = (
        _NOW      => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime($now) ),
        _NOW_UNIX => int($now),
        _UUID     => _gen_uuid4(),
        _INDEX    => defined $index ? $index + 1 : '',
        _TOTAL    => defined $total ? $total     : '',
        _SOURCE          => $template_file,
        _SOURCE_BASENAME => (
            $template_file ne '::BUFFER::' ? basename($template_file)
            : ''
        ),
        _SOURCE_DIR => (
            $template_file ne '::BUFFER::' ? dirname($template_file)
            : ''
        ),
    );
}

sub _gen_uuid4 {
    my @b = map { int( rand(256) ) } 1 .. 16;
    $b[6] = ( $b[6] & 0x0f ) | 0x40;
    $b[8] = ( $b[8] & 0x3f ) | 0x80;
    return
        sprintf(
        '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x',
        @b );
}

sub resolve_include {
    my ( $arg, $template_file ) = @_;
    die
        "@[diagnostic:error(true)]: include() nesting too deep (> $MAX_INCLUDE_DEPTH)\n"
        if @INCLUDE_STACK >= $MAX_INCLUDE_DEPTH;

    my $path = $arg;
    unless ( File::Spec->file_name_is_absolute($path) ) {
        my $base
            = ( $template_file ne '::BUFFER::'
                && length $template_file )
            ? dirname($template_file)
            : '.';
        $path = File::Spec->catfile( $base, $path );
    }
    my $abs = eval { File::Spec->rel2abs($path) } // $path;

    return undef unless -f $abs;
    if ( grep { $_ eq $abs } @INCLUDE_STACK ) {
        die
            "@[diagnostic:error(true)]: include() cycle detected: $abs is already being included ("
            . join( ' -> ', @INCLUDE_STACK, $abs ) . ")\n";
    }

    my $content = do {
        local $/;
        open my $fh, '<', $abs or return undef;
        <$fh>;
    };

    push @INCLUDE_STACK, $abs;
    my $rendered = eval { render_text( $content, $template_file ) };
    my $err      = $@;
    pop @INCLUDE_STACK;
    die $err if $err;

    return $rendered;
}

# ---------------------------------------------------------------------------
# Header tags
#
# Canonical form:  $PATH:target|$REQUIRE:{VARS}|$PRE:{hooks}|$RUN:{hooks}
# Tags may appear in any order and are all optional except $PATH (which
# falls back, with a warning, to an untagged leading path for older
# templates -- see parse_directives()). $PATH:{a,b,c} fans the same
# rendered body out to multiple targets.
# ---------------------------------------------------------------------------
my $TAGS          = qr/(?:PATH|REQUIRE|PRE|RUN)/;
my $PLANNING_PASS = 0
    ; # set during the pre-fork target-resolution pass; suppresses warn/die and one-time notices so they fire only during real processing

# True balanced-brace matching, not a lazy-match-plus-lookahead heuristic.
# The lazy form ("\{.*?\}" stopping at the first "}" satisfying some
# lookahead) breaks the moment the *body* contains any later "}" of its
# own -- which is the common case, not an edge case: --compat-hyir's
# ${VAR} syntax, JSON, YAML flow mappings, and HCL blocks all put "}"
# characters throughout ordinary body content. A lazy match whose
# lookahead accepts "nothing but whitespace to end of file" will happily
# balloon across the entire rest of the file looking for a qualifying
# "}", silently swallowing the whole body into what it thinks is the
# header. True balance has no such failure mode: it always closes on the
# "}" that actually pairs with the opening "{", at any nesting depth,
# regardless of what text follows.
my $braces = qr/
    \{
        (?: [^{}]++ | (?&HYIR_BRACE) )*
    \}
    (?(DEFINE)
        (?<HYIR_BRACE> \{ (?: [^{}]++ | (?&HYIR_BRACE) )* \} )
    )
/x;

my $HEADER_RE
    = qr/^(?<header>.*?(?:\|?\s*\$${TAGS}:\s*(?:$braces|[^\n]*?(?=\|\s*\$${TAGS}:|\n|$)))+\s*?;?\s*?(?:\n|$))(?<body>.*)$/s;

sub split_header_body {
    my ($raw) = @_;
    if ( $raw =~ $HEADER_RE ) {
        return ( $+{header}, $+{body} );
    }
    my $nl_idx = index( $raw, "\n" );
    my $hdr    = $nl_idx >= 0 ? substr( $raw, 0, $nl_idx ) : $raw;
    my $body   = $nl_idx >= 0 ? substr( $raw, $nl_idx + 1 ) : '';
    if ( $hdr =~ /\|\s*\$${TAGS}:\s*\{/ ) {
        die
            "@[diagnostic:error:syntax(true)]: Hanging '{' detected in header ... Missing closing '}'\n";
    }
    return ( $hdr, $body );
}

# Extract one |$TAG:{...} or |$TAG:bare segment from $header. Returns
# (value, was_braced) or (undef, undef) if the tag isn't present.
sub extract_tag {
    my ( $href, $tag ) = @_;
    if ( $$href
        =~ s/\|?\s*\$${tag}:\s*($braces|.*?);?(?=\s*\||\s*$)//s )
    {
        my $v = $1;
        $v =~ s/^\s+|\s+$//g;
        my $was_braced = ( $v =~ /^\{/ ) ? 1 : 0;
        $v =~ s/^\{\s*//;
        $v =~ s/\s*\}$//;
        return ( $v, $was_braced );
    }
    return ( undef, undef );
}

# $RUN is always the terminal segment (its content can itself contain a
# literal "|", e.g. a shell pipeline) so it absorbs to end-of-line rather
# than stopping at the next "|".
sub extract_run_tag {
    my ($href) = @_;
    if ( $$href =~ s/\|?\s*\$RUN:(.*)$//s ) {
        my $v = $1;
        $v =~ s/^\s+|\s+$//g;
        $v =~ s/^\{\s*//;
        $v =~ s/\s*\}\s*$//;
        return $v;
    }
    return undef;
}

# Parses a raw header string into its directive parts. $PATH: (or a
# --header T: override) is the only way to give a template a target --
# there is no fallback interpretation of untagged text as a path. A
# header with no recognized $TAG: at all simply isn't a header, and the
# caller treats the whole raw file as body (signaled via no_header, since
# parse_directives only sees the already-split header candidate, not the
# original raw text, so it can't hand the text back to the body itself).
sub parse_directives {
    my ( $header, $template_file ) = @_;
    $header =~ s/^\s+|\s+$//g;
    my $has_hooks = ( index( $header, '|' ) >= 0 );

    my %d = (
        path        => undef,
        path_braced => 0,
        require     => undef,
        pre         => undef,
        run         => undef,
        no_header   => 0
    );

    if ( $has_hooks || $header =~ /^\s*\$${TAGS}:/ ) {
        ( $d{require}, undef ) = extract_tag( \$header, 'REQUIRE' );
        ( $d{pre},     undef ) = extract_tag( \$header, 'PRE' );
        $d{run} = extract_run_tag( \$header );
        ( $d{path}, $d{path_braced} )
            = extract_tag( \$header, 'PATH' );

        $header =~ s/^\s*\|+\s*//;
        $header =~ s/\s*\|+\s*$//;
        $header =~ s/^\s+|\s+$//g;

        if ( length($header) && !$PLANNING_PASS ) {
            warn
                "@[diagnostic:warn(true)]: Unrecognized header content in $template_file: '$header' (check for a misspelled \$TAG:)\n";
            die
                "@[diagnostic:arg:strict_warn(true)]: Unrecognized header content in $template_file: '$header'\n"
                if $ALLOW_STRICT_WARNINGS;
        }
    }
    elsif ( length $header ) {
        $d{no_header} = 1;
    }

    return \%d;
}

my %warned_unbound;

sub render_text {
    my ( $text, $template_file ) = @_;
    return $text unless defined $text && length $text;

    if ( index( $text, '[::' ) >= 0 ) {
        $text
            =~ s/$NEW_PLACEHOLDER_RE/_replace_new($1, $template_file)/ge;
    }

    return $text;
}

sub resolve_placeholder_core {
    my ( $core, $template_file ) = @_;

    return ( $BUILTINS{$core}, undef ) if exists $BUILTINS{$core};

    if ( $core =~ /^include\(\s*(.+?)\s*\)$/ ) {
        my $inc = resolve_include( $1, $template_file )
            ;    # dies on cycle/depth
        return ( $inc, undef );
    }

    if ( $core =~ /^(\w+_rgba)\(\s*([^)]*)\s*\)$/ ) {
        my ( $base, $args ) = ( $1, $2 );
        return (
            exists $RGBA_BASE{$base}
            ? "$RGBA_BASE{$base}$args)"
            : undef,
            undef
        );
    }

    return ( exists $REPLACE{$core} ? $REPLACE{$core} : undef,
        undef );
}

sub _replace_new {
    my ( $blob, $template_file ) = @_;
    my $full_match = "[::${blob}::]";
    return $full_match unless length $blob;

    my $idx = index( $blob, ':-' );
    my ( $core_part, $fb )
        = $idx >= 0
        ? ( substr( $blob, 0, $idx ), substr( $blob, $idx + 2 ) )
        : ( $blob, undef );

    my @segs = map { my $s = $_; $s =~ s/^\s+|\s+$//g; $s } split /:/,
        $core_part;
    my $core = pop @segs // '';

    my ( $val, undef )
        = resolve_placeholder_core( $core, $template_file );

    if ( !defined $val && defined $fb ) {
        ( my $rfb = $fb ) =~ s/^\s+|\s+$//g;
        $rfb
            =~ s/$NEW_PLACEHOLDER_RE/_replace_new($1, $template_file)/ge;
        $val = length($rfb) ? $rfb : undef;
    }

    if ( !defined $val ) {
        return $full_match if $IGNORE_UNBOUND || $PLANNING_PASS;
        if ($ALLOW_STRICT_WARNINGS) {
            die
                "@[diagnostic:arg:strict_warn(true)]: Unbound variable [::${core}::] in $template_file\n";
        }
        warn
            "@[diagnostic:warn(true)]: Unbound variable [::${core}::] in $template_file; leaving as placeholder\n"
            unless $warned_unbound{"$core\0$template_file"}++;
        return $full_match;
    }

    if (@segs) {
        my ( $piped, $bad ) = apply_modifier_pipeline( \@segs, $val );
        if ( !defined $piped ) {
            return $full_match if $IGNORE_UNBOUND || $PLANNING_PASS;
            if ($ALLOW_STRICT_WARNINGS) {
                die
                    "@[diagnostic:arg:strict_warn(true)]: Unknown modifier '$bad' in [::${blob}::] in $template_file\n";
            }
            warn
                "@[diagnostic:warn(true)]: Unknown modifier '$bad' in [::${blob}::] in $template_file; leaving as placeholder\n"
                unless $warned_unbound{"mod:$bad\0$template_file"}++;
            return $full_match;
        }
        return $piped;
    }
    return $val;
}

# $REQUIRE:{VAR1,VAR2,...} -- validated right after PRE runs (PRE is often
# exactly what's expected to provide these), before target/body rendering.
# Reports every missing name in one message rather than failing one
# placeholder at a time as substitution happens to reach them.
sub check_require {
    my ( $require_str, $template_file ) = @_;
    return 1 unless defined $require_str && length $require_str;
    my @names
        = grep {length}
        map    { my $s = $_; $s =~ s/^\s+|\s+$//g; $s } split /,/,
        $require_str;
    my @missing = grep { !exists $REPLACE{$_} } @names;
    return 1 unless @missing;

    my $msg
        = "@[diagnostic:require(false)]: $template_file is missing required variable(s): "
        . join( ', ', @missing ) . "\n";
    if ( $ALLOW_STRICT_WARNINGS || $FAIL_FAST ) {
        die $msg;
    }
    warn $msg;
    return 0;
}

# Global cache to track pre-hooks that have already executed in this process
my %executed_pre_hooks;

sub _redact {
    my ($text) = @_;
    return $text unless defined $text;

 # Pass 1: redact by known secret VALUES currently in the environment.
 # Catches a secret referenced via placeholder substitution (the
 # common case: a RUN hook embeds ${API_TOKEN} in a command string).
    while ( my ( $k, $v ) = each %ENV ) {
        next
            unless defined $v
            && length($v) >= 4
            && $k =~ $SECRET_PATTERN;
        my $q = quotemeta($v);
        $text =~ s/$q/***REDACTED***/g;
    }

 # Pass 2: redact by KEY=VALUE shape in the text itself. This is what
 # catches the narrower gap pass 1 can't: a PRE hook whose job is to
 # *create* a secret ("export API_TOKEN=abc123") is logged before that
 # value exists anywhere in %ENV, so there's nothing yet to substring-
 # match against -- the value would otherwise reach the audit log in
 # plain text on the one run that matters most (the secret's origin).
    $text
        =~ s/(\b[A-Za-z_][A-Za-z0-9_]*)(=)(\S+)/$1 =~ $SECRET_PATTERN ? "$1$2***REDACTED***" : "$1$2$3"/ge;

    return $text;
}

sub audit {
    my (%rec) = @_;
    return unless $AUDIT_LOG;
    $rec{ts}  = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime() );
    $rec{pid} = $$;
    $rec{cmd} = _redact( $rec{cmd} ) if defined $rec{cmd};
    my $json = '{' . join(
        ',',
        map {
            my $v = $rec{$_};
            $v = '' unless defined $v;
            $v =~ s/([\\"])/\\$1/g;
            $v =~ s/\n/\\n/g;
            qq{"$_":"$v"}
        } sort keys %rec
    ) . "}\n";
    if ( open my $fh, '>>', $AUDIT_LOG ) {
        flock( $fh, 2 ) if eval { require Fcntl; 1 };
        print {$fh} $json;
        close $fh;
    }
}

sub manifest_record {
    my (%rec) = @_;
    return unless $MANIFEST;
    my $json = '{' . join(
        ',',
        map {
            my $v = $rec{$_};
            $v = '' unless defined $v;
            $v =~ s/([\\"])/\\$1/g;
            qq{"$_":"$v"}
        } sort keys %rec
    ) . "}\n";
    if ( open my $fh, '>>', $MANIFEST ) {
        print {$fh} $json;
        close $fh;
    }
}

# Run $cmd via bash -c under an optional wall-clock timeout, killing the
# actual child (not just abandoning our wait on it) if it fires. Using an
# explicit fork/exec rather than system()/backticks is what makes the kill
# possible: system() gives us no handle on the grandchild once it's
# spawned, so a naive alarm() around it can time out our *wait* without
# ever stopping the runaway process itself.
sub _run_with_timeout {
    my ( $cmd, $timeout, @extra_open_args ) = @_;
    my $pid = open( my $fh, '-|' );
    die "@[diagnostic:error(true)]: fork failed: $!\n"
        unless defined $pid;

    if ( $pid == 0 ) {

     # Its own process group, so a timeout can kill the whole tree
     # (e.g. "sleep 30; touch x" spawns sleep as a *child of bash*;
     # killing just the bash pid leaves sleep running, orphaned, still
     # holding our stdout pipe open -- which then hangs any caller
     # piping this script's output, long after we've moved on).
        eval { require POSIX; POSIX::setpgid( 0, 0 ); };
        open STDIN, '<', '/dev/null';
        open STDERR, '>&STDOUT';
        exec( 'bash', '-c', $cmd ) or exit 127;
    }

    my $timed_out = 0;
    my @lines;
    if ( $timeout > 0 ) {
        local $SIG{ALRM}
            = sub { $timed_out = 1; die "HYIR_TIMEOUT\n"; };
        alarm($timeout);
        eval {
            local $/ = "\0";
            while ( my $l = <$fh> ) { push @lines, $l; }
            1;
        };
        alarm(0);
        if ($timed_out) {
            kill( 'TERM', -$pid );
            Time::HiRes::sleep(0.2);
            kill( 'KILL', -$pid );
            waitpid( $pid, 0 );
            close $fh;
            return ( undef, -1, 1 );
        }
    }
    else {
        local $/ = "\0";
        while ( my $l = <$fh> ) { push @lines, $l; }
    }
    close $fh;
    waitpid( $pid, 0 ) if kill( 0, $pid );
    my $status = $? >> 8;
    return ( \@lines, $status, 0 );
}

sub import_shell_env {
    my ($cmd) = @_;
    return 1 unless $cmd;

    unless ($ALLOW_PRE) {
        warn
            "@[arg:allow_pre(false)]: Skipping pre-hook (HYIR_ALLOW_PRE not enabled): $cmd\n";
        return 0;
    }

    if ( defined $PRE_ALLOW_PATTERN && $cmd !~ /$PRE_ALLOW_PATTERN/ )
    {
        die
            "@[diagnostic:error:security_policy(true)]: PRE hook does not match --pre-allow-pattern, refusing to run: $cmd\n";
    }

    return 1 if $executed_pre_hooks{$cmd}++;

    my $attempts = 0;
    my ( $lines, $status, $timed_out );
    while (1) {
        $attempts++;
        my $t0 = [gettimeofday];
        ( $lines, $status, $timed_out )
            = _run_with_timeout( "$cmd && env -0", $HOOK_TIMEOUT );
        my $dur_ms = int( 1000 * tv_interval($t0) );
        audit(
            action      => 'pre',
            cmd         => $cmd,
            exit_code   => ( $timed_out ? 'timeout' : $status ),
            duration_ms => $dur_ms,
        );
        last if !$timed_out && defined($status) && $status == 0;
        last if $attempts > $HOOK_RETRIES;
        warn
            "@[diagnostic:warn(true)]: PRE hook failed (attempt $attempts"
            . ( $timed_out ? ', timed out' : ", exit $status" )
            . "), retrying: $cmd\n";
        Time::HiRes::sleep( 0.2 * $attempts );
    }

    if ($timed_out) {
        warn
            "@[diagnostic:error(true)]: PRE hook timed out after ${HOOK_TIMEOUT}s: $cmd\n";
        return 0;
    }
    unless ( defined $status && $status == 0 ) {
        warn
            "@[diagnostic:error(true)]: PRE hook exited non-zero (status=$status): $cmd\n";
        return 0;
    }

    my $env_changed = 0;
    for my $entry (@$lines) {
        $entry =~ s/\0$//;
        if ( $entry =~ /^([^=]+)=(.*)$/s ) {
            my ( $key, $val ) = ( $1, $2 );
            if ( !exists $ENV{$key} || $ENV{$key} ne $val ) {
                $ENV{$key} = $val;
                $env_changed = 1;
            }
        }
    }

    if ($env_changed) {
        sanitize_env();
        build_env_cache();
    }
    return 1;
}

sub read_template_raw {
    my ($template_file) = @_;
    if ( $template_file eq '::BUFFER::' ) {
        return decode_escapes( $ENV{HYIR_HEADER_BUFFER} );
    }
    return undef unless -f $template_file;
    return do {
        local $/;
        open my $fh, '<', $template_file
            or die
            "@[populate:open(true)]: Cannot open $template_file: $!";
        <$fh>;
    };
}

sub check_disable_fallback {
    my ( $raw, $template_file ) = @_;
    return unless $DISABLE_FALLBACK;
    if ( $raw =~ /\[::[^\[\]]*?:-/ ) {
        die
            "@[diagnostic:arg:ignore_unbound(true)]: $template_file uses :- fallback syntax, which is disabled under --disable-fallback\n";
    }
}

# Resolve a header-derived directive value against the --header CLI
# overrides, which always win when present.
sub apply_header_overrides {
    my ($d) = @_;
    if ( defined $ENV{HYIR_HEADER_TARGET} ) {
        $d->{path}        = $ENV{HYIR_HEADER_TARGET};
        $d->{path_braced} = 0;
    }
    $d->{pre} = $ENV{HYIR_HEADER_PRE}
        if defined $ENV{HYIR_HEADER_PRE};
    if ( defined $ENV{HYIR_HEADER_RUN} ) {
        $d->{run} = $ENV{HYIR_HEADER_RUN};
    }
    return $d;
}

# Resolve just the target path(s) for a template, WITHOUT running any PRE
# hook or writing anything. Used by the pre-fork planning pass to group
# templates that resolve to the same target so they're always handled by
# a single worker in file order (see the work-distribution section below)
# -- this is what makes concurrent rendering deterministic instead of
# leaving same-target writes to race across worker processes.
sub resolve_targets_only {
    my ( $template_file, $index, $total ) = @_;
    $PLANNING_PASS = 1;
    my ( $rendered, @targets ) = (undef);
    my $ok = eval {
        my $raw = read_template_raw($template_file);
        return () unless defined $raw;
        my ( $header, undef ) = split_header_body($raw);
        my $d = parse_directives( $header, $template_file );
        apply_header_overrides($d);
        return () unless defined $d->{path} && length $d->{path};

        reset_builtins_for_file( $template_file, $index, $total );
        $rendered = render_text( $d->{path}, $template_file );
        return () unless defined $rendered;
        @targets
            = $d->{path_braced}
            ? (
            grep {length}
                map { my $s = $_; $s =~ s/^\s+|\s+$//g; $s }
                split /,/,
            $rendered
            )
            : ($rendered);
        1;
    };
    $PLANNING_PASS = 0;
    return $ok ? @targets : ();
}

sub process_template {
    my ( $template_file, $index, $total ) = @_;

    my $raw = read_template_raw($template_file);
    return 1 unless defined $raw;

    check_disable_fallback( $raw, $template_file );

    my ( $header, $body ) = split_header_body($raw);
    my $d = parse_directives( $header, $template_file );
    $body = $raw
        if $d->{no_header}
        ;   # header candidate wasn't actually a header; it's all body
    apply_header_overrides($d);

    reset_builtins_for_file( $template_file, $index, $total );

    my $ok = 1;

    # PRE hook: substitute first, then run, unless a global pre-scan
    # already covered every unique PRE hook up front.
    if ( $d->{pre} ) {
        my $pre_rendered = render_text( $d->{pre}, $template_file );
        if ( $ENV{HYIR_PRE_SCAN_RAN} ) {
            warn
                "@[diagnostic:warn:arg:pre_scan(true)]: Pre-scan already ran; skipping PRE for $template_file\n"
                if $SPIT_DEBUG;
        }
        else {
            $ok = 0 unless import_shell_env($pre_rendered);
        }
    }

    unless ( check_require( $d->{require}, $template_file ) ) {

        # A failed $REQUIRE check must actually stop this template --
        # marking the run failed while still writing output built from
        # data we just said was incomplete would defeat the point of
        # validating up front.
        return 0;
    }

    my $target_rendered
        = defined $d->{path}
        ? render_text( $d->{path}, $template_file )
        : undef;
    my $run_rendered
        = defined $d->{run}
        ? render_text( $d->{run}, $template_file )
        : undef;
    $body = render_text( $body, $template_file );

    unless ( defined $target_rendered && length $target_rendered ) {
        print
            "@[arg:empty_path(true)] No target specified in $template_file; skipping\n"
            if $SPIT_DEBUG;
        return $ok;
    }

    my @targets
        = $d->{path_braced}
        ? (
        grep {length}
            map { my $s = $_; $s =~ s/^\s+|\s+$//g; $s } split /,/,
        $target_rendered
        )
        : ($target_rendered);

    my $any_written = 0;
    for my $target (@targets) {
        my $target_dir = dirname($target);
        if ( $target_dir && $target_dir ne '' && $target_dir ne '.' )
        {
            unless ( $made_dirs{$target_dir}++ ) {
                eval {
                    make_path($target_dir) unless -d $target_dir;
                    1;
                } or do {
                    warn
                        "@[diagnostic:error(true)]: Could not create directory $target_dir: $@";
                    $ok = 0;
                    next;
                };
            }
        }

        my $existing    = '';
        my $file_exists = 0;
        if ( -f $target ) {
            $existing = eval {
                local $/;
                open my $fh, '<', $target
                    or die
                    "@[populate:error(true)]: Cannot read $target: $!";
                <$fh>;
            };
            if ($@) { warn $@; $ok = 0; next; }
            $file_exists = 1;
        }

        my $needs_write = ( !$file_exists || $existing ne $body );

        if ($needs_write) {
            if ($DRY_RUN) {
                print
                    "@[arg:dry_run(true)]: Would populate $target <- $template_file\n"
                    if $SPIT_DEBUG;
                $any_written = 1;
            }
            else {
                warn_if_networked($target_dir) if $SPIT_DEBUG;
                my $write_ok = eval {
                    if ($NO_ATOMIC) {
                        $current_lock = acquire_lock($target);
                        direct_write_to_target( $target, $body );
                    }
                    else {
                        my $tmp_path
                            = write_temp_file( $target_dir, $body );
                        $current_lock = acquire_lock($target);
                        eval {
                            rename_tmp_to_target( $tmp_path,
                                $target );
                            1;
                        } or do {
                            unlink $tmp_path if -f $tmp_path;
                            die $@;
                        };
                    }
                    1;
                };
                if ( !$write_ok ) {
                    my $err = $@ || 'Unknown error during write';
                    warn
                        "@[populate:error(true)]: Failed writing $target: $err";
                    $ok = 0;
                }
                else {
                    $any_written = 1;
                    manifest_record(
                        target => $target,
                        source => $template_file,
                        sha256 =>
                            ( $MANIFEST ? _sha256_hex($body) : '' ),
                    );
                }
                release_lock($current_lock) if defined $current_lock;
                $current_lock = undef;
            }
        }
    }

    if ( $run_rendered && $ALLOW_RUN ) {
        if ( defined $RUN_ALLOW_PATTERN
            && $run_rendered !~ /$RUN_ALLOW_PATTERN/ )
        {
            warn
                "@[diagnostic:error:security_policy(true)]: RUN hook does not match --run-allow-pattern, refusing to run: $run_rendered\n";
            $ok = 0;
        }
        elsif ($DRY_RUN) {
            print
                "@[arg:dry_run(true)]: Would run post-script: $run_rendered\n"
                if $SPIT_DEBUG;
        }
        elsif ($DEFER_RUN) {
            enqueue_post_script( $queue_fh, 1, $template_file,
                $run_rendered );
            print
                "@[defer_run:queued(true)]: Queued post-script from $template_file\n"
                if $SPIT_DEBUG;
        }
        else {
            $ok = 0
                unless execute_post_script( $run_rendered, 1,
                $template_file );
        }
    }

    if ($SPIT_DEBUG) {
        if ($any_written) {
            print
                "@[populate:write(true)]: @{[join(', ', @targets)]} <- $template_file\n";
        }
        else {
            print
                "@[populate:write(false)]: Skipped changing @{[join(', ', @targets)]} <- $template_file\n";
        }
    }

    return $ok;
}

sub enqueue_post_script {
    my ( $fh, $is_run, $source, $cmd ) = @_;
    return unless $fh;
    print $fh join( "\0", ( $is_run ? 1 : 0 ), $source, $cmd ), "\0";
}

sub read_queue_dir {
    my ($dir) = @_;
    my @items;
    return @items unless opendir( my $dh, $dir );
    my @qfiles = sort grep {/\.queue$/} readdir $dh;
    closedir $dh;

    for my $qfile (@qfiles) {
        my $path = File::Spec->catfile( $dir, $qfile );
        next unless -f $path;
        open my $fh, '<', $path or do {
            warn
                "@[diagnostic:error(true)]: Cannot read queue file $path: $!\n";
            next;
        };
        local $/ = "\0";
        my @fields;
        while ( my $chunk = <$fh> ) {
            chomp $chunk;
            push @fields, $chunk;
            if ( @fields == 3 ) {
                push @items,
                    {
                    is_run => $fields[0],
                    source => $fields[1],
                    cmd    => $fields[2]
                    };
                @fields = ();
            }
        }

     # A partial record here means a queued RUN hook is being silently
     # dropped -- that's data loss, not a debug curiosity, so this
     # warns unconditionally rather than only under --allow-debug.
        warn
            "@[diagnostic:warn(true)]: Discarding incomplete queue record in $path (a RUN hook may have been lost)\n"
            if @fields;
        close $fh;
    }
    return @items;
}

sub execute_post_script {
    my ( $cmd, $is_run, $source ) = @_;

    if ( defined $RUN_ALLOW_PATTERN && $cmd !~ /$RUN_ALLOW_PATTERN/ )
    {
        warn
            "@[diagnostic:error:security_policy(true)]: RUN hook does not match --run-allow-pattern, refusing to run: $cmd\n";
        return 0;
    }

    unless ( $is_run || -x $cmd ) {
        print
            "@[execution(false)]: Theme Control - Skipped non-executable script from $source\n"
            if $SPIT_DEBUG;
        return 1;
    }

    my $t0 = [gettimeofday];
    my ( $pid, $status, $timed_out );
    $pid = fork();
    die "@[diagnostic:error(true)]: fork failed: $!\n"
        unless defined $pid;
    if ( $pid == 0 ) {
        eval { require POSIX; POSIX::setpgid( 0, 0 ); }; # own process group: see _run_with_timeout for why
        exec( 'bash', '-c', $cmd ) or exit 127;
    }
    if ( $HOOK_TIMEOUT > 0 ) {
        local $SIG{ALRM}
            = sub { $timed_out = 1; die "HYIR_TIMEOUT\n"; };
        alarm($HOOK_TIMEOUT);
        eval { waitpid( $pid, 0 ); 1; };
        alarm(0);
        if ($timed_out) {
            kill( 'TERM', -$pid );
            Time::HiRes::sleep(0.2);
            kill( 'KILL', -$pid );
            waitpid( $pid, 0 );
        }
    }
    else {
        waitpid( $pid, 0 );
    }
    $status = $? >> 8;
    my $dur_ms = int( 1000 * tv_interval($t0) );
    audit(
        action      => 'run',
        cmd         => $cmd,
        target      => $source,
        exit_code   => ( $timed_out ? 'timeout' : $status ),
        duration_ms => $dur_ms
    );

    if ($timed_out) {
        warn
            "@[execution:error(true)]: $cmd from $source timed out after ${HOOK_TIMEOUT}s\n";
        return 0;
    }
    if ( $status != 0 ) {
        warn
            "@[execution:error(true)]: Failed to execute $cmd from $source (exit $status)\n";
        return 0;
    }
    return 1;
}

sub run_queue_serial {
    my ($items) = @_;
    my $any_failed = 0;
    for my $item (@$items) {
        last if $FAIL_FAST && aborted();
        execute_post_script( $item->{cmd}, $item->{is_run},
            $item->{source} )
            or do { $any_failed = 1; trip_abort() if $FAIL_FAST; };
    }
    return $any_failed;
}

sub run_queue_concurrent {
    my ( $items, $concurrency ) = @_;
    my @pending = @$items;
    my %running;
    my $any_failed = 0;

    while ( @pending || %running ) {
        while ( @pending && scalar( keys %running ) < $concurrency ) {
            last if $FAIL_FAST && aborted();
            my $item = shift @pending;
            my $pid  = fork;
            if ( !defined $pid ) {
                warn
                    "@[diagnostic:error:fork:run(false)]: Fork failed for deferred post-script, running inline: $!\n";
                execute_post_script( $item->{cmd}, $item->{is_run},
                    $item->{source} )
                    or $any_failed = 1;
                next;
            }
            if ( $pid == 0 ) {
                my $ok = execute_post_script( $item->{cmd},
                    $item->{is_run}, $item->{source} );
                exit( $ok ? 0 : 1 );
            }
            $running{$pid} = 1;
        }
        last unless %running;
        my $p = wait();
        if ( $p > 0 ) {
            if ( ( $? >> 8 ) != 0 ) {
                $any_failed = 1;
                trip_abort() if $FAIL_FAST;
            }
            delete $running{$p};
        }
    }
    return $any_failed;
}

sub run_queue_background {
    my ($items) = @_;
    execute_post_script_background( $_->{cmd}, $_->{is_run},
        $_->{source} )
        for @$items;
    return 0;
}

# Detached execution ("fire and forget", --run-concurrency 0). The
# original built a shell string ("nohup $cmd >>'$log' 2>&1 &") and handed
# it to system() -- fragile if $log or $cmd ever contained a quote, and
# dependent on the external `nohup` binary. A double-fork daemonizes the
# command directly: the intermediate child exits immediately so the
# grandchild is reparented to init right away, so it survives this
# process exiting without becoming a zombie we never reap.
sub execute_post_script_background {
    my ( $cmd, $is_run, $source ) = @_;

    unless ( $is_run || -x $cmd ) {
        print
            "@[execution(false)]: Theme Control - Skipped non-executable script from $source\n"
            if $SPIT_DEBUG;
        return;
    }

    my $log = File::Spec->catfile( $ENV{HYIR_LOCK_DIR} // $locks_base,
        'nohup.out' );

    my $mid = fork();
    if ( !defined $mid ) {
        warn
            "@[diagnostic:error:fork:run(false)]: Fork failed for background post-script: $!\n";
        return;
    }
    if ( $mid == 0 ) {
        my $gc = fork();
        if ( !defined $gc ) { exit 1; }
        if ( $gc == 0 ) {
            eval { require POSIX; POSIX::setsid(); };
            open STDIN,  '<',  '/dev/null';
            open STDOUT, '>>', $log or open STDOUT, '>', '/dev/null';
            open STDERR, '>>', $log or open STDERR, '>', '/dev/null';
            exec( 'bash', '-c', $cmd ) or exit 127;
        }
        exit 0;
    }
    waitpid( $mid, 0 );
    warn
        "@[defer_run:background(true)]: Backgrounded post-script from $source (log: $log)\n"
        if $SPIT_DEBUG;
}

# ---------------------------------------------------------------------------
# File discovery (unchanged natural sort: case-insensitive, numeric runs
# compared as numbers so "file2" sorts before "file10").
# ---------------------------------------------------------------------------
find(
    {   wanted => sub {
            return
                unless -f && /\.(dcol|theme)$/
                && !exists $SKIP_SET{ basename($_) };
            $found = 1;
            push @files, $File::Find::name;
        },
        no_chdir => 1,
    },
    @template_source
);

unless ( $found || defined $ENV{HYIR_HEADER_BUFFER} ) {
    printf(
        "@[stream:file_capture(false)]: %s: no .dcol templates found, nothing to apply.\n",
        $SCRIPT_NAME );
    exit 1;
}

@files = map { $_->[0] }
    sort {
    my ( $ap, $bp ) = ( $a->[1], $b->[1] );
    $res = 0;
    for ( my $i = 0; $i < @$ap && $i < @$bp; $i++ ) {
        $res
            = $ap->[$i] =~ /^\d+$/ && $bp->[$i] =~ /^\d+$/
            ? ( $ap->[$i] <=> $bp->[$i] )
            : ( lc( $ap->[$i] ) cmp lc( $bp->[$i] ) );
        last if $res;
    }
    $res || scalar(@$ap) <=> scalar(@$bp);
    }
    map {
    [ $_, [ map { /^\d+$/ ? $_ : lc($_) } split /(\d+)/, $_ ] ]
    } @files;

if ( defined $ENV{HYIR_HEADER_BUFFER} ) {
    push @files, '::BUFFER::';
    $found = 1;
}

$n = scalar @files;

# ---------------------------------------------------------------------------
# PRE-scan: run each unique PRE hook once in the parent before forking, so
# workers inherit a fully-populated environment instead of re-running the
# same hook once per worker that happens to see it.
#
# The original implementation deduplicated and executed the *raw,
# unsubstituted* PRE text -- if a hook itself contained a placeholder
# (e.g. "export X=[::BASE_DIR::]/thing"), pre-scan ran it with the literal
# placeholder text still in there while the non-pre-scan path substituted
# it first, so enabling --pre-scan could silently change (or break) hook
# behavior. Pre-scan now renders each hook exactly the way process_template
# would before deduplicating and running it, which also makes the dedup
# key meaningful (two hooks that are only superficially different in their
# raw text but render identically are now correctly treated as the same).
# ---------------------------------------------------------------------------
if ($ALLOW_PRE_SCAN) {
    unless ($ALLOW_PRE) {
        die
            "@[arg:required_flag(--allow-pre)]: Pre-scan requested but PRE is not allowed. Set \$HYIR_ALLOW_PRE=1.\n";
    }

    my %seen_pre;
    for my $idx ( 0 .. $n - 1 ) {
        last if $FAIL_FAST && aborted();
        my $f   = $files[$idx];
        my $raw = eval { read_template_raw($f) };
        next unless defined $raw;
        my ( $header, undef ) = split_header_body($raw);
        my $d = parse_directives( $header, $f );
        apply_header_overrides($d);
        next unless defined $d->{pre} && length $d->{pre};

        reset_builtins_for_file( $f, $idx, $n );
        my $pre_rendered = render_text( $d->{pre}, $f );
        ( my $key = $pre_rendered ) =~ s/\s+/ /g;
        $key =~ s/^\s+|\s+$//g;

        unless ( $seen_pre{$key}++ ) {
            warn
                "@[active:arg:flag(--pre-scan)]: Running PRE - $pre_rendered\n"
                if $SPIT_DEBUG;
            unless ( import_shell_env($pre_rendered) ) {
                die
                    "@[diagnostic:error(true)]: PRE hook failed during --pre-scan, aborting: $pre_rendered\n"
                    if $FAIL_FAST || $ALLOW_STRICT_WARNINGS;
            }
        }
    }

    $ENV{HYIR_PRE_SCAN_RAN} = 1;
    build_env_cache();
}

if ( $ALLOW_PRE && $NPROC > 1 && !$ALLOW_PRE_SCAN ) {
    warn
        "@[diagnostic:warn(true)]: Running with --proc $NPROC and PRE hooks without --pre-scan: an identical PRE hook may run once per worker instead of once globally. Pass --pre-scan if your hooks are not idempotent.\n";
}

# ---------------------------------------------------------------------------
# Work distribution: group templates whose *resolved* targets collide so
# they're always handled by one worker, in file order, instead of leaving
# same-target writes to race across worker processes (the target lock
# still exists, but only as a safety net across separate invocations --
# this is what makes a single run's own output deterministic). Templates
# with a unique target are singleton units. Units are then spread across
# workers with a longest-first greedy balance.
# ---------------------------------------------------------------------------
sub compute_work_units {
    my %target_to_indices;
    for my $i ( 0 .. $n - 1 ) {
        my @tgts
            = eval { resolve_targets_only( $files[$i], $i, $n ) };
        for my $t (@tgts) {
            push @{ $target_to_indices{$t} }, $i;
        }
    }

    my @parent = ( 0 .. $n - 1 );
    my $find;
    $find = sub {
        my ($x) = @_;
        while ( $parent[$x] != $x ) {
            $parent[$x] = $parent[ $parent[$x] ];
            $x = $parent[$x];
        }
        return $x;
    };
    for my $t ( keys %target_to_indices ) {
        my @idxs = @{ $target_to_indices{$t} };
        next if @idxs < 2;
        for my $k ( 1 .. $#idxs ) {
            my ( $ra, $rb )
                = ( $find->( $idxs[0] ), $find->( $idxs[$k] ) );
            $parent[$ra] = $rb if $ra != $rb;
        }
    }

    my %members;
    for my $i ( 0 .. $n - 1 ) {
        push @{ $members{ $find->($i) } }, $i;
    }

    my $collisions = grep { @$_ > 1 } values %members;
    if ( $collisions && $SPIT_DEBUG ) {
        warn
            "@[diagnostic:debug(true)]: $collisions target-collision group(s) detected; each will be rendered by a single worker in file order\n";
    }

    return [
        map {
            [ sort { $a <=> $b } @{ $members{$_} } ]
        } keys %members
    ];
}

sub distribute_work_units {
    my ( $units, $workers ) = @_;
    my @sorted  = sort { scalar(@$b) <=> scalar(@$a) } @$units;
    my @buckets = map  { [] } 1 .. $workers;
    my @load    = (0) x $workers;
    for my $unit (@sorted) {
        my ($min_i) = sort { $load[$a] <=> $load[$b] } 0 .. $#buckets;
        push @{ $buckets[$min_i] }, $unit;
        $load[$min_i] += scalar(@$unit);
    }
    return @buckets;
}

$workers = $n < $NPROC ? $n : $NPROC;
$workers = 1 if $workers < 1;

my $work_units = compute_work_units();
my @buckets    = distribute_work_units( $work_units, $workers );

my $t0 = [gettimeofday];

for my $bucket (@buckets) {
    next unless @$bucket;
    my $pid = fork // die "Fork failed: $!";
    if ( $pid == 0 ) {
        my $worker_failed = 0;
        eval {
            if ($DEFER_RUN) {
                my $qfile
                    = File::Spec->catfile( $queue_dir, "$$.queue" );
                open $queue_fh, '>', $qfile
                    or die
                    "@[diagnostic:error:populate:write(false)]: Cannot create queue file $qfile: $!\n";
                binmode $queue_fh;
            }
        UNIT: for my $unit (@$bucket) {
                for my $i (@$unit) {
                    if ( $FAIL_FAST && aborted() ) {
                        last UNIT;
                    }
                    my $ok = eval {
                        process_template( $files[$i], $i, $n );
                    };
                    if ($@) {
                        warn
                            "@[diagnostic:error(true)]: $files[$i]: $@";
                        $worker_failed = 1;
                        trip_abort() if $FAIL_FAST;
                    }
                    elsif ( !$ok ) {
                        $worker_failed = 1;
                        trip_abort() if $FAIL_FAST;
                    }
                }
            }
            1;
        } or do {
            warn
                "@[diagnostic:error:fork:worker(false)]: Worker encountered an error: \n\t$@";
            $worker_failed = 1;
        };
        close $queue_fh if $queue_fh;
        exit( $worker_failed ? 1 : 0 );
    }
    $pids{$pid} = 1;
}

my $failed = 0;
while ( scalar keys %pids ) {
    my $p = wait();
    last if $p == -1;
    if ( $p > 0 ) {
        my $status = $? >> 8;
        $failed = 1 if $status != 0;
        delete $pids{$p};
    }
}

if ($DEFER_RUN) {
    my @queued = read_queue_dir($queue_dir);
    if (@queued) {
        warn sprintf(
            "@[defer_run:queue(true)]: Running %d deferred post-script(s)\n",
            scalar @queued )
            if $SPIT_DEBUG;
        my $run_failed
            = $RUN_CONCURRENCY == 0 ? run_queue_background( \@queued )
            : $RUN_CONCURRENCY > 1
            ? run_queue_concurrent( \@queued, $RUN_CONCURRENCY )
            : run_queue_serial( \@queued );
        $failed = 1 if $run_failed;
    }
    if ( opendir my $dh, $queue_dir ) {
        unlink File::Spec->catfile( $queue_dir, $_ )
            for grep {/\.queue$/} readdir $dh;
        closedir $dh;
    }
    rmdir $queue_dir;
}

my $elapsed = tv_interval($t0);

if ($STATS_JSON) {
    my $stats
        = sprintf(
        qq({"files":%d,"workers":%d,"elapsed_seconds":%.4f,"failed":%s}\n),
        $n, $workers, $elapsed, ( $failed ? 'true' : 'false' ) );
    if ( open my $fh, '>', $STATS_JSON ) {
        print {$fh} $stats;
        close $fh;
    }
    else {
        warn
            "@[diagnostic:error(true)]: Could not write --stats-json to $STATS_JSON: $!\n";
    }
}

if ($SPIT_DEBUG) {
    printf(
        "@[diagnostic:telemetry(On)]: Rendered %d templates using %d workers in %.4f seconds (%s).\n",
        $n, $workers, $elapsed,
        ( $failed ? 'with failures' : 'all succeeded' ) );
}
exit( $failed ? 1 : 0 );
HYIR_PERL_SCRIPT_EOF
