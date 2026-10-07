#!/usr/bin/env bash

# Script safety options
set -eu
# -e: If any command fails, the script stops immediately.
# -u: Treat unset variables as an error, so the script will stop

# ###### #
# Colors #
# ###### #

COLOR="\033[1;33m"
NC="\033[0;37m" # No Color

# ######## #
# Settings #
# ######## #

# Versions, these are hardcoded:
#    - Stability: The script won't break when new Nix releases come out
#    - Reproducibility en syncing: All machines will get the same setup
NIX_CHANNEL="nixos-24.11" # or "nixpkgs-24.11" for non-NixOS
HM_RELEASE="24.11"

# GitHub repo (used for cloning + gh auth)
GH_REPO="HanneMaes/sync-settings-and-files"
GH_SSH_URL="git@github.com:${GH_REPO}.git"

# Directory locations
if grep -qi microsoft /proc/version 2>/dev/null; then
  # On WSL
  echo -e "\n🏗️ ${COLOR}WSL detected${NC}\n"
  # Read Windows username from the filesystem instead of cmd.exe
  WIN_USER=$(ls /mnt/c/Users/ | grep -v -E "^(Public|Default|Default User|All Users|desktop.ini)$" | head -1)
  PARENT_DIR="/mnt/c/Users/$WIN_USER/Documents"
else
  # On Linux
  PARENT_DIR="$HOME/Documents"
fi
TARGET_DIR="$PARENT_DIR/sync-settings-and-files"
mkdir -p "$PARENT_DIR" # Create dir if it doesn't exist

# ###### #
# Checks #
# ###### #

# Detect if on NixOS
is_nixos=false
if [ -f /etc/NIXOS ]; then
  is_nixos=true
fi
echo -e "\n🏗️ ${COLOR}Is this NixOS: $is_nixos${NC}\n"

# ######## #
# Hostname #
# ######## #

# Update the hostname given to this machine (/etc/hostname) to /etc/hosts
# This is needed to run sudo commands
# Not needed on NixOS, because the hostname is defined in configuration.nix
if [ "$is_nixos" = false ]; then
  if ! grep -q "$(hostname)" /etc/hosts; then
    sudo sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost\n127.0.0.1\t$(hostname)/" /etc/hosts
  fi
fi

# ############################ #
# NIX Pre-Install Safety Check #
# ############################ #

# If the official Nix installer failed before, it leaves 'backup-before-nix' files.
# These files prevent the script from being "idempotent" (runnable multiple times).
if [ -f /etc/bash.bashrc.backup-before-nix ]; then # This removes the backup files
  echo -e "\n🏗️ ${COLOR} Removing old Nix backup blockers...${NC}\n"
  sudo rm -f /etc/bash.bashrc.backup-before-nix
fi
if [ -d "/nix" ] && ! command -v nix &>/dev/null; then # If /nix exists but nix isn't installed, it's a "ghost" directory that breaks the installer
  echo -e "\n🏗️ ${COLOR} Cleaning up broken /nix directory...${NC}\n"
  sudo rm -rf /nix
fi

# ###################### #
# DETECT PACKAGE MANAGER #
# ###################### #

echo -e "\n🏗️ ${COLOR}Detecting package manager...${NC}\n"

if command -v apt >/dev/null 2>&1; then
  PACKAGEMANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
  PACKAGEMANAGER="dnf"
elif command -v pacman >/dev/null 2>&1; then
  PACKAGEMANAGER="pacman"
elif [ -f /etc/NIXOS ]; then
  PACKAGEMANAGER="nixos"
else
  echo -e "\n🏗️ ${COLOR}❌ Could not detect package manager. Install packages manually.${NC}\n"
  exit 1
fi

echo -e "\n🏗️ ${COLOR}Found package manager: $PACKAGEMANAGER${NC}\n"

# ############# #
# Update system #
# ############# #

echo -e "\n🏗️ ${COLOR}Updating system...${NC}\n"

