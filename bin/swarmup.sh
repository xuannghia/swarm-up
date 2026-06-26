#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_gum_available() { command -v gum &>/dev/null; }

info()    { if _gum_available; then gum style --foreground 33 "  $*"; else echo "[info] $*"; fi; }
success() { if _gum_available; then gum style --foreground 82 "  $*"; else echo "[ok]   $*"; fi; }
error()   { if _gum_available; then gum style --foreground 196 "  $*" >&2; else echo "[err]  $*" >&2; fi; }

die() { error "$*"; exit 1; }

require_gum() {
  _gum_available || die "gum is required. Run: ./swarmup.sh setup"
}

require_swarm() {
  local state
  state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)
  [[ "$state" == "active" ]] || die "Docker Swarm is not active. Run: ./swarmup.sh setup"
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

usage() {
  cat <<EOF
Usage: swarmup.sh <command> [args]

Commands:
  setup                                          Install deps, init Swarm, deploy Traefik
  create <service> <image> [--replicas N] [--domain DOMAIN]
                                                 Scaffold service folder and compose file
  start <service>                                Create secret and deploy service to Swarm
  update <service>                               Rotate secrets and rolling-update a service
  stop <service>                                 Remove service from Swarm (keeps files)
  remove <service>                               Tear down service, secret, and files
EOF
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

cmd_setup() {
  local distro
  distro=$(detect_distro)

  # -- Gum ----------------------------------------------------------------
  if ! _gum_available; then
    info "Installing gum..."
    case "$distro" in
      ubuntu|debian)
        sudo apt-get update -qq
        sudo apt-get install -y gpg curl
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key \
          | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
          | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y gum
        ;;
      arch)
        sudo pacman -S --noconfirm gum
        ;;
      *)
        die "Cannot auto-install gum on '$distro'. Install manually: https://github.com/charmbracelet/gum"
        ;;
    esac
    success "gum installed."
  else
    success "gum already installed."
  fi

  # -- Docker -------------------------------------------------------------
  if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    case "$distro" in
      ubuntu|debian)
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "$USER"
        info "Docker installed. Re-login (or run 'newgrp docker') for group membership to take effect."
        ;;
      arch)
        sudo pacman -S --noconfirm docker
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
        info "Docker installed. Re-login (or run 'newgrp docker') for group membership to take effect."
        ;;
      *)
        die "Cannot auto-install Docker on '$distro'. Install manually: https://docs.docker.com/engine/install/"
        ;;
    esac
    success "Docker installed."
  else
    success "Docker already installed."
  fi

  # -- Swarm init ---------------------------------------------------------
  local swarm_state
  swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)
  if [[ "$swarm_state" != "active" ]]; then
    info "Initializing Docker Swarm..."
    local advertise_addr
    advertise_addr=$(hostname -I | awk '{print $1}')
    docker swarm init --advertise-addr "$advertise_addr"
    success "Swarm initialized (advertise-addr: $advertise_addr)."
  else
    success "Swarm already active."
  fi

  # -- Overlay networks ---------------------------------------------------
  for net in traefik-public app-network; do
    if [[ -z "$(docker network ls --filter name="^${net}$" --format '{{.Name}}' 2>/dev/null)" ]]; then
      info "Creating overlay network: $net"
      docker network create --driver overlay "$net"
      success "Network '$net' created."
    else
      success "Network '$net' already exists."
    fi
  done

  # -- Traefik ------------------------------------------------------------
  if [[ -n "$(docker service ls --filter name=traefik_traefik --format '{{.Name}}' 2>/dev/null)" ]]; then
    success "Traefik already deployed."
    return
  fi

  info "Configuring Traefik..."
  local acme_email
  acme_email=$(gum input --placeholder "your@email.com" --prompt "ACME email for Let's Encrypt: ")
  [[ -n "$acme_email" ]] || die "ACME email is required."

  mkdir -p ~/traefik

  cat > ~/traefik/docker-compose.yml <<EOF
version: "3.8"
services:
  traefik:
    image: traefik:v3.0
    command:
      - --providers.docker
      - --providers.docker.swarmMode=true
      - --providers.docker.exposedByDefault=false
      - --providers.docker.network=traefik-public
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.letsencrypt.acme.email=${acme_email}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik-letsencrypt:/letsencrypt
    networks:
      - traefik-public
    deploy:
      placement:
        constraints:
          - node.role == manager
volumes:
  traefik-letsencrypt:
networks:
  traefik-public:
    external: true
EOF

  info "Deploying Traefik..."
  docker stack deploy -c ~/traefik/docker-compose.yml traefik
  success "Traefik deployed."
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

