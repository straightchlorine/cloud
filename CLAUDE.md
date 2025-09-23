# Claude Code Development Guidelines

This document outlines the development principles and guidelines for maintaining this Ansible-based infrastructure deployment system.

## Core Principles

### 1. No Redundancy
- **Single Source of Truth**: Common functionality must be centralized in shared roles
- **DRY Principle**: Never duplicate code, tasks, or configuration
- **Common Roles**: Use `roles/common/tasks/` for shared functionality (Docker, packages, network facts, etc.)
- **Consolidated Templates**: Reuse templates and configuration patterns across roles

### 2. Fail-Fast Validation
- **No Defaults**: Never use `| default()` - force explicit configuration
- **Pre-deployment Validation**: Validate all required variables and dependencies before deployment
- **Required Variables**: Use validation tasks to ensure critical variables are set
- **Explicit Configuration**: All configuration must be intentionally set, not assumed

### 3. Generalized Roles
- **Role Abstraction**: Create roles that work across multiple hosts and scenarios
- **Parameterization**: Use variables to make roles flexible and reusable
- **Common Tasks**: Extract common patterns into shared task files
- **Scalable Design**: Design roles to work with 1 host or 100 hosts

### 4. No Hardcoding
- **Dynamic Detection**: Use Ansible facts for system information (IPs, interfaces, architecture)
- **Variable References**: Use variables for all configuration values
- **Environment Adaptation**: Code should adapt to different environments automatically
- **Network Facts**: Use `primary_interface`, `primary_ip`, `host_ip_cidr` instead of hardcoded values

### 5. Security First
- **Principle of Least Privilege**: Minimal access and permissions
- **Container Isolation**: Use Docker user namespace mapping (`userns-remap: default`)
- **Interface Binding**: Bind management interfaces to localhost only
- **Authentication Required**: No unauthenticated access to management interfaces
- **GPG Verification**: Verify signatures for all downloaded binaries
- **Secure Defaults**: When security options exist, choose the most secure

## Implementation Guidelines

### Variable Management
```yaml
# ❌ Wrong - uses defaults
pihole_interface: "{{ primary_interface | default('eth0') }}"

# ✅ Correct - explicit, will fail if undefined
pihole_interface: "{{ primary_interface }}"
```

### Role Structure
```yaml
# ❌ Wrong - duplicated across roles
- name: Install packages
  apt: name={{ packages }} state=present

# ✅ Correct - use common role
- name: Include common package management
  include_role: name=common tasks_from=packages
```

### Network Configuration
```yaml
# ❌ Wrong - hardcoded IP
pihole_ipv4_address: 192.168.20.10/24

# ✅ Correct - dynamic detection
pihole_ipv4_address: "{{ host_ip_cidr }}"
```

### Security Configuration
```yaml
# ❌ Wrong - exposed interface
traefik_dashboard_port: 8080

# ✅ Correct - localhost only
ports: "127.0.0.1:{{ traefik_dashboard_port }}:8080"
```

## Validation Requirements

### Pre-deployment Checks
- All required variables must be defined in host_vars or group_vars
- Network connectivity and interface availability
- Required directories and permissions
- Service dependencies (Docker running, etc.)

### Required Variables List
Always validate these variable categories:
- Domain and SSL configuration (`vault_domain_name`, `vault_letsencrypt_email`)
- Service-specific passwords and tokens
- Network configuration (automatically detected, but validated)
- Storage paths and mount points

### Validation Task Pattern
```yaml
- name: Validate required variables
  ansible.builtin.fail:
    msg: "{{ item }} must be defined"
  when: vars[item] is not defined
  loop:
    - vault_domain_name
    - vault_letsencrypt_email
```

## Role Organization

### Common Role Structure
```
roles/common/
├── tasks/
│   ├── detect_hardware.yml    # Pi model detection
│   ├── docker.yml            # Docker with user namespaces
│   ├── network_facts.yml     # Network discovery
│   └── packages.yml          # Package management
├── defaults/main.yml
└── handlers/main.yml
```

### Service Role Pattern
```yaml
- name: Include validation
  include_tasks: validate.yml

- name: Gather network facts
  include_role: name=common tasks_from=network_facts

- name: Include common packages
  include_role: name=common tasks_from=packages

- name: Include service-specific setup
  include_tasks: service.yml

- name: Configure firewall
  include_role: name=firewall
```

## Documentation Standards

### Code Comments
- No inline comments unless explaining complex logic
- Self-documenting variable names and task descriptions
- README files for complex roles only when absolutely necessary

### Configuration Comments
```yaml
# ✅ Good - explains the why
# Docker user namespace mapping for container isolation
userns-remap: default

# ❌ Bad - explains the what (obvious)
# Set the domain name
domain_name: "{{ vault_domain_name }}"
```

## Testing and Deployment

### Deployment Order
1. Validation tasks (fail-fast if misconfigured)
2. Common setup (packages, Docker, network facts)
3. Service-specific configuration
4. Health checks and verification

### Error Handling
- Use `failed_when` for expected failure conditions
- Use `ignore_errors: true` sparingly and with explicit reasoning
- Implement rollback handlers for critical failures

## Maintenance Guidelines

### Adding New Features
1. Check if functionality already exists in common roles
2. If similar functionality exists, generalize it instead of duplicating
3. Add validation for any new required variables
4. Test with minimal configuration (no defaults)

### Refactoring Existing Code
1. Identify redundant patterns across roles
2. Extract common functionality to shared roles
3. Remove defaults and add explicit validation
4. Replace hardcoded values with dynamic facts

### Version Control
- Commit frequently with descriptive messages
- Tag major changes and refactoring milestones
- Document breaking changes that require configuration updates

---

**Remember**: If you're about to copy-paste code or add a default value, stop and think about how to make it reusable and explicit instead.