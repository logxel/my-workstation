#!/usr/bin/env bash
# ============================================================================
# setup-ai.sh
# -----------
# Instala herramientas de IA opcionales (APM, OpenCode, gem-team, Claude CLI
# y Oh My Opencode Slim) desde un devcontainer fresh.
#
# Al ejecutarse sin argumentos muestra un selector interactivo: ↑/↓ para
# moverse, Espacio para marcar/desmarcar ([x]/[ ]) y Enter para confirmar,
# con OpenCode y gem-team preseleccionados. APM y OpenCode se auto-marcan
# si gem-team está seleccionado (requisito), y OpenCode también si se elige
# Oh My Opencode Slim. Para uso no interactivo (p. ej. en Dockerfiles o
# postCreateCommand) se pueden pasar flags:
#
#   --all        instala todas las herramientas
#   --apm        instala APM (Agent Package Manager)
#   --opencode   instala OpenCode
#   --gem-team   instala la extensión gem-team para OpenCode
#   --omos       instala el plugin Oh My Opencode Slim (orquestación de agentes)
#   --claude     instala Claude CLI
#   --help       muestra esta ayuda
#
# Flujo:
#   1. APM via installer oficial (curl -sSL https://aka.ms/apm-unix | sh)
#      → si falla por incompatibilidad de glibc, fallback a pipx
#   2. OpenCode via installer oficial (curl -fsSL https://opencode.ai/install | bash)
#   3. gem-team via apm install mubaidr/gem-team --target opencode
#   4. Claude CLI via installer oficial (curl -fsSL https://claude.ai/install.sh | bash)
#   5. Oh My Opencode Slim via bunx oh-my-opencode-slim@latest install
#      --preset=opencode-go --reset (interactivo; --reset reescribe la config)
#
# Maneja:
#   - Incompatibilidad de glibc (Debian 12 bookworm → glibc 2.36 vs 2.38 requerido)
#   - PEP 668 (entorno Python externamente gestionado, pip bloqueado)
#   - Idempotencia (seguro de re-ejecutar)
# ============================================================================
set -euo pipefail

# ── Colores ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1" >&2; }
fail() { echo -e "  ${RED}✖${NC} $1" >&2; }

# ── Selección de herramientas ──────────────────────────────────────────────
# 1 = instalar, 0 = omitir. Los flags de línea de comandos tienen prioridad
# sobre el prompt interactivo.
DO_APM=0
DO_OPENCODE=0
DO_GEM_TEAM=0
DO_CLAUDE=0
DO_OMOS=0
FLAGS_SET=0

usage() {
  cat <<EOF
Uso: $0 [opciones]

Sin flags, muestra un selector interactivo (↑/↓ + Espacio + Enter).
Por defecto (y en modo no interactivo): OpenCode + gem-team.

Opciones:
  --all        Instala todas las herramientas
  --apm        Instala APM (Agent Package Manager)
  --opencode   Instala OpenCode
  --gem-team   Instala la extensión gem-team para OpenCode
  --omos       Instala el plugin Oh My Opencode Slim (orquestación de agentes)
  --claude     Instala Claude CLI
  --help       Muestra esta ayuda
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --all)       DO_APM=1; DO_OPENCODE=1; DO_GEM_TEAM=1; DO_CLAUDE=1; DO_OMOS=1; FLAGS_SET=1 ;;
      --apm)       DO_APM=1; FLAGS_SET=1 ;;
      --opencode)  DO_OPENCODE=1; FLAGS_SET=1 ;;
      --gem-team)  DO_GEM_TEAM=1; FLAGS_SET=1 ;;
      --omos)      DO_OMOS=1; FLAGS_SET=1 ;;
      --claude)    DO_CLAUDE=1; FLAGS_SET=1 ;;
      --help|-h)   usage; exit 0 ;;
      *)
        fail "Argumento desconocido: $arg"
        usage
        return 1
        ;;
    esac
  done

  # Sin flags → defaults (OpenCode + gem-team)
  if [[ "$FLAGS_SET" -eq 0 ]]; then
    DO_OPENCODE=1
    DO_GEM_TEAM=1
  fi
}

