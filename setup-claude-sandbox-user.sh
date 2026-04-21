#!/usr/bin/env bash
#
# setup-claude-sandbox-user.sh
#
# Creates an unprivileged Linux user intended to run
# `claude --dangerously-skip-permissions` in a blast-radius-limited way.
# The account has:
#   - no password (locked), no SSH login
#   - zsh as its login shell
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
# On completion, writes `instructions-<username>.txt` into the cwd,
# owned by $SUDO_USER.
#
set -euo pipefail

# -------------------- config --------------------
USERNAME="${1:-claude-agent}"
NODE_VERSION="${NODE_VERSION:-lts/*}"     # nvm spec, e.g. 20, 22, lts/*
SHARED_GROUP="${SHARED_GROUP:-}"           # optional: existing group to add the user to

# -------------------- sanity checks --------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (use sudo)." >&2
  exit 1
fi

if ! command -v useradd >/dev/null 2>&1; then
  echo "ERROR: this script expects a Linux host with useradd." >&2
  exit 1
fi

echo "==> Target username: $USERNAME"
echo "==> Node version:    $NODE_VERSION"
[[ -n "$SHARED_GROUP" ]] && echo "==> Shared group:    $SHARED_GROUP"

# -------------------- install zsh (and git, while we're here) --------------------
install_pkgs() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${pkgs[@]}"
  else
    echo "ERROR: no supported package manager found (tried apt/dnf/yum/pacman)." >&2
    exit 1
  fi
}

need_install=()
command -v zsh  >/dev/null 2>&1 || need_install+=(zsh)
command -v git  >/dev/null 2>&1 || need_install+=(git)
command -v curl >/dev/null 2>&1 || need_install+=(curl)

if (( ${#need_install[@]} > 0 )); then
  echo "==> installing: ${need_install[*]}"
  install_pkgs "${need_install[@]}"
else
  echo "==> zsh, git, curl already present."
fi

ZSH_PATH="$(command -v zsh)"

# Make sure zsh is listed in /etc/shells (chsh requires this on some distros)
if [[ -f /etc/shells ]] && ! grep -qx "$ZSH_PATH" /etc/shells; then
  echo "$ZSH_PATH" >> /etc/shells
fi

# -------------------- create (or update) user --------------------
if id "$USERNAME" >/dev/null 2>&1; then
  echo "==> User '$USERNAME' already exists."
  current_shell="$(getent passwd "$USERNAME" | cut -d: -f7)"
  if [[ "$current_shell" != "$ZSH_PATH" ]]; then
    chsh -s "$ZSH_PATH" "$USERNAME"
    echo "==> Changed login shell of '$USERNAME' to $ZSH_PATH."
  fi
else
  useradd --create-home --shell "$ZSH_PATH" "$USERNAME"
  passwd -l "$USERNAME" >/dev/null
  echo "==> Created user '$USERNAME' with shell $ZSH_PATH and locked password."
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

# -------------------- deny SSH explicitly --------------------
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-deny-${USERNAME}.conf"
if [[ -d /etc/ssh/sshd_config.d ]]; then
  if [[ ! -f "$SSHD_DROPIN" ]]; then
    echo "DenyUsers $USERNAME" > "$SSHD_DROPIN"
    chmod 644 "$SSHD_DROPIN"
    echo "==> Wrote $SSHD_DROPIN (denies SSH for $USERNAME)."
    if systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl reload ssh || true
    elif systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl reload sshd || true
    fi
  fi
fi

# -------------------- install nvm + node + claude code as the new user --------------------
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

# Minimal .zshrc so zsh-newuser-install never prompts
touch "\$HOME/.zshrc"

# Add our block only once
if ! grep -q '# >>> claude sandbox >>>' "\$HOME/.zshrc"; then
  cat >> "\$HOME/.zshrc" <<'RC'

# >>> claude sandbox >>>
# nvm
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && . "\$NVM_DIR/bash_completion"

# Claude Code convenience
alias yolo='claude --dangerously-skip-permissions'

# Prompt: yellow [claude-sandbox] tag + cwd
autoload -U colors && colors
setopt prompt_subst
PROMPT='%F{yellow}[claude-sandbox]%f %~ %# '

# History
HISTFILE=\$HOME/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history hist_ignore_dups inc_append_history

# Completion
autoload -Uz compinit && compinit -i

# Editor
export EDITOR="\${EDITOR:-vi}"
# <<< claude sandbox <<<
RC
fi

# Reasonable git defaults for a throwaway sandbox
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global credential.helper store

# Workspace dir
mkdir -p "\$HOME/workspace"

echo "  -> done as user $USERNAME."
EOF

# -------------------- write instructions file --------------------
INSTRUCTIONS_FILE="instructions-${USERNAME}.txt"

cat > "$INSTRUCTIONS_FILE" <<MSG
==========================================================
 Sandbox user '$USERNAME' is ready.
 Shell: $ZSH_PATH
 Home:  $USER_HOME
==========================================================

ENTER THE SANDBOX
-----------------
    sudo -iu $USERNAME

    # you are now in zsh, prompt shows [claude-sandbox]
    cd ~/workspace
    yolo                 # = claude --dangerously-skip-permissions


CLONE A REPO AND COMMIT
-----------------------
Inside the sandbox:

    git config --global user.name  "Your Name"
    git config --global user.email "you@example.com"
    git clone https://github.com/<you>/<repo>.git
    cd <repo>
    git checkout -b experiment/<branch-name>
    # ... let the agent work ...
    git add -A && git commit -m "..."


PUSHING YOUR CHANGES (three options)
------------------------------------
A) Fine-grained PAT, scoped to one repo, short TTL (24h):
   On GitHub -> Settings -> Developer settings -> Fine-grained tokens.
   Repository access: just the repo you're touching.
   Permissions: Contents: Read and write.
   Expiration: 1 day.

       git push -u origin experiment/<branch-name>
       # first push prompts for user + token; credential.helper store caches it.

   When done with the session: revoke the PAT on GitHub.

B) No creds in the sandbox; exfiltrate the diff and push from a trusted box:

       # in the sandbox:
       git bundle create /tmp/changes.bundle origin/main..experiment/<branch-name>

       # on your laptop:
       scp user@gpu-host:/tmp/changes.bundle .
       git fetch ./changes.bundle experiment/<branch-name>:experiment/<branch-name>
       git push origin experiment/<branch-name>

   Bundles preserve commit SHAs exactly -- useful for reproducibility.

C) Work against a throwaway fork, PAT scoped to the fork only.
   Agent pushes to the fork; you open the PR manually from the fork.


TEARDOWN
--------
    sudo userdel -r $USERNAME
    sudo rm -f $SSHD_DROPIN


NOTES ON ISOLATION
------------------
- This is a UID-level sandbox, not a VM or container.
- The sandbox user can still reach the local network and use any outbound
  HTTP. If that matters, use a VM or container instead / in addition.
- Anything in this user's home is readable by the agent. Treat any credential
  you drop in here as burnable.
MSG

# Chown the instructions file back to the invoking user, if applicable.
if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$INSTRUCTIONS_FILE"
fi

# -------------------- finish --------------------
echo
cat "$INSTRUCTIONS_FILE"
echo
echo "==> Instructions also written to: $(pwd)/$INSTRUCTIONS_FILE"