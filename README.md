# swarmup.sh

A single script to deploy web applications to a Docker Swarm cluster using [Traefik](https://traefik.io) for routing and SSL, and [Gum](https://github.com/charmbracelet/gum) for interactive prompts.

## Installation

```bash
curl -fsSL https://github.com/xuannghia/swarm-up/raw/refs/heads/main/bin/swarmup.sh \
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

## Example

Test your setup locally using `traefik/whoami` on `example.swarm.localhost`:

```bash
# 1. Scaffold the service
swarmup create whoami traefik/whoami --domain example.swarm.localhost

# 2. Deploy it
swarmup start whoami

# 3. Test (skip TLS verification for self-signed cert)
curl -k https://example.swarm.localhost
```

You should see a response from the whoami container with request headers and IP info.

> **Using a real domain?** Point your domain's DNS A record to the VPS IP before running `start` — Traefik requests a Let's Encrypt certificate immediately on deploy and will fail if DNS isn't resolving yet.
>
> **DNSSEC enabled?** Ensure the DS records are correctly configured at your registrar — a misconfiguration will cause Let's Encrypt's DNS validation to fail.

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
swarmup update <service-name> [--image IMAGE] [--replicas N]
```

- Rotates the Docker secret from the current `secrets` file
- Performs a rolling update via `docker service update`
- Optionally overrides the image or replica count for this update

| Option | Description |
|---|---|
| `--image IMAGE` | Switch to a different image (e.g. `nginx:1.27`) |
| `--replicas N` | Scale the service up or down |

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
