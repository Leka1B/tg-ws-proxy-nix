{ self, pkgs }:
let
  inherit (pkgs) lib;

  eval =
    settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        self.nixosModules.default
        {
          # Гасим собственные assertion nixpkgs
          fileSystems."/" = {
            device = "/dev/null";
            fsType = "tmpfs";
          };
          boot.loader.grub.devices = [ "/dev/null" ];
          system.stateVersion = lib.trivial.release;
          services.tg-ws-proxy = {
            enable = true;
          }
          // settings;
        }
      ];
    }).config;

  serviceOf = settings: (eval settings).systemd.services.tg-ws-proxy;
  scriptOf = settings: (serviceOf settings).script;

  failing = settings: lib.filter (a: !a.assertion) (eval settings).assertions;
  failsWith = settings: text: lib.any (a: lib.hasInfix text a.message) (failing settings);

  has = lib.hasInfix;
  fail = msg: throw "tg-ws-proxy module: ${msg}";

  # Каждая опция выставлена не по умолчанию, поэтому каждый флаг обязан попасть в команду.
  all = {
    host = "127.0.0.1";
    port = 1443;
    secret = "0123456789abcdef0123456789abcdef";
    dcIps = [ "2:149.154.167.220" ];
    fakeTlsDomain = "example.com";
    cfproxyDomains = [ "example.com" ];
    cfproxyWorkerDomains = [ "worker.example.com" ];
    noCfproxy = true;
    noH2 = true;
    noSecure = true;
    forceTestDc = true;
    proxyProtocol = true;
    bufferKb = 128;
    poolSize = 2;
    verbose = true;
    logToFile = true;
    logMaxMb = 2;
    logBackups = 2;
    extraArgs = [ ];
  };

  allScript = scriptOf all;
  defaultScript = scriptOf { };

  expectedFlags = [
    "--host"
    "--port"
    "--secret"
    "--dc-ip"
    "--fake-tls-domain"
    "--cfproxy-domain"
    "--cfproxy-worker-domain"
    "--no-cfproxy"
    "--no-h2"
    "--no-secure"
    "--force-test-dc"
    "--proxy-protocol"
    "--buf-kb"
    "--pool-size"
    "-v"
    "--log-file"
    "--log-max-mb"
    "--log-backups"
  ];

  emptyDcScript = scriptOf { dcIps = [ ]; };

  checks = [
    {
      ok = lib.all (flag: has flag allScript) expectedFlags;
      msg = "flags not emitted: ${toString (lib.filter (flag: !(has flag allScript)) expectedFlags)}";
    }
    # dcIps = [ "2:…" ] -> по значению на элемент
    {
      ok = has "--dc-ip 2:149.154.167.220" allScript;
      msg = "--dc-ip entry not emitted";
    }
    # dcIps = [] -> голый --dc-ip, очищающий список, без значения после него
    {
      ok = has "--dc-ip --buf-kb" emptyDcScript;
      msg = "dcIps = [] must emit a bare --dc-ip";
    }
    # dcIps = null -> флага нет вовсе
    {
      ok = !(has "--dc-ip" defaultScript);
      msg = "dcIps = null must not emit --dc-ip";
    }
    # Опциональные по умолчанию выключены
    {
      ok =
        !(has "--log-file" defaultScript) && !(has "-v" defaultScript) && !(has "--no-h2" defaultScript);
      msg = "defaults must not emit --log-file, -v or --no-h2";
    }
    # Числовые флаги эмитятся всегда
    {
      ok = has "--buf-kb 256" defaultScript && has "--pool-size 4" defaultScript;
      msg = "numeric flags must always be emitted";
    }
    # secretFile: менеджер systemd копирует файл в credential, напрямую не читаем
    {
      ok =
        let
          s = serviceOf { secretFile = "/run/secrets/tg"; };
        in
        s.serviceConfig.LoadCredential == "secret:/run/secrets/tg"
        && has "$CREDENTIALS_DIRECTORY/secret" s.script
        && !(has "/run/secrets/tg" s.script)
        && !(has "/dev/urandom" s.preStart);
      msg = "secretFile must be passed as a systemd credential";
    }
    # Путь в store читается всеми, поэтому assertion его отклоняет
    {
      ok = failsWith {
        secretFile = pkgs.writeText "secret" "0123456789abcdef0123456789abcdef";
      } "must not be a Nix store path";
      msg = "a store path for secretFile must fail the assertion";
    }
    # --log-file живёт в LogsDirectory, иначе ProtectSystem = "strict" его не пустит
    {
      ok =
        (serviceOf { logToFile = true; }).serviceConfig.LogsDirectory == "tg-ws-proxy"
        && !(serviceOf { }).serviceConfig ? LogsDirectory;
      msg = "LogsDirectory must follow logToFile";
    }
    # В логе лежит секрет: всё, что создаёт сервис, должно быть 0600
    {
      ok = (serviceOf { }).serviceConfig.UMask == "0077";
      msg = "UMask 0077 must protect the log";
    }
    # Assertion'ы: дефолтный конфиг проходит, каждый битый выдаёт своё сообщение
    {
      ok = failing { } == [ ];
      msg = "default config must not fail assertions";
    }
    {
      ok = failsWith {
        secret = "0123456789abcdef0123456789abcdef";
        secretFile = "/run/secrets/tg";
      } "at most one of secret and secretFile";
      msg = "secret + secretFile must fail the exclusivity assertion";
    }
    {
      ok = failsWith { secret = "short"; } "32 hex";
      msg = "a short secret must fail the 32-hex assertion";
    }
    {
      ok = failsWith { port = 80; } ">= 1024";
      msg = "port < 1024 must fail the port assertion";
    }
  ];

  broken = map (c: c.msg) (lib.filter (c: !c.ok) checks);

  secretPreStart = (serviceOf { logToFile = true; }).preStart;

  secretTest = ''
    export STATE_DIRECTORY=$TMPDIR/state
    mkdir -p "$STATE_DIRECTORY"
    ( ${secretPreStart} )
    secretFile="$STATE_DIRECTORY/secret"
    test "$(stat -c %a "$secretFile")" = 600
    test "$(wc -c < "$secretFile")" = 32
    cp "$secretFile" "$TMPDIR/secret.first"
    ( ${secretPreStart} )
    test "$(cat "$TMPDIR/secret.first")" = "$(cat "$secretFile")"
    printf 'x%.0s' {1..31} > "$secretFile"
    if ( ${secretPreStart} ); then
      echo "31-char secret must fail preStart" >&2
      exit 1
    fi
  '';
in
if broken != [ ] then
  fail (lib.concatStringsSep "; " broken)
else
  pkgs.runCommand "tg-ws-proxy-module-eval" { } ''
    ${secretTest}
    touch $out
  ''
