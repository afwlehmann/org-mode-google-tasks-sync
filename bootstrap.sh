#!/usr/bin/env sh
# org-mode-google-tasks-sync — OAuth bootstrap helper.
#
# Run via curl, no clone needed:
#
#   curl -fsSL https://raw.githubusercontent.com/afwlehmann/org-mode-google-tasks-sync/main/bootstrap.sh | sh
#
# Or, equivalently:
#
#   nix run github:afwlehmann/org-mode-google-tasks-sync#bootstrap
#
# The helper:
#   1. Prompts for client_id and client_secret (Google Cloud Console).
#   2. Opens your browser to the OAuth consent screen.
#   3. Captures the redirect and exchanges the code for a refresh token.
#   4. Prints client_id, refresh_token, and your Google Tasks list IDs
#      to stdout, ready to paste into SOPS + Home Manager config.

set -eu

if ! command -v nix >/dev/null 2>&1; then
  cat >&2 <<'EOF'
This bootstrap helper needs Nix to fetch the package and its dependencies.

If you don't have Nix:
  - Install the package the usual way (see README) and run
    M-x org-mode-google-tasks-sync-bootstrap from inside Emacs.
EOF
  exit 1
fi

# `--refresh` forces Nix to re-resolve the flake input instead of using
# its cached copy.  Without this, a user who ran an earlier (buggy)
# version of the script will keep hitting the cached commit even after
# we've pushed a fix to main.
exec nix --extra-experimental-features 'nix-command flakes' \
  run --refresh github:afwlehmann/org-mode-google-tasks-sync#bootstrap
