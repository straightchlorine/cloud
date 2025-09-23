# DNS Role - Secure Pi-hole Installation

This role deploys Pi-hole DNS server using secure installation practices.

## Security Enhancements

### Pi-hole Installation Security
The role implements **secure installation practices** recommended by Pi-hole developers:

```yaml
# Secure installation method (replaces curl-to-bash)
✅ Official GitHub repository clone
✅ Pinned version tags for reproducibility
✅ Commit hash verification for integrity
✅ Code review opportunity before installation
✅ Verifiable source and provenance
```

**Before (Insecure)**:
```bash
curl -sSL https://install.pi-hole.net | bash
```

**After (Secure)**:
```bash
git clone --depth 1 --branch v5.18.3 https://github.com/pi-hole/pi-hole.git
cd pi-hole/automated\ install/
bash basic-install.sh --unattended
```

### Configuration Variables

#### Security Configuration
```yaml
pihole_git_repo: "https://github.com/pi-hole/pi-hole.git"
pihole_version: "v5.18.3"  # Pin to verified release
pihole_verify_commit: true
```

#### Required Variables (must be in vault)
```yaml
vault_pihole_webpassword: "secure-admin-password"
vault_pihole_admin_password: "secure-admin-password"
```

## Installation Process

1. **Repository Clone**: Downloads official Pi-hole repository at specified version
2. **Verification**: Validates installer script exists and verifies commit hash
3. **Installation**: Runs unattended installation from verified source
4. **Configuration**: Applies Pi-hole settings from templates
5. **Cleanup**: Removes temporary repository after installation

## Security Benefits

- **No Remote Code Execution**: Eliminates curl-to-bash security risk
- **Version Pinning**: Ensures reproducible, tested deployments
- **Source Verification**: Cryptographic verification of installation source
- **Audit Trail**: Clear record of exact Pi-hole version deployed
- **Code Review**: Opportunity to inspect installation script before execution

## Dependencies

- `git` package (automatically installed)
- Network connectivity to GitHub
- Sudo privileges for Pi-hole installation

## Validation

The role includes comprehensive validation that checks:
- Required variables are defined
- Network interface availability
- DNS server reachability
- Port availability (53, 80)
- Sufficient disk space
- Internet connectivity

Run validation before deployment:
```bash
ansible-playbook -i inventory validate-deployment.yml --limit pi-dns
```