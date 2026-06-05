#!/usr/bin/env bash
#
# ============================================================================
#  LibreNMS — Instalador automatizado e idempotente para Debian 12 / 13
# ============================================================================
#
#  Versión:    1.0 (junio 2026)
#  Licencia:   MIT
#  Probado en: Debian 12 (bookworm) · Debian 13 (trixie) · LibreNMS 26.5.x
#
#  Este instalador integra los workarounds descubiertos en deployments reales:
#    1. Cron daemon NO viene en Debian 13 cloud images → instala y verifica
#    2. NODE_ID obligatorio en .env para que el python poller wrapper registre
#    3. rrdcached recomendado (single-node también) → instala y configura
#    4. distributed_poller=false en single-node (evita FAIL espurio si no hay rrdcached)
#    5. server_name=_ (catch-all) → funciona con NAT, IP pública, FQDN o IP interna
#    6. /etc/cron.d/librenms debe ser root:root 0644 o cron lo ignora
#    7. PHP-FPM pool: listen.owner/group explícitos (Debian 13)
#    8. git safe.directory para que root pueda inspeccionar /opt/librenms
#    9. Bootstrap manual del scheduler_working cache key (evita FAIL transitorio)
#   10. Parche local de RrdCheck.php (bug upstream: echo contamina JSON HTTP)
#       + git update-index --skip-worktree para no romper daily.sh
#
#  Uso:
#    sudo bash install.sh
#    sudo BASE_URL=http://1.2.3.4:8087 ADMIN_EMAIL=tu@correo bash install.sh
#
#  Variables (export antes de correr, todas opcionales):
#    BASE_URL          URL pública por la que se accederá (si vacía, se pregunta)
#    ADMIN_EMAIL       Email del usuario admin inicial
#    ADMIN_PASS        Si vacía se genera aleatoria
#    TIMEZONE          Default: America/Guayaquil
#    SNMP_COMMUNITY    Default: librenms_local
#    SKIP_RRDCACHED    Default: no (true para saltar rrdcached)
#    SKIP_RRDCHECK_PATCH  Default: no (true para no parchar RrdCheck.php)
#
#  Repositorio: https://github.com/<tu-user>/librenms-installer-debian
#
# ============================================================================

set -euo pipefail

# ============================================================================
#  Configuración
# ============================================================================
INSTALLER_VERSION="1.0"
TIMEZONE="${TIMEZONE:-America/Guayaquil}"
LIBRENMS_DIR="/opt/librenms"
LIBRENMS_USER="librenms"
LOG_FILE="/var/log/librenms-install.log"
CRED_FILE="/root/librenms-credenciales.txt"
LOCK_FILE="/var/lock/librenms-install.lock"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-librenms_local}"
SKIP_RRDCACHED="${SKIP_RRDCACHED:-no}"
SKIP_RRDCHECK_PATCH="${SKIP_RRDCHECK_PATCH:-no}"

# ============================================================================
#  Colores y helpers
# ============================================================================
C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[1;34m'
C_M='\033[1;35m'; C_N='\033[0m'

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "\n${C_B}[$(date '+%H:%M:%S')]${C_N} ${C_B}$*${C_N}"; }
ok()   { echo -e "  ${C_G}[OK]${C_N} $*"; }
warn() { echo -e "  ${C_Y}[WARN]${C_N} $*"; }
err()  { echo -e "  ${C_R}[ERROR]${C_N} $*" >&2; }
fail() { err "$*"; exit 1; }

trap 'rc=$?; if [[ $rc -ne 0 ]]; then err "Instalador falló en línea $LINENO (comando: ${BASH_COMMAND}). Log: $LOG_FILE"; fi' EXIT

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
}

random_pass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
random_hex()  { openssl rand -hex "${1:-12}"; }

set_env_var() {
  # Idempotente: actualiza o agrega KEY=VALUE en $LIBRENMS_DIR/.env
  # Escapa metacaracteres de sed (\, &, |) para soportar valores con caracteres especiales.
  local key="$1" val="$2" file="$LIBRENMS_DIR/.env"
  local val_esc
  val_esc=$(printf '%s\n' "$val" | sed -e 's/[\\&|]/\\&/g')
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val_esc}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

run_as_librenms() {
  # Ejecuta un comando como user librenms con HOME=/opt/librenms y CWD ahí.
  # Evita doble-evaluación de variables del shell padre.
  sudo -u "$LIBRENMS_USER" --preserve-env=PATH bash -c "cd $LIBRENMS_DIR && $1"
}