choose_tools() {
  # Selección por defecto: OpenCode + gem-team
  DO_APM=0; DO_OPENCODE=1; DO_GEM_TEAM=1; DO_CLAUDE=0; DO_OMOS=0

  local -a names=(
    "APM (Agent Package Manager)"
    "OpenCode"
    "gem-team (para OpenCode)"
    "Claude CLI"
    "Oh My Opencode Slim (orquestación de agentes)"
  )
  local -i rows=11
  local -i cursor=1   # opción resaltada (arranca en OpenCode)
  local msg=""       # mensaje transitorio (dependencia bloqueada)

  render_menu() {
    local apm_auto=0 opencode_auto=0
    [[ "$DO_GEM_TEAM" -eq 1 ]] && apm_auto=1
    [[ "$DO_GEM_TEAM" -eq 1 || "$DO_OMOS" -eq 1 ]] && opencode_auto=1

    local -a marks=(" " " " " " " " " ")
    { [[ "$DO_APM" -eq 1 || "$apm_auto" -eq 1 ]] && marks[0]="x"; }
    { [[ "$DO_OPENCODE" -eq 1 || "$opencode_auto" -eq 1 ]] && marks[1]="x"; }
    { [[ "$DO_GEM_TEAM" -eq 1 ]] && marks[2]="x"; }
    { [[ "$DO_CLAUDE" -eq 1 ]] && marks[3]="x"; }
    { [[ "$DO_OMOS" -eq 1 ]] && marks[4]="x"; }

    local -a notes=("" "" "" "" "")
    { [[ "$apm_auto" -eq 1 && "$DO_APM" -eq 0 ]] && notes[0]=" (auto con gem-team)"; }
    if [[ "$opencode_auto" -eq 1 && "$DO_OPENCODE" -eq 0 ]]; then
      if [[ "$DO_GEM_TEAM" -eq 1 ]]; then
        notes[1]=" (auto con gem-team)"
      else
        notes[1]=" (auto con oh-my-slim)"
      fi
    fi

    local i
    printf '\e[2K  ¿Qué herramientas quieres instalar?\n'
    printf '\e[2K  ↑/↓ mover · Espacio marcar/desmarcar · Enter confirmar\n'
    printf '\e[2K\n'
    for i in 0 1 2 3 4; do
      if [[ "$i" -eq "$cursor" ]]; then
        printf '\e[2K  \e[7m> [%s] %s%s\e[0m\n' "${marks[$i]}" "${names[$i]}" "${notes[$i]}"
      else
        printf '\e[2K    [%s] %s%s\n' "${marks[$i]}" "${names[$i]}" "${notes[$i]}"
      fi
    done
    printf '\e[2K\n'
    printf '\e[2K  %s\n' "$msg"
    printf '\e[2K  Enter = confirmar selección\n'
  }

  redraw() {
    [[ "$first_render" -eq 0 ]] && printf '\e[%dA' "$rows"
    render_menu
    first_render=0
  }

  toggle_option() {
    local idx="$1"
    case "$idx" in
      0)
        if [[ "$DO_GEM_TEAM" -eq 1 ]]; then
          msg="APM es requerido por gem-team — desmarca gem-team para quitarlo"
        else
          DO_APM=$(( 1 - DO_APM )); msg=""
        fi
        ;;
      1)
        if [[ "$DO_GEM_TEAM" -eq 1 || "$DO_OMOS" -eq 1 ]]; then
          msg="OpenCode es requerido por gem-team u oh-my-slim — desmárcalos primero"
        else
          DO_OPENCODE=$(( 1 - DO_OPENCODE )); msg=""
        fi
        ;;
      2) DO_GEM_TEAM=$(( 1 - DO_GEM_TEAM )); msg="" ;;
      3) DO_CLAUDE=$(( 1 - DO_CLAUDE )); msg="" ;;
      4) DO_OMOS=$(( 1 - DO_OMOS )); msg="" ;;
    esac
  }

  local first_render=1
  redraw

  local key="" k2="" k3=""
  while true; do
    key=""
    IFS= read -r -s -n1 key || true
    case "$key" in
      "") break ;;                            # EOF
      $'\e')                                   # flechas: ESC [ A / ESC [ B
        k2=""; k3=""
        IFS= read -r -s -n1 -t 0.2 k2 || true
        [[ "$k2" == "[" ]] && IFS= read -r -s -n1 -t 0.2 k3 || true
        case "$k2$k3" in
          "[A") (( cursor > 0 )) && cursor=$(( cursor - 1 )) ;;
          "[B") (( cursor < 4 )) && cursor=$(( cursor + 1 )) ;;
        esac
        ;;
      $' ') toggle_option "$cursor" ;;        # Espacio: marcar/desmarcar
      '1') toggle_option 0 ;;
      '2') toggle_option 1 ;;
      '3') toggle_option 2 ;;
      '4') toggle_option 3 ;;
      '5') toggle_option 4 ;;
      $'\n'|$'\r') break ;;                   # Enter: confirmar
    esac
    redraw
  done

  echo ""
}

