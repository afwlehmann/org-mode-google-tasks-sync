{
  description = "Pure Emacs Lisp two-way sync between org-mode and Google Tasks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
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
    //
    flake-utils.lib.eachDefaultSystem (system:
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
        emacsForDev = pkgs.emacs.pkgs.withPackages (epkgs:
          with epkgs; [ plz oauth2 ]);
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
          meta.description =
            "Interactive OAuth bootstrap: prompts for client_id and client_secret, captures the consent redirect, and prints the refresh token plus Google Tasks list IDs.";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            emacsForDev
            pkgs.gnupg
          ];
          shellHook = ''
            echo "org-mode-google-tasks-sync dev shell"
            echo "  emacs (with plz + oauth2): ${emacsForDev}/bin/emacs"
            echo "  run tests: emacs --batch -l test/run-tests.el -f ert-run-tests-batch-and-exit"
          '';
        };

        checks.tests = pkgs.runCommand "org-mode-google-tasks-sync-tests"
          {
            buildInputs = [ emacsForDev ];
          } ''
          cp -r ${./.}/* .
          chmod -R u+w .
          export HOME=$TMPDIR
          emacs --batch -L . -l test/run-tests.el -f ert-run-tests-batch-and-exit
          touch $out
        '';
      });
}