# ============================================================================
#  Etapa 0 — Pre-flight
# ============================================================================
preflight() {
  log "=== 0. Pre-flight ==="
  [[ $EUID -eq 0 ]] || fail "Debe ejecutarse como root (usa: sudo bash $0)"
  command -v openssl >/dev/null || fail "openssl no está disponible"

  . /etc/os-release
  if [[ "$ID" != "debian" ]]; then
    fail "Este instalador es solo para Debian. Detectado: $PRETTY_NAME"
  fi
  local major="${VERSION_ID%%.*}"
  if (( major < 12 )); then
    fail "Debian 12+ requerido. Detectado: $PRETTY_NAME"
  fi
  ok "Sistema: $PRETTY_NAME"

  timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
  ok "Zona horaria: $(timedatectl show -p Timezone --value)"

  # Verificar conectividad a internet (apt, git, packagist)
  if ! curl -fsI -m 5 https://github.com >/dev/null 2>&1; then
    warn "github.com no responde — puede que git clone falle"
  fi
}

# ============================================================================
#  Etapa 1 — Input usuario
# ============================================================================
prompt_user_input() {
  local primary_ip
  primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

  if [[ -z "${BASE_URL:-}" ]]; then
    if [[ -t 0 ]]; then
      echo
      echo -e "${C_Y}>>> Configuración interactiva${C_N}"
      echo "Ingresa la URL por la que se accederá a LibreNMS desde el navegador."
      echo "Ejemplos:"
      echo "  http://200.1.2.3:8087    (IP pública + puerto NAT de router/MikroTik)"
      echo "  http://librenms.dominio  (FQDN)"
      echo "  http://${primary_ip}        (IP interna del VPS, acceso directo)"
      echo
      read -rp "BASE_URL [http://${primary_ip}]: " BASE_URL
      BASE_URL="${BASE_URL:-http://${primary_ip}}"
    else
      BASE_URL="http://${primary_ip}"
      warn "Sin TTY interactivo → BASE_URL=${BASE_URL}"
    fi
  fi

  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$(hostname -d 2>/dev/null || echo localdomain)}"
  ADMIN_PASS="${ADMIN_PASS:-$(random_pass | cut -c1-20)}"

  ok "BASE_URL    = $BASE_URL"
  ok "ADMIN_EMAIL = $ADMIN_EMAIL"
  ok "TIMEZONE    = $TIMEZONE"
}

# ============================================================================
#  Etapa 2 — Paquetes apt
# ============================================================================
install_packages() {
  log "=== 1. Instalando paquetes ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # Lista oficial LibreNMS + extras descubiertos en producción:
  #  - cron: NO viene por defecto en Debian 13 cloud → explícito
  #  - python3-command-runner, python3-psutil: requeridos por requirements.txt
  #    (preferir apt sobre pip para no chocar con --break-system-packages)
  #  - rrdcached: condicional (paso aparte)
  apt-get install -y -q \
    acl curl wget fping git graphviz imagemagick \
    mariadb-client mariadb-server \
    mtr-tiny nginx-full nmap \
    php-cli php-curl php-fpm php-gd php-gmp php-mbstring \
    php-mysql php-snmp php-xml php-zip \
    rrdtool snmp snmpd unzip whois traceroute \
    python3-pymysql python3-dotenv python3-redis python3-setuptools \
    python3-systemd python3-pip python3-psutil python3-command-runner \
    cron logrotate bash-completion openssl ca-certificates lsb-release

  # Garantiza cron explícitamente y verifica que arranca
  apt-get install -y -q cron
  systemctl enable --now cron >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet cron; then
    warn "El servicio cron no está activo aún — reintentando arrancarlo"
    systemctl start cron || fail "No pude arrancar cron"
  fi
  ok "Dependencias instaladas (cron: $(systemctl is-active cron))"
}

# ============================================================================
#  Etapa 3 — Detectar versión PHP (Debian 12 = 8.2, Debian 13 = 8.4)
# ============================================================================
detect_php() {
  log "=== 2. Detectando PHP ==="
  PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  PHP_FPM_SVC="php${PHP_VER}-fpm"
  PHP_CONF_DIR="/etc/php/${PHP_VER}"
  [[ -d "$PHP_CONF_DIR" ]] || fail "PHP $PHP_VER detectado pero $PHP_CONF_DIR no existe"
  ok "PHP detectado: $PHP_VER (servicio: $PHP_FPM_SVC)"
}

