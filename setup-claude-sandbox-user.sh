#!/usr/bin/env bash
#
# setup-claude-sandbox-user.sh
#
# Creates an unprivileged Linux user intended to run
# `claude --dangerously-skip-permissions` in a blast-radius-limited way.
#
# The account has:
#   - no password (inactive, but account is active; SSH key auth works)
#   - SSH key access copied from the invoking user (or root as fallback)
#   - zsh as its login shell
#   - Oh My Zsh with a couple of community plugins
#   - its own nvm + Node + Claude Code install
#   - an alias `yolo` = `claude --dangerously-skip-permissions`
#
# Rationale: this is sized for ephemeral GPU instances (Vast / RunPod / Lambda)
# where the whole box is already disposable, and you want VS Code Remote-SSH /
# the Claude Code extension to connect as the sandbox user so that
# `--dangerously-skip-permissions` (which refuses to run as root) works.
#
# Usage:
#   sudo ./setup-claude-sandbox-user.sh [username]
#
# Default username is "claude-agent".
#
# After running, SSH in as that user directly, or from the same host:
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
OMZ_THEME="${OMZ_THEME:-robbyrussell}"     # any built-in OMZ theme

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
echo "==> OMZ theme:       $OMZ_THEME"
[[ -n "$SHARED_GROUP" ]] && echo "==> Shared group:    $SHARED_GROUP"

# -------------------- install zsh / git / curl on the host --------------------
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
  # Ensure password state is "no valid password but account active"
  # so SSH key auth works even if a previous run used `passwd -l`.
  usermod -p '*' "$USERNAME"
else
  useradd --create-home --shell "$ZSH_PATH" "$USERNAME"
  # Disable password login but keep account active so SSH key auth works.
  # `passwd -l` prepends '!' to the hash, which some sshd configs reject
  # even for key-based auth; '*' is the safe "invalid password" marker.
  usermod -p '*' "$USERNAME"
  echo "==> Created user '$USERNAME' with shell $ZSH_PATH (no password, keys only)."
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

# -------------------- clean up any legacy SSH-deny drop-in --------------------
# Previous versions of this script wrote a DenyUsers drop-in. Remove it so
# this user is reachable over SSH.
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-deny-${USERNAME}.conf"
if [[ -f "$SSHD_DROPIN" ]]; then
  rm -f "$SSHD_DROPIN"
  echo "==> Removed legacy SSH deny drop-in at $SSHD_DROPIN."
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh || true
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd || true
  fi
fi

# -------------------- SSH: install authorized_keys for this user --------------------
AUTHKEYS_SRC=""
if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
  sudo_user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if [[ -n "$sudo_user_home" && -f "$sudo_user_home/.ssh/authorized_keys" ]]; then
    AUTHKEYS_SRC="$sudo_user_home/.ssh/authorized_keys"
  fi
fi
# Fall back to root's keys (typical on Vast / RunPod where you log in as root)
if [[ -z "$AUTHKEYS_SRC" && -f "/root/.ssh/authorized_keys" ]]; then
  AUTHKEYS_SRC="/root/.ssh/authorized_keys"
fi

USER_SSH_DIR="$USER_HOME/.ssh"
mkdir -p "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"
touch "$USER_SSH_DIR/authorized_keys"

if [[ -n "$AUTHKEYS_SRC" ]]; then
  # Merge + dedupe so re-runs are idempotent and don't drop keys the user
  # may have added by hand.
  cat "$AUTHKEYS_SRC" "$USER_SSH_DIR/authorized_keys" \
    | awk 'NF && !/^#/ && !seen[$0]++' \
    > "$USER_SSH_DIR/authorized_keys.new"
  mv "$USER_SSH_DIR/authorized_keys.new" "$USER_SSH_DIR/authorized_keys"
  key_count="$(wc -l < "$USER_SSH_DIR/authorized_keys")"
  echo "==> Installed $key_count SSH key(s) from $AUTHKEYS_SRC"
else
  echo "WARN: no authorized_keys source found on this host." >&2
  echo "      Add your public key manually:" >&2
  echo "        echo 'ssh-ed25519 AAAA... you@laptop' >> $USER_SSH_DIR/authorized_keys" >&2
fi

chmod 600 "$USER_SSH_DIR/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "$USER_SSH_DIR"

# -------------------- provision the new user's environment --------------------
sudo -iu "$USERNAME" bash -s <<EOF
set -euo pipefail

export HOME="$USER_HOME"
cd "\$HOME"

# ---- nvm ----
if [[ ! -d "\$HOME/.nvm" ]]; then
  echo "  -> installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

export NVM_DIR="\$HOME/.nvm"
# shellcheck disable=SC1091
. "\$NVM_DIR/nvm.sh"

if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
  echo "  -> installing node ($NODE_VERSION)..."
  nvm install "$NODE_VERSION"
fi
nvm use "$NODE_VERSION" >/dev/null
nvm alias default "$NODE_VERSION" >/dev/null

# ---- Claude Code ----
if ! command -v claude >/dev/null 2>&1; then
  echo "  -> installing @anthropic-ai/claude-code..."
  npm install -g @anthropic-ai/claude-code
fi

# ---- Oh My Zsh ----
if [[ ! -d "\$HOME/.oh-my-zsh" ]]; then
  echo "  -> installing oh-my-zsh..."
  RUNZSH=no CHSH=no KEEP_ZSHRC=no \
    sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# ---- Community plugins ----