cmd_create() {
  require_gum

  local service_name="${1:-}"
  local image_name="${2:-}"
  [[ -n "$service_name" ]] || die "Usage: swarmup.sh create <service> <image> [--replicas N] [--domain DOMAIN]"
  [[ -n "$image_name" ]]   || die "Usage: swarmup.sh create <service> <image> [--replicas N] [--domain DOMAIN]"
  shift 2

  local replicas=1
  local domain=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --replicas) replicas="${2:?--replicas requires a value}"; shift 2 ;;
      --domain)   domain="${2:?--domain requires a value}"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local service_dir=~/apps/"$service_name"
  local secret_name="${service_name}_secrets"
  mkdir -p "$service_dir"

  # Create empty secrets file if not present
  if [[ ! -f "$service_dir/secrets" ]]; then
    touch "$service_dir/secrets"
    info "Created empty secrets file at $service_dir/secrets"
  fi

  # Compose file
  if [[ -n "$domain" ]]; then
    local port
    port=$(gum input --placeholder "8080" --prompt "Container port for Traefik routing: ")
    [[ -n "$port" ]] || die "Container port is required when --domain is set."

    cat > "$service_dir/docker-compose.yml" <<EOF
version: "3.8"
services:
  ${service_name}:
    image: ${image_name}
    secrets:
      - ${secret_name}
    networks:
      - traefik-public
      - app-network
    deploy:
      replicas: ${replicas}
      update_config:
        order: start-first
        failure_action: rollback
      rollback_config:
        order: stop-first
      labels:
        - traefik.enable=true
        - traefik.http.routers.${service_name}.rule=Host(\`${domain}\`)
        - traefik.http.routers.${service_name}.entrypoints=websecure
        - traefik.http.routers.${service_name}.tls.certresolver=letsencrypt
        - traefik.http.services.${service_name}.loadbalancer.server.port=${port}
secrets:
  ${secret_name}:
    external: true
networks:
  traefik-public:
    external: true
  app-network:
    external: true
EOF
  else
    cat > "$service_dir/docker-compose.yml" <<EOF
version: "3.8"
services:
  ${service_name}:
    image: ${image_name}
    secrets:
      - ${secret_name}
    networks:
      - app-network
    deploy:
      replicas: ${replicas}
      update_config:
        order: start-first
        failure_action: rollback
      rollback_config:
        order: stop-first
secrets:
  ${secret_name}:
    external: true
networks:
  app-network:
    external: true
EOF
  fi

  success "Service '$service_name' scaffolded at $service_dir"
  info "Edit $service_dir/secrets then run: ./swarmup.sh start $service_name"
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

cmd_start() {
  require_gum
  require_swarm

  local service_name="${1:-}"
  [[ -n "$service_name" ]] || die "Usage: swarmup.sh start <service>"

  local service_dir=~/apps/"$service_name"
  [[ -f "$service_dir/docker-compose.yml" ]] || die "No docker-compose.yml found. Run: ./swarmup.sh create $service_name <image>"

  local secret_name="${service_name}_secrets"

  info "Creating Docker secret '$secret_name'..."
  docker secret create "$secret_name" "$service_dir/secrets"
  success "Secret '$secret_name' created."

  info "Deploying stack '$service_name'..."
  docker stack deploy -c "$service_dir/docker-compose.yml" "$service_name"
  success "Service '$service_name' deployed."
  info "Secrets are mounted at /run/secrets/${secret_name} inside the container."
}

# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------

cmd_update() {
  require_gum
  require_swarm

  local service_name="${1:-}"
  [[ -n "$service_name" ]] || die "Usage: swarmup.sh update <service>"

  local service_dir=~/apps/"$service_name"
  [[ -d "$service_dir" ]] || die "Service directory not found: $service_dir"
  [[ -f "$service_dir/docker-compose.yml" ]] || die "No docker-compose.yml found in $service_dir"

  local secret_name="${service_name}_secrets"

  info "Rotating secret '$secret_name'..."
  docker secret rm "$secret_name" &>/dev/null || true
  docker secret create "$secret_name" "$service_dir/secrets"
  success "Secret rotated."

  info "Rolling update for '$service_name'..."
  docker stack deploy -c "$service_dir/docker-compose.yml" "$service_name"
  success "Service '$service_name' updated."
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------

cmd_stop() {
  require_swarm

  local service_name="${1:-}"
  [[ -n "$service_name" ]] || die "Usage: swarmup.sh stop <service>"

  info "Stopping stack '$service_name'..."
  docker stack rm "$service_name"
  success "Service '$service_name' stopped. Files and secret preserved."
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

cmd_remove() {
  require_gum
  require_swarm

  local service_name="${1:-}"
  [[ -n "$service_name" ]] || die "Usage: swarmup.sh remove <service>"

  gum confirm "Remove service '$service_name'? This is irreversible." || exit 0

  local secret_name="${service_name}_secrets"

  info "Removing stack '$service_name'..."
  docker stack rm "$service_name" &>/dev/null || true

  info "Removing secret '$secret_name'..."
  docker secret rm "$secret_name" &>/dev/null || true

  info "Removing service directory..."
  rm -rf ~/apps/"$service_name"

  success "Service '$service_name' removed."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  setup)  cmd_setup ;;
  create) shift; cmd_create "$@" ;;
  start)  shift; cmd_start "$@" ;;
  update) shift; cmd_update "$@" ;;
  stop)   shift; cmd_stop "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  *)      usage; exit 1 ;;
esac
