#!/usr/bin/env bash
# install.sh — install or uninstall arch-recovery
#
# Usage:
#   sudo ./install.sh                        # install to /usr/local
#   sudo ./install.sh --prefix /opt/recovery
#   sudo ./install.sh --uninstall
#   sudo ./install.sh --prefix /usr --uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
PREFIX="/usr/local"
UNINSTALL=false
INSTALL_COMPLETIONS=true
INSTALL_MAN=true

# ── Parse ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)              PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
        --uninstall)           UNINSTALL=true;            shift ;;
        --no-completions)      INSTALL_COMPLETIONS=false; shift ;;
        --no-man)              INSTALL_MAN=false;         shift ;;
        --help|-h)
            cat <<EOF
Usage: sudo ./install.sh [OPTIONS]

Options:
  --prefix DIR        Install root (default: /usr/local)
  --uninstall         Remove all installed files
  --no-completions    Skip shell completion installation
  --no-man            Skip manpage installation
  --help              This message
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Paths ─────────────────────────────────────────────────────────────────────
BIN_DIR="${PREFIX}/bin"
LIB_DIR="${PREFIX}/lib/arch-recovery"
DOC_DIR="${PREFIX}/share/doc/arch-recovery"
MAN_DIR="${PREFIX}/share/man/man1"
BASH_COMP_DIR="${PREFIX}/share/bash-completion/completions"
ZSH_COMP_DIR="${PREFIX}/share/zsh/site-functions"
FISH_COMP_DIR="${PREFIX}/share/fish/vendor_completions.d"

# ── Privilege ─────────────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || { echo "Error: must run as root." >&2; exit 1; }

# ── Uninstall ─────────────────────────────────────────────────────────────────
if ${UNINSTALL}; then
    echo "Uninstalling arch-recovery from ${PREFIX}..."
    rm -fv "${BIN_DIR}/arch-recovery"
    rm -fv "${BIN_DIR}/arch-recovery.fish"
    rm -fv "${BIN_DIR}/arch-recovery.sh"
    rm -rf "${LIB_DIR}"
    rm -rf "${DOC_DIR}"
    rm -fv "${MAN_DIR}/arch-recovery.1" "${MAN_DIR}/arch-recovery.1.gz"
    rm -fv "${BASH_COMP_DIR}/arch-recovery"
    rm -fv "${ZSH_COMP_DIR}/_arch-recovery"
    rm -fv "${FISH_COMP_DIR}/arch-recovery.fish"
    echo "Done."
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo "Installing arch-recovery to ${PREFIX}..."

install -d "${BIN_DIR}" "${LIB_DIR}" "${DOC_DIR}"

# ── Library modules ───────────────────────────────────────────────────────────
for module in "${SCRIPT_DIR}/lib/"*.sh; do
    install -m 644 "${module}" "${LIB_DIR}/"
    echo "  lib: ${LIB_DIR}/$(basename "${module}")"
done

# ── Entry point (patch LIB_DIR path at install time) ─────────────────────────
sed \
    -e "s|LIB_DIR=\"\${REPO_ROOT}/lib\"|LIB_DIR=\"${LIB_DIR}\"  # patched by install.sh|" \
    "${SCRIPT_DIR}/bin/arch-recovery" \
    > /tmp/arch-recovery-install-patched

install -m 755 /tmp/arch-recovery-install-patched "${BIN_DIR}/arch-recovery"
rm -f /tmp/arch-recovery-install-patched
echo "  bin: ${BIN_DIR}/arch-recovery"

# ── Shell launchers ───────────────────────────────────────────────────────────
install -m 755 "${SCRIPT_DIR}/bin/arch-recovery.fish" "${BIN_DIR}/arch-recovery.fish"
install -m 755 "${SCRIPT_DIR}/bin/arch-recovery.sh"   "${BIN_DIR}/arch-recovery.sh"
echo "  bin: ${BIN_DIR}/arch-recovery.fish"
echo "  bin: ${BIN_DIR}/arch-recovery.sh"

# ── Documentation ─────────────────────────────────────────────────────────────
for doc in "${SCRIPT_DIR}/docs/"*.md "${SCRIPT_DIR}/README.md"; do
    install -m 644 "${doc}" "${DOC_DIR}/"
    echo "  doc: ${DOC_DIR}/$(basename "${doc}")"
done

# ── Manpage ───────────────────────────────────────────────────────────────────
if ${INSTALL_MAN} && [[ -f "${SCRIPT_DIR}/man/arch-recovery.1" ]]; then
    install -d "${MAN_DIR}"
    if command -v gzip &>/dev/null; then
        gzip -9 -c "${SCRIPT_DIR}/man/arch-recovery.1" \
            > "${MAN_DIR}/arch-recovery.1.gz"
        chmod 644 "${MAN_DIR}/arch-recovery.1.gz"
        echo "  man: ${MAN_DIR}/arch-recovery.1.gz"
    else
        install -m 644 "${SCRIPT_DIR}/man/arch-recovery.1" "${MAN_DIR}/"
        echo "  man: ${MAN_DIR}/arch-recovery.1"
    fi
fi

# ── Shell completions ─────────────────────────────────────────────────────────
if ${INSTALL_COMPLETIONS}; then
    # Bash
    install -d "${BASH_COMP_DIR}"
    install -m 644 "${SCRIPT_DIR}/completions/arch-recovery.bash" \
        "${BASH_COMP_DIR}/arch-recovery"
    echo "  completion (bash): ${BASH_COMP_DIR}/arch-recovery"

    # Zsh
    install -d "${ZSH_COMP_DIR}"
    install -m 644 "${SCRIPT_DIR}/completions/_arch-recovery" \
        "${ZSH_COMP_DIR}/_arch-recovery"
    echo "  completion (zsh):  ${ZSH_COMP_DIR}/_arch-recovery"

    # Fish
    install -d "${FISH_COMP_DIR}"
    install -m 644 "${SCRIPT_DIR}/completions/arch-recovery.fish" \
        "${FISH_COMP_DIR}/arch-recovery.fish"
    echo "  completion (fish): ${FISH_COMP_DIR}/arch-recovery.fish"
fi

# ── Post-install summary ──────────────────────────────────────────────────────
echo ""
echo "Installation complete."
echo ""
echo "  Usage:      sudo arch-recovery --help"
echo "  Manpage:    man arch-recovery"
echo "  Docs:       ${DOC_DIR}/"
echo "  Log:        /tmp/recovery-toolkit.log"
echo ""
echo "  To uninstall:   sudo ./install.sh --uninstall"
echo ""

# Fish users: print reminder to source completions
if command -v fish &>/dev/null && ${INSTALL_COMPLETIONS}; then
    echo "  Fish users: completions are auto-loaded on next fish session."
fi
