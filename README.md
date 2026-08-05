# Dotfiles híbridos para Pop!_OS y Ubuntu

Este repositorio aprovisiona una estación de trabajo Pop!_OS o Ubuntu con una estrategia en dos capas:

- Ansible gestiona tanto la capa base del sistema operativo (repositorios APT, paquetes del sistema, Docker, Flatpak guiado por facts, integración con el gestor de archivos) como el entorno de usuario (Zsh, Oh My Zsh, herramientas de desarrollo, variables de entorno y el timer de limpieza periódica).
- Nix se mantiene instalado únicamente para `nix shell` / `nix develop` y la integración con `direnv`; ya no gestiona paquetes de usuario ni dotfiles (ver «Migración desde Home Manager» más abajo).
- El DevContainer permite validar, lintar y evolucionar la configuración sin contaminar el host.

## Estructura

```text
dotfiles/
├── .devcontainer/
│   ├── devcontainer.json
│   └── Dockerfile
├── .ansible-lint
├── ansible.cfg
├── ansible/
│   ├── group_vars/
│   │   └── all/
│   │       └── main.yml
│   ├── inventories/
│   │   └── local/
│   │       └── hosts.yml
│   ├── local.yml
│   └── roles/
│       ├── common/
│       ├── system/
│       ├── apt_repositories/
│       ├── desktop_apps/
│       ├── virt_manager/
│       ├── flatpak/
│       ├── docker/
│       ├── file_manager/
│       ├── nix/
│       ├── dev_tools/
│       └── shell_config/
├── nix/
│   └── flake.nix
├── bootstrap.sh
└── README.md
```

## Flujo recomendado

1. En el host Pop!_OS o Ubuntu real, ejecuta `./bootstrap.sh`.
2. El script instala `git`, `curl` y `ansible` solo si faltan, clona el repositorio en `~/my-workstation` desde `https://github.com/techlogycs/my-workstation.git` por defecto si hace falta y lanza el playbook local.
3. El playbook configura APT y, según los flags de `ansible/group_vars/all/main.yml`, instala VS Code, Brave, Docker, virt-manager con libvirt, RustDesk nativo, Warp Terminal, Flatpak en Ubuntu y Pop!_OS, integración con el gestor de archivos y el binario de Nix (solo para `nix shell`/`nix develop`).
4. El rol `dev_tools` instala bun, uv, dust y Node.js (vía NodeSource); el rol `rustup` provee el toolchain de Rust necesario para compilar dust.
5. Finalmente, el rol `shell_config` instala Oh My Zsh, plantea `~/.zshrc` (aliases, integración con Nix/direnv, autosuggestions/syntax-highlighting) y activa el timer `workstation-auto-clean`. `npm`/`npx` vienen del paquete `nodejs` de NodeSource, sin alias ni wrapper hacia Bun.

## Roles y tags

El playbook usa roles pequeños y etiquetados para que puedas ejecutar solo una parte del aprovisionamiento:

- `common`: validación del host y facts compartidos.
- `system`: paquetes base, herramientas de escritorio y shell por defecto.
- `apt_repositories`: repositorios y llaves APT de proveedores.
- `desktop_apps`: instalación de VS Code, Brave y RustDesk nativo.
- `virt_manager`: stack de virtualización local con libvirt y virt-manager.
- `flatpak`: Flathub y aplicaciones Flatpak por distro.
- `docker`: configuración de `daemon.json` y servicio.
- `file_manager`: integración “Open in Code”.
- `nix`: instalación del binario de Nix (solo para `nix shell`/`nix develop`, sin Home Manager).
- `dev_tools`: instala bun, uv, dust (vía cargo) y Node.js (vía NodeSource).
- `shell_config`: Oh My Zsh, plantilla de `~/.zshrc` y timer `workstation-auto-clean`.
- `apt-clean`: elimina definiciones legacy de repositorios APT gestionados por el repo, purga paquetes huérfanos y limpia la caché local de APT.
- `nix-clean`: garbage collection genérico del store de Nix (`make nix-clean`).
- `nix-migrate-single-user`: desinstala una instalación multiusuario existente de Nix y reprovisiona Nix en modo `single-user`.
- `nix-teardown`: desinstala una activación previa de Home Manager en hosts que migraron desde la versión anterior de este repo (ver «Migración desde Home Manager»).
- `migrate`: encadena `nix-teardown` con la limpieza de artefactos huérfanos de migraciones internas de este repo (el antiguo `CARGO_HOME` personalizado en `~/.local/share/cargo`, los wrappers de Bun para `npm`/`npx`/`yarn`/`pnpm`); idempotente, seguro de correr aunque no aplique nada.

