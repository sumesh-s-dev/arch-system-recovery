#!/usr/bin/env fish
# bin/arch-recovery.fish — Fish shell launcher for arch-system-recovery
#
# Fish cannot source bash scripts, so this wrapper simply forwards all
# arguments to the bash entry point, which lives alongside this file.
#
# Installation:  the install.sh script places this in $PREFIX/bin/
# Usage:         arch-recovery [FLAGS]  (same flags as the bash entry point)

set -l script_dir (dirname (status filename))
set -l bash_entry "$script_dir/arch-recovery"

# Prefer explicit bash; fall back to env lookup
if not command -q bash
    echo "arch-recovery: bash is required but was not found in PATH." >&2
    exit 1
end

if not test -x "$bash_entry"
    echo "arch-recovery: cannot find bash entry point at: $bash_entry" >&2
    exit 1
end

# Forward all arguments unchanged
exec bash "$bash_entry" $argv
