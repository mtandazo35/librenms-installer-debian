# LibreNMS Installer — Debian 12 / 13

Instalador automatizado, idempotente y autocorrectivo de **LibreNMS** para servidores Debian 12 (bookworm) y Debian 13 (trixie).

Diseñado para VPS detrás de NAT (MikroTik, OPNsense, Cloudflare Tunnel, etc.) y para hosts con IP pública directa. Deja `validate.php` **completamente verde** al primer intento, sin FAILs transitorios.

---

## ¿Qué hace este instalador?

Instala y configura el stack completo de LibreNMS en una sola corrida:

- **nginx** con vhost catch-all (`server_name _`) + **PHP-FPM** (pool dedicado, socket Unix)
- **MariaDB** con DB y usuario `librenms` (contraseña aleatoria de 24 chars)
- **rrdcached** con socket Unix `/run/rrdcached.sock` (corre como user librenms)
- **snmpd** local con community parametrizable (bind 127.0.0.1)
- **Cron** de polling clásico (`/etc/cron.d/librenms`) — el polling SNMP real
- **librenms-scheduler.timer** — tareas Laravel (alertas, cleanup)
- **logrotate** para los logs de la app
- Genera usuario admin web con contraseña aleatoria
- Pre-carga la cache key del scheduler → validate.php sale verde al toque
- Aplica un **patch local** al bug upstream de `RrdCheck.php` para que la página `/validate` del web UI no falle

Al final guarda todas las credenciales en `/root/librenms-credenciales.txt` (modo 600).

---

## Tabla de fixes integrados

Este instalador resuelve por defecto **todos** los errores típicos que aparecen al seguir la guía oficial paso a paso:

| Problema | Solución integrada |
|---|---|
| `FAIL: Scheduler is not running` (los primeros minutos) | Bootstrap manual del cache key `scheduler_working` al final del install |
| `FAIL: No python wrapper pollers found` | Genera `NODE_ID` aleatorio en `.env` (sin esto, `poller-wrapper.py` falla silencioso) |
| `FAIL: You have not enabled rrdcached` | Instala y configura `rrdcached` con socket Unix + `lnms config:set rrdcached unix:/run/rrdcached.sock` |
| `WARN: Distributed Polling enabled` sin querer | Tuning automático según si rrdcached está disponible |
| `RRD Check: Failed to fetch validation results` (web UI) | Parche local de `RrdCheck.php` envolviendo los `echo` con `app()->runningInConsole()` |
| `WARN: Your local git contains modified files` | `git update-index --skip-worktree` sobre el archivo parchado |
| `dubious ownership in repository` | `git config --system --add safe.directory /opt/librenms` |
| `cron` package missing en Debian 13 cloud | Install explícito + `systemctl is-active cron` check |
| `/etc/cron.d/librenms` ignorado por cron | Force `chown root:root && chmod 644` post-cp |
| PHP-FPM 502 (`listen.owner` missing en Debian 13) | Append explícito si los `sed` upstream no aplican |
| Pool `www` default desperdiciando workers | `mv www.conf www.conf.disabled` |
| Acceso vía NAT con puerto distinto a :80 (ej `:8087`) | `server_name _` (catch-all) + `APP_URL` con puerto correcto |

---

## Requisitos

- **OS:** Debian 12 (bookworm) o Debian 13 (trixie). Recién instalado o limpio.
- **Acceso:** root (vía `sudo` o login directo).
- **Recursos mínimos:** 2 GB RAM, 20 GB disco, 1 vCPU. Recomendado para >100 devices: 4 GB RAM.
- **Red:** acceso saliente a `github.com`, `packagist.org`, `repo.librenms.org` (apt repos), `pypi.org`.
- **MariaDB:** se asume instalación limpia con `unix_socket` auth para root (default en Debian).

---

## Quick start

```bash
# 1. Clonar este repo en tu VPS
git clone https://github.com/<tu-user>/librenms-installer-debian.git
cd librenms-installer-debian

# 2. Correr el instalador (modo interactivo: te pregunta el BASE_URL)
sudo bash install.sh

# 3. O modo no-interactivo con todas las variables
sudo BASE_URL=http://1.2.3.4:8087 \
     ADMIN_EMAIL=tu@correo.com \
     TIMEZONE=America/Guayaquil \
     bash install.sh
```