Ejemplos:

```bash
ansible-playbook ansible/local.yml --tags docker
ansible-playbook ansible/local.yml --tags virt-manager
ansible-playbook ansible/local.yml --tags nix,file-manager
ansible-playbook ansible/apt-clean.yml
ansible-playbook ansible/nix-clean.yml
ansible-playbook ansible/nix-migrate-single-user.yml
ansible-playbook ansible/nix-teardown.yml
ansible-playbook ansible/migrate.yml
make install-feature features=thunderbird
make apt-clean
make nix-clean
make nix-migrate-single-user
make nix-teardown
make migrate
./bootstrap.sh --only-feature thunderbird
./bootstrap.sh --tags system
```

## DevContainer

El contenedor existe únicamente para desarrollo y validación de la configuración. Incluye:

- `ansible-lint` y `yamllint` para Ansible/YAML.
- `nix`, `statix` y `nixpkgs-fmt` para evaluar, lintar y formatear la configuración Nix (el `flake.nix` restante solo expone un `devShell` y checks de lint, ya sin Home Manager).
- Extensiones de VS Code orientadas a Ansible, Nix y TOML.

La imagen del DevContainer instala directamente `ansible-core`, `ansible-lint`, `yamllint` y Nix. Después, `postCreateCommand` solo añade `statix` y `nixpkgs-fmt` al perfil del usuario y ejecuta `nix flake check --impure` sobre `nix/`.

Si ya tenías el DevContainer creado antes de estos cambios, reconstruye el contenedor para que las herramientas nuevas queden disponibles en `PATH`.

## Validación manual

Dentro del DevContainer o en una máquina con las dependencias instaladas:

```bash
make lint
make format

ansible-playbook --syntax-check ansible/local.yml
ansible-lint ansible
yamllint .
DOTFILES_USER="$USER" DOTFILES_HOME="$HOME" NIX_SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)" nix --extra-experimental-features "nix-command flakes" flake check --impure ./nix
```

El `Makefile` expone también objetivos separados:

- `make lint-ansible`
- `make lint-nix`
- `make format-ansible`
- `make format-nix`
- `make install-feature features=thunderbird`
- `make apt-clean`
- `make nix-migrate-single-user`
- `make nix-clean`

## Configuración

Los componentes opcionales están controlados desde `ansible/group_vars/all/main.yml`:

