#!/bin/sh
# bin/arch-recovery.sh — POSIX sh launcher for arch-system-recovery
#
# Use this if your login shell is dash, sh, or any POSIX shell that
# cannot source Bash 4+ syntax.  It delegates entirely to bash.
#
# Usage: sh arch-recovery.sh [FLAGS]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASH_ENTRY="${SCRIPT_DIR}/arch-recovery"

if ! command -v bash >/dev/null 2>&1; then
    printf 'arch-recovery: bash is required but was not found in PATH.\n' >&2
    exit 1
fi

if [ ! -x "${BASH_ENTRY}" ]; then
    printf 'arch-recovery: cannot find bash entry point at: %s\n' "${BASH_ENTRY}" >&2
    exit 1
fi

exec bash "${BASH_ENTRY}" "$@"