Al finalizar verás:

```
=================================================================
  ✓ LibreNMS instalado correctamente
=================================================================

  URL:        http://1.2.3.4:8087
  Usuario:    admin
  Password:   <generado-aleatorio-20-chars>

  Credenciales completas: /root/librenms-credenciales.txt
  Log de instalación:     /var/log/librenms-install.log
```

---

## Variables de entorno

Todas son opcionales. Si no se proveen, el script las genera o las pregunta.

| Variable | Default | Descripción |
|---|---|---|
| `BASE_URL` | (interactivo) | URL pública por la que se accede al web UI. Ej: `http://200.1.2.3:8087` |
| `ADMIN_EMAIL` | `admin@<dominio>` | Email del usuario admin inicial |
| `ADMIN_PASS` | (random 20 chars) | Password del usuario admin. Si no se provee se genera |
| `TIMEZONE` | `America/Guayaquil` | Zona horaria del sistema y de PHP |
| `SNMP_COMMUNITY` | `librenms_local` | Community v2c del snmpd local |
| `SKIP_RRDCACHED` | `no` | `yes`/`true` para no instalar rrdcached |
| `SKIP_RRDCHECK_PATCH` | `no` | `yes`/`true` para no parchar `RrdCheck.php` (el web UI mostrará error en RRD Check) |

---

## Acceso al panel web

1. Abre `http://<tu-base-url>` en el navegador.
2. Login: `admin` + el password que muestra el banner final (o lee `/root/librenms-credenciales.txt`).
3. Cambia el password en `User → Preferences` apenas entres.

### Acceso detrás de NAT (MikroTik / OPNsense)

El instalador usa `server_name _` (catch-all) en nginx, así que funciona con cualquier Host header. Solo necesitas que tu firewall haga port-forward del puerto público que elijas → `<ip-privada-del-vps>:80`.

Ejemplo MikroTik (forward de puerto público 8087 → VPS 10.0.0.50:80):

```
/ip firewall nat add chain=dstnat protocol=tcp dst-port=8087 \
    action=dst-nat to-addresses=10.0.0.50 to-ports=80
```

Y al correr el instalador: `BASE_URL=http://<tu-ip-pública>:8087`

---

## Validar que está funcionando

### Desde CLI

```bash
sudo -u librenms /opt/librenms/validate.php
```

Debería mostrar todo `[OK]`, ningún `[WARN]` ni `[FAIL]`.

### Desde el web UI

`http://<tu-base-url>/validate` — todas las secciones deben estar en verde.

---

## Agregar tu primer device

### Vía CLI

```bash
# El host local (loopback) usando el snmpd que ya está corriendo
sudo -u librenms lnms device:add 127.0.0.1 --v2c --community=librenms_local

# Un MikroTik / switch / router
sudo -u librenms lnms device:add 10.0.0.1 --v2c --community=public

# Listar devices
sudo -u librenms lnms device:list
```

### Vía web UI

`Devices → Add Device` desde el menú superior.

---

## Troubleshooting

### "El instalador falló en línea X"

El log completo queda en `/var/log/librenms-install.log`. Búscalo allí — la línea anterior al error suele tener la causa real.

### `mysql -uroot falló`

MariaDB tiene un password de root configurado. En Debian limpio NO debería ser el caso (usa `unix_socket` auth). Si tienes un password de root previo, edítalo manualmente y vuelve a correr.

### El web UI sigue con `RRD Check: Failed to fetch`

Posibles causas:
1. Tu navegador cacheó la respuesta vieja → `Ctrl+Shift+R` para recargar duro.
2. El parche no se aplicó (corre `grep -c runningInConsole /opt/librenms/LibreNMS/Validations/RrdCheck.php` — debe ser ≥ 1).
3. PHP-FPM no recargó el opcache → `sudo systemctl reload php8.2-fpm` (o 8.4 en Debian 13).

### `FAIL: Scheduler is not running` después de instalar

