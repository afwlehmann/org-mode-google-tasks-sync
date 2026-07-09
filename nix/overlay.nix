# Nixpkgs overlay: adds `org-mode-google-tasks-sync` to every `emacsPackages` scope.
#
# Apply it via:
#
#   nixpkgs.overlays = [ inputs.org-mode-google-tasks-sync.overlays.default ];
#
# Then `pkgs.emacsPackages.org-mode-google-tasks-sync` is available, and so is
# `epkgs.org-mode-google-tasks-sync` inside `programs.emacs.extraPackages = epkgs: ...`.

final: prev: {
  emacsPackagesFor =
    emacs:
    (prev.emacsPackagesFor emacs).overrideScope (
      eself: _esuper: {
        org-mode-google-tasks-sync = eself.callPackage ./package.nix { };
      }
    );

  emacsPackages = final.emacsPackagesFor final.emacs;
}
