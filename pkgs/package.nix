{
  lib,
  python3Packages,
  fetchFromGitHub,
  nix-update-script,
  withTray ? false,
  wrapGAppsHook3,
  gobject-introspection,
  gtk3,
  libayatana-appindicator,
  wl-clipboard,
  xclip,
  xsel,
  xdg-utils,
}:

python3Packages.buildPythonPackage rec {
  pname = "tg-ws-proxy";
  name = if withTray then "tg-ws-proxy-tray-${version}" else "tg-ws-proxy-${version}";
  version = "1.11.4";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Flowseal";
    repo = "tg-ws-proxy";
    rev = "v${version}";
    hash = "sha256-N7k8D2tnO4iVFq5lXjhdKpYMR+gDsCkKZLTpACpJStY=";
  };

  build-system = [ python3Packages.hatchling ];

  dependencies =
    with python3Packages;
    [
      certifi
      cryptography
      httpx
      h2
    ]
    ++ lib.optionals withTray [
      customtkinter
      pystray
      pillow
      pyperclip
      psutil
      pygobject3
      tkinter
    ];

  pythonRemoveDeps = lib.optionals (!withTray) [
    "customtkinter"
    "pillow"
    "psutil"
    "pyperclip"
    "pystray"
  ];

  pythonRelaxDeps = [
    "cryptography"
    "httpx"
    "certifi"
  ]
  ++ lib.optionals withTray [
    "pillow"
    "psutil"
    "pyperclip"
  ];

  nativeBuildInputs = lib.optionals withTray [
    wrapGAppsHook3
    gobject-introspection
  ];

  buildInputs = lib.optionals withTray [
    gtk3
    libayatana-appindicator
  ];

  makeWrapperArgs = lib.optionals withTray [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      wl-clipboard
      xclip
      xsel
      xdg-utils
    ])
  ];

  postInstall =
    if withTray then
      ''
        rm -f $out/bin/tg-ws-proxy $out/bin/tg-ws-proxy-tray-win $out/bin/tg-ws-proxy-tray-macos
        ln -s tg-ws-proxy-tray-linux $out/bin/tg-ws-proxy-tray
      ''
    else
      ''
        rm -f $out/bin/tg-ws-proxy-tray-*
      '';

  # Трей из Nix не должен пытаться подменять файлы в store.
  postPatch = lib.optionalString withTray ''
    substituteInPlace utils/default_config.py \
      --replace-fail '"check_updates": True' '"check_updates": False'
  '';

  doCheck = false;
  pythonImportsCheck = [ "proxy" ];

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Telegram MTProto WebSocket bridge proxy";
    homepage = "https://github.com/Flowseal/tg-ws-proxy";
    license = lib.licenses.mit;
    mainProgram = if withTray then "tg-ws-proxy-tray" else "tg-ws-proxy";
    platforms = lib.platforms.linux;
  };
}
