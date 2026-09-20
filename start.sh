#!/usr/bin/env bash
# install.sh - Instalador para antiX + runit
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
ACTION=${1:-install}

# ---------------------------------------------------------------------------
# Rutas y nombres
# ---------------------------------------------------------------------------
DEST_DIR="/usr/libexec"
BINARIES=(
    "runkit"
    "runkitd"
)

ICON_BASE_NAME="runkit"
ICON_SOURCE_DIR="assets/icons/hicolor"
ICON_TARGET_BASE="/usr/share/icons/hicolor"
ICON_SIZES=(16x16 24x24 32x32 48x48 64x64 96x96 128x128 256x256 512x512)

DESKTOP_SOURCE="assets/applications/tech.geektoshi.Runkit.desktop"
DESKTOP_TARGET="/usr/share/applications/tech.geektoshi.Runkit.desktop"

DBUS_SERVICE_SOURCE="assets/dbus-1/services/tech.geektoshi.Runkit.service"
DBUS_SERVICE_TARGET="/usr/share/dbus-1/services/tech.geektoshi.Runkit.service"

DBUS_SYSTEM_SERVICE_SOURCE="assets/dbus-1/system-services/tech.geektoshi.Runkit1.service"
DBUS_SYSTEM_SERVICE_TARGET="/usr/share/dbus-1/system-services/tech.geektoshi.Runkit1.service"

DBUS_SYSTEM_CONFIG_SOURCE="assets/dbus-1/system.d/tech.geektoshi.Runkit1.conf"
DBUS_SYSTEM_CONFIG_TARGET="/etc/dbus-1/system.d/tech.geektoshi.Runkit1.conf"

POLKIT_POLICY_SOURCE="assets/polkit-1/actions/tech.geektoshi.Runkit.policy"
POLKIT_POLICY_TARGET="/usr/share/polkit-1/actions/tech.geektoshi.Runkit.policy"

SERVICE_DESCRIPTIONS_TEMPLATE="assets/config/services.json"

# --- runit -----------------------------------------------------------------
RUNIT_SV_DIR="/etc/sv/runkitd"
RUNIT_SERVICE_LINK_CANDIDATES=("/etc/service/runkitd" "/var/service/runkitd")

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
require_sudo() {
    sudo -v
}

# Devuelve 0 si el paquete está instalado en Debian/antiX
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_dependencies() {
    # Traducción de dependencias Void -> Debian/antiX
    local deps=(
        build-essential
        pkg-config
        libgtk-4-dev
        libadwaita-1-dev
        libglib2.0-dev
        libpango1.0-dev
        libdbus-1-dev
    )

    # Comprobamos si existe cargo/rustup; si no, lo pedimos aparte.
    local need_rust=false
    if ! command -v cargo >/dev/null 2>&1; then
        need_rust=true
    fi

    local missing=()
    echo "Comprobando dependencias del sistema..."
    for dep in "${deps[@]}"; do
        if pkg_installed "$dep"; then
            echo "  ya instalado: ${dep}"
        else
            echo "  falta: ${dep}"
            missing+=("$dep")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "Instalando dependencias que faltan: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    else
        echo "Todas las dependencias ya están satisfechas."
    fi

    if $need_rust; then
        cat <<'EOF'
--------------------------------------------------------------------
No se ha encontrado 'cargo' en el PATH.

antiX no empaqueta 'rustup'. Instala Rust de una de estas formas:

  A) Vía apt (más sencillo, versión más antigua):
       sudo apt-get install -y rustc cargo

  B) Vía rustup (recomendado para compilar proyectos modernos):
       curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
       source "$HOME/.cargo/env"

Después vuelve a ejecutar este script.
--------------------------------------------------------------------
EOF
        exit 1
    fi
}

build_binaries() {
    echo "Compilando paquetes..."
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        sudo -u "$SUDO_USER" bash -lc '
            if [[ -f "$HOME/.cargo/env" ]]; then
                source "$HOME/.cargo/env"
            fi
            if ! command -v cargo >/dev/null 2>&1; then
                echo "Error: cargo no está en el PATH para ${USER}." >&2
                exit 1
            fi
            cargo build --release
        '
    else
        if ! command -v cargo >/dev/null 2>&1; then
            if [[ -f "$HOME/.cargo/env" ]]; then
                # shellcheck disable=SC1090
                source "$HOME/.cargo/env"
            fi
        fi
        if ! command -v cargo >/dev/null 2>&1; then
            echo "Error: cargo no está en el PATH." >&2
            exit 1
        fi
        cargo build --release
    fi
}

