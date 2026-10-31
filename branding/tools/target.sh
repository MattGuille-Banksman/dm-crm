# Shared helpers for the update scripts: run commands against the local
# Docker Compose stack, or against the Oracle server over SSH.
#
# Environment:
#   SSH_HOST     e.g. ubuntu@140.238.103.97 (empty = this machine)
#   SSH_KEY      private key for SSH_HOST (default ~/.ssh/dmcrm_oracle)
#   COMPOSE_DIR  compose project folder (default: repo root locally,
#                ~/dm-crm/deploy/oracle on the server)

SSH_KEY=${SSH_KEY:-~/.ssh/dmcrm_oracle}

if [ -n "${SSH_HOST:-}" ]; then
  COMPOSE_DIR=${COMPOSE_DIR:-'~/dm-crm/deploy/oracle'}
  # run a shell command on the target
  on_target() { ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_HOST" "$*"; }
  DOCKER="sudo docker"
  # copy a local file or folder to the target's /tmp, printing the remote path
  to_target() {
    local remote="/tmp/$(basename "$1")-$$"
    scp -i "$SSH_KEY" -q -r "$1" "$SSH_HOST:$remote" && echo "$remote"
  }
else
  COMPOSE_DIR=${COMPOSE_DIR:-$(pwd)}
  on_target() { bash -c "$*"; }
  DOCKER="docker"
  to_target() { echo "$1"; }
fi

# docker compose in the target's project folder
dc() { on_target "cd $COMPOSE_DIR && $DOCKER compose $*"; }
