# swarmup.sh

A single script to deploy web applications to a Docker Swarm cluster using [Traefik](https://traefik.io) for routing and SSL, and [Gum](https://github.com/charmbracelet/gum) for interactive prompts.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/xuannghia/swarm-up/main/bin/swarmup.sh \
  -o /tmp/swarmup.sh && \
  sudo mv /tmp/swarmup.sh /usr/local/bin/swarmup && \
  sudo chmod +x /usr/local/bin/swarmup
```

Then run from anywhere:

```bash
swarmup setup
```

## Requirements

- Fresh, secure Ubuntu/Debian or Arch Linux server
- `curl` and `sudo` available
- Port 80 and 443 open (for Traefik and Let's Encrypt)

## Typical Workflow

```
setup → create → start → update → stop → remove
```

1. **`setup`** — once per server
2. **`create`** — once per service, scaffolds files
3. **`start`** — deploy the service to the Swarm
4. **`update`** — rotate secrets and rolling-restart
5. **`stop`** — take the service offline (files preserved)
6. **`remove`** — permanently delete service, secret, and files

---

## Commands

### `setup`

```bash
swarmup setup
```

Run once on a fresh server. Idempotent — safe to re-run.

- Installs Gum and Docker if missing (distro-aware: apt for Ubuntu/Debian, pacman for Arch)
- Initializes Docker Swarm
- Creates two overlay networks: `traefik-public` and `app-network`
- Prompts for a Let's Encrypt email and deploys Traefik at `~/traefik/docker-compose.yml`

---

### `create`

```bash
swarmup create <service-name> <image-name> [--replicas N] [--domain DOMAIN]
```

Scaffolds `~/apps/<service-name>/` with a `docker-compose.yml` and an empty `secrets` file. Does **not** deploy — run `start` when ready.

| Option | Default | Description |
|---|---|---|
| `--replicas N` | `1` | Number of Swarm replicas |
| `--domain DOMAIN` | _(none)_ | Public domain for Traefik routing |

**With `--domain`:** attaches to both `traefik-public` and `app-network`, adds Traefik labels, prompts for the container port. Traefik handles HTTPS via Let's Encrypt automatically.

**Without `--domain`:** attaches to `app-network` only (internal service, not publicly routed).

Both variants include rolling-update and auto-rollback configuration:

```yaml
update_config:
  order: start-first       # new container starts before old one stops
  failure_action: rollback # auto-rollback if the update fails
rollback_config:
  order: stop-first
```

After scaffolding, populate `~/apps/<service-name>/secrets` with `KEY=VALUE` pairs before running `start`.

---

### `start`

```bash
swarmup start <service-name>
```

- Creates a Docker secret from `~/apps/<service-name>/secrets`
- Deploys the stack to the Swarm

The secret is mounted inside the container at `/run/secrets/<service-name>_secrets`. The application reads it directly from that path.

---

### `update`

```bash
swarmup update <service-name>
```

- Removes the old Docker secret and creates a new one from the current `secrets` file
- Redeploys the stack — Docker Swarm performs a rolling update automatically

---

### `stop`

```bash
swarmup stop <service-name>
```

Removes the service from the Swarm (`docker stack rm`). The `~/apps/<service-name>/` folder and Docker secret are preserved — run `start` to bring it back up.

---

### `remove`

```bash
swarmup remove <service-name>
```

Permanently removes the service. Prompts for confirmation, then:

- Removes the stack from the Swarm
- Deletes the Docker secret
- Deletes `~/apps/<service-name>/`