install_binaries() {
    local src_dir="target/release"

    if [[ ! -d "$src_dir" ]]; then
        echo "Error: el directorio '$src_dir' no existe."
        exit 1
    fi

    for bin in "${BINARIES[@]}"; do
        local src_path="${src_dir}/${bin}"
        local dest_path="${DEST_DIR}/${bin}"

        if [[ ! -f "$src_path" ]]; then
            echo "Aviso: '$src_path' no encontrado – se omite."
            continue
        fi

        echo "Instalando '$src_path' → '$dest_path'..."
        sudo install -m755 "$src_path" "$DEST_DIR"
    done
}

install_service_descriptions() {
    local template="$SERVICE_DESCRIPTIONS_TEMPLATE"
    if [[ ! -f "$template" ]]; then
        echo "Nota: no se encuentra la plantilla en ${template}; se omite."
        return
    fi

    local merger_binary="target/release/services-merge"
    if [[ ! -x "$merger_binary" ]]; then
        echo "Aviso: no se encuentra services-merge en ${merger_binary}; se omite."
        return
    fi

    local target_user="${SUDO_USER:-$USER}"
    if [[ -z "$target_user" ]]; then
        echo "Aviso: no se puede determinar el usuario destino; se omite."
        return
    fi

    local target_home
    if ! target_home=$(getent passwd "$target_user" | cut -d: -f6); then
        echo "Aviso: no se puede resolver el home de '${target_user}'; se omite."
        return
    fi
    if [[ -z "$target_home" ]]; then
        echo "Aviso: home vacío para '${target_user}'; se omite."
        return
    fi

    local target_file="${target_home}/.config/runkit/services.json"
    echo "Fusionando descripciones de servicios en '${target_file}' para '${target_user}'..."

    if [[ "$target_user" == "$USER" ]]; then
        if ! "$merger_binary" --template "$template" --target "$target_file"; then
            echo "Aviso: fallo al fusionar descripciones para ${target_user}."
        fi
    else
        if ! sudo -u "$target_user" "$merger_binary" --template "$template" --target "$target_file"; then
            echo "Aviso: fallo al fusionar descripciones para ${target_user}."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Iconos / desktop / dbus / polkit
# ---------------------------------------------------------------------------
install_icons() {
    local installed_any=false
    local missing_sizes=()

    for size in "${ICON_SIZES[@]}"; do
        local src="${ICON_SOURCE_DIR}/${size}/apps/${ICON_BASE_NAME}.png"
        if [[ -f "$src" ]]; then
            local dest="${ICON_TARGET_BASE}/${size}/apps/${ICON_BASE_NAME}.png"
            echo "Instalando icono '$src' -> '$dest'..."
            sudo install -D -m644 "$src" "$dest"
            installed_any=true
        else
            missing_sizes+=("$size")
        fi
    done

    if (( ${#missing_sizes[@]} > 0 )); then
        echo "Nota: faltan PNGs para los tamaños: ${missing_sizes[*]}"
    fi

    local svg_src="${ICON_SOURCE_DIR}/scalable/apps/${ICON_BASE_NAME}.svg"
    if [[ -f "$svg_src" ]]; then
        local svg_dest="${ICON_TARGET_BASE}/scalable/apps/${ICON_BASE_NAME}.svg"
        echo "Instalando icono '$svg_src' -> '$svg_dest'..."
        sudo install -D -m644 "$svg_src" "$svg_dest"
        installed_any=true
    else
        echo "Nota: falta el icono escalable en ${svg_src}"
    fi

    if [[ "$installed_any" == true ]]; then
        refresh_icon_cache
    fi
}

install_desktop_entry() {
    if [[ -f "$DESKTOP_SOURCE" ]]; then
        echo "Instalando entrada de escritorio '$DESKTOP_SOURCE' -> '$DESKTOP_TARGET'..."
        sudo install -D -m644 "$DESKTOP_SOURCE" "$DESKTOP_TARGET"
        refresh_desktop_database
    else
        echo "Nota: no se encuentra la entrada de escritorio; se omite."
    fi
}

install_dbus_service() {
    if [[ -f "$DBUS_SERVICE_SOURCE" ]]; then
        echo "Instalando servicio D-Bus '$DBUS_SERVICE_SOURCE' -> '$DBUS_SERVICE_TARGET'..."
        sudo install -D -m644 "$DBUS_SERVICE_SOURCE" "$DBUS_SERVICE_TARGET"
    else
        echo "Nota: no se encuentra el servicio D-Bus; se omite."
    fi

    if [[ -f "$DBUS_SYSTEM_SERVICE_SOURCE" ]]; then
        echo "Instalando servicio D-Bus de sistema '$DBUS_SYSTEM_SERVICE_SOURCE' -> '$DBUS_SYSTEM_SERVICE_TARGET'..."
        sudo install -D -m644 "$DBUS_SYSTEM_SERVICE_SOURCE" "$DBUS_SYSTEM_SERVICE_TARGET"
    else
        echo "Nota: no se encuentra el servicio D-Bus de sistema; se omite."
    fi

    if [[ -f "$DBUS_SYSTEM_CONFIG_SOURCE" ]]; then
        echo "Instalando política D-Bus de sistema '$DBUS_SYSTEM_CONFIG_SOURCE' -> '$DBUS_SYSTEM_CONFIG_TARGET'..."
        sudo install -D -m644 "$DBUS_SYSTEM_CONFIG_SOURCE" "$DBUS_SYSTEM_CONFIG_TARGET"
    else
        echo "Nota: no se encuentra la política D-Bus de sistema; se omite."
    fi
}

install_polkit_policy() {
    if [[ -f "$POLKIT_POLICY_SOURCE" ]]; then
        echo "Instalando política polkit '$POLKIT_POLICY_SOURCE' -> '$POLKIT_POLICY_TARGET'..."
        sudo install -D -m644 "$POLKIT_POLICY_SOURCE" "$POLKIT_POLICY_TARGET"
    else
        echo "Nota: no se encuentra la política polkit; se omite."
    fi
}

# ---------------------------------------------------------------------------
# runit
# ---------------------------------------------------------------------------
runit_enabled_link() {
    # Devuelve la ruta del enlace activo, o cadena vacía si no existe.
    local link
    for link in "${RUNIT_SERVICE_LINK_CANDIDATES[@]}"; do
        if [[ -L "$link" || -e "$link" ]]; then
            echo "$link"
            return 0
        fi
    done
    echo ""
}

install_runit_service() {
    if ! command -v sv >/dev/null 2>&1; then
        echo "Nota: 'sv' no encontrado; parece que runit no está activo. Se omite el servicio runitd."
        return
    fi

    echo "Instalando servicio runit para runkitd..."
    sudo mkdir -p "$RUNIT_SV_DIR"

    # Script de arranque. Ajusta las rutas/argumentos si runkitd los necesita.
    sudo tee "${RUNIT_SV_DIR}/run" >/dev/null <<'EOF'
#!/bin/sh
exec 2>&1
# Si runkitd necesita un usuario concreto, descomenta y ajusta:
# exec chpst -u _runkit /usr/libexec/runkitd
exec /usr/libexec/runkitd
EOF
    sudo chmod +x "${RUNIT_SV_DIR}/run"

    # runit en antiX usa /etc/service (enlace a /etc/sv). Algunos forks usan /var/service.
    local activated=""
    for link in "${RUNIT_SERVICE_LINK_CANDIDATES[@]}"; do
        local parent
        parent=$(dirname "$link")
        if [[ -d "$parent" ]]; then
            sudo ln -sfn "$RUNIT_SV_DIR" "$link"
            activated="$link"
            break
        fi
    done

    if [[ -z "$activated" ]]; then
        echo "Aviso: no se encontró /etc/service ni /var/service; crea el enlace manualmente:"
        echo "    sudo ln -s $RUNIT_SV_DIR /etc/service/runkitd"
        return
    fi

    echo "Servicio runit activado en '$activated'."

    # Arrancarlo ya, sin reiniciar.
    if sudo sv status runkitd >/dev/null 2>&1; then
        sudo sv up runkitd || true
    else
        # A veces hace falta update-service para que runit lo vea.
        if command -v update-service >/dev/null 2>&1; then
            sudo update-service --add "$RUNIT_SV_DIR" runkitd || true
        fi
        sudo sv up runkitd || true
    fi
}

uninstall_runit_service() {
    if ! command -v sv >/dev/null 2>&1; then
        return
    fi

    echo "Deteniendo y eliminando servicio runit de runkitd..."
    sudo sv down runkitd 2>/dev/null || true
    if command -v update-service >/dev/null 2>&1; then
        sudo update-service --remove "$RUNIT_SV_DIR" runkitd 2>/dev/null || true
    fi

    local link
    for link in "${RUNIT_SERVICE_LINK_CANDIDATES[@]}"; do
        if [[ -L "$link" || -e "$link" ]]; then
            sudo rm -f "$link"
        fi
    done
    sudo rm -rf "$RUNIT_SV_DIR"
}

# ---------------------------------------------------------------------------
# Refrescos de caché
# ---------------------------------------------------------------------------
refresh_icon_cache() {
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        echo "Actualizando caché de iconos..."
        sudo gtk-update-icon-cache -f "$ICON_TARGET_BASE" || true
    fi
}

refresh_desktop_database() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        local dir
        dir=$(dirname "$DESKTOP_TARGET")
        echo "Refrescando base de datos de escritorio para $dir..."
        sudo update-desktop-database "$dir" || true
    fi
}

# ---------------------------------------------------------------------------
# Desinstalación
# ---------------------------------------------------------------------------
uninstall_icons() {
    local removed_any=false

    for size in "${ICON_SIZES[@]}"; do
        local dest="${ICON_TARGET_BASE}/${size}/apps/${ICON_BASE_NAME}.png"
        if [[ -f "$dest" ]]; then
            echo "Eliminando icono '$dest'..."
            sudo rm -f "$dest"
            removed_any=true
        fi
    done

    local svg_dest="${ICON_TARGET_BASE}/scalable/apps/${ICON_BASE_NAME}.svg"
    if [[ -f "$svg_dest" ]]; then
        echo "Eliminando icono '$svg_dest'..."
        sudo rm -f "$svg_dest"
        removed_any=true
    fi

    if [[ "$removed_any" == true ]]; then
        refresh_icon_cache
    fi
}

uninstall_desktop_entry() {
    if [[ -f "$DESKTOP_TARGET" ]]; then
        echo "Eliminando entrada de escritorio '$DESKTOP_TARGET'..."
        sudo rm -f "$DESKTOP_TARGET"
        refresh_desktop_database
    fi
}

uninstall_dbus_service() {
    if [[ -f "$DBUS_SERVICE_TARGET" ]]; then
        echo "Eliminando servicio D-Bus '$DBUS_SERVICE_TARGET'..."
        sudo rm -f "$DBUS_SERVICE_TARGET"
    fi
    if [[ -f "$DBUS_SYSTEM_SERVICE_TARGET" ]]; then
        echo "Eliminando servicio D-Bus de sistema '$DBUS_SYSTEM_SERVICE_TARGET'..."
        sudo rm -f "$DBUS_SYSTEM_SERVICE_TARGET"
    fi
    if [[ -f "$DBUS_SYSTEM_CONFIG_TARGET" ]]; then
        echo "Eliminando política D-Bus de sistema '$DBUS_SYSTEM_CONFIG_TARGET'..."
        sudo rm -f "$DBUS_SYSTEM_CONFIG_TARGET"
    fi
}

uninstall_polkit_policy() {
    if [[ -f "$POLKIT_POLICY_TARGET" ]]; then
        echo "Eliminando política polkit '$POLKIT_POLICY_TARGET'..."
        sudo rm -f "$POLKIT_POLICY_TARGET"
    fi
}

uninstall_binaries() {
    echo "Eliminando binarios instalados..."
    for bin in "${BINARIES[@]}"; do
        local dest_path="${DEST_DIR}/${bin}"
        if [[ ! -f "$dest_path" ]]; then
            echo "Omitiendo '${dest_path}'; no existe."
            continue
        fi
        echo "Eliminando '$dest_path'..."
        sudo rm -f "$dest_path"
    done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
case "$ACTION" in
    install)
        require_sudo
        install_dependencies
        build_binaries
        install_binaries
        install_icons
        install_desktop_entry
        install_dbus_service
        install_polkit_policy
        install_service_descriptions
        install_runit_service
        ;;
    uninstall)
        require_sudo
        uninstall_runit_service
        uninstall_binaries
        uninstall_icons
        uninstall_desktop_entry
        uninstall_dbus_service
        uninstall_polkit_policy
        ;;
    *)
        echo "Uso: $SCRIPT_NAME [install|uninstall]" >&2
        exit 1
        ;;
esac

echo "Hecho."