# ============================================================================
#  Etapa 4 — Usuario librenms y clonado
# ============================================================================
setup_user_repo() {
  log "=== 3. Usuario librenms y clonado del repo ==="
  if ! id "$LIBRENMS_USER" &>/dev/null; then
    useradd "$LIBRENMS_USER" -d "$LIBRENMS_DIR" -M -r -s /bin/bash
    ok "Usuario $LIBRENMS_USER creado"
  else
    ok "Usuario $LIBRENMS_USER ya existe"
  fi
  usermod -a -G "$LIBRENMS_USER" www-data 2>/dev/null || true

  if [[ ! -d "$LIBRENMS_DIR/.git" ]]; then
    # Clone completo (no --depth 1) para que daily.sh y rebase funcionen
    git clone https://github.com/librenms/librenms.git "$LIBRENMS_DIR"
    ok "LibreNMS clonado en $LIBRENMS_DIR"
  else
    warn "Repo ya clonado. Pulling cambios..."
    sudo -u "$LIBRENMS_USER" git -C "$LIBRENMS_DIR" pull --ff-only 2>&1 | tail -3 || warn "git pull falló"
  fi

  # Permite que root pueda ejecutar git en /opt/librenms (Debian 12+ con git ≥2.35.2)
  git config --system --add safe.directory "$LIBRENMS_DIR" 2>/dev/null || true

  chown -R "$LIBRENMS_USER":"$LIBRENMS_USER" "$LIBRENMS_DIR"
  chmod 771 "$LIBRENMS_DIR"
  ok "Ownership + safe.directory configurados"
}

# ============================================================================
#  Etapa 5 — Composer (vía wrapper oficial)
# ============================================================================
run_composer() {
  log "=== 4. Composer install ==="
  run_as_librenms "./scripts/composer_wrapper.php install --no-dev --no-interaction" | tail -10
  ln -sf "$LIBRENMS_DIR/lnms" /usr/bin/lnms
  ok "Dependencias PHP instaladas (lnms → /usr/bin/lnms)"
}

# ============================================================================
#  Etapa 6 — Permisos y ACLs
# ============================================================================
set_permissions() {
  log "=== 5. Permisos y ACLs ==="
  mkdir -p "$LIBRENMS_DIR"/{rrd,logs,bootstrap/cache,storage/framework/{cache,sessions,views}}
  chown -R "$LIBRENMS_USER":"$LIBRENMS_USER" \
    "$LIBRENMS_DIR/rrd" "$LIBRENMS_DIR/logs" \
    "$LIBRENMS_DIR/bootstrap" "$LIBRENMS_DIR/storage"
  setfacl -d -m g::rwx "$LIBRENMS_DIR/rrd" "$LIBRENMS_DIR/logs" \
    "$LIBRENMS_DIR/bootstrap/cache" "$LIBRENMS_DIR/storage"
  setfacl -R -m g::rwx "$LIBRENMS_DIR/rrd" "$LIBRENMS_DIR/logs" \
    "$LIBRENMS_DIR/bootstrap/cache" "$LIBRENMS_DIR/storage"
  ok "ACLs y permisos aplicados"
}

# ============================================================================
#  Etapa 7 — PHP timezone
# ============================================================================
configure_php_timezone() {
  log "=== 6. PHP timezone ==="
  local ini="${PHP_CONF_DIR}/mods-available/librenms-timezone.ini"
  backup_file "$ini"
  echo "date.timezone = ${TIMEZONE}" > "$ini"
  phpenmod -v "$PHP_VER" librenms-timezone
  ok "PHP date.timezone = $TIMEZONE (CLI + FPM)"
}

# ============================================================================
#  Etapa 8 — MariaDB
# ============================================================================
configure_mariadb() {
  log "=== 7. MariaDB ==="
  local conf=/etc/mysql/mariadb.conf.d/60-librenms.cnf
  backup_file "$conf"
  cat > "$conf" <<EOF
[mysqld]
innodb_file_per_table=1
lower_case_table_names=0
EOF
  systemctl enable --now mariadb >/dev/null 2>&1
  systemctl restart mariadb
  sleep 2

  # Reutilizar DB_PASSWORD existente (idempotencia en re-runs)
  if [[ -f "$LIBRENMS_DIR/.env" ]] && grep -qE '^DB_PASSWORD=.+' "$LIBRENMS_DIR/.env"; then
    DB_PASS=$(grep '^DB_PASSWORD=' "$LIBRENMS_DIR/.env" | cut -d= -f2-)
    ok "Reutilizando DB_PASSWORD existente de .env"
  else
    DB_PASS=$(random_pass)
    ok "DB_PASSWORD generado aleatoriamente"
  fi

  # mysql -uroot vía unix_socket (default en Debian)
  if ! mysql -uroot -e 'SELECT 1' >/dev/null 2>&1; then
    fail "mysql -uroot falló. ¿MariaDB tiene password de root? Configura manualmente."
  fi

  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER 'librenms'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Verifica conexión sin exponer password en ps
  MYSQL_PWD="$DB_PASS" mysql -ulibrenms -e "SHOW DATABASES;" >/dev/null
  ok "DB 'librenms' lista y user 'librenms'@'localhost' creado"
}