- Todos los `feature_flags.*` aceptan `enabled`, `disabled` o `auto`. Los booleanos antiguos siguen funcionando porque se normalizan internamente a esos modos.
- `feature_flags.vscode`, `feature_flags.brave`, `feature_flags.docker`, `feature_flags.nix` y `feature_flags.git_credential_oauth` usan `enabled` por defecto. Hoy en día `auto` se resuelve igual que `enabled` para esos componentes, porque no hay una detección de alternativa equivalente.
- Si detecta `docker-desktop`, el playbook falla de forma explícita antes de instalar Docker Engine. Para reemplazarlo, debes aprobarlo con `docker_desktop_cleanup_approved: true`; ese flujo elimina el paquete `docker-desktop`, migra `~/.docker/config.json` quitando `credsStore` y `currentContext`, crea un backup `~/.docker/config.json.docker-desktop.bak` cuando hace cambios y borra `~/.docker/desktop`.
- `feature_flags.virt_manager` usa `disabled` por defecto; cuando lo activas instala libvirt, QEMU y virt-manager, arranca `libvirtd`, añade el usuario objetivo a los grupos `libvirt` y `kvm`, y fija `qemu:///system` como URI por defecto de libvirt para la sesión de usuario.
- `feature_flags.openvpn` usa `auto` por defecto; cuando detecta `network-manager` en el host instala el backend mínimo de OpenVPN que NetworkManager necesita para las conexiones VPN nativas. Si el host no usa NetworkManager, `auto` no arrastra ese stack por sorpresa; en ese caso solo `enabled` fuerza la instalación.
- `feature_flags.thunderbird` usa `disabled` por defecto; cuando lo activas, instala `org.mozilla.Thunderbird` vía Flatpak.
- `feature_flags.desktop_tools` usa `auto` por defecto y solo instala tooling específico de escritorio cuando detecta una base compatible.
- `feature_flags.clipboard_history` usa `auto` por defecto y convierte Ringboard (clipboard-history con GUI Iced) en el gestor de portapapeles preferido cuando no detecta otro ya instalado.
- `feature_flags.copyq` queda como vía legacy y usa `disabled` por defecto; solo conviene activarlo explícitamente si quieres seguir en CopyQ.
- `feature_flags.office_suite` usa `auto` por defecto y solo instala LibreOffice si no detecta otra suite ofimática ya instalada.
- `feature_flags.file_manager_integration` usa `auto` por defecto y solo habilita la integración si VS Code también está habilitado.
- `feature_flags.git_credential_oauth` migra la autenticación HTTP(S) de Git a Git Credential Manager, instalado desde un `.deb` upstream fijado por versión y checksum para Ubuntu y Pop!_OS.
- La configuración global de Git pasa a usar `credential.helper=/usr/local/bin/git-credential-manager` y `credential.credentialStore=secretservice`, de modo que los tokens quedan persistidos en el keyring del escritorio y sobreviven reinicios.
- Si el host tiene una sesión GNOME, Pop o COSMIC y habilitas VS Code o Git Credential Manager, el playbook instala `gnome-keyring` para que exista un proveedor Secret Service/libsecret y no aparezca el warning de keyring en VS Code.
- El playbook elimina `git-credential-oauth` y mantiene el repositorio estable de git-core en Ubuntu y Pop!_OS para instalar una versión upstream reciente de Git, compatible con Git Credential Manager.
- Los repositorios APT gestionados directamente por este repo para Microsoft, Docker y git-core usan keyrings dedicados bajo `/etc/apt/keyrings`, y el flujo `apt-clean` borra definiciones legacy conocidas para evitar entradas duplicadas o avisos por `trusted.gpg` en `apt`.
- `apt_base_packages` incluye `ripgrep` (antes también se instalaba por duplicado vía Home Manager; ahora `rg` viene solo de APT).
- `distro_flatpak_apps` define las aplicaciones de escritorio vía Flatpak por distro, excluyendo RustDesk porque se instala de forma nativa.
- `rustdesk_version` acepta `latest` (por defecto) o una versión fija; el paquete `.deb` se resuelve desde los metadatos de GitHub y se verifica su SHA-256 antes de instalar.
- `rustdesk_release_arch_map` traduce la arquitectura Debian detectada al sufijo usado por los artefactos oficiales de RustDesk.
- `supported_distributions`, `deb_arch_map` y `nix_system_map` convierten facts de Ansible en valores utilizables para APT y Nix en Ubuntu y Pop!_OS, incluyendo hosts ARM64.
- `clipboard_manager_package_candidates` define qué paquetes cuentan como gestor de portapapeles existente a efectos del modo `auto` de clipboard-history y CopyQ.
- `clipboard_history_branch` fija la rama del fork `axellpadilla/clipboard-history` desde la que se descargan los binarios precompilados y los ficheros de sistema (por defecto `patched`).
- `office_suite_package_candidates` define qué paquetes cuentan como suite ofimática existente a efectos del modo `auto` de LibreOffice.
- `gnome_desktop_package_candidates` define qué paquetes se consideran evidencia de una sesión GNOME; `gnome-tweaks` solo se añade cuando esa base existe.
- `gnome_secret_service_packages` define qué paquete aporta el backend Secret Service/libsecret para sesiones GNOME.
- `vscode_file_manager_integration` acepta `auto`, `nautilus`, `desktop-entry` o `disabled`.
- `virt_manager_packages` define los paquetes APT que componen el stack de virtualización local.
- `openvpn_core_packages` define la base mínima de OpenVPN.
- `openvpn_network_manager_packages` define el backend adicional que solo se instala cuando el modo `auto` detecta `network-manager` o cuando fuerzas `feature_flags.openvpn=enabled`.
- `virt_manager_default_uri` define la URI por defecto que usará virt-manager/libvirt en `~/.config/libvirt/libvirt.conf`.

