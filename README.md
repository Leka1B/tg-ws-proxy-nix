# tg-ws-proxy-nix

Nix-flake, упаковывающий [`Flowseal/tg-ws-proxy`](https://github.com/Flowseal/tg-ws-proxy) в два пакета и модуль NixOS.

- `tg-ws-proxy` - headless-CLI, рекомендуемый способ запуска.
- `tg-ws-proxy-tray` - тот же прокси с треем и GUI (GTK3/AppIndicator).
- `services.tg-ws-proxy` - системный сервис NixOS поверх headless-CLI.

Платформа: только `x86_64-linux` (aarch64 не собирается и не тестируется).

## Быстрый запуск

```bash
nix run github:Leka1B/tg-ws-proxy-nix -- --help
nix build github:Leka1B/tg-ws-proxy-nix#tg-ws-proxy
```

Атрибуты пакетов - `tg-ws-proxy` и `tg-ws-proxy-tray`; `default` - headless-пакет.


## Применение в Telegram

1. Откройте ссылку `tg://proxy?...` из журнала.
2. Telegram: Настройки → Данные и хранилище → Прокси.


## Модуль NixOS

```nix
# flake.nix
inputs.tg-ws-proxy = {
  url = "github:Leka1B/tg-ws-proxy-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
# configuration.nix
imports = [ inputs.tg-ws-proxy.nixosModules.default ];

services.tg-ws-proxy.enable = true;
```

Включение без опций запускает ту же программу, но с постоянным секретом: голая CLI генерирует новый при каждом старте, а сервис хранит его в state-каталоге.

Сервис - systemd-юнит **system** (не композиторный автозапуск): даёт перезапуск при падении, journald и песочницу. Секрет и ссылка `tg://` печатаются в журнал при старте:

```bash
journalctl -u tg-ws-proxy | grep 'tg://'
```

## Трей

На данный момент модуль Home Manager отсутствует - трей запускается командой.

## Опции

| Опция | Тип | По умолчанию | Флаг |
|---|---|---|---|
| `enable` | bool | `false` | - |
| `package` | package | `pkgs.callPackage "${self}/pkgs/package.nix" {}` | - |
| `host` | str | `"127.0.0.1"` | `--host` |
| `port` | port | `1443` | `--port` |
| `secret` | nullOr str | `null` | `--secret` |
| `secretFile` | nullOr path | `null` | `--secret` |
| `dcIps` | nullOr (listOf str) | `null` | `--dc-ip` |
| `fakeTlsDomain` | nullOr str | `null` | `--fake-tls-domain` |
| `cfproxyDomains` | listOf str | `[]` | `--cfproxy-domain` |
| `cfproxyWorkerDomains` | listOf str | `[]` | `--cfproxy-worker-domain` |
| `noCfproxy` | bool | `false` | `--no-cfproxy` |
| `noH2` | bool | `false` | `--no-h2` |
| `noSecure` | bool | `false` | `--no-secure` |
| `forceTestDc` | bool | `false` | `--force-test-dc` |
| `proxyProtocol` | bool | `false` | `--proxy-protocol` |
| `bufferKb` | positive int | `256` | `--buf-kb` |
| `poolSize` | unsigned int | `4` | `--pool-size` |
| `verbose` | bool | `false` | `-v` |
| `logToFile` | bool | `false` | `--log-file /var/log/tg-ws-proxy/proxy.log` |
| `logMaxMb` | non-negative number | `5` | `--log-max-mb` |
| `logBackups` | int >= 1 | `1` | `--log-backups` |
| `extraArgs` | listOf str | `[]` | дописывается последним, дословно |

`extraArgs` - escape hatch, дописывается после всех сгенерированных флагов. `dcIps = null` оставляет список DC из upstream, `[]` очищает его, список задаёт по одному значению на элемент.

Upstream молча поднимает `bufferKb` меньше 4 до 4 KiB, а `logMaxMb` меньше 0.03125 до 32 KiB.

## Секреты

Сервис сам генерирует секрет при первом старте и пишет в state-каталог `DynamicUser` с режимом `0600`:

```
/var/lib/private/tg-ws-proxy/secret
```

Файл лога `/var/log/tg-ws-proxy/proxy.log` тоже содержит секрет и создаётся с umask `0077` (`0600`), включая ротации.

`secretFile` указывает на файл, расшифрованный sops/agenix (32 hex-символа, проверяется перед стартом). Файл читает менеджер systemd и копирует его сервису как credential, поэтому подходят умолчания sops-nix/agenix (`root:root`, `0400`). Путь в Nix store отклоняется assertion'ом: store читается всеми.
Inline `secret` работает, но кладёт значение в Nix store - не рекомендуется.

Секрет виден в командной строке, однако `ProtectProc = "invisible"` вместе с `ProcSubset = "pid"` скрывают `/proc/<pid>/cmdline` от других пользователей. Стартовый баннер печатает ссылку `tg://` вместе с секретом в journald.

## Диагностика

- **Не грузятся фото и видео.** Telegram берёт медиа с других DC, помимо проксируемого. Сузьте или очистите `dcIps` (например, `dcIps = []`) и добавьте нужные DC.
- **Нет иконки в трее.** `pystray` использует StatusNotifier/AppIndicator; без StatusNotifier host прокси работает, но иконка невидима. Настройте модуль `tray` в Waybar.
- **Трей не стартует под Hyprland.** При `programs.hyprland.withUWSM = false` `graphical-session.target` может не активироваться. Запускайте трей через `hl.on("hyprland.start", …)` в `hyprland.lua`; если ещё используется `hyprland.conf` - строкой `exec-once`.
- **Порт занят.** Headless-сервис и трей оба слушают `127.0.0.1:1443`; запускайте один или смените `port`.
- **Секрет в журнале.** Так и задумано: баннер печатает ссылку для копирования. Журнал - механизм доставки ссылки, а не утечка в `ps`.

## Разработка

```bash
nix build .#tg-ws-proxy .#tg-ws-proxy-tray
nix flake check
nix fmt -- flake.nix pkgs/package.nix modules/nixos.nix tests/module-eval.nix
nix run . -- --help
```

После `git init` добавьте файлы через `git add` до первой сборки: Nix видит в git-репозитории только отслеживаемые файлы.

`nix flake check` собирает оба варианта пакета и проверку module-eval (каждая опция → свой флаг) на `x86_64-linux`. VM-теста NixOS в v1 нет.

## Лицензия и атрибуция

MIT. Upstream `Flowseal/tg-ws-proxy` под MIT; см. [`LICENSE`](LICENSE) и [репозиторий upstream](https://github.com/Flowseal/tg-ws-proxy).