# gem-team necesita APM y OpenCode; Oh My Opencode Slim necesita OpenCode.
# APM solo se instala cuando se elige explícitamente o viene de gem-team.
resolve_dependencies() {
  if [[ "$DO_GEM_TEAM" -eq 1 ]]; then
    DO_APM=1
    DO_OPENCODE=1
  fi
  if [[ "$DO_OMOS" -eq 1 ]]; then
    DO_OPENCODE=1
  fi
}

print_selection() {
  local parts=()
  [[ "$DO_APM" -eq 1 ]] && parts+=("APM")
  [[ "$DO_OPENCODE" -eq 1 ]] && parts+=("OpenCode")
  [[ "$DO_GEM_TEAM" -eq 1 ]] && parts+=("gem-team")
  [[ "$DO_OMOS" -eq 1 ]] && parts+=("oh-my-slim")
  [[ "$DO_CLAUDE" -eq 1 ]] && parts+=("Claude CLI")
  echo "  Selección: ${parts[*]:-<ninguna>}"
}

# ── Preflight ──────────────────────────────────────────────────────────────
preflight() {
  for cmd in curl sudo; do
    if ! command -v "$cmd" &>/dev/null; then
      fail "Requerido: $cmd no está instalado"
      return 1
    fi
  done
}

# ── Asegurar directorios comunes en PATH ─────────────────────────────────────
# pipx → ~/.local/bin, opencode → ~/.opencode/bin, etc.
# Algunos entornos (devcontainer) no los traen por defecto en PATH.
ensure_common_bins_in_path() {
  local dirs
  dirs=(
    "$HOME/.local/bin"
    "$HOME/.opencode/bin"
  )
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]] && [[ ":$PATH:" != *":$dir:"* ]]; then
      export PATH="$dir:$PATH"
    fi
  done
}

# ── 1. APM ─────────────────────────────────────────────────────────────────
install_apm() {
  if command -v apm &>/dev/null; then
    ok "APM ya instalado ($(apm --version 2>&1))"
    return 0
  fi

  echo ""
  echo "  ── Instalando APM (Agent Package Manager) ──"

  # Intento 1 — installer oficial
  # Funciona en sistemas con glibc >= 2.38.
  if curl -sSL https://aka.ms/apm-unix | sh; then
    if command -v apm &>/dev/null; then
      ok "APM instalado via installer oficial"
      return 0
    fi
  fi

  # Intento 2 — pipx
  # Fallback para Debian 12 (bookworm) y distribuciones similares donde
  # el binario precompilado requiere glibc 2.38 pero el sistema tiene 2.36.
  warn "Installer oficial falló — usando pipx como fallback..."
  if ! command -v pipx &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends pipx
  fi

  pipx install apm-cli
  ensure_common_bins_in_path

  if command -v apm &>/dev/null; then
    ok "APM instalado via pipx ($(apm --version 2>&1))"
  else
    fail "No se pudo instalar APM."
    fail "Intenta manualmente: pipx install apm-cli"
    return 1
  fi
}

