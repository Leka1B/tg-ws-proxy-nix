{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tg-ws-proxy;

  # Секрет генерируется в StateDirectory либо задаётся inline (не рекомендуется). Читается из systemd-credential
  secretRef =
    if cfg.secretFile != null then
      "\"$CREDENTIALS_DIRECTORY/secret\""
    else
      "\"$STATE_DIRECTORY/secret\"";

  secretArg = if cfg.secret != null then lib.escapeShellArg cfg.secret else "\"$(< ${secretRef})\"";

  # У dcIps три состояния:
  #   null -> значения по умолчанию из upstream (флага нет)
  #   []   -> голый --dc-ip (очистить список)
  #   список -> по одному --dc-ip на элемент
  args = [
    "--host"
    cfg.host
    "--port"
    (toString cfg.port)
  ]
  ++ (
    if cfg.dcIps == null then
      [ ]
    else if cfg.dcIps == [ ] then
      [ "--dc-ip" ]
    else
      lib.concatMap (dc: [
        "--dc-ip"
        dc
      ]) cfg.dcIps
  )
  ++ lib.optionals (cfg.fakeTlsDomain != null) [
    "--fake-tls-domain"
    cfg.fakeTlsDomain
  ]
  ++ lib.concatMap (d: [
    "--cfproxy-domain"
    d
  ]) cfg.cfproxyDomains
  ++ lib.concatMap (d: [
    "--cfproxy-worker-domain"
    d
  ]) cfg.cfproxyWorkerDomains
  ++ lib.optionals cfg.noCfproxy [ "--no-cfproxy" ]
  ++ lib.optionals cfg.noH2 [ "--no-h2" ]
  ++ lib.optionals cfg.noSecure [ "--no-secure" ]
  ++ lib.optionals cfg.forceTestDc [ "--force-test-dc" ]
  ++ lib.optionals cfg.proxyProtocol [ "--proxy-protocol" ]
  ++ [
    "--buf-kb"
    (toString cfg.bufferKb)
    "--pool-size"
    (toString cfg.poolSize)
  ]
  ++ lib.optionals cfg.logToFile [
    "--log-file"
    "/var/log/tg-ws-proxy/proxy.log"
  ]
  ++ [
    "--log-max-mb"
    (toString cfg.logMaxMb)
    "--log-backups"
    (toString cfg.logBackups)
  ]
  ++ lib.optionals cfg.verbose [ "-v" ];
in
{
  options.services.tg-ws-proxy = {
    enable = lib.mkEnableOption "tg-ws-proxy Telegram MTProto WebSocket bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage "${self}/pkgs/package.nix" { };
      defaultText = lib.literalExpression "pkgs.callPackage \"${self}/pkgs/package.nix\" { }";
      description = "The tg-ws-proxy package to use.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to listen on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1443;
      description = "Port to listen on.";
    };

    secret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Inline 32-hex-char secret. Stored world-readably in the Nix store and
        visible in the systemd unit; prefer {option}`secretFile`.
      '';
    };

    secretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File with the 32-hex-char secret (e.g. from sops-nix/agenix). The
        service manager copies it into a systemd credential (`LoadCredential`),
        so a `root:root 0400` file works. Nix store paths are rejected: the
        store is world-readable.
      '';
    };

    dcIps = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        `DC:IP` entries. `null` keeps upstream defaults, `[]` passes a bare
        `--dc-ip` to clear the list.
      '';
    };

    fakeTlsDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fake TLS domain.";
    };

    cfproxyDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Cloudflare proxy domains.";
    };

    cfproxyWorkerDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Cloudflare worker proxy domains.";
    };

    noCfproxy = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable Cloudflare proxy.";
    };

    noH2 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable HTTP/2.";
    };

    noSecure = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable secure mode.";
    };

    forceTestDc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Force the test DC.";
    };

    proxyProtocol = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable PROXY protocol.";
    };

    bufferKb = lib.mkOption {
      # upstream делает max(4, args.buf_kb): меньше 4 молча поднимается.
      type = lib.types.ints.positive;
      default = 256;
      description = "Buffer size in KiB (upstream raises values below 4 to 4).";
    };

    poolSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 4;
      description = "WebSocket pool size.";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose logging.";
    };

    logToFile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Also log to `/var/log/tg-ws-proxy/proxy.log`.";
    };

    logMaxMb = lib.mkOption {
      # CLI принимает обычное число; types.float отклонил бы целое 5.
      type = lib.types.numbers.nonnegative;
      default = 5;
      description = "Maximum log size in MiB (upstream raises values below 0.03125 to 32 KiB).";
    };

    logBackups = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of rotated log files to keep.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra command-line arguments, appended last.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.secret != null && cfg.secretFile != null);
        message = "services.tg-ws-proxy: set at most one of secret and secretFile.";
      }
      {
        assertion = cfg.secret == null || builtins.match "[0-9a-fA-F]{32}" cfg.secret != null;
        message = "services.tg-ws-proxy: secret must be exactly 32 hex characters.";
      }
      {
        assertion = cfg.port >= 1024;
        message = "services.tg-ws-proxy: port must be >= 1024 (the service has no capabilities).";
      }
      {
        assertion =
          cfg.secretFile == null || !(lib.hasPrefix "${builtins.storeDir}/" (toString cfg.secretFile));
        message = "services.tg-ws-proxy: secretFile must not be a Nix store path.";
      }
    ];

    warnings =
      lib.optional (cfg.secret != null)
        "services.tg-ws-proxy: secret is stored in the Nix store and the systemd unit; prefer secretFile.";

    systemd.services.tg-ws-proxy = {
      description = "Telegram MTProto WebSocket bridge proxy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      documentation = [ "https://github.com/Flowseal/tg-ws-proxy" ];

      preStart =
        lib.optionalString (cfg.secretFile == null && cfg.secret == null) ''
          if [ ! -s "$STATE_DIRECTORY/secret" ]; then
            umask 077
            ${pkgs.coreutils}/bin/od -An -N16 -tx1 /dev/urandom \
              | ${pkgs.coreutils}/bin/tr -d ' \n' > "$STATE_DIRECTORY/secret"
          fi
        ''
        + lib.optionalString (cfg.secret == null) ''
          # Битый файл sops/agenix даёт понятную ошибку юнита, а не traceback
          # из upstream. secretRef - shell-экранированный токен;
          # $CREDENTIALS_DIRECTORY и $STATE_DIRECTORY раскрываются при запуске.
          ${pkgs.gnugrep}/bin/grep -Eq '^[0-9a-fA-F]{32}$' ${secretRef} \
            || { echo "tg-ws-proxy: secret is not 32 hex chars" >&2; exit 1; }
        '';

      script = ''
        exec ${lib.getExe cfg.package} --secret ${secretArg} ${lib.escapeShellArgs (args ++ cfg.extraArgs)}
      '';

      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "tg-ws-proxy";
        StateDirectoryMode = "0700";
        # Лог содержит секрет: 0600 и для активного файла, и для ротаций.
        UMask = "0077";
        # sops-nix/agenix отдают root:root 0400; копию для сервиса делает
        # менеджер systemd.
        LoadCredential = lib.mkIf (cfg.secretFile != null) "secret:${toString cfg.secretFile}";
        # Нужен, чтобы --log-file работал при ProtectSystem = "strict".
        LogsDirectory = lib.mkIf cfg.logToFile "tg-ws-proxy";
        Restart = "on-failure";
        RestartSec = 5;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        CapabilityBoundingSet = [ ];
        AmbientCapabilities = [ ];
      };
    };
  };
}