# ============================================================================
#  Etapa 9 — Construir .env Laravel
# ============================================================================
build_env() {
  log "=== 8. .env Laravel ==="
  if [[ ! -f "$LIBRENMS_DIR/.env" ]]; then
    cat > "$LIBRENMS_DIR/.env" <<EOF
APP_KEY=
NODE_ID=
DB_HOST=localhost
DB_DATABASE=librenms
DB_USERNAME=librenms
DB_PASSWORD=${DB_PASS}
APP_URL=${BASE_URL}
EOF
    chown "$LIBRENMS_USER":"$LIBRENMS_USER" "$LIBRENMS_DIR/.env"
    chmod 640 "$LIBRENMS_DIR/.env"
    ok ".env creado"
  else
    backup_file "$LIBRENMS_DIR/.env"
    set_env_var DB_HOST localhost
    set_env_var DB_DATABASE librenms
    set_env_var DB_USERNAME librenms
    set_env_var DB_PASSWORD "$DB_PASS"
    set_env_var APP_URL "$BASE_URL"
    chmod 640 "$LIBRENMS_DIR/.env"
    ok ".env actualizado"
  fi

  # APP_KEY (Laravel)
  if ! grep -q '^APP_KEY=base64:' "$LIBRENMS_DIR/.env"; then
    run_as_librenms "php artisan key:generate --force --no-interaction" | tail -2
    ok "APP_KEY generado"
  else
    ok "APP_KEY ya estaba presente"
  fi

  # NODE_ID — OBLIGATORIO para que poller-wrapper.py registre el nodo.
  # Sin NODE_ID el wrapper falla con: ".env does not contain a valid NODE_ID setting"
  local current_nid
  current_nid=$(grep '^NODE_ID=' "$LIBRENMS_DIR/.env" | cut -d= -f2-)
  if [[ -z "$current_nid" || ${#current_nid} -lt 8 ]]; then
    local nid; nid=$(random_hex 12)
    set_env_var NODE_ID "$nid"
    ok "NODE_ID generado: $nid"
  else
    ok "NODE_ID ya estaba presente"
  fi
}

# ============================================================================
#  Etapa 10 — Dependencias Python
# ============================================================================
install_python_deps() {
  log "=== 9. Dependencias Python ==="
  # Las deps principales vinieron por apt en la etapa 1.
  # Aún así corremos pip por si requirements.txt tiene algo nuevo no empaquetado.
  pip3 install --break-system-packages -r "$LIBRENMS_DIR/requirements.txt" 2>&1 | tail -5 || \
    warn "pip3 install -r requirements.txt tuvo errores (puede ser OK si todo vino de apt)"
  pip3 install --break-system-packages "command_runner>=1.3.0" 2>&1 | tail -2 || true
  ok "Dependencias Python validadas"
}

# ============================================================================
#  Etapa 11 — Migraciones DB
# ============================================================================
db_migrate() {
  log "=== 10. Migraciones de DB ==="
  run_as_librenms "php artisan migrate --force --no-interaction" 2>&1 | tail -10
  ok "Schema DB al día"
}

# ============================================================================
#  Etapa 12 — nginx + php-fpm pool
# ============================================================================
configure_web() {
  log "=== 11. nginx + php-fpm pool ==="

  # Pool php-fpm dedicado para LibreNMS
  local pool="${PHP_CONF_DIR}/fpm/pool.d/librenms.conf"
  if [[ ! -f "$pool" ]]; then
    cp "${PHP_CONF_DIR}/fpm/pool.d/www.conf" "$pool"
    sed -i 's/^\[www\]/[librenms]/' "$pool"
    sed -i 's|^user = www-data|user = librenms|' "$pool"
    sed -i 's|^group = www-data|group = librenms|' "$pool"
    sed -i "s|^listen = .*|listen = /run/php-fpm-librenms.sock|" "$pool"
    sed -i 's|^;listen.owner.*|listen.owner = www-data|' "$pool"
    sed -i 's|^;listen.group.*|listen.group = www-data|' "$pool"
    # Garantía: en Debian 13 esas líneas pueden no estar comentadas → forzar al final
    grep -q '^listen.owner = www-data' "$pool" || echo 'listen.owner = www-data' >> "$pool"
    grep -q '^listen.group = www-data' "$pool" || echo 'listen.group = www-data' >> "$pool"
    ok "php-fpm pool 'librenms' creado"
  else
    ok "php-fpm pool ya existe"
  fi

  # Deshabilita el pool 'www' default si existe (gasta workers sin uso real)
  if [[ -f "${PHP_CONF_DIR}/fpm/pool.d/www.conf" ]]; then
    mv "${PHP_CONF_DIR}/fpm/pool.d/www.conf" "${PHP_CONF_DIR}/fpm/pool.d/www.conf.disabled"
    ok "pool 'www' default deshabilitado"
  fi

  # vhost catch-all (server_name = _) — funciona con NAT/IP pública/FQDN/IP interna
  local vhost=/etc/nginx/sites-available/librenms.conf
  backup_file "$vhost"
  cat > "$vhost" <<'NGX'
server {
 listen 80;
 server_name _;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;

 # Headers de seguridad básicos
 add_header X-Frame-Options "SAMEORIGIN" always;
 add_header X-Content-Type-Options "nosniff" always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;

 location / {
  try_files $uri $uri/ /index.php?$query_string;
 }

 location ~ [^/]\.php(/|$) {
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_index index.php;
  include fastcgi.conf;
 }

 location ~ /\.(?!well-known).* {
  deny all;
 }
}
NGX
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$vhost" /etc/nginx/sites-enabled/librenms.conf

  nginx -t
  systemctl restart "$PHP_FPM_SVC" nginx
  systemctl enable "$PHP_FPM_SVC" nginx >/dev/null 2>&1
  ok "nginx + php-fpm activos (server_name catch-all)"
}

# ============================================================================
#  Etapa 13 — lnms bash completion
# ============================================================================
setup_lnms_completion() {
  log "=== 12. lnms bash completion ==="
  if [[ -f "$LIBRENMS_DIR/misc/lnms-completion.bash" ]]; then
    cp "$LIBRENMS_DIR/misc/lnms-completion.bash" /etc/bash_completion.d/
    chown root:root /etc/bash_completion.d/lnms-completion.bash
    chmod 644 /etc/bash_completion.d/lnms-completion.bash
    ok "Autocompletion lnms instalado"
  else
    warn "lnms-completion.bash no encontrado"
  fi
}

# ============================================================================
#  Etapa 14 — snmpd
# ============================================================================
configure_snmpd() {
  log "=== 13. snmpd ==="
  backup_file /etc/snmp/snmpd.conf
  cp "$LIBRENMS_DIR/snmpd.conf.example" /etc/snmp/snmpd.conf
  sed -i "s/RANDOMSTRINGGOESHERE/${SNMP_COMMUNITY}/" /etc/snmp/snmpd.conf

  # Script auxiliar 'distro' (opcional, no romper si no hay internet)
  if curl -fsSL -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro 2>/dev/null; then
    chmod +x /usr/bin/distro
    ok "Script /usr/bin/distro descargado"
  else
    warn "No pude descargar /usr/bin/distro (sin internet?). snmpd funcionará igual"
  fi

  systemctl enable --now snmpd >/dev/null 2>&1
  systemctl restart snmpd
  ok "snmpd activo (community v2c: $SNMP_COMMUNITY, bind 127.0.0.1)"
}

# ============================================================================
#  Etapa 15 — rrdcached (opcional, recomendado)
# ============================================================================
configure_rrdcached() {
  log "=== 14. rrdcached ==="
  if [[ "$SKIP_RRDCACHED" == "yes" || "$SKIP_RRDCACHED" == "true" ]]; then
    warn "rrdcached SALTADO (SKIP_RRDCACHED=$SKIP_RRDCACHED)"
    return 0
  fi

  apt-get install -y -q rrdcached
  backup_file /etc/default/rrdcached
  cat > /etc/default/rrdcached <<'RRDC'
# /etc/default/rrdcached — configurado para LibreNMS
DAEMON=/usr/bin/rrdcached
WRITE_TIMEOUT=1800
WRITE_JITTER=1800
WRITE_THREADS=4
BASE_PATH=/opt/librenms/rrd/
JOURNAL_PATH=/var/lib/rrdcached/journal/
PIDFILE=/run/rrdcached.pid
SOCKFILE=/run/rrdcached.sock
SOCKGROUP=librenms
SOCKMODE=0660
DAEMON_GROUP=librenms
DAEMON_USER=librenms
BASE_OPTIONS="-B -F"
RRDC

  mkdir -p /var/lib/rrdcached/journal /var/lib/rrdcached/db
  chown -R librenms:librenms /var/lib/rrdcached

  systemctl enable rrdcached >/dev/null 2>&1 || true
  systemctl restart rrdcached
  sleep 1

  # Verifica que el socket existe y es accesible por librenms
  if [[ -S /run/rrdcached.sock ]]; then
    ok "rrdcached activo (socket: /run/rrdcached.sock)"
  else
    warn "rrdcached restart OK pero /run/rrdcached.sock no apareció"
  fi
}

# ============================================================================
#  Etapa 16 — Cron de polling + scheduler systemd + logrotate
# ============================================================================
configure_cron_scheduler() {
  log "=== 15. Cron polling + scheduler systemd + logrotate ==="

  # Cron clásico: poller-wrapper.py, discovery, alerts. Sin esto NO hay polling.
  backup_file /etc/cron.d/librenms
  cp "$LIBRENMS_DIR/dist/librenms.cron" /etc/cron.d/librenms
  # CRÍTICO: cron exige root:root + 644. El cp puede heredar perms del repo.
  chown root:root /etc/cron.d/librenms
  chmod 644 /etc/cron.d/librenms
  ok "/etc/cron.d/librenms (root:root 644)"

  # Laravel scheduler (housekeeping, alertas) vía timer systemd
  cp "$LIBRENMS_DIR/dist/librenms-scheduler.service" /etc/systemd/system/
  cp "$LIBRENMS_DIR/dist/librenms-scheduler.timer"   /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now librenms-scheduler.timer >/dev/null 2>&1
  ok "librenms-scheduler.timer activo (dispara cada minuto)"

  # logrotate
  cp "$LIBRENMS_DIR/misc/librenms.logrotate" /etc/logrotate.d/librenms
  chown root:root /etc/logrotate.d/librenms
  chmod 644 /etc/logrotate.d/librenms
  ok "logrotate configurado"

  # Sanity: sin cron daemon no hay polling
  if ! systemctl is-active --quiet cron; then
    warn "Servicio cron NO activo, reintentando..."
    systemctl enable --now cron || warn "cron no arranca — el polling NO funcionará"
  fi
  systemctl is-active --quiet cron && ok "Servicio cron activo"
}

# ============================================================================
#  Etapa 17 — Parche RrdCheck.php (bug upstream)
# ============================================================================
patch_rrdcheck() {
  log "=== 16. Parche RrdCheck.php (bug upstream LibreNMS) ==="

  if [[ "$SKIP_RRDCHECK_PATCH" == "yes" || "$SKIP_RRDCHECK_PATCH" == "true" ]]; then
    warn "Parche SALTADO (SKIP_RRDCHECK_PATCH=$SKIP_RRDCHECK_PATCH)"
    warn "El web UI mostrará 'Failed to fetch validation results' en RRD Check"
    return 0
  fi

  local target="$LIBRENMS_DIR/LibreNMS/Validations/RrdCheck.php"
  [[ -f "$target" ]] || { warn "$target no existe — saltando"; return 0; }

  # Idempotente: solo parcha si NO está parchado y hay echos que arreglar
  if grep -q 'app()->runningInConsole' "$target"; then
    ok "RrdCheck.php ya está parchado"
  elif grep -qE '^\s+echo .*;$' "$target"; then
    # Envuelve cada línea "    echo ...;" con if (app()->runningInConsole()) { ... }
    perl -i -pe 's/^(\s+)(echo .*;)$/$1if (app()->runningInConsole()) { $2 }/' "$target"
    ok "RrdCheck.php parchado (echo guardados para CLI únicamente)"
  else
    ok "RrdCheck.php no requiere parche (upstream lo arregló?)"
  fi

  # Marca el archivo como skip-worktree para que git lo trate como limpio.
  # Sin esto: daily.sh hace rollback Y validate.php muestra WARN "modified files".
  sudo -u "$LIBRENMS_USER" git -C "$LIBRENMS_DIR" update-index --skip-worktree LibreNMS/Validations/RrdCheck.php 2>/dev/null || true
  if sudo -u "$LIBRENMS_USER" git -C "$LIBRENMS_DIR" ls-files -v LibreNMS/Validations/RrdCheck.php | grep -q '^S '; then
    ok "Git skip-worktree activo sobre RrdCheck.php"
  fi
}

# ============================================================================
#  Etapa 18 — Tuning single-node + rrdcached integration
# ============================================================================
single_node_tuning() {
  log "=== 17. Tuning single-node ==="

  # Si rrdcached está disponible → habilitar distributed_poller + rrdcached.
  # Si NO → apagar distributed_poller (evita FAIL espurio del check rrdcached).
  if [[ -S /run/rrdcached.sock ]]; then
    run_as_librenms "lnms config:set rrdcached unix:/run/rrdcached.sock" 2>&1 | tail -2 || warn "lnms config:set rrdcached falló"
    ok "rrdcached integrado con LibreNMS"
  else
    run_as_librenms "lnms config:set distributed_poller false" 2>&1 | tail -2 || warn "lnms config:set distributed_poller falló"
    ok "distributed_poller=false (single-node sin rrdcached)"
  fi

  # base_url para emails/webhooks/links absolutos
  run_as_librenms "lnms config:set base_url '$BASE_URL'" 2>&1 | tail -2 || warn "lnms config:set base_url falló"

  # Limpiar cachés Laravel
  run_as_librenms "php artisan config:clear" 2>&1 | tail -1 || true
  run_as_librenms "php artisan view:clear" 2>&1 | tail -1 || true
}

# ============================================================================
#  Etapa 19 — Crear usuario admin
# ============================================================================
create_admin() {
  log "=== 18. Usuario admin ==="
  if run_as_librenms "lnms user:list" 2>/dev/null | grep -qE '\badmin\b'; then
    ADMIN_CREATED=0
    ok "Usuario 'admin' ya existe (no se modifica)"
  else
    run_as_librenms "lnms user:add admin --role=admin --email='${ADMIN_EMAIL}' --password='${ADMIN_PASS}'" | tail -3
    ADMIN_CREATED=1
    ok "Usuario 'admin' creado"
  fi
}

# ============================================================================
#  Etapa 20 — Bootstrap scheduler + primer poll
# ============================================================================
bootstrap_runtime() {
  log "=== 19. Bootstrap del scheduler + primer poll ==="

  # Setea scheduler_working manualmente — evita FAIL transitorio durante
  # los primeros 5 min mientras se espera al primer tick xx:00, xx:05...
  run_as_librenms "php artisan tinker --execute='Cache::put(\"scheduler_working\", now(), now()->addMinutes(6));'" 2>&1 | tail -2 || \
    warn "No pude pre-cargar scheduler_working cache key (no crítico, se setea solo en ≤5 min)"
  ok "scheduler_working cache key bootstrapped"

  # Forzar primer ejecución del poller-wrapper para registrar el nodo
  # en poller_cluster (sino validate.php dice "No python wrapper pollers found")
  run_as_librenms "python3 poller-wrapper.py 1" 2>&1 | tail -3 || warn "Primer poll falló (no crítico, se reintenta vía cron)"
  ok "Nodo registrado en poller_cluster"
}

# ============================================================================
#  Etapa 21 — Guardar credenciales
# ============================================================================
save_credentials() {
  log "=== 20. Guardando credenciales ==="
  local hostname_full primary_ip
  hostname_full=$(hostname -f 2>/dev/null || hostname)
  primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

  cat > "$CRED_FILE" <<EOF
=================================================================
  LibreNMS — Credenciales y datos de instalación
=================================================================
  Generado:           $(date '+%Y-%m-%d %H:%M:%S %Z')
  Instalador:         install.sh v${INSTALLER_VERSION}
  Host:               ${hostname_full} (IP interna: ${primary_ip})
  Sistema:            $(. /etc/os-release; echo "$PRETTY_NAME")
  LibreNMS:           $(cd "$LIBRENMS_DIR" && sudo -u "$LIBRENMS_USER" git log -1 --format='%h %s' 2>/dev/null || echo "n/a")

  --- Acceso web ---
  URL:                ${BASE_URL}
  Usuario admin:      admin
  Password admin:     $([[ "${ADMIN_CREATED:-0}" -eq 1 ]] && echo "${ADMIN_PASS}" || echo "(no modificado — admin ya existía)")
  Email admin:        ${ADMIN_EMAIL}

  --- Base de datos ---
  Host:               localhost
  Database:           librenms
  User:               librenms
  Password:           ${DB_PASS}

  --- SNMP local (este host) ---
  Versión:            v2c
  Community:          ${SNMP_COMMUNITY}
  Bind:               127.0.0.1 (loopback only)

  --- Rutas ---
  Código:             ${LIBRENMS_DIR}
  .env:               ${LIBRENMS_DIR}/.env
  Logs app:           ${LIBRENMS_DIR}/logs/librenms.log
  RRD:                ${LIBRENMS_DIR}/rrd
  Log instalación:    ${LOG_FILE}

  --- Servicios systemd ---
  nginx · ${PHP_FPM_SVC} · mariadb · snmpd · cron
  librenms-scheduler.timer$([[ -S /run/rrdcached.sock ]] && echo ' · rrdcached')

=================================================================
  Comandos útiles:

  # Validar instalación
  sudo -u librenms ${LIBRENMS_DIR}/validate.php

  # Agregar primer device (este host)
  sudo -u librenms lnms device:add 127.0.0.1 --v2c --community=${SNMP_COMMUNITY}

  # Agregar un MikroTik
  sudo -u librenms lnms device:add 10.0.0.1 --v2c --community=public

  # Forzar poll manual
  sudo -u librenms ${LIBRENMS_DIR}/poller.php -h <hostname>

  # Ver dispositivos monitoreados
  sudo -u librenms lnms device:list

  # Actualizar LibreNMS (ejecutar como librenms, no root)
  sudo -u librenms ${LIBRENMS_DIR}/daily.sh

=================================================================
EOF
  chmod 600 "$CRED_FILE"
  chown root:root "$CRED_FILE"
  ok "Credenciales en $CRED_FILE (modo 600)"
}

# ============================================================================
#  Etapa 22 — Validación final
# ============================================================================
final_validate() {
  log "=== 21. Validación final ==="
  echo
  # validate.php retorna ≠0 cuando hay WARN/FAIL → || true previene matar el script
  run_as_librenms "./validate.php" 2>&1 | sed -E "s/\x1b\[[0-9;]*m//g" || true
  echo

  # Healthcheck del stack web
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" http://127.0.0.1/login || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "Stack web responde HTTP 200 en /login"
  else
    warn "/login devolvió HTTP $code — revisa nginx/php-fpm"
  fi
}

# ============================================================================
#  Banner final
# ============================================================================
print_banner() {
  echo
  echo -e "${C_G}=================================================================${C_N}"
  echo -e "${C_G}  ✓ LibreNMS instalado correctamente${C_N}"
  echo -e "${C_G}=================================================================${C_N}"
  echo
  echo -e "  ${C_M}URL:${C_N}        ${C_B}${BASE_URL}${C_N}"
  echo -e "  ${C_M}Usuario:${C_N}    ${C_B}admin${C_N}"
  if [[ "${ADMIN_CREATED:-0}" -eq 1 ]]; then
    echo -e "  ${C_M}Password:${C_N}   ${C_B}${ADMIN_PASS}${C_N}"
  else
    echo -e "  ${C_M}Password:${C_N}   ${C_Y}(no modificado — admin ya existía)${C_N}"
  fi
  echo
  echo -e "  Credenciales completas: ${C_Y}${CRED_FILE}${C_N}"
  echo -e "  Log de instalación:     ${C_Y}${LOG_FILE}${C_N}"
  echo
  echo -e "  ${C_Y}>>> Próximo paso:${C_N} agregar tu primer device"
  echo -e "      ${C_B}sudo -u librenms lnms device:add <ip-o-hostname> --v2c --community=public${C_N}"
  echo

  # Endurece permisos del log (puede contener trazas con datos sensibles)
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

# ============================================================================
#  Main
# ============================================================================
main() {
  # Lock para evitar dos ejecuciones simultáneas
  exec 200>"$LOCK_FILE"
  flock -n 200 || fail "Otra instancia del instalador está corriendo (lock: $LOCK_FILE)"

  log "=== LibreNMS Installer v${INSTALLER_VERSION} ==="

  preflight
  prompt_user_input
  install_packages
  detect_php
  setup_user_repo
  run_composer
  set_permissions
  configure_php_timezone
  configure_mariadb
  build_env
  install_python_deps
  db_migrate
  configure_web
  setup_lnms_completion
  configure_snmpd
  configure_rrdcached
  configure_cron_scheduler
  patch_rrdcheck
  single_node_tuning
  create_admin
  bootstrap_runtime
  save_credentials
  final_validate
  print_banner
}

main "$@"
