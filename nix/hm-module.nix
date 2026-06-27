# Home Manager module for org-mode-google-tasks-sync.
#
# Two ways to wire credentials:
#
# 1. Easiest, no Nix coupling: leave `clientId` / `clientSecretFile` null and
#    run `M-x org-mode-google-tasks-sync-configure` once.  All three secrets
#    end up in `~/.authinfo.gpg` via auth-source.
#
# 2. Declarative (sops-nix, agenix, hand-managed file, etc.):
#    set `clientId` (string), `clientSecretFile` (runtime path), and
#    `gpgRecipient` (your GPG key id/email).  At activation, the module
#    writes a two-file GPG-encrypted auth-source pair under
#    `$XDG_DATA_HOME/org-mode-google-tasks-sync/`:
#
#      static-creds.authinfo.gpg  -- HM owns; contains client_id + client_secret.
#                                    Re-encrypted from scratch on every rebuild.
#                                    HM never decrypts, so gpg-agent does NOT
#                                    need to be unlocked at activation time.
#
#      dynamic-creds.authinfo.gpg -- Emacs owns; contains the refresh_token,
#                                    written by `M-x org-mode-google-tasks-sync-authorize`.
#                                    HM never touches it.  Emacs uses the
#                                    .dir-locals.el (pinned by HM) to pick the
#                                    correct GPG recipient without prompting.
#
#    Your `~/.authinfo.gpg` is never touched.
#
# Example with sops-nix:
#
#   sops.secrets.org-mode-google-tasks-sync-client-secret = {
#     sopsFile = ./secrets.yaml;
#   };
#   programs.org-mode-google-tasks-sync = {
#     enable = true;
#     clientId         = "1234567890-abcdef.apps.googleusercontent.com";
#     clientSecretFile = config.sops.secrets.org-mode-google-tasks-sync-client-secret.path;
#     gpgRecipient     = "alex@example.com";
#     map = {
#       "MTYxOTU..." = { file = "~/org/personal.org"; parentHeading = "Inbox"; };
#     };
#   };

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.org-mode-google-tasks-sync;

  hasStaticCreds = cfg.clientId != null
                   && cfg.clientSecretFile != null
                   && cfg.gpgRecipient != null;

  xdgDir = "${config.xdg.dataHome}/org-mode-google-tasks-sync";
  staticPath  = "${xdgDir}/static-creds.authinfo.gpg";
  dynamicPath = "${xdgDir}/dynamic-creds.authinfo.gpg";
  dirLocalsPath = "${xdgDir}/.dir-locals.el";

  mapEntryType = lib.types.submodule {
    options = {
      file = lib.mkOption {
        type = lib.types.str;
        description = "Path to the org file that holds the synced subtree.";
        example = "~/org/personal.org";
      };
      parentHeading = lib.mkOption {
        type = lib.types.str;
        description = ''
          Exact text of the parent heading.  Sync touches only direct
          children of this heading; anything else in the file is left alone.
        '';
        example = "Inbox";
      };
    };
  };

  mapAsElisp =
    let
      entry = id: e:
        ''("${id}" . ("${e.file}" . "${e.parentHeading}"))'';
    in
    lib.concatStringsSep "\n            "
      (lib.mapAttrsToList entry cfg.map);
