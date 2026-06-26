#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_gum_available() { command -v gum &>/dev/null; }

info()    { if _gum_available; then gum style --foreground "212" "  $*"; else echo "[info] $*"; fi; }
success() { if _gum_available; then gum style --foreground "10" "  $*"; else echo "[ok]   $*"; fi; }
error()   { if _gum_available; then gum style --foreground "9" "  $*" >&2; else echo "[err]  $*" >&2; fi; }

die() { error "$*"; exit 1; }

cleanup_secrets() {
  local prefix="$1"
  # Collect secrets in use by any running service
  local in_use
  in_use=$(docker service ls --format '{{.Name}}' 2>/dev/null | xargs -I{} \
    docker service inspect {} --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}' 2>/dev/null || true)

  local removed=0
  while IFS= read -r name; do
    if echo "$in_use" | grep -qw "$name"; then
      continue
    fi
    docker secret rm "$name" &>/dev/null && (( removed++ )) || true
  done < <(docker secret ls --format '{{.Name}}' | grep "^${prefix}")

  [[ $removed -gt 0 ]] && success "Removed $removed stale secret(s) with prefix '$prefix'." || info "No stale secrets found."
}

pick_service() {
  local prompt="$1"
  local services=()
  if [[ -d ~/apps ]]; then
    while IFS= read -r dir; do
      services+=("$(basename "$dir")")
    done < <(find ~/apps -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  [[ ${#services[@]} -gt 0 ]] || die "No services found in ~/apps"
  gum choose --header "$prompt" "${services[@]}"
}

create_secret() {
  local name="$1" file="$2"
  if [[ ! -s "$file" ]]; then
    echo "" | docker secret create "$name" -
  else
    docker secret create "$name" "$file"
  fi
}

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
  update <service> [--image IMAGE] [--replicas N] Rotate secrets and rolling-update a service
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

  mkdir -p ~/traefik/certs/letsencrypt

  # Generate self-signed wildcard cert for *.swarm.localhost (local/internal use)
  if [[ ! -f ~/traefik/certs/local.crt ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout ~/traefik/certs/local.key \
      -out ~/traefik/certs/local.crt \
      -subj "/CN=*.swarm.localhost" 2>/dev/null
  fi

  # Dynamic config: wire up the self-signed cert (lives inside ~/traefik/certs/)
  cat > ~/traefik/certs/tls.yml <<EOF
tls:
  certificates:
    - certFile: /certs/local.crt
      keyFile: /certs/local.key
EOF

  cat > ~/traefik/docker-compose.yml <<EOF
version: "3.8"
services:
  traefik:
    image: traefik:v3.7
    command:
      # Swarm provider
      - --providers.swarm=true
      - --providers.swarm.endpoint=unix:///var/run/docker.sock
      - --providers.swarm.watch=true
      - --providers.swarm.exposedByDefault=false
      - --providers.swarm.network=traefik-public
      # Dynamic config (self-signed cert)
      - --providers.file.filename=/certs/tls.yml
      - --providers.file.watch=true
      # Entrypoints
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      # HTTP -> HTTPS redirect
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.web.http.redirections.entrypoint.permanent=true
      # Let's Encrypt
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.letsencrypt.acme.email=${acme_email}
      - --certificatesresolvers.letsencrypt.acme.storage=/certs/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ~/traefik/certs:/certs
    networks:
      - traefik-public
    deploy:
      placement:
        constraints:
          - node.role == manager
networks:
  traefik-public:
    external: true
EOF

  info "Deploying Traefik..."
  docker stack deploy -d -c ~/traefik/docker-compose.yml traefik
  success "Traefik deployed."
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

cmd_create() {
  require_gum

  local service_name="${1:-}"
  local image_name="${2:-}"
  shift $(( $# >= 2 ? 2 : $# ))

  local replicas=1
  local domain=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --replicas) replicas="${2:?--replicas requires a value}"; shift 2 ;;
      --domain)   domain="${2:?--domain requires a value}"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -n "$service_name" ]] || service_name=$(gum input --placeholder "my-app" --prompt "Service name: ")
  [[ -n "$service_name" ]] || die "Service name is required."

  [[ -n "$image_name" ]] || image_name=$(gum input --placeholder "nginx:latest" --prompt "Docker image: ")
  [[ -n "$image_name" ]] || die "Docker image is required."

  if [[ -z "$domain" ]]; then
    domain=$(gum input --placeholder "app.example.com (leave empty to skip)" --prompt "Domain (optional): ")
  fi

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
        - traefik.http.routers.${service_name}.tls=true
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
  if [[ -z "$service_name" ]]; then
    # List ~/apps dirs that are NOT already running as a stack
    local running=()
    while IFS= read -r stack; do running+=("$stack"); done \
      < <(docker stack ls --format '{{.Name}}' 2>/dev/null)

    local stopped=()
    if [[ -d ~/apps ]]; then
      while IFS= read -r dir; do
        local name; name=$(basename "$dir")
        local is_running=false
        for s in "${running[@]}"; do [[ "$s" == "$name" ]] && is_running=true && break; done
        $is_running || stopped+=("$name")
      done < <(find ~/apps -mindepth 1 -maxdepth 1 -type d | sort)
    fi

    [[ ${#stopped[@]} -gt 0 ]] || die "No stopped services found in ~/apps"
    service_name=$(gum choose --header "Select service to start:" "${stopped[@]}")
  fi

  local service_dir=~/apps/"$service_name"
  [[ -f "$service_dir/docker-compose.yml" ]] || die "No docker-compose.yml found. Run: ./swarmup.sh create $service_name <image>"

  local secret_name="${service_name}_secrets"

  cleanup_secrets "${service_name}_secrets"

  info "Creating Docker secret '$secret_name'..."
  create_secret "$secret_name" "$service_dir/secrets"
  success "Secret '$secret_name' created."

  info "Deploying stack '$service_name'..."
  docker stack deploy -d -c "$service_dir/docker-compose.yml" "$service_name"
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
  [[ -n "$service_name" ]] || service_name=$(pick_service "Select service to update:")
  shift || true

  local new_image="" new_replicas=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)    new_image="${2:?--image requires a value}"; shift 2 ;;
      --replicas) new_replicas="${2:?--replicas requires a value}"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local service_dir=~/apps/"$service_name"
  [[ -d "$service_dir" ]] || die "Service directory not found: $service_dir"
  [[ -f "$service_dir/docker-compose.yml" ]] || die "No docker-compose.yml found in $service_dir"

  local old_secret new_secret svc_id
  svc_id="${service_name}_${service_name}"
  new_secret="${service_name}_secrets_$(date +%s)"

  # Find current secret mounted at this target
  old_secret=$(docker service inspect "$svc_id" \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep "^${service_name}_secrets" | head -1 || true)

  info "Creating new secret '$new_secret'..."
  create_secret "$new_secret" "$service_dir/secrets"
  success "New secret created."

  info "Updating service '$svc_id'..."
  local update_args=()
  [[ -n "$new_image" ]]    && update_args+=(--image "$new_image")
  [[ -n "$new_replicas" ]] && update_args+=(--replicas "$new_replicas")
  if [[ -n "$old_secret" ]]; then
    update_args+=(--secret-rm "$old_secret")
  fi
  update_args+=(--secret-add "source=${new_secret},target=${service_name}_secrets")

  docker service update "${update_args[@]}" "$svc_id"

  cleanup_secrets "${service_name}_secrets"
  success "Service '$service_name' updated."
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------

cmd_stop() {
  require_swarm

  local service_name="${1:-}"
  [[ -n "$service_name" ]] || service_name=$(pick_service "Select service to stop:")

  info "Stopping stack '$service_name'..."
  docker stack rm "$service_name"
  cleanup_secrets "${service_name}_secrets"
  success "Service '$service_name' stopped. Files preserved."
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

cmd_remove() {
  require_gum
  require_swarm

  local service_name="${1:-}"
  [[ -n "$service_name" ]] || service_name=$(pick_service "Select service to remove:")

  gum confirm "Remove service '$service_name'? This is irreversible." || exit 0

  info "Removing stack '$service_name'..."
  docker stack rm "$service_name" &>/dev/null || true

  info "Cleaning up secrets..."
  cleanup_secrets "${service_name}_secrets"

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
