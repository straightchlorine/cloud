#!/bin/bash
# Setup git hooks for testing infrastructure
# Installs pre-commit and pre-push hooks for comprehensive testing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==============================================="
echo "Setting up git hooks for testing..."
echo "==============================================="

# Check if we're in a git repository
if [ ! -d .git ]; then
    echo "ERROR: Not a git repository. Please run this from the repository root."
    exit 1
fi

# Install pre-commit if not already installed
if ! command -v pre-commit &> /dev/null; then
    echo ""
    echo "pre-commit not found. Installing..."
    pip install pre-commit > /dev/null
else
    echo ""
    echo "✓ pre-commit already installed"
fi

# Verify version
pre_commit_version=$(pre-commit --version 2>/dev/null || echo "unknown")
echo "  Version: $pre_commit_version"

# Install pre-commit hook
echo ""
echo "Installing pre-commit hook..."
pre-commit install > /dev/null 2>&1 || {
    echo "ERROR: Failed to install pre-commit hook"
    exit 1
}
echo "✓ Pre-commit hook installed"

# Install pre-push hook
echo ""
echo "Installing pre-push hook..."
pre-commit install --hook-type pre-push -c .pre-push-config.yaml > /dev/null 2>&1 || {
    echo "ERROR: Failed to install pre-push hook"
    exit 1
}
echo "✓ Pre-push hook installed"

# Update pre-commit frameworks (optional but recommended)
echo ""
echo "Updating pre-commit repositories (this may take a moment)..."
pre-commit autoupdate > /dev/null 2>&1 || {
    echo "WARNING: Failed to auto-update pre-commit hooks"
    echo "You can update manually with: pre-commit autoupdate"
}

# Final verification
echo ""
echo "==============================================="
echo "Verifying hook installation..."
echo "==============================================="

if [ -f .git/hooks/pre-commit ] && [ -x .git/hooks/pre-commit ]; then
    echo "✓ Pre-commit hook is installed and executable"
else
    echo "ERROR: Pre-commit hook installation failed"
    exit 1
fi

if [ -f .git/hooks/pre-push ] && [ -x .git/hooks/pre-push ]; then
    echo "✓ Pre-push hook is installed and executable"
else
    echo "ERROR: Pre-push hook installation failed"
    exit 1
fi

# Display usage information
echo ""
echo "==============================================="
echo "Git hooks configured successfully!"
echo "==============================================="
echo ""
echo "Usage:"
echo "  - Pre-commit: Runs automatically on 'git commit'"
echo "  - Pre-push: Runs automatically on 'git push'"
echo ""
echo "Manual execution:"
echo "  - Run pre-commit checks: pre-commit run --all-files"
echo "  - Run pre-push checks: pre-commit run --hook-stage push --all-files"
echo ""
echo "Skip hooks (not recommended):"
echo "  - Skip pre-commit: git commit --no-verify"
echo "  - Skip pre-push: git push --no-verify"
echo ""
echo "Update hooks:"
echo "  - Update to latest versions: pre-commit autoupdate"
echo "  - Clean cache: pre-commit clean"
echo ""