Para instalar el perfil nativo de NetworkManager con los ajustes de split tunnel y split DNS validados en este host, usa:

```bash
sudo ./scripts/nm-openvpn-helper.sh install ~/Documents/farintervpn-final.nmconnection
./scripts/nm-openvpn-helper.sh up farintervpn-final
```

Para personalizar opciones sin tocar el baseline versionado:

- Copia `ansible/group_vars/all/override.example` a `ansible/group_vars/all/override.yml`.
- El archivo `override.yml` queda ignorado por Git y Ansible lo cargará automáticamente al ejecutar el playbook.

El modo `auto` se comporta así:

- Si `nautilus` aparece en los facts de paquetes, crea el script en `~/.local/share/nautilus/scripts/Open in Code`.
- Si `nautilus` no está instalado, crea `~/.local/share/applications/code-open-here.desktop` como alternativa genérica basada en desktop entry. Esto evita asumir GNOME en Pop!_OS, pero no garantiza un menú contextual nativo en gestores como COSMIC Files.

El modo `auto` de `clipboard_history` se comporta así:

- Si ya está instalado `ringboard-server`, `ringboard-iced`, `copyq` u otro gestor de portapapeles conocido como `gpaste`, `klipper`, `diodon`, `cliphist`, `clipman`, `xfce4-clipman` o un applet de portapapeles para COSMIC, no instala nada adicional.
- Si `clip-win` está instalado, lo desinstala automáticamente y migra a Ringboard.
- Si no detecta ningún gestor, ejecuta el script oficial `install-with-cargo-systemd.sh` del fork `axellpadilla/clipboard-history` con `RINGBOARD_CLIENT=iced`, que descarga los binarios precompilados, instala los servicios systemd de usuario y arranca el servidor junto con el watcher de sesión.
- En COSMIC además precrea la entrada de `Super+V` en el fichero de shortcuts y configura `COSMIC_DATA_CONTROL_ENABLED=1` para el soporte de portapapeles en Wayland; en GNOME/Pop!_OS intenta registrar el custom shortcut vía `gsettings` y libera tanto `toggle-message-tray` como `toggle-quick-settings` cuando hay una sesión DBus disponible.

El modo legacy de CopyQ se comporta así:

- Si ya está instalado `copyq` o algún gestor de portapapeles conocido como `gpaste`, `klipper`, `diodon`, `cliphist`, `clipman`, `xfce4-clipman` o un applet de portapapeles para COSMIC, no instala nada adicional.
- Si no detecta ninguno y `feature_flags.clipboard_history` está en `disabled`, añade `copyq` al conjunto de paquetes base.

En Pop!_OS 24.04 LTS con COSMIC, System76 no anuncia todavía un historial de portapapeles integrado por defecto en la release actual. Sí aparece como trabajo planificado en el roadmap oficial de COSMIC Epoch 2 bajo “COSMIC Clipboard Manager”, así que la detección `auto` contempla también nombres de paquetes plausibles del ecosistema COSMIC para evitar instalar CopyQ encima cuando esa pieza ya exista en el sistema.

El modo `auto` de LibreOffice se comporta así:

- Si ya está instalada una suite conocida como `libreoffice`, `onlyoffice-desktopeditors`, `calligra`, `abiword` o `gnumeric`, no instala nada adicional.
- Si no detecta ninguna, añade `libreoffice` al conjunto de paquetes base.

Las herramientas de escritorio GNOME se comportan así:

- `gnome-tweaks` solo se instala cuando el host ya tiene una pila GNOME detectada.
- Esto evita meter tooling específico de GNOME en equipos Pop!_OS que no estén usando GNOME/Nautilus como entorno principal.

## Decisiones técnicas

