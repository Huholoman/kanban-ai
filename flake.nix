{
  description = "kanban-ai — file-based backlog for parallel AI coding agents: CLI, server and web board";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "0.1.0";

      # Only what the builds need, so that docs or the playground do not
      # trigger rebuilds.
      sourceFor =
        pkgs:
        pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./pubspec.yaml
            ./pubspec.lock
            ./analysis_options.yaml
            ./packages
          ];
        };

      packagesFor =
        pkgs:
        let
          src = sourceFor pkgs;

          web = pkgs.flutter332.buildFlutterApplication {
            pname = "kanban-ai-web";
            inherit version src;
            # Unpack the whole tree (the app path-depends on ../backlog_api)
            # and build from the app folder.
            sourceRoot = "${src.name}/packages/backlog_app";
            autoPubspecLock = ./packages/backlog_app/pubspec.lock;
            targetFlutterPlatform = "web";
            meta.description = "Web board of kanban-ai (static files, served by backlog-server)";
          };

          tools = pkgs.buildDartApplication {
            pname = "kanban-ai";
            inherit version src;
            autoPubspecLock = ./pubspec.lock;
            dartEntryPoints = {
              "bin/backlog" = "packages/backlog_cli/bin/backlog.dart";
              "bin/backlog-server" = "packages/backlog_server/bin/backlog_server.dart";
            };
            nativeBuildInputs = [ pkgs.makeWrapper ];
            preBuild = "mkdir -p bin";
            # The server serves the web app from the store unless told otherwise.
            postFixup = ''
              wrapProgram $out/bin/backlog-server --set-default BACKLOG_WEB ${web}
            '';
            meta = {
              description = "File-based backlog for parallel AI coding agents: `backlog` CLI and `backlog-server`";
              homepage = "https://github.com/Huholoman/kanban-ai";
              mainProgram = "backlog";
            };
          };
        in
        {
          inherit web;
          kanban-ai = tools;
          default = tools;
        };
    in
    {
      packages = forAllSystems packagesFor;

      apps = forAllSystems (
        pkgs:
        let
          tools = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        in
        {
          default = {
            type = "app";
            program = "${tools}/bin/backlog";
          };
          backlog = self.apps.${pkgs.stdenv.hostPlatform.system}.default;
          server = {
            type = "app";
            program = "${tools}/bin/backlog-server";
          };
        }
      );

      overlays.default = final: _prev: {
        kanban-ai = self.packages.${final.stdenv.hostPlatform.system}.default;
      };

      nixosModules.default = import ./nix/module.nix self;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.flutter332
            pkgs.jq
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