case "$PACKAGEMANAGER" in
apt)
  sudo apt update
  sudo apt upgrade -y
  ;;
dnf)
  sudo dnf upgrade -y
  ;;
pacman)
  sudo pacman -Syu --noconfirm
  ;;
nixos)
  echo -e "\n🏗️ ${COLOR}NixOS system updates are handled through nixos-rebuild${NC}\n"
  ;;
*)
  echo -e "⚠️ ${COLOR}Could not update system with unknown package manager"
  ;;
esac

echo -e "\n🏗️ ${COLOR}System update complete${NC}\n"

# ########################### #
# INSTALL NIX PACKAGE MANAGER #
# ########################### #

if [ "$is_nixos" = false ]; then
  if ! command -v nix &>/dev/null; then
    echo -e "🏗️ Installing Nix (The Modern Way)..."

    # Run the Determinate Systems installer
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm

    # Source Nix immediately so it works in the current shell session
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
      . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi

    # Verify installation
    if command -v nix &>/dev/null; then
      echo -e "\n🏗️ ${COLOR}Nix installed successfully: $(nix --version)${NC}\n"
    else
      echo -e "\n🏗️ ${COLOR}Nix installation failed or is not in PATH.${NC}\n"
      exit 1
    fi
  else
    echo -e "\n🏗️ ${COLOR}Nix is already installed${NC}\n"
  fi
fi

# ################### #
#  GIT / GH NIX-SHELL #
# ################### #

echo -e "\n🏗️ ${COLOR}Getting a git gh nix-shell...${NC}\n"

export TARGET_DIR GH_SSH_URL

nix-shell -p git gh --run '
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    gh auth login --hostname github.com --git-protocol https --web </dev/tty || exit 1
  fi
  gh auth setup-git

  if [ ! -d "$TARGET_DIR/.git" ]; then
    git clone "$GH_SSH_URL" "$TARGET_DIR"
  else
    cd "$TARGET_DIR" && git remote set-url origin "$GH_SSH_URL" && git pull
  fi
'

# ############## #
# INSTALL DOCKER #
# ############## #

if [ "$is_nixos" = false ]; then
  echo -e "\n🏗️ ${COLOR}Installing Docker on non-NixOS...${NC}\n"

  if ! command -v docker >/dev/null 2>&1; then
    # Use the official Docker installer script
    # This works on Pi (ARM), Ubuntu, Fedora, and Debian
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
  else
    echo -e "\n🏗️ ${COLOR}Docker is already installed.${NC}\n"
  fi

  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER" || true
  echo -e "\n🏗️ ${COLOR}Docker setup complete. (Note: You may need to log out and back in for group changes to take effect)${NC}\n"
else
  echo -e "\n🏗️ ${COLOR}NixOS detected: Docker is managed via configuration.nix${NC}\n"
fi

# #################### #
# INSTALL HOME-MANAGER #
# #################### #

if [ "$is_nixos" = false ]; then
  echo -e "\n🏗️ ${COLOR}Installing home-manager...${NC}\n"

  # 1. Clean up the failed config folder so the installer can start fresh
  rm -rf "$HOME/.config/home-manager"

  # 2. Re-set channels for future use
  nix-channel --add "https://nixos.org/channels/${NIX_CHANNEL}" nixpkgs
  nix-channel --add "https://github.com/nix-community/home-manager/archive/release-${HM_RELEASE}.tar.gz" home-manager

  # 3. Force the installer to use 24.11 by overriding the NIX_PATH
  if ! command -v home-manager >/dev/null 2>&1; then
    echo -e "\n🏗️ ${COLOR}Running installer with version lock...${NC}\n"

    # We set NIX_PATH inside the command to ensure it points to 24.11
    # and NOT the system's 26.05 version.
    NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/${NIX_CHANNEL}.tar.gz \
      nix-shell "https://github.com/nix-community/home-manager/archive/release-${HM_RELEASE}.tar.gz" \
      -A install
  else
    echo -e "\n🏗️ ${COLOR}Home Manager already installed${NC}\n"
  fi
