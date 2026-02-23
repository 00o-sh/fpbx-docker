# fpbx-docker

Containerised [FreePBX](https://www.freepbx.org/) 17 with Asterisk 22 on Debian Bookworm.
Ships as a single image that works with both Docker Compose and Kubernetes.

```
ghcr.io/00o-sh/fpbx-docker:17
```

## Quick start (Docker Compose)

```bash
git clone https://github.com/00o-sh/fpbx-docker.git
cd fpbx-docker
docker compose up -d
```

FreePBX will be available at `http://localhost` once the entrypoint finishes (first boot takes a few minutes while the database schema is imported). MariaDB credentials default to what is defined in `docker-compose.yml` -- change them before running in production.

## Environment variables

All database connection settings are configured via environment variables.
The entrypoint writes them into `/etc/freepbx.conf`, `/etc/odbc.ini`, and the `freepbx_settings` database table on every start.

| Variable | Default | Description |
|---|---|---|
| `DB_HOST` | `db` | MariaDB hostname or service address |
| `DB_PORT` | `3306` | MariaDB port |
| `DB_USER` | `freepbx` | Database user |
| `DB_PASS` | `freepbx` | Database password |
| `DB_NAME` | `asterisk` | Primary FreePBX database name |
| `DB_CDR_NAME` | `asteriskcdrdb` | CDR/CEL database name |

## Image contents

| Component | Version |
|---|---|
| Debian | Bookworm (slim) |
| Asterisk | 22 (Sangoma packages) |
| FreePBX | 17 |
| PHP | 8.2 + IonCube |
| Apache | 2.x (runs as `asterisk` user) |
| MariaDB client | 10.x |
| Redis | For FreePBX session/cache |
| Fail2ban | Asterisk filter, 1-week ban |
| Postfix | Local MTA for voicemail-to-email |

## How it works

### Build phase (`Dockerfile` + `build-freepbx.sh`)

1. Installs Asterisk 22 and all runtime dependencies from the Sangoma repository
2. Spins up a **temporary** MariaDB inside the build container
3. Installs the `freepbx17` Debian package (which runs its own `postinst` against the temp DB)
4. Removes unlicensed commercial modules, installs open-source modules
5. Dumps the resulting `asterisk` and `asteriskcdrdb` schemas to `/usr/local/src/*.sql` (with `DEFINER` clauses stripped so a non-SUPER user can import them)
6. Removes the temporary MariaDB server from the image
7. Snapshots `/etc/asterisk` and `/var/lib/asterisk` to `-defaults` directories (used to seed empty PVC mounts in Kubernetes)

### Runtime phase (`entrypoint.sh`)

```
init_volumes     Seed empty PVC mounts from build-time defaults
      |
wait_for_db      Poll MariaDB until it responds (up to 120 s)
      |
configure_db     Write /etc/freepbx.conf and /etc/odbc.ini from env vars
      |
init_db          First-run only: import SQL dumps into the external DB
      |
sync_db_settings Update freepbx_settings table to match env vars
      |
start_services   cron, Redis, Postfix, FreePBX (fwconsole), Fail2ban, Apache
```

The shell process stays as PID 1 and traps `SIGTERM`/`SIGINT` for graceful shutdown (stops services in reverse order).

### Why `sync_db_settings` exists

FreePBX's PHP bootstrap loads settings from the `freepbx_settings` database table, and those values **override** anything set in `/etc/freepbx.conf`. The SQL dump imported at first run contains the build-time defaults (e.g. `CDRDBNAME=asteriskcdrdb`). If `DB_CDR_NAME` is set to something different at runtime (common in multi-tenant Kubernetes deployments), the file-based config is correct but the database-stored setting wins, causing CDR/CEL connection failures.

`sync_db_settings` runs on every container start and UPDATEs the `CDRDBNAME`, `CDRDBHOST`, `CDRDBPORT`, `CDRDBUSER`, `CDRDBPASS`, and `CDRDBTYPE` rows in `freepbx_settings` to match the environment variables.

## Volumes

| Mount path | Purpose |
|---|---|
| `/etc/asterisk` | Asterisk & FreePBX configuration files |
| `/var/lib/asterisk` | FreePBX modules, sounds, AGI scripts, `fwconsole` |
| `/var/spool/asterisk` | Voicemail, recordings, monitor |
| `/var/log/asterisk` | Asterisk & FreePBX logs |

On first boot with empty mounts (fresh PVCs in Kubernetes), the entrypoint copies build-time defaults into the volumes automatically.

## Exposed ports

| Port | Protocol | Service |
|---|---|---|
| 80 | TCP | HTTP (FreePBX GUI) |
| 443 | TCP | HTTPS |
| 5060 | UDP/TCP | SIP signalling |
| 5061 | TCP | SIP TLS |
| 8001 | TCP | UCP (User Control Panel) |
| 8003 | TCP | Admin |
| 10000-20000 | UDP | RTP media |

## Kubernetes deployment

Reference manifests are provided in [`k8s/`](k8s/).

### Prerequisites

- [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) installed in the cluster
- Secrets created for MariaDB root and user passwords

```bash
kubectl create secret generic freepbx-mariadb-root \
  --from-literal=password='<root-password>'
kubectl create secret generic freepbx-mariadb-password \
  --from-literal=password='<user-password>'
```

### Apply the database

```bash
kubectl apply -f k8s/mariadb.yaml
```

This creates a MariaDB instance, the `asteriskcdrdb` database, and grants the `freepbx` user access to both databases.

### Deploy FreePBX

The Helm values file uses [bjw-s/app-template](https://github.com/bjw-s/helm-charts):

```bash
helm repo add bjw-s https://bjw-s.github.io/helm-charts
helm install freepbx bjw-s/app-template -f k8s/values.yaml
```

The values file configures host networking (required for SIP/RTP NAT traversal), persistent volume claims, health probes, and all `DB_*` environment variables.

### Multi-tenant / custom database names

To use non-default database names (e.g. `b1_asterisk` / `b1_asteriskcdrdb` for tenant isolation), set the env vars in your Helm values or pod spec:

```yaml
env:
  DB_HOST: mariadb-primary.database.svc.cluster.local
  DB_USER: freepbx_b1
  DB_NAME: b1_asterisk
  DB_CDR_NAME: b1_asteriskcdrdb
  DB_PASS:
    valueFrom:
      secretKeyRef:
        name: freepbx-secret
        key: DB_PASS
```

The entrypoint handles all configuration -- no manual SQL or FreePBX GUI changes needed.

## CI/CD

### PR workflow (`.github/workflows/build-and-push.yml`)

On every pull request:
1. Builds the image with `docker compose build`
2. Starts the full stack (FreePBX + MariaDB)
3. Waits for the entrypoint to complete
4. Runs smoke tests: verifies `freepbx_settings` table exists and Apache returns HTTP 200
5. Tears down the stack

On merge to `main` or tag push: builds and pushes to GHCR with `latest`, `17`, semver, and SHA tags.

### Scheduled builds (`.github/workflows/scheduled-builds.yml`)

| Cadence | Tags | Description |
|---|---|---|
| Nightly (3 AM UTC) | `17-nightly`, `17-nightly-YYYYMMDD` | Full rebuild + smoke test |
| Weekly (Monday 5 AM UTC) | `17-weekly`, `17-weekly-YYYYWWW` | Promotes tested nightly |
| Monthly (1st, 7 AM UTC) | `17-stable`, `17-stable-YYYYMM` | Promotes tested weekly |

All scheduled builds can also be triggered manually via `workflow_dispatch`.

## Security

- **Fail2ban** is enabled with an Asterisk filter that monitors `/var/log/asterisk/full` for SIP registration failures, authentication errors, and ACL violations. Default: 3 retries in 60 seconds = 1-week ban.
- **Apache** runs as the `asterisk` user with `ServerTokens Prod` and `ServerSignature Off`.
- **PHP** has `expose_php = Off`.
- The container requires `NET_ADMIN` capability for iptables (Fail2ban + FreePBX firewall module).

## License

FreePBX is licensed under the GPLv3 by Sangoma Technologies. Asterisk is licensed under the GPLv2 by Sangoma Technologies. This repository contains only the Dockerfile, build scripts, and deployment configuration.
