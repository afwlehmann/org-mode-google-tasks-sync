{
  trivialBuild,
  plz,
  oauth2,
  lib,
}:

trivialBuild {
  pname = "org-mode-google-tasks-sync";
  version = "0.2.0";
  src = ../.;
  packageRequires = [
    plz
    oauth2
  ];

  # Tests aren't shipped with the installed package; they're only run via
  # `nix flake check`.
  preBuild = ''
    rm -rf test
  '';

  meta = {
    description = "Two-way sync between org-mode and Google Tasks";
    homepage = "https://github.com/afwlehmann/org-mode-google-tasks-sync";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