fi

# ########################### #
# SYMLINK CONFIGURATION FILES #
# ########################### #

echo -e "\n🏗️ ${COLOR}Linking configuration files...${NC}\n"

# Prevent Home Manager collision by removing existing default Firefox profiles
if [ -f "$HOME/.mozilla/firefox/profiles.ini" ]; then
  echo -e "🏗️ ${COLOR}Removing existing Firefox profiles.ini to prevent HM conflict...${NC}"
  rm -rf ~/.mozilla/firefox/profiles.ini
fi

# Link home-manager config (ALL systems)
mkdir -p ~/.config/home-manager
ln -sf "$TARGET_DIR/home-manager/home.nix" ~/.config/home-manager/home.nix
echo -e "🏗️ ${COLOR}🔗 home-manager config linked${NC}"

# Link nix config (ALL systems)
mkdir -p ~/.config/nix
ln -sf "$TARGET_DIR/nix/nix.conf" ~/.config/nix/nix.conf
echo -e "🏗️ ${COLOR}🔗 nix config linked${NC}"

# Link NixOS config (ONLY on NixOS)
if [ "$is_nixos" = true ]; then
  sudo ln -sf "$TARGET_DIR/nixos/configuration.nix" /etc/nixos/configuration.nix
  echo -e "🏗️ ${COLOR}🔗 NixOS config linked${NC}"
fi

echo -e "\n🏗️ ${COLOR}Configuration linking complete!${NC}\n"

# ######## #
# FINISHED #
# ######## #

echo -e "\n${COLOR}#######################################################################################"
echo -e "\n✅ ${COLOR}Setup complete!${NC}\n"

# Show repo got cloned
if [ -d "$TARGET_DIR" ]; then
  echo -e "✅ ${COLOR} Repo cloned to:${NC} $TARGET_DIR"
  echo -e " ${COLOR}ls ${NC} $TARGET_DIR"
  ls "$TARGET_DIR"
else
  echo -e "❌ ${COLOR} Repo not found at:${NC} $TARGET_DIR"
fi

# Show symlinks got created
echo -e "\n${COLOR}Symlinks created:${NC}"
for link in \
  "$HOME/.config/home-manager/home.nix" \
  "$HOME/.config/nix/nix.conf" \
  "/etc/nixos/configuration.nix"; do
  if [ -L "$link" ]; then
    echo -e "✅ ${COLOR} $link${NC} 🔗 $(readlink "$link")"
  elif [ -e "$link" ]; then
    echo -e "⚠️ ${COLOR} $link${NC} exists but is not a symlink"
  else
    echo -e "❌ ${COLOR} $link${NC} not found"
  fi
done

# Show installed versions (only on non-NixOS systems where we installed them)
if [ "$is_nixos" = false ]; then
  echo -e "\n✅ ${COLOR}Installed versions:${NC}\n"

  # Git
  if command -v git >/dev/null 2>&1; then
    echo -e "✅ ${COLOR}Git:${NC} $(git --version)"
  fi

  # GitHub CLI
  if command -v gh >/dev/null 2>&1; then
    echo -e "✅ ${COLOR}GitHub CLI:${NC} $(gh --version | head -1)"
  fi

  # Docker
  if command -v docker >/dev/null 2>&1; then
    echo -e "✅ ${COLOR}Docker:${NC} $(docker --version)"
  fi

  # Docker Compose (plugin)
  if docker compose version >/dev/null 2>&1; then
    echo -e "✅ ${COLOR}Docker Compose:${NC} $(docker compose version)"
  fi

  # Nix
  if command -v nix >/dev/null 2>&1; then
    echo -e "✅ ${COLOR}Nix:${NC} $(nix --version)"
  fi

  # Home Manager
  if command -v home-manager >/dev/null 2>&1; then
    echo -e "✅ ${COLOR}Home Manager:${NC} $(home-manager --version)"
  fi

  echo ""
fi