ZSH_CUSTOM="\$HOME/.oh-my-zsh/custom"
if [[ ! -d "\$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
  echo "  -> installing zsh-autosuggestions..."
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    "\$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi
if [[ ! -d "\$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
  echo "  -> installing zsh-syntax-highlighting..."
  git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
    "\$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# ---- OMZ template .zshrc: theme + plugins ----
if [[ -f "\$HOME/.zshrc" ]]; then
  sed -i "s|^ZSH_THEME=.*|ZSH_THEME=\"$OMZ_THEME\"|" "\$HOME/.zshrc"
  sed -i "s|^plugins=.*|plugins=(git command-not-found zsh-autosuggestions zsh-syntax-highlighting)|" \
    "\$HOME/.zshrc"
fi

# ---- Sandbox block (once) ----
if ! grep -q '# >>> claude sandbox >>>' "\$HOME/.zshrc"; then
  cat >> "\$HOME/.zshrc" <<'RC'

# >>> claude sandbox >>>
# nvm
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && . "\$NVM_DIR/bash_completion"

# Claude Code convenience
alias yolo='claude --dangerously-skip-permissions'

# Prepend a yellow [claude-sandbox] marker to whatever OMZ theme set up,
# so we keep git-branch info etc. but always know we're in the sandbox.
PROMPT='%F{yellow}[claude-sandbox]%f '\$PROMPT

# Editor
export EDITOR="\${EDITOR:-vi}"
# <<< claude sandbox <<<
RC
fi

# ---- Git defaults for a throwaway sandbox ----
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global credential.helper store

# ---- Workspace ----
mkdir -p "\$HOME/workspace"

echo "  -> done as user $USERNAME."
EOF

# -------------------- write instructions file --------------------
INSTRUCTIONS_FILE="instructions-${USERNAME}.txt"

# Build a human-readable key summary for the instructions
if [[ -s "$USER_SSH_DIR/authorized_keys" ]]; then
  KEY_SUMMARY="$(awk '{print "      - " $3 " (" $1 ")"}' "$USER_SSH_DIR/authorized_keys")"
else
  KEY_SUMMARY="      (none installed -- add one before you can SSH in)"
fi

cat > "$INSTRUCTIONS_FILE" <<MSG
==========================================================
 Sandbox user '$USERNAME' is ready.
 Shell:       $ZSH_PATH  (with Oh My Zsh)
 Home:        $USER_HOME
 OMZ theme:   $OMZ_THEME
 OMZ plugins: git, command-not-found,
              zsh-autosuggestions, zsh-syntax-highlighting
 SSH keys authorized for '$USERNAME':
$KEY_SUMMARY
==========================================================

CONNECT VIA SSH
---------------
Add this to your LAPTOP's ~/.ssh/config:

    Host sandbox
        HostName <ip-or-hostname-of-this-machine>
        Port    <ssh-port>
        User    $USERNAME
        IdentityFile ~/.ssh/id_ed25519   # or whichever key you use

Then, from your laptop:

    ssh sandbox

Or, if you're already on this machine as root/another user:

    sudo -iu $USERNAME


VS CODE REMOTE-SSH
------------------
Use the same 'Host sandbox' entry. Because the SSH session lands as
'$USERNAME' (not root), any 'claude' process the VS Code extension
spawns will run as '$USERNAME' too -- which is required for
--dangerously-skip-permissions (Claude Code refuses to run as root).

Then in VS Code Settings, search "claude code" and:
  - check   "Allow dangerously skip permissions"
  - set     "Initial Permission Mode" = bypassPermissions
  - reload  window (Ctrl/Cmd+Shift+P -> "Developer: Reload Window")

After reload, click the mode indicator at the bottom of the Claude
prompt box and pick "Bypass permissions".


USE CLAUDE CODE IN THE TERMINAL
-------------------------------
Once you're in as $USERNAME (via SSH or sudo -iu):

    cd ~/workspace
    yolo                 # = claude --dangerously-skip-permissions


CLONE A REPO AND COMMIT
-----------------------
    git config --global user.name  "Your Name"
    git config --global user.email "you@example.com"
    git clone https://github.com/<you>/<repo>.git
    cd <repo>
    git checkout -b experiment/<branch-name>
    # ... let the agent work ...
    git add -A && git commit -m "..."


PUSHING YOUR CHANGES (three options)
------------------------------------
A) Fine-grained PAT, scoped to one repo, 24h TTL:
   GitHub -> Settings -> Developer settings -> Fine-grained tokens.
   Repository access: just the repo. Contents: Read and write. Exp: 1 day.

       git push -u origin experiment/<branch-name>

   When done: revoke the PAT.

B) No creds in the sandbox; exfiltrate a git bundle:

       # in the sandbox:
       git bundle create /tmp/changes.bundle origin/main..experiment/<branch>

       # on your laptop:
       scp sandbox:/tmp/changes.bundle .
       git fetch ./changes.bundle experiment/<branch>:experiment/<branch>
       git push origin experiment/<branch>

C) Push to a throwaway fork with a fork-scoped PAT; open the PR manually.


TEARDOWN
--------
    sudo userdel -r $USERNAME


NOTES ON ISOLATION
------------------
- This is a UID-level sandbox, not a VM or container. It's sized for
  ephemeral GPU instances (Vast / RunPod / Lambda) where the whole
  machine is already disposable.
- On a machine you care about, remember: the sandbox user shares the
  kernel, the local network, and outbound internet with everything else.
- Anything in ~/$USERNAME is readable by the agent. Treat any credential
  you drop in here as burnable.
MSG

if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$INSTRUCTIONS_FILE"
fi

# -------------------- finish --------------------
echo
cat "$INSTRUCTIONS_FILE"
echo
echo "==> Instructions also written to: $(pwd)/$INSTRUCTIONS_FILE"