#!/usr/bin/env bash
# Provision the persistent `mage-context-engine` container, out-of-band (mage
# attaches, never creates). Host-FS-isolated (no mounts), open network.
# Idempotent: DESTROYS and recreates the container from scratch — push your work
# first, anything not on GitHub is lost.
set -euo pipefail

NAME=mage-context-engine
REPO=https://github.com/kasbuunk/context-engine.git

echo "== removing any prior $NAME =="
docker rm -f "$NAME" >/dev/null 2>&1 || true

# Ports are fixed at creation for a named container (mage refuses ingress rules
# on one), so they're published here. Loopback-only.
echo "== creating $NAME (ports 8000, 5173 on 127.0.0.1; no mounts) =="
docker run -d --name "$NAME" --hostname context-engine \
  -p 127.0.0.1:8000:8000 \
  -p 127.0.0.1:5173:5173 \
  debian:bookworm-slim sleep infinity

echo "== apt base + build deps + shell + editor (as root) =="
docker exec -u root "$NAME" bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg git build-essential pkg-config \
    libssl-dev sqlite3 libsqlite3-dev \
    python3 python3-venv python3-dev \
    zsh zsh-autosuggestions zsh-syntax-highlighting \
    tmux ripgrep fd-find jq less unzip xz-utils gzip file procps sudo
  ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true

  echo "-- node 22 LTS --"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs

  echo "-- gh cli --"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -q && apt-get install -y --no-install-recommends gh

  echo "-- neovim (latest stable, arm64) --"
  curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.tar.gz -o /tmp/nvim.tgz
  rm -rf /opt/nvim && mkdir -p /opt/nvim
  tar -C /opt/nvim --strip-components=1 -xzf /tmp/nvim.tgz && rm /tmp/nvim.tgz
  ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim

  echo "-- toolchain PATH for login shells --"
  cat > /etc/profile.d/mage-toolchain.sh <<EOP
export PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:\$HOME/.npm-global/bin:\$PATH"
export NPM_CONFIG_PREFIX="\$HOME/.npm-global"
export EDITOR=nvim VISUAL=nvim
EOP
  chmod 0644 /etc/profile.d/mage-toolchain.sh
  if ! grep -q "source /etc/profile" /etc/zsh/zprofile 2>/dev/null; then
    printf "emulate sh -c '"'"'source /etc/profile'"'"'\n" >> /etc/zsh/zprofile
  fi

  echo "-- session user dev (uid 1000, zsh, passwordless sudo) --"
  id -u dev >/dev/null 2>&1 || useradd -m -s /usr/bin/zsh -u 1000 dev
  # Full root inside the box is fine: the container is the boundary, and it lets
  # a yolo agent apt-get whatever it needs.
  echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev && chmod 0440 /etc/sudoers.d/dev
  # ~/.claude must be dev-owned BEFORE mage projects settings.json into it, or
  # docker cp creates it root:root and /login cannot write credentials.
  mkdir -p /work /home/dev/.config /home/dev/.claude
  chown -R dev:dev /work /home/dev
'

echo "== uv (python toolchain, as dev) =="
docker exec -u dev "$NAME" bash -lc '
  set -euo pipefail
  export HOME=/home/dev
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
'

# Installed as dev into ~/.local/bin so it self-updates (egress is open).
echo "== claude code (native installer, as dev) =="
docker exec -u dev "$NAME" bash -lc '
  set -euo pipefail
  export HOME=/home/dev
  curl -fsSL https://claude.ai/install.sh | bash
'

echo "== clone repo into /work/context-engine =="
docker exec -u dev "$NAME" bash -lc "
  set -euo pipefail
  cd /work
  test -d context-engine || git clone $REPO context-engine
  cd context-engine
  git remote set-url --push origin $REPO
"

echo "== versions =="
docker exec -u dev "$NAME" zsh -lc '
  echo "python: $(python3 -V 2>/dev/null)"
  echo "uv:     $(uv --version 2>/dev/null || echo MISSING)"
  echo "node:   $(node -v 2>/dev/null || echo MISSING)"
  echo "gh:     $(gh --version 2>/dev/null | head -1 || echo MISSING)"
  echo "claude: $(claude --version 2>/dev/null || echo MISSING)"
  echo "git:    $(git --version 2>/dev/null)"
  echo "nvim:   $(nvim --version 2>/dev/null | head -1)"
  echo "tmux:   $(tmux -V 2>/dev/null)"
'
echo "== DONE provisioning $NAME — enter with: mage context-engine =="
