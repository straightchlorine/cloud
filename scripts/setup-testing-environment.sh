#!/bin/bash
# Setup testing environment for Ansible infrastructure
# Installs all dependencies for local testing with Molecule and Podman

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==============================================="
echo "Setting up testing environment..."
echo "==============================================="

# Check Python version
python_version=$(python3 --version 2>&1 | cut -d' ' -f2)
echo "Python version: $python_version"

# Verify Python 3.10+
required_version="3.10"
if ! python3 -c "import sys; sys.exit(0 if tuple(map(int, sys.version.split()[:1][0].split('.'))) >= tuple(map(int, '$required_version'.split('.'))) else 1)" 2>/dev/null; then
    echo "ERROR: Python 3.10 or higher required. Current: $python_version"
    exit 1
fi

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo ""
    echo "Creating Python virtual environment..."
    python3 -m venv .venv
else
    echo ""
    echo "Using existing Python virtual environment..."
fi

# Activate virtual environment
echo "Activating virtual environment..."
source .venv/bin/activate

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip wheel setuptools > /dev/null

# Install Python requirements
echo "Installing Python dependencies from requirements.txt..."
pip install -r requirements.txt > /dev/null

# Install Ansible collections
echo "Installing Ansible Galaxy collections..."
ansible-galaxy collection install -r requirements.yml --force > /dev/null

# Check for Podman
echo ""
echo "Checking for Podman installation..."
if ! command -v podman &> /dev/null; then
    echo "WARNING: Podman not found. Installing..."
    if [ -f /etc/debian_version ]; then
        echo "  Debian/Ubuntu system detected. Run:"
        echo "  sudo apt update && sudo apt install -y podman"
    elif [ -f /etc/arch-release ]; then
        echo "  Arch Linux system detected. Run:"
        echo "  sudo pacman -S --noconfirm podman"
    else
        echo "  Please install Podman manually for your distribution"
        echo "  Visit: https://podman.io/docs/installation"
    fi
else
    echo "✓ Podman found: $(podman --version)"
fi

# Verify installations
echo ""
echo "==============================================="
echo "Verifying installations..."
echo "==============================================="

# Check Ansible
ansible_version=$(ansible --version 2>/dev/null | head -n1)
echo "✓ Ansible: $ansible_version"

# Check Molecule
molecule_version=$(molecule --version 2>/dev/null)
echo "✓ Molecule: $molecule_version"

# Check collections
echo ""
echo "Installed collections:"
ansible-galaxy collection list | grep -E "ansible|community|containers" || echo "  (Collections installed but not listed)"

# Setup git hooks
echo ""
echo "==============================================="
echo "Setting up git hooks..."
echo "==============================================="

if bash scripts/setup-git-hooks.sh; then
    echo "✓ Git hooks configured"
else
    echo "WARNING: Git hooks setup encountered an issue"
    echo "You can configure them manually with: bash scripts/setup-git-hooks.sh"
fi

# Final summary
echo ""
echo "==============================================="
echo "Testing environment setup complete!"
echo "==============================================="
echo ""
echo "To activate the environment in future sessions:"
echo "  source .venv/bin/activate"
echo ""
echo "To run tests:"
echo "  cd roles/common && molecule test"
echo ""
echo "To run specific scenario:"
echo "  cd roles/common && molecule test --scenario-name docker-installation"
echo ""
echo "To run pre-commit checks:"
echo "  pre-commit run --all-files"
echo ""
echo "To run pre-push checks:"
echo "  pre-commit run --hook-stage push --all-files"
echo ""
