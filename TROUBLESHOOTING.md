# Troubleshooting

When the background tick fails, the error lands in `*org-mode-google-tasks-sync-log*` rather than `*Messages*` — open that buffer first with `M-x org-mode-google-tasks-sync-show-log`.

## `(epg-error "no usable configuration" OpenPGP)`

Emacs uses its built-in EasyPG (`epa-file`) to read and write `.gpg` files like `~/.authinfo.gpg`.  EasyPG is a thin wrapper that shells out to a real `gpg` binary — the binary itself isn't shipped with Emacs.  The error means EasyPG looked at `epg-gpg-program` (default `"gpg"`), tried to resolve it through `exec-path` / `PATH`, and found nothing usable.

The most common cause on macOS is **GUI Emacs being launched with a stripped PATH** that doesn't include the directory where `gpg` lives.  Open Emacs and check:

```elisp
M-: (executable-find "gpg") RET
```

If that returns `nil`, EasyPG can't find a gpg binary on `exec-path` — the GUI Emacs PATH problem on macOS.  Two options, pick whichever fits your setup:

1. **Add the binary's directory to `exec-path` explicitly.**  Pick the path returned by `which gpg` in a shell that *can* find it (Homebrew: `/opt/homebrew/bin/gpg` on Apple Silicon, `/usr/local/bin/gpg` on Intel; Nix/Home Manager: usually `/etc/profiles/per-user/$USER/bin/gpg` or directly under `/nix/store/.../bin/gpg`).  Then in `init.el`:
   ```elisp
   (add-to-list 'exec-path "/etc/profiles/per-user/alex/bin")
   ```
   `exec-path` is a list of directories, not a list of program paths — point at the directory containing `gpg`.

2. **Use [`exec-path-from-shell`](https://github.com/purcell/exec-path-from-shell)** so Emacs inherits your shell's `PATH` at startup.  Add to `init.el`:
   ```elisp
   (use-package exec-path-from-shell
     :if (memq window-system '(mac ns))
     :config (exec-path-from-shell-initialize))
   ```
   Fixes a much wider class of "GUI Emacs can't find a CLI tool" problems.

After applying either, restart Emacs (or toggle `org-mode-google-tasks-sync-mode` off and on) so the next tick re-probes.

### What *doesn't* work: pinning `epg-gpg-program`

You'll find advice online (and in older versions of this file) suggesting `(setq epg-gpg-program "/path/to/gpg")`.  Don't bother — in modern Emacs (≥27) this only sets the **default value** that gets baked into `epg-config--program-alist` at load time.  The actual dispatcher, `epg-find-configuration`, walks the program *names* (`"gpg2"`, `"gpg"`) with `executable-find` against your live `exec-path`, ignoring the variable.  In the common case the override appears to work only because `(executable-find "gpg")` happens to return the same path you set anyway.  When they diverge — as with a Nix-store path while `exec-path` excludes the dir — only `exec-path` wins.

Diagnose by running both:

```elisp
M-: epg-gpg-program RET                 ; whatever you set
M-: (executable-find "gpg") RET         ; what the dispatcher actually finds
```

If those don't agree, `executable-find` is the one to fix.

## Sync runs but nothing changes

Verify `org-mode-google-tasks-sync-map` has entries and that the parent heading text in your config matches the heading in the file exactly — case-sensitive, no leading stars.  Check `*org-mode-google-tasks-sync-log*` for `Skip tick` lines.

## Refresh token revoked at Google

After visiting https://myaccount.google.com/permissions and removing the app, the next tick will fail authenticating.  Re-run `M-x org-mode-google-tasks-sync-authorize` (or the `bootstrap` helper if you're declaratively-managed) to mint a fresh token.