# ── 2. OpenCode ────────────────────────────────────────────────────────────
install_opencode() {
  # command -v falla si ~/.opencode/bin no está en PATH (el installer solo lo
  # escribe en los archivos de shell, no en la sesión actual): comprobar también
  # la ubicación conocida del binario.
  if command -v opencode &>/dev/null || [[ -x "$HOME/.opencode/bin/opencode" ]]; then
    ok "OpenCode ya instalado ($(opencode --version 2>&1))"
    return 0
  fi

  echo ""
  echo "  ── Instalando OpenCode ──"

  # CI=true suprime la barra de progreso del installer (usa \r)
  if CI=true curl -fsSL https://opencode.ai/install | bash; then
    # opencode se instala en ~/.opencode/bin/
    ensure_common_bins_in_path
    if command -v opencode &>/dev/null; then
      ok "OpenCode instalado ($(opencode --version 2>&1))"
    else
      fail "OpenCode instalado pero no encontrado en PATH."
      fail "Prueba reiniciar tu shell o agregar ~/.opencode/bin a PATH."
      return 1
    fi
  else
    fail "Error al instalar OpenCode."
    fail "Intenta manualmente: curl -fsSL https://opencode.ai/install | bash"
    return 1
  fi
}

# ── 3. gem-team ────────────────────────────────────────────────────────────
install_gem_team() {
  if ! command -v apm &>/dev/null; then
    fail "APM no está instalado — no se puede instalar gem-team."
    return 1
  fi

  echo ""
  echo "  ── Instalando extensión gem-team para OpenCode ──"
  echo "  Comando: apm install mubaidr/gem-team --target opencode"
  echo ""

  if apm install mubaidr/gem-team --target opencode; then
    ok "Extensión gem-team instalada correctamente"
  else
    # Puede fallar si ya está instalada o si opencode no es detectable
    warn "No se pudo instalar gem-team."
    warn "Verifica con: apm list --target opencode"
  fi
}

# ── 4. Claude CLI ──────────────────────────────────────────────────────────
install_claude() {
  if command -v claude &>/dev/null; then
    ok "Claude CLI ya instalado ($(claude --version 2>&1))"
    return 0
  fi

  echo ""
  echo "  ── Instalando Claude CLI ──"

  if curl -fsSL https://claude.ai/install.sh | bash; then
    if command -v claude &>/dev/null; then
      ok "Claude CLI instalado ($(claude --version 2>&1))"
    else
      fail "Claude CLI instalado pero no encontrado en PATH."
      fail "Prueba reiniciar tu shell o agregar ~/.local/bin a PATH."
      return 1
    fi
  else
    fail "Error al instalar Claude CLI."
    fail "Intenta manualmente: curl -fsSL https://claude.ai/install.sh | bash"
    return 1
  fi
}

# ── 5. Oh My Opencode Slim ──────────────────────────────────────────────────
install_omos() {
  # El plugin vive en ~/.config/opencode/plugin/ (best-effort para idempotencia)
  if compgen -G "$HOME/.config/opencode/plugin/*oh-my-opencode-slim*" &>/dev/null; then
    ok "Oh My Opencode Slim ya instalado"
    return 0
  fi

  if ! command -v bunx &>/dev/null && ! command -v bun &>/dev/null; then
    fail "bun no está instalado — no se puede instalar Oh My Opencode Slim."
    fail "Instala bun: curl -fsSL https://bun.sh/install | bash"
    return 1
  fi

  echo ""
  echo "  ── Instalando Oh My Opencode Slim (plugin de OpenCode) ──"
  echo "  Nota: el instalador es interactivo (configura proveedores)."
  echo ""

  if bunx oh-my-opencode-slim@latest install --preset=opencode-go --reset; then
    ok "Oh My Opencode Slim instalado (preset opencode-go activo)"
    echo ""
    echo "  Siguientes pasos:"
    echo "    - opencode auth login   (autenticar proveedores)"
    echo "    - dentro de OpenCode: ping all agents"
    echo ""
    echo "  --reset deja copia .bak de la config previa. Verifica el preset:"
    echo "    grep preset ~/.config/opencode/oh-my-opencode-slim.json"
  else
    warn "No se pudo completar la instalación de Oh My Opencode Slim."
    warn "Intenta manualmente: bunx oh-my-opencode-slim@latest install"
  fi
}

