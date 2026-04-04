# Durian Linux Dev VM (Fedora headless on Apple Silicon via QEMU)
#
# Usage:
#   vagrant up        — start VM (first run downloads image + provisions)
#   vagrant ssh       — SSH into VM
#   vagrant halt      — stop VM (preserves state)
#   vagrant destroy   — delete VM entirely
#
# Inside the VM:
#   cd /vagrant       — shared folder = this repo (auto-synced)
#   bazel build //linux:durian --repo_env=QTDIR=/usr
#   bazel test //linux:all --repo_env=QTDIR=/usr
#   bazel test //cli/...

Vagrant.configure("2") do |config|
  # Fedora 41 ARM64 (matches your Linux laptop)
  config.vm.box = "generic-a64/fedora39"
  config.vm.hostname = "durian-dev"

  # QEMU provider for Apple Silicon
  config.vm.provider "qemu" do |qe|
    qe.memory = "4096"       # 4GB RAM (headless is fine with this)
    qe.cpus = 4              # 4 cores
    qe.arch = "aarch64"      # ARM64 to match host (no emulation overhead)
  end

  # /vagrant = this repo, auto-mounted via rsync
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", "bazel-*", ".DS_Store"]

  # Provision: install Bazel + Qt6 dev headers
  config.vm.provision "shell", inline: <<-SHELL
    set -e

    # Bazel via Bazelisk
    if ! command -v bazel &> /dev/null; then
      echo "Installing Bazelisk..."
      curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-arm64 -o /usr/local/bin/bazel
      chmod +x /usr/local/bin/bazel
    fi

    # Qt6 dev headers (for Linux GUI build)
    echo "Installing Qt6 dev packages..."
    dnf install -y -q qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtwebengine-devel

    # Go (for CLI build/test)
    if ! command -v go &> /dev/null; then
      echo "Installing Go..."
      dnf install -y -q golang
    fi

    echo "Done. Run: cd /vagrant && bazel test //cli/... //linux:all --repo_env=QTDIR=/usr"
  SHELL
end