in
{
  options.programs.org-mode-google-tasks-sync = {
    enable = lib.mkEnableOption "two-way sync between org-mode and Google Tasks";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.emacsPackages.org-mode-google-tasks-sync;
      defaultText = lib.literalExpression
        "pkgs.emacsPackages.org-mode-google-tasks-sync";
      description = "Package to install.";
    };

    clientId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "1234567890-abcdef.apps.googleusercontent.com";
      description = ''
        OAuth client ID.  When set together with `clientSecretFile` and
        `gpgRecipient`, the module materializes a GPG-encrypted
        auth-source file under $XDG_DATA_HOME and points Emacs at it.
        Null = use `M-x org-mode-google-tasks-sync-configure` instead.

        Client IDs are semi-public (visible in browser URLs during
        consent), so keeping this as a Nix string is fine.
      '';
    };

    clientSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression ''
        config.sops.secrets.org-mode-google-tasks-sync-client-secret.path
      '';
      description = ''
        Path to a runtime file containing the OAuth client secret.  Read
        at activation, so this must be a runtime-mounted path (sops-nix,
        agenix, NixOS keys, `home.file`) — never a `/nix/store/` path,
        which would leak the secret into the world-readable store.
      '';
    };

    gpgRecipient = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alex@example.com";
      description = ''
        GPG key id or email used to encrypt the credentials files in
        $XDG_DATA_HOME.  Required whenever `clientId` and
        `clientSecretFile` are set.  Used both for the initial
        encryption of the static-creds file and as the recipient pinned
        in `.dir-locals.el` so that Emacs's EasyPG knows which key to
        encrypt the dynamic-creds file with when `M-x ...-authorize`
        writes the refresh_token.
      '';
    };

    map = lib.mkOption {
      type = lib.types.attrsOf mapEntryType;
      default = { };
      example = lib.literalExpression ''
        {
          "MTYxOTU..." = { file = "~/org/work.org";     parentHeading = "Tasks"; };
          "MTk0NDg..." = { file = "~/org/personal.org"; parentHeading = "Inbox"; };
        }
      '';
      description = ''
        Maps Google Tasks list IDs (as returned by
        `M-x org-mode-google-tasks-sync-list-discover`) to an org file
        and the exact text of the parent heading under which synced
        tasks live.
      '';
    };

    tickInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Seconds between cheap wake-up checks.  Each tick checks the
        mtimes of the configured org files and triggers a sync only
        when something changed — so external edits land in Google
        within roughly this many seconds.
      '';
    };

    pollInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Maximum seconds between syncs.  Safety net so Google-side
        changes get pulled even when no local file has been modified.
      '';
    };

    fetchTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Seconds after which a sync in flight is considered hung; the
        engine resets state so the next tick can try again.  Bump if
        you have many lists or a slow network.
      '';
    };

    fullSyncInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 86400;
      description = ''
        Seconds between full reconciliation passes.  Full sync drops
        `updatedMin` and diffs Google's full ID set against local IDs to
        detect long-tombstoned deletions.
      '';
    };

    autoEnableMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to call `(org-mode-google-tasks-sync-mode 1)` at the end
        of the generated config.  Disable to start sync manually.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra Emacs Lisp appended after the generated config.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.clientId == null)
                       && (cfg.clientSecretFile == null)
                       && (cfg.gpgRecipient == null)
                   || (cfg.clientId != null)
                       && (cfg.clientSecretFile != null)
                       && (cfg.gpgRecipient != null);
          message = ''
            programs.org-mode-google-tasks-sync: clientId, clientSecretFile,
            and gpgRecipient must all be set together (declarative bridge)
            or all be null (interactive setup via M-x ...-configure).
          '';
        }
      ];

      # Ensure all the runtime prerequisites are present.  `programs.emacs`
      # is enabled by default; the user can override with mkForce or by
      # declaring their own Emacs setup elsewhere.  GnuPG is needed in PATH
      # for Emacs's EasyPG to read/write `.gpg` auth-source files.  plz and
      # oauth2 flow in automatically via the package's `packageRequires`.
      programs.emacs.enable = lib.mkDefault true;
      programs.emacs.extraPackages = epkgs: [ epkgs.org-mode-google-tasks-sync ];
      home.packages = [ pkgs.gnupg ];

      programs.emacs.extraConfig = lib.mkAfter ''
        ;; --- org-mode-google-tasks-sync (managed by Home Manager) ---
        (require 'org-mode-google-tasks-sync)
        ${lib.optionalString hasStaticCreds ''
          (with-eval-after-load 'auth-source
            (add-to-list 'auth-sources "${staticPath}")
            (add-to-list 'auth-sources "${dynamicPath}"))
          (setq org-mode-google-tasks-sync-oauth-write-target "${dynamicPath}")
        ''}
        (setq org-mode-google-tasks-sync-map
              '(${mapAsElisp}))
        (setq org-mode-google-tasks-sync-tick-interval ${toString cfg.tickInterval})
        (setq org-mode-google-tasks-sync-poll-interval ${toString cfg.pollInterval})
        (setq org-mode-google-tasks-sync-fetch-timeout ${toString cfg.fetchTimeout})
        (setq org-mode-google-tasks-sync-full-sync-interval ${toString cfg.fullSyncInterval})
        ${lib.optionalString cfg.autoEnableMode "(org-mode-google-tasks-sync-mode 1)"}
        ${cfg.extraConfig}
        ;; --- end org-mode-google-tasks-sync ---
      '';
    }

    # When bridge is active: encrypt static-creds + drop .dir-locals.el.
    # HM never decrypts anything — only encrypts with the public key — so
    # gpg-agent does NOT need to be unlocked at activation time.
    (lib.mkIf hasStaticCreds {
      home.activation.org-mode-google-tasks-sync-credentials =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          set -eu

          $DRY_RUN_CMD install -m 0700 -d ${lib.escapeShellArg xdgDir}

          # static-creds.authinfo.gpg — encrypted with the public key.
          # No decrypt step; no gpg-agent unlock required.
          tmp=$(mktemp)
          chmod 600 "$tmp"
          {
            printf 'machine api.google.com login org-mode-google-tasks-sync-client-id      password %s\n' \
              ${lib.escapeShellArg cfg.clientId}
            printf 'machine api.google.com login org-mode-google-tasks-sync-client-secret  password %s\n' \
              "$(cat ${lib.escapeShellArg (toString cfg.clientSecretFile)})"
          } > "$tmp"
          ${pkgs.gnupg}/bin/gpg --encrypt \
            --recipient ${lib.escapeShellArg cfg.gpgRecipient} \
            --batch --yes --trust-model always \
            --output ${lib.escapeShellArg staticPath} "$tmp"
          chmod 600 ${lib.escapeShellArg staticPath}
          rm -f "$tmp"

          # .dir-locals.el pins the recipient EasyPG will use when Emacs
          # writes dynamic-creds.authinfo.gpg.  epa-file-encrypt-to is
          # marked safe-local-variable in epa-file.el, so no prompt.
          $DRY_RUN_CMD install -m 0644 /dev/null ${lib.escapeShellArg dirLocalsPath}
          cat > ${lib.escapeShellArg dirLocalsPath} <<EOF
          ;;; Generated by Home Manager. Do not edit by hand.
          ((nil . ((epa-file-encrypt-to . (${lib.escapeShellArg cfg.gpgRecipient})))))
          EOF
        '';
    })

    # When bridge is disabled, remove anything HM put there previously.
    (lib.mkIf (!hasStaticCreds) {
      home.activation.org-mode-google-tasks-sync-credentials =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD rm -f ${lib.escapeShellArg staticPath} \
                             ${lib.escapeShellArg dirLocalsPath}
        '';
    })
  ]);
}
