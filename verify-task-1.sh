#!/bin/bash
# Verification script for Task 1: Repository skeleton + Kubespray submodule
# This script checks all required files and structure before implementation

set -e

REPO_ROOT="/Users/ai_ovsyannikov/Documents/claude/k8s_va"
FAILED=0
PASSED=0

check_file() {
  local path="$1"
  local description="$2"
  if [ -f "$path" ]; then
    echo "✓ $description: $path"
    ((PASSED++))
    return 0
  else
    echo "✗ $description: MISSING $path"
    ((FAILED++))
    return 1
  fi
}

check_dir() {
  local path="$1"
  local description="$2"
  if [ -d "$path" ]; then
    echo "✓ $description: $path"
    ((PASSED++))
    return 0
  else
    echo "✗ $description: MISSING $path"
    ((FAILED++))
    return 1
  fi
}

check_content() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if grep -q "$pattern" "$path" 2>/dev/null; then
    echo "✓ $description"
    ((PASSED++))
    return 0
  else
    echo "✗ $description"
    ((FAILED++))
    return 1
  fi
}

echo "=== Task 1 Verification Checks ==="
echo

echo "Checking Git initialization..."
check_dir "$REPO_ROOT/.git" "Git repository"
if [ -d "$REPO_ROOT/.git" ]; then
  cd "$REPO_ROOT"
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$BRANCH" = "main" ]; then
    echo "✓ On main branch"
    ((PASSED++))
  else
    echo "✗ Not on main branch (current: $BRANCH)"
    ((FAILED++))
  fi
fi
echo

echo "Checking core repository files..."
check_file "$REPO_ROOT/.gitignore" ".gitignore file"
check_file "$REPO_ROOT/.gitmodules" ".gitmodules file"
check_file "$REPO_ROOT/Makefile" "Makefile"
check_file "$REPO_ROOT/README.md" "README.md"
check_file "$REPO_ROOT/ansible/ansible.cfg" "ansible/ansible.cfg"
echo

echo "Checking .gitignore content..."
check_content "$REPO_ROOT/.gitignore" "*.retry" ".gitignore has *.retry"
check_content "$REPO_ROOT/.gitignore" ".vault_pass" ".gitignore has .vault_pass"
check_content "$REPO_ROOT/.gitignore" "kubeconfig" ".gitignore has kubeconfig"
echo

echo "Checking .gitmodules content..."
check_content "$REPO_ROOT/.gitmodules" "submodule \"ansible/kubespray\"" ".gitmodules has kubespray submodule"
check_content "$REPO_ROOT/.gitmodules" "v2.26.0" ".gitmodules has v2.26.0"
echo

echo "Checking ansible/ansible.cfg content..."
check_content "$REPO_ROOT/ansible/ansible.cfg" "inventory.*hosts.yaml" "ansible.cfg has inventory setting"
check_content "$REPO_ROOT/ansible/ansible.cfg" "roles_path" "ansible.cfg has roles_path"
check_content "$REPO_ROOT/ansible/ansible.cfg" "pipelining.*True" "ansible.cfg has pipelining"
echo

echo "Checking Makefile content..."
check_content "$REPO_ROOT/Makefile" "host-prep" "Makefile has host-prep target"
check_content "$REPO_ROOT/Makefile" "bootstrap" "Makefile has bootstrap target"
check_content "$REPO_ROOT/Makefile" "post-bootstrap" "Makefile has post-bootstrap target"
check_content "$REPO_ROOT/Makefile" "reset" "Makefile has reset target"
echo

echo "Checking README.md content..."
check_content "$REPO_ROOT/README.md" "k8s-platform" "README.md has project title"
check_content "$REPO_ROOT/README.md" "Quick start" "README.md has Quick start section"
echo

echo "Checking Kubespray placeholder..."
check_dir "$REPO_ROOT/ansible/kubespray" "kubespray directory placeholder"
check_file "$REPO_ROOT/ansible/kubespray/README.md" "kubespray/README.md"
echo

echo "Checking docs directory..."
check_dir "$REPO_ROOT/docs" "docs directory (should exist)"
check_dir "$REPO_ROOT/docs/superpowers" "docs/superpowers (existing)"
echo

echo "Checking git commits..."
if [ -d "$REPO_ROOT/.git" ]; then
  cd "$REPO_ROOT"
  COMMITS=$(git log --oneline 2>/dev/null | wc -l)
  if [ "$COMMITS" -gt 0 ]; then
    echo "✓ Initial commit exists (total: $COMMITS commits)"
    ((PASSED++))
    LAST_MSG=$(git log -1 --format=%B 2>/dev/null | head -1)
    echo "  Last commit: $LAST_MSG"
  else
    echo "✗ No commits found"
    ((FAILED++))
  fi
fi
echo

echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo

if [ $FAILED -eq 0 ]; then
  echo "✓ All checks passed!"
  exit 0
else
  echo "✗ Some checks failed"
  exit 1
fi
