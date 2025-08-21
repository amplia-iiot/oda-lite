#!/usr/bin/env bash
set -euo pipefail

# Valores por defecto
TELEGRAF_VERSION="1.31.1"
CONFIG_DIR="config"
CUSTOM_PLUGINS_DIR="plugins"
MODE="mini"  # mini por defecto
DIST_DIR="." # directorio destino de distribución (por defecto, raíz)

usage() {
    echo "Uso: $0 [--version <telegraf_version>] [--config-dir <dir_config>] [--plugins-dir <dir_plugins>] [--mode <nano|mini>] [--dist-dir <dir_destino>]"
    echo
    echo "Argumentos (opcional, se usan valores por defecto si no se especifican):"
    echo "  --version       Versión de Telegraf a compilar (default: $TELEGRAF_VERSION)"
    echo "  --config-dir    Directorio con ficheros de configuración de Telegraf (.conf) (default: $CONFIG_DIR)"
    echo "  --plugins-dir   Directorio con los plugins custom (default: $CUSTOM_PLUGINS_DIR)"
    echo "  --mode          Tipo de compilación: nano (solo plugins de configs) o mini (todos los plugins + custom) (default: $MODE)"
    echo "  --dist-dir      Directorio de salida para binario y configs (default: $DIST_DIR)"
    echo "  --help          Muestra esta ayuda"
    echo
    echo "Ejemplo de uso:"
    echo "  $0 --version 1.31.0 --config-dir /ruta/configs --plugins-dir /ruta/mis_plugins --mode mini --dist-dir dist"
    exit 0
}

# Comprobar dependencias esenciales al inicio
for cmd in make go git; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Error: '$cmd' no está instalado. Instálalo antes de ejecutar este script."
        exit 1
    fi
done

# Parse CLI y sobrescribir valores por defecto si se pasan argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      TELEGRAF_VERSION="$2"
      shift 2
      ;;
    --config-dir|-c)
      CONFIG_DIR="$2"
      shift 2
      ;;
    --plugins-dir|-p)
      CUSTOM_PLUGINS_DIR="$2"
      shift 2
      ;;
    --dist-dir|-d)
      DIST_DIR="$2"
      shift 2
      ;;
    --mode|-m)
      MODE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "❌ Opción desconocida: $1"
      usage
      ;;
  esac
done

# Comprobación temprana: el directorio destino debe existir
if [ ! -d "$DIST_DIR" ]; then
    echo "ℹ️ El directorio de destino '$DIST_DIR' no existe. Créalo y vuelve a ejecutar el script."
    exit 1
fi

# Validaciones de argumentos
if [ ! -d "$CONFIG_DIR" ]; then
    echo "❌ Error: el directorio de configuración '$CONFIG_DIR' no existe."
    exit 1
fi