- Ubuntu y Pop!_OS usan Flatpak para la mayoría de aplicaciones de escritorio de terceros; la selección se resuelve a partir de facts de Ansible y se puede diferenciar por distro sin tocar los roles.
- La instalación de Flatpak comprueba primero qué remotos y aplicaciones existen antes de añadir o instalar nada, para mantener la ejecución repetible.
- RustDesk se instala desde el `.deb` oficial upstream y no vía Flatpak, porque el servicio nativo de systemd es el camino necesario para acceso pre-login y reinicios limpios del host.
- Docker usa `json-file` con rotación, modo `non-blocking` y buffer acotado para evitar crecimiento descontrolado de logs y reducir bloqueos por I/O, preservando otras claves ya presentes en `daemon.json` como `data-root`. Los `log-opts` se escriben como strings porque `dockerd` lo exige en `daemon.json`.
- Nix usa `nix_install_mode` para controlar cómo se instala en el host. El valor por defecto es `single-user`, que evita crear la batería de usuarios `nixbld*` en estaciones de trabajo donde no hace falta el daemon multiusuario. Si necesitas el modelo clásico con daemon y build users compartidos, cambia `nix_install_mode` a `multi-user`.
- En modo `multi-user`, el repositorio sigue usando Determinate Systems para simplificar una instalación consistente en Ubuntu/Pop!_OS.
- Desde que se retiró Home Manager, el rol `nix` solo instala el binario de Nix; no construye ni activa ningún perfil. `nix/flake.nix` únicamente expone `devShells` (nil, nixpkgs-fmt, statix) y los checks de lint — úsalo con `nix develop` para un shell de validación, no para gestionar paquetes de usuario.
- El rol `shell_config` reemplaza lo que antes hacía Home Manager: instala Oh My Zsh (instalador oficial, modo `--unattended`) y plantea `~/.zshrc` desde una plantilla Jinja2 (tema, plugins, autosuggestions/syntax-highlighting vía paquetes APT, alias, variables de sesión y el hook de `direnv`).
- `npm`/`npx` no tienen wrapper ni alias hacia Bun: vienen directos del paquete `nodejs` de NodeSource. Se probaron wrappers hacia Bun para `npm`/`npx`/`yarn`/`pnpm`, pero Bun migra `package-lock.json`/`pnpm-lock.yaml`/`yarn.lock` a su propio `bun.lock` de forma unidireccional y sin flag para desactivarlo — sorprendía en proyectos existentes, así que se quitaron.
- El rol `shell_config` también instala el timer de usuario `workstation-auto-clean` (plantillas `.service`/`.timer` en `~/.config/systemd/user/`), que limpia periódicamente `~/Downloads` y directorios de caché de herramientas (`~/.bun/install/cache`, `~/.cache/cargo-target`, `~/.cache/go-build`, `~/.cache/go/pkg/mod`), y ejecuta `uv cache prune`, `direnv prune` y `nix-collect-garbage --delete-older-than`.
- `direnv` ahora se instala como paquete APT (antes lo aportaba Home Manager); el hook de Zsh vive en la plantilla de `shell_config`.
- Si una máquina ya tiene Nix multiusuario y quieres eliminar los usuarios `nixbld*`, usa `ansible/nix-migrate-single-user.yml` o `make nix-migrate-single-user`. Ese flujo desinstala la instalación multiusuario existente con `/nix/nix-installer uninstall --no-confirm` cuando detecta Determinate, o aplica los pasos documentados por upstream para Linux con systemd cuando no hay receipt/uninstaller, y luego vuelve a aprovisionar Nix en modo `single-user`.
- `ansible/nix-clean.yml` / `make nix-clean` ahora solo ejecuta `nix-collect-garbage` genérico — la poda de generaciones de Home Manager se retiró porque ya no se crean generaciones nuevas.
- Warp Terminal se instala desde el repositorio APT oficial (`releases.warp.dev`), no desde Flatpak (no publican uno) ni desde Nix.

## Migración desde Home Manager

Si este host todavía tiene una activación de Home Manager de una versión anterior de este repo (perfil en `~/.local/state/nix/profiles/my-workstation-home-manager`, el timer `workstation-auto-clean` instalado por Nix, wrappers de `npm`/`npx`/`yarn`/`pnpm` enlazados al store, o un `~/.zshrc` simbólico hacia `/nix/store`), ejecuta la limpieza dedicada antes de volver a aplicar el playbook normal:

```bash
ansible-playbook ansible/nix-teardown.yml -K
# o
make nix-teardown
```

