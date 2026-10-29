self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kanban-ai;
in
{
  options.services.kanban-ai = {
    enable = lib.mkEnableOption "the kanban-ai backlog server (web board and API)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "kanban-ai.packages.\${system}.default";
    };

    backlog = lib.mkOption {
      type = lib.types.str;
      example = "/home/me/projects/myapp/backlog";
      description = "Backlog folder (the one with backlog.yaml).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User the server runs as; it needs write access to the backlog folder.";
    };

    host = lib.mkOption {
      type = lib.types.coercedTo lib.types.str lib.toList (lib.types.listOf lib.types.str);
      default = [ "127.0.0.1" ];
      example = [
        "127.0.0.1"
        "10.77.1.2"
      ];
      description = "Address or addresses to bind; 0.0.0.0 for the whole network.";
    };

    allow = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "127.0.0.1"
        "10.77.0.0/16"
      ];
      description = "If not empty, only these client addresses or CIDR ranges are answered (others get 403).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8640;
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File with the access token (BACKLOG_TOKEN=…), kept out of the Nix store.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.services.kanban-ai = {
      description = "kanban-ai backlog server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        User = cfg.user;
        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/backlog-server"
          "--dir"
          cfg.backlog
          "--host"
          (lib.concatStringsSep "," cfg.host)
          "--port"
          (toString cfg.port)
          "--quiet"
        ]
        + lib.optionalString (cfg.allow != [ ]) " --allow ${lib.escapeShellArg (lib.concatStringsSep "," cfg.allow)}";
        EnvironmentFile = lib.mkIf (cfg.tokenFile != null) cfg.tokenFile;
        Restart = "on-failure";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
