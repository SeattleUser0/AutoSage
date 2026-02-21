#!/usr/bin/env bash
set -e

OS="$(uname -s)"

echo "[AutoSage setup] Detected OS: ${OS}"

case "${OS}" in
  Darwin)
    echo "[AutoSage setup] Configuring macOS dependencies via Homebrew..."

    if ! command -v brew >/dev/null 2>&1; then
      echo "[AutoSage setup] Homebrew is required but not installed."
      echo "Install Homebrew first: https://brew.sh"
      exit 1
    fi

    echo "[AutoSage setup] Installing build tools (cmake, ninja, rust, autoconf, automake, libtool)..."
    brew install cmake ninja rust autoconf automake libtool

    echo "[AutoSage setup] Installing VTK..."
    # Homebrew's vtk formula provides the Cocoa-backed VTK build on macOS.
    brew install vtk

    echo "[AutoSage setup] macOS dependency installation complete."
    ;;

  Linux)
    echo "[AutoSage setup] Configuring Linux dependencies via APT (Debian/Ubuntu)..."

    if ! command -v apt-get >/dev/null 2>&1; then
      echo "[AutoSage setup] Unsupported Linux distribution: apt-get not found."
      echo "This setup script currently supports Debian/Ubuntu-based systems only."
      exit 1
    fi

    if ! command -v sudo >/dev/null 2>&1; then
      echo "[AutoSage setup] 'sudo' is required for APT installs."
      exit 1
    fi

    echo "[AutoSage setup] Updating package index..."
    sudo apt-get update

    echo "[AutoSage setup] Installing build tools (build-essential, cmake, ninja-build, cargo, autoconf, automake, libtool)..."
    sudo apt-get install -y \
      build-essential \
      cmake \
      ninja-build \
      cargo \
      autoconf \
      automake \
      libtool

    echo "[AutoSage setup] Checking Swift toolchain availability..."
    if command -v swift >/dev/null 2>&1; then
      echo "[AutoSage setup] Swift is already installed ($(swift --version | head -n 1)); skipping swiftlang apt install."
    else
      echo "[AutoSage setup] Swift not found; attempting to install swiftlang..."
      # Assumes a compatible Ubuntu environment where the Swift apt repository is configured.
      if apt-cache show swiftlang >/dev/null 2>&1; then
        sudo apt-get install -y swiftlang
      else
        echo "[AutoSage setup] Package 'swiftlang' is not available in current APT sources."
        echo "Install Swift manually (or via CI setup action) and re-run this script."
        exit 1
      fi
    fi

    echo "[AutoSage setup] Installing graphics/runtime libraries for headless VTK..."
    # libvtk9-dev: VTK development headers/libraries.
    # libgl1-mesa-dev + libegl1-mesa-dev: OpenGL/EGL interfaces needed by rendering backends.
    # libosmesa6-dev: off-screen Mesa rendering for headless environments (no X/Wayland display).
    sudo apt-get install -y \
      libvtk9-dev \
      libgl1-mesa-dev \
      libegl1-mesa-dev \
      libosmesa6-dev

    echo "[AutoSage setup] Linux dependency installation complete."
    ;;

  *)
    echo "[AutoSage setup] Unsupported OS: ${OS}"
    echo "Supported operating systems are: Darwin (macOS), Linux (Debian/Ubuntu)."
    exit 1
    ;;
esac

echo "[AutoSage setup] Done."