# ── Resumen final ──────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "  ────────────────────────────────────────────────"
  ok "Instalación completada"
  echo ""

  # Verificar estado final de cada herramienta seleccionada
  local all_ok=true

  if [[ "$DO_APM" -eq 1 ]]; then
    if command -v apm &>/dev/null; then
      ok "APM:        $(apm --version 2>&1)"
    else
      fail "APM:        NO INSTALADO"
      all_ok=false
    fi
  fi

  if [[ "$DO_OPENCODE" -eq 1 ]]; then
    if command -v opencode &>/dev/null || [[ -x "$HOME/.opencode/bin/opencode" ]]; then
      ok "OpenCode:   $(opencode --version 2>&1)"
    else
      fail "OpenCode:   NO INSTALADO"
      all_ok=false
    fi
  fi

  # gem-team: verificar via apm.yml (dónde apm escribe las dependencias)
  if [[ "$DO_GEM_TEAM" -eq 1 ]]; then
    if [[ -f "$PWD/apm.yml" ]] && grep -q 'mubaidr/gem-team' "$PWD/apm.yml" 2>/dev/null; then
      ok "gem-team:   Instalada en apm.yml"
    else
      warn "gem-team:   No detectada en apm.yml"
    fi
  fi

  if [[ "$DO_CLAUDE" -eq 1 ]]; then
    if command -v claude &>/dev/null; then
      ok "Claude CLI: $(claude --version 2>&1)"
    else
      fail "Claude CLI: NO INSTALADO"
      all_ok=false
    fi
  fi

  # oh-my-opencode-slim: verificar el directorio del plugin en la config de opencode
  if [[ "$DO_OMOS" -eq 1 ]]; then
    if compgen -G "$HOME/.config/opencode/plugin/*oh-my-opencode-slim*" &>/dev/null; then
      ok "oh-my-slim: Instalado en ~/.config/opencode/plugin"
    else
      warn "oh-my-slim: No detectado en ~/.config/opencode/plugin"
    fi
  fi

  echo ""
  if ! $all_ok; then
    warn "Algunas herramientas no se instalaron correctamente."
    warn "Revisa los mensajes de error arriba o ejecuta el script de nuevo."
  fi

  # Sugerir reinicio de shell
  echo ""
  warn "Si algún comando recién instalado no se encuentra en el PATH, prueba:"
  warn "  source ~/.zshrc  (o reinicia la terminal)"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
  parse_args "$@" || return 1

  echo ""
  echo "  ┌──────────────────────────────────────────────┐"
  echo "  │        Instalación de herramientas AI        │"
  echo "  └──────────────────────────────────────────────┘"

  if [[ "$FLAGS_SET" -eq 0 ]]; then
    if [[ -t 0 ]]; then
      choose_tools
    else
      echo ""
      warn "Sin terminal interactiva — usando selección por defecto (OpenCode + gem-team)."
      warn "Para otra selección usa flags (p. ej. $0 --all)."
    fi
  fi

  resolve_dependencies
  print_selection

  if [[ "$DO_APM" -eq 0 && "$DO_OPENCODE" -eq 0 && "$DO_GEM_TEAM" -eq 0 && "$DO_CLAUDE" -eq 0 && "$DO_OMOS" -eq 0 ]]; then
    echo ""
    warn "No se seleccionó ninguna herramienta. Nada que instalar."
    return 0
  fi

  preflight || { fail "Preflight falló"; return 1; }

  # El installer de opencode solo añade ~/.opencode/bin al PATH en los archivos
  # de shell (no en la sesión actual): añadir los dirs comunes antes de cualquier
  # chequeo para no reinstalar lo que ya está instalado.
  ensure_common_bins_in_path

  # Cada paso es independiente: un fallo no aborta el resto,
  # el resumen final reporta qué quedó pendiente.
  if [[ "$DO_APM" -eq 1 ]]; then
    install_apm || true
  fi
  if [[ "$DO_OPENCODE" -eq 1 ]]; then
    install_opencode || true
  fi
  if [[ "$DO_GEM_TEAM" -eq 1 ]]; then
    install_gem_team || true
  fi
  if [[ "$DO_CLAUDE" -eq 1 ]]; then
    install_claude || true
  fi
  if [[ "$DO_OMOS" -eq 1 ]]; then
    install_omos || true
  fi

  print_summary
}

main "$@"