Esto: detiene y deshabilita el timer/servicio `workstation-auto-clean` heredado, elimina los wrappers de `~/.local/bin` que aún apunten al store, borra el perfil nombrado de Home Manager y las rutas legacy conocidas, restaura `.zshrc`/`.zshenv` desde su copia `.home-manager-backup` si Ansible la había creado, y finalmente ejecuta `nix-collect-garbage -d` para reclamar el espacio del store. Nix en sí **no** se desinstala — se mantiene para `nix shell`/`nix develop`. Después, vuelve a correr `make playbook` para que `dev_tools`, `desktop_apps` y `shell_config` aprovisionen lo que Home Manager gestionaba antes.

Si el host ya corrió una versión anterior de este mismo repo (no de Home Manager, sino de cambios internos posteriores: el antiguo `CARGO_HOME` personalizado en `~/.local/share/cargo`, o los wrappers de Bun para `npm`/`npx`/`yarn`/`pnpm` en `~/.local/bin`), usa en cambio `make migrate` (`ansible/migrate.yml`) — encadena el teardown de Home Manager con esas limpiezas adicionales, idempotente y seguro de correr sin importar cuáles apliquen.

## Ajustes que probablemente querrás personalizar

- `DOTFILES_REPO_URL` en `bootstrap.sh` si quieres clonar desde un fork o mirror distinto al repositorio oficial.
- El tema y los plugins de Oh My Zsh: `oh_my_zsh_theme` y `oh_my_zsh_plugins` en `ansible/group_vars/all/main.yml`.
- La política de limpieza en `ansible/roles/shell_config/templates/workstation-auto-clean.sh.j2` y sus variables (`workstation_cleanup_*_max_age_days`, `nix_cleanup_generation_max_age_days`) en `ansible/group_vars/all/main.yml`.
- `nodesource_major_version` en `ansible/group_vars/all/main.yml` si quieres cambiar la versión mayor de Node.js instalada.
- `nix_install_mode` en `ansible/group_vars/all/main.yml` si quieres elegir entre `single-user` y `multi-user`. Si una máquina ya tiene Nix multiusuario instalado, el playbook falla de forma explícita cuando pides `single-user` para que no te quedes con los usuarios `nixbld*` pensando que el modo cambió solo.
- `DOTFILES_EDITOR` si desactivas VS Code y quieres que `EDITOR` y `VISUAL` apunten a otro binario.
- `rustdesk_version` en `ansible/group_vars/all/main.yml` si quieres fijar una release específica de RustDesk en lugar de `latest`.
- `feature_flags.virt_manager`, `virt_manager_packages` y `virt_manager_default_uri` si quieres ajustar el stack de virtualización local.
- Los `feature_flags`, `distro_flatpak_apps` y el modo de integración del gestor de archivos en `ansible/group_vars/all/main.yml`.
- `feature_flags.openvpn`, `openvpn_core_packages` y `openvpn_network_manager_packages` si quieres ajustar cuándo se instala el backend de OpenVPN y evitar dependencias de NetworkManager cuando no hagan falta.

Para aprovisionar solo OpenVPN y sus paquetes relacionados:

```bash
ansible-playbook ansible/local.yml --tags openvpn
./bootstrap.sh --tags openvpn
```

Para instalar solo una feature opcional sin tocar `override.yml`, usa `dotfiles_only_features`.
El selector fuerza a `enabled` solo las features indicadas, desactiva el resto de features opcionales durante esa ejecución y evita incluir roles no relacionados. En una ejecución como `thunderbird`, el playbook ya no recorre `desktop_apps`, `docker`, `virt_manager`, `file_manager` ni `nix`, y tampoco instala el bundle por defecto de Flatpaks de escritorio.

Ejemplos:

```bash
ansible-playbook ansible/local.yml --extra-vars 'dotfiles_only_features=thunderbird' -K
make install-feature features=thunderbird
./bootstrap.sh --only-feature thunderbird
```

También acepta varias features separadas por comas:

```bash
make install-feature features=thunderbird,openvpn
./bootstrap.sh --only-feature thunderbird,openvpn
```

## Nota sobre RustDesk

RustDesk queda aprovisionado como paquete nativo y con el servicio `rustdesk` habilitado en systemd, así que tras volver a ejecutar el playbook no debería hacer falta reiniciar toda la máquina. Si el login manager sigue usando Wayland, el acceso a la pantalla de login puede seguir limitado porque upstream todavía depende de X11 para ese escenario.