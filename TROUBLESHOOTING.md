# Troubleshooting

When the background tick fails, the error lands in `*org-mode-google-tasks-sync-log*` rather than `*Messages*` — open that buffer first with `M-x org-mode-google-tasks-sync-show-log`.

## `(epg-error "no usable configuration" OpenPGP)`

Emacs uses its built-in EasyPG (`epa-file`) to read and write `.gpg` files like `~/.authinfo.gpg`.  EasyPG is a thin wrapper that shells out to a real `gpg` binary — the binary itself isn't shipped with Emacs.  The error means EasyPG looked at `epg-gpg-program` (default `"gpg"`), tried to resolve it through `exec-path` / `PATH`, and found nothing usable.

The most common cause on macOS is **GUI Emacs being launched with a stripped PATH** that doesn't include the directory where `gpg` lives.  Open Emacs and check:

```elisp
M-: (executable-find "gpg") RET
```

If that returns `nil`, the rest of this section applies.  Three options, pick whichever fits your setup:

1. **Pin the gpg path explicitly** (works for any Emacs).  Add to `init.el`:
   ```elisp
   (setq epg-gpg-program "/path/to/gpg")
   ```
   The path comes from `which gpg` in a shell that *can* find it.  On a Home Manager / Nix setup the gpg binary lives at something like `/etc/profiles/per-user/$USER/bin/gpg` or directly under the Nix store; on Homebrew it's `/opt/homebrew/bin/gpg` (Apple Silicon) or `/usr/local/bin/gpg` (Intel).

2. **Use [`exec-path-from-shell`](https://github.com/purcell/exec-path-from-shell)** so Emacs inherits your shell's `PATH` at startup.  Add to `init.el`:
   ```elisp
   (use-package exec-path-from-shell
     :if (memq window-system '(mac ns))
     :config (exec-path-from-shell-initialize))
   ```
   This fixes a much wider class of "GUI Emacs can't find a CLI tool" problems.

3. **Make sure `gpg` is installed at all.**  `brew install gnupg` on macOS, your distro's `gnupg` package on Linux.  Nix/HM users already get it via the module's `home.packages` — but that puts it on the shell PATH, which doesn't help GUI Emacs without one of the two fixes above.

After applying any of these, restart Emacs (or toggle `org-mode-google-tasks-sync-mode` off and on) so the timer picks up the fix.

## Sync runs but nothing changes

Verify `org-mode-google-tasks-sync-map` has entries and that the parent heading text in your config matches the heading in the file exactly — case-sensitive, no leading stars.  Check `*org-mode-google-tasks-sync-log*` for `Skip tick` lines.

## Refresh token revoked at Google

After visiting https://myaccount.google.com/permissions and removing the app, the next tick will fail authenticating.  Re-run `M-x org-mode-google-tasks-sync-authorize` (or the `bootstrap` helper if you're declaratively-managed) to mint a fresh token.