Si pasaron menos de 5 minutos desde el install, espera hasta el próximo tick de minuto múltiplo de 5 (xx:00, xx:05, xx:10...). El instalador pre-carga el cache key pero si tu reloj no estaba sincronizado, puede haberse seteado mal.

Forzar manualmente:
```bash
sudo -u librenms bash -c "cd /opt/librenms && \
    php artisan tinker --execute='Cache::put(\"scheduler_working\", now(), now()->addMinutes(6));'"
```

### Re-ejecutar el instalador

El script es **idempotente** — puedes re-correrlo sin romper la instalación. Cada paso detecta si ya está hecho y lo salta o lo actualiza. Útil después de un upgrade de Debian o si moviste el VPS de IP.

### Actualizar LibreNMS

```bash
sudo -u librenms /opt/librenms/daily.sh
```

El parche de `RrdCheck.php` está protegido con `skip-worktree` → los updates upstream no lo rompen, y tampoco se aplicarían cambios upstream sobre él. Cuando upstream merge el fix:

```bash
sudo -u librenms git -C /opt/librenms update-index --no-skip-worktree LibreNMS/Validations/RrdCheck.php
sudo -u librenms git -C /opt/librenms checkout -- LibreNMS/Validations/RrdCheck.php
sudo -u librenms /opt/librenms/daily.sh
```

---

## Arquitectura final del stack

```
┌─────────────────────────────────────────────────────────────────┐
│                     Internet / LAN                              │
└──────────────────────┬──────────────────────────────────────────┘
                       │ Host header cualquiera
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  nginx :80    (server_name _, catch-all)                        │
│  └── FastCGI → /run/php-fpm-librenms.sock                       │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  php-fpm (pool 'librenms', user/group librenms)                 │
│  └── /opt/librenms/html/* (Laravel app)                         │
└──────────────────────┬──────────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┬──────────────┐
        ▼              ▼              ▼              ▼
   ┌─────────┐    ┌─────────┐    ┌──────────┐   ┌──────────┐
   │ MariaDB │    │  RRDs   │    │ rrdcached│   │ snmpd    │
   │ :3306   │    │ /opt/   │◄───┤ Unix sock│   │ :161 udp │
   │ localh. │    │ librenms│    │ writes   │   │ localh.  │
   └─────────┘    │ /rrd    │    └──────────┘   └──────────┘
                  └─────────┘

  cron (/etc/cron.d/librenms)
   ├─ */5  → poller-wrapper.py (poll SNMP de devices)
   ├─ */6h → discovery-wrapper.py
   ├─ *    → alerts.php
   └─ 0:19 → daily.sh (updates + mantenimiento)

  systemd timer (librenms-scheduler.timer, cada minuto)
   └─ php artisan schedule:run (housekeeping Laravel)
```

---

## Cosas que el instalador NO hace (a propósito)

- **TLS / HTTPS**: si necesitas, agrega `certbot --nginx -d tu.fqdn.com` después del install (requiere FQDN público y DNS apuntando al server).
- **Firewall**: no configura ufw/nftables. Configúralo según tu necesidad.
- **fail2ban**: no se instala. Recomendado para servidores expuestos.
- **Redis para queue/cache**: no se configura. Útil solo a partir de >500 devices o en cluster.
- **Dispatcher Service**: la doc oficial lo recomienda para distributed polling. Single-node funciona perfecto con cron + scheduler timer.
- **Backup automatizado**: no se configura. Considera `mariadb-backup` o `mysqldump` periódico de la DB `librenms` + tarball del dir `/opt/librenms/rrd`.

---

## Contribuir

PRs bienvenidos. Si encuentras un escenario donde el script falla:

1. Abre un issue con: salida de `/etc/os-release`, output relevante de `/var/log/librenms-install.log`, y `sudo -u librenms /opt/librenms/validate.php`.
2. Si es un bug del upstream LibreNMS y el script lo workaround-ea: deja una línea en la tabla de fixes de este README.

---

## Licencia

MIT — ver [LICENSE](LICENSE).

---

## Créditos

Basado en la [doc oficial de LibreNMS](https://docs.librenms.org/Installation/Install-LibreNMS/) más workarounds descubiertos en deployments reales (junio 2026).