if ! ls "$CONFIG_DIR"/*.conf >/dev/null 2>&1; then
    echo "❌ Error: el directorio '$CONFIG_DIR' no contiene ningún archivo .conf"
    exit 1
fi

if [ ! -d "$CUSTOM_PLUGINS_DIR" ]; then
    echo "❌ Error: el directorio de plugins '$CUSTOM_PLUGINS_DIR' no existe."
    exit 1
fi

# Clonar Telegraf
REPO_URL="https://github.com/influxdata/telegraf.git"
CLONE_DIR="telegraf_src"
REPO_ROOT="$(pwd)"

if [ -d "$CLONE_DIR" ]; then
    echo "ℹ️ Eliminando directorio previo $CLONE_DIR"
    rm -rf "$CLONE_DIR"
fi

echo "📥 Clonando Telegraf versión $TELEGRAF_VERSION..."
git clone --branch "v${TELEGRAF_VERSION}" --depth 1 "$REPO_URL" "$CLONE_DIR"

# Copiar configs
PLUGINS_TELEGRAF_DIR="plugins_conf"
PLUGINS_CONF_DIR="$CLONE_DIR/$PLUGINS_TELEGRAF_DIR"
mkdir -p "$PLUGINS_CONF_DIR"

echo "📂 Copiando configuraciones de $CONFIG_DIR a $PLUGINS_CONF_DIR..."
cp -r "$CONFIG_DIR"/*.conf "$PLUGINS_CONF_DIR"/

# Copiar plugins custom al árbol "plugins/"
echo "📂 Copiando plugins custom al árbol de Telegraf..."
cp -a "$CUSTOM_PLUGINS_DIR"/. "$CLONE_DIR/plugins/"

# Interactivo: añadir librerías al go.mod
echo "📦 Añadir dependencias adicionales al go.mod (opcional)"
echo "   Pega las librerías que necesites añadir. Presiona Enter para confirmar cada iteración."
echo "   Presiona Enter sin escribir nada para finalizar."

cd "$CLONE_DIR"

while true; do
    read -r -p "Agregar librerías (una o varias, separadas por Enter, iteración final Enter solo): " input
    if [ -z "$input" ]; then
        break
    fi
    while IFS= read -r lib; do
        [ -z "$lib" ] && continue
        echo "➕ Añadiendo $lib al go.mod..."
        go get "$lib"
    done <<< "$input"
done

# Limpiar y preparar dependencias
go mod tidy

# Compilar herramientas
echo "🛠 Compilando herramientas build_tools..."
make build_tools

# Compilación según modo
TELEGRAF_CONF=""
if [ "$MODE" = "nano" ]; then
    echo "⚡ Compilación NANO: solo plugins referenciados en los .conf de $CONFIG_DIR"
    ./tools/custom_builder/custom_builder --config-dir "$PLUGINS_TELEGRAF_DIR"

elif [ "$MODE" = "mini" ]; then
    echo "⚡ Compilación MINI: todos los plugins de Telegraf + plugins custom"

    # Crear archivo vacío de manera segura (se limpia su contenido si ya existe)
    TELEGRAF_CONF="$PLUGINS_TELEGRAF_DIR/telegraf_all.conf"
    > "$TELEGRAF_CONF"

    EXCLUDE_PLUGINS=("outputs.all" "inputs.all" "inputs.example" "processors.all" "parsers.xpath" "parsers.all" "serializers.all" "secretstores.all" "aggregators.all")

    for type in inputs processors outputs aggregators parsers secretstores serializers; do
        for plugin_dir in "plugins/$type/"*; do
            if [ -d "$plugin_dir" ]; then
                plugin_name=$(basename "$plugin_dir")
                full_name="$type.$plugin_name"

                # Saltar plugins excluidos
                skip=false
                for ex in "${EXCLUDE_PLUGINS[@]}"; do
                    if [ "$full_name" = "$ex" ]; then
                        skip=true
                        break
                    fi
                done
                $skip && continue

                echo "[[$full_name]]" >> "$TELEGRAF_CONF"
            fi
        done
    done


    echo "📄 Archivo de configuración generado para MINI: $TELEGRAF_CONF"

    ./tools/custom_builder/custom_builder --config-dir "$PLUGINS_TELEGRAF_DIR" --config "$TELEGRAF_CONF"

else
    echo "❌ Modo desconocido: $MODE"
    exit 1
fi

# Preparar distribución en el directorio elegido
cd "$REPO_ROOT"

# Copiar binario compilado
if [ -f "$CLONE_DIR/telegraf" ]; then
  echo "📦 Copiando binario a destino: $DIST_DIR/telegraf"
  cp -f "$CLONE_DIR/telegraf" "$DIST_DIR/telegraf"
else
  echo "❌ No se encontró el binario compilado en $CLONE_DIR/telegraf"
  exit 1
fi

# Preparar y copiar configuraciones destinadas a runtime
echo "📂 Preparando carpeta de configuración en destino: $DIST_DIR/plugins_conf"
rm -rf "$DIST_DIR/plugins_conf"
mkdir -p "$DIST_DIR/plugins_conf"
cp -f "$CONFIG_DIR"/*.conf "$DIST_DIR/plugins_conf/"

## Generar script de ejecución run_oda_lite.sh en el directorio raíz del repo
## El script detectará si DIST_DIR es absoluto o relativo
cat > run_oda_lite.sh <<EOS
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

DIST_DIR_INPUT="${DIST_DIR}"

if [[ "\${DIST_DIR_INPUT}" = /* ]]; then
  TELEGRAF_BIN="\${DIST_DIR_INPUT}/telegraf"
  CONF_DIR="\${DIST_DIR_INPUT}/plugins_conf"
else
  TELEGRAF_BIN="\${SCRIPT_DIR}/\${DIST_DIR_INPUT}/telegraf"
  CONF_DIR="\${SCRIPT_DIR}/\${DIST_DIR_INPUT}/plugins_conf"
fi

if [ ! -x "\${TELEGRAF_BIN}" ]; then
  echo "❌ Telegraf no encontrado en \${TELEGRAF_BIN}"
  exit 1
fi

echo "🚀 Lanzando Telegraf con configs en: \${CONF_DIR}"
exec "\${TELEGRAF_BIN}" --config-directory "\${CONF_DIR}" "\$@"
EOS
chmod +x run_oda_lite.sh

# Eliminar directorio de compilación para no depender de él en runtime
echo "🧹 Eliminando directorio de compilación: $CLONE_DIR"
rm -rf "$CLONE_DIR"

echo "✅ Compilación finalizada. Ejecutable y configs listos en: $DIST_DIR"
echo "   Usa ./run_oda_lite.sh para arrancar Telegraf"
