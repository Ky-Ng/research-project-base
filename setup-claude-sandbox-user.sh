#!/usr/bin/env bash
#
# setup-claude-sandbox-user.sh
#
# Creates an unprivileged Linux user intended to run
# `claude --dangerously-skip-permissions` in a blast-radius-limited way.
# The account has:
#   - no password (locked), no SSH login
#   - its own nvm + Node + Claude Code install
#   - an alias `yolo` = `claude --dangerously-skip-permissions`
#
# Usage:
#   sudo ./setup-claude-sandbox-user.sh [username]
#
# Default username is "claude-agent".
#
# After running, enter the sandbox with:
#   sudo -iu <username>
# then:
#   yolo
#
set -euo pipefail

# -------------------- config --------------------
USERNAME="${1:-claude-agent}"
NODE_VERSION="${NODE_VERSION:-lts/*}"     # nvm spec, e.g. 20, 22, lts/*
SHARED_GROUP="${SHARED_GROUP:-}"           # optional: existing group to add the user to
                                           # (useful if you want to share a workspace dir)

# -------------------- sanity checks --------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (use sudo)." >&2
  exit 1
fi

if ! command -v useradd >/dev/null 2>&1; then
  echo "ERROR: this script expects a Debian/Ubuntu/Fedora-like system with useradd." >&2
  exit 1
fi

echo "==> Target username: $USERNAME"
echo "==> Node version:    $NODE_VERSION"
[[ -n "$SHARED_GROUP" ]] && echo "==> Shared group:    $SHARED_GROUP"

# -------------------- create user --------------------
if id "$USERNAME" >/dev/null 2>&1; then
  echo "==> User '$USERNAME' already exists; skipping creation."
else
  useradd --create-home --shell /bin/bash "$USERNAME"
  # Lock the password: no direct login, only `sudo -iu` from an admin.
  passwd -l "$USERNAME" >/dev/null
  echo "==> Created user '$USERNAME' with locked password."
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  echo "ERROR: could not resolve home dir for $USERNAME" >&2
  exit 1
fi

# -------------------- optional shared group --------------------
if [[ -n "$SHARED_GROUP" ]]; then
  if getent group "$SHARED_GROUP" >/dev/null; then
    usermod -aG "$SHARED_GROUP" "$USERNAME"
    echo "==> Added '$USERNAME' to group '$SHARED_GROUP'."
  else
    echo "WARN: group '$SHARED_GROUP' does not exist; skipping." >&2
  fi
fi

# -------------------- deny SSH explicitly (belt + suspenders) --------------------
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-deny-${USERNAME}.conf"
if [[ -d /etc/ssh/sshd_config.d ]]; then
  if [[ ! -f "$SSHD_DROPIN" ]]; then
    echo "DenyUsers $USERNAME" > "$SSHD_DROPIN"
    chmod 644 "$SSHD_DROPIN"
    echo "==> Wrote $SSHD_DROPIN (denies SSH for $USERNAME)."
    # Only reload sshd if it's actually running; don't fail the script if not.
    if systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl reload ssh || true
    elif systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl reload sshd || true
    fi
  fi
fi

# -------------------- install nvm + node + claude code as the new user --------------------
# Everything below runs AS the new user, in their home dir.
sudo -iu "$USERNAME" bash -s <<EOF
set -euo pipefail

export HOME="$USER_HOME"
cd "\$HOME"

# Install nvm if missing
if [[ ! -d "\$HOME/.nvm" ]]; then
  echo "  -> installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# Load nvm for this subshell
export NVM_DIR="\$HOME/.nvm"
# shellcheck disable=SC1091
. "\$NVM_DIR/nvm.sh"

# Install requested Node
if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
  echo "  -> installing node ($NODE_VERSION)..."
  nvm install "$NODE_VERSION"
fi
nvm use "$NODE_VERSION" >/dev/null
nvm alias default "$NODE_VERSION" >/dev/null

# Install Claude Code
if ! command -v claude >/dev/null 2>&1; then
  echo "  -> installing @anthropic-ai/claude-code..."
  npm install -g @anthropic-ai/claude-code
fi

# Convenience alias + env in .bashrc (only add once)
if ! grep -q '# >>> claude sandbox >>>' "\$HOME/.bashrc"; then
  cat >> "\$HOME/.bashrc" <<'RC'

# >>> claude sandbox >>>
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
alias yolo='claude --dangerously-skip-permissions'
# Friendly prompt so you always know you're in the sandbox
PS1='\[\033[01;33m\][claude-sandbox]\[\033[00m\] \w \$ '
# <<< claude sandbox <<<
RC
fi

# Create a workspace dir
mkdir -p "\$HOME/workspace"

echo "  -> done as user $USERNAME."
EOF

# -------------------- finish --------------------
cat <<MSG

==========================================================
 Sandbox user '$USERNAME' is ready.

 Enter the sandbox:
     sudo -iu $USERNAME

 Then from inside:
     cd ~/workspace
     yolo           # = claude --dangerously-skip-permissions

 To remove everything later:
     sudo userdel -r $USERNAME
     sudo rm -f $SSHD_DROPIN
==========================================================
MSG