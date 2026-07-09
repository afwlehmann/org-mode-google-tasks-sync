{
  description = "Pure Emacs Lisp two-way sync between org-mode and Google Tasks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    let
      inherit (nixpkgs) lib;
      # System-independent outputs (used by downstream Home-Manager/NixOS configs).
      overlay = import ./nix/overlay.nix;
      hmModule = import ./nix/hm-module.nix;
    in
    {
      overlays = {
        default = overlay;
        org-mode-google-tasks-sync = overlay;
      };

      homeManagerModules = {
        default = hmModule;
        org-mode-google-tasks-sync = hmModule;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };

        package = pkgs.emacsPackages.org-mode-google-tasks-sync;

        # Emacs preloaded with the package + its runtime deps, suitable for
        # interactive use: `nix run .#emacs`.
        emacsWithPackage = pkgs.emacs.pkgs.withPackages (_epkgs: [ package ]);

        # Emacs preloaded with just the deps (no package), suitable for
        # development.  The package itself is loaded from the working tree
        # via `add-to-list 'load-path`.
        emacsForDev = pkgs.emacs.pkgs.withPackages (
          epkgs: with epkgs; [
            plz
            oauth2
          ]
        );

        # git-hooks configuration: convco for commit messages + a custom
        # Emacs Lisp lint/test hook for pre-commit.
        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            # Enforce Conventional Commits on commit messages.
            convco.enable = true;

            # Byte-compile + checkdoc lint + ert test suite.
            emacs-lint-checks = {
              enable = true;
              name = "emacs-lint-checks";
              description = "Byte-compile + checkdoc + ert tests";
              entry = "${pkgs.writeShellScript "emacs-lint-checks" ''
                set -e
                ${emacsForDev}/bin/emacs --batch -L . \
                  -l hooks/lint.el -f org-mode-google-tasks-sync-lint
                ${emacsForDev}/bin/emacs --batch \
                  -l test/run-tests.el -f ert-run-tests-batch-and-exit
              ''}";
              files = "\\.el$";
              pass_filenames = false;
            };

            # Nix formatting.  Auto-stage reformatted files so the user
            # doesn't have to `git add` manually after formatting.
            nixfmt = {
              enable = true;
              entry = lib.mkForce "${pkgs.writeShellScript "nixfmt-and-stage" ''
                ${pkgs.nixfmt}/bin/nixfmt "$@"
                ${pkgs.git}/bin/git add -u
              ''}";
            };
          };
        };
      in
      {
        packages = {
          default = package;
          org-mode-google-tasks-sync = package;
          emacs = emacsWithPackage;
        };

        apps.emacs = {
          type = "app";
          program = "${emacsWithPackage}/bin/emacs";
          meta.description = "Emacs preloaded with org-mode-google-tasks-sync";
        };

        apps.bootstrap = {
          type = "app";
          program = "${pkgs.writeShellScript "org-mode-google-tasks-sync-bootstrap" ''
            exec ${emacsWithPackage}/bin/emacs --batch \
              -l org-mode-google-tasks-sync \
              -f org-mode-google-tasks-sync-bootstrap
          ''}";
          meta.description = "Interactive OAuth bootstrap: prompts for client_id and client_secret, captures the consent redirect, and prints the refresh token plus Google Tasks list IDs.";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            emacsForDev
            pkgs.gnupg
          ]
          ++ pre-commit-check.enabledPackages;
          shellHook = ''
            # Remove stale pre-commit legacy hooks left behind by previous
            # `pre-commit install` runs over hand-written hooks.  These
            # chain-via pre-commit's _run_legacy and may call flags the
            # current tool version no longer supports (e.g. convco 0.6.3
            # dropped `--file` in favour of `--from-stdin`), producing
            # spurious "unexpected argument" errors on every commit.
            for h in "$PWD/.git/hooks/"*.legacy; do
              [ -e "$h" ] && rm -f -- "$h"
            done
            ${pre-commit-check.shellHook}
            echo "org-mode-google-tasks-sync dev shell"
            echo "  emacs (with plz + oauth2): ${emacsForDev}/bin/emacs"
            echo "  run tests: emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit"
            echo "  git hooks auto-installed (convco + emacs-lint-checks)"
          '';
        };

        checks = {
          tests =
            pkgs.runCommand "org-mode-google-tasks-sync-tests"
              {
                buildInputs = [ emacsForDev ];
              }
              ''
                cp -r ${./.}/* .
                chmod -R u+w .
                export HOME=$TMPDIR
                emacs --batch -L . -l test/run-tests.el -f ert-run-tests-batch-and-exit
                touch $out
              '';

          lint =
            pkgs.runCommand "org-mode-google-tasks-sync-lint"
              {
                buildInputs = [ emacsForDev ];
              }
              ''
                cp -r ${./.}/* .
                chmod -R u+w .
                export HOME=$TMPDIR
                emacs --batch -L . -l hooks/lint.el -f org-mode-google-tasks-sync-lint
                touch $out
              '';

          pre-commit-check = pre-commit-check;
        };
      }
    );
}
