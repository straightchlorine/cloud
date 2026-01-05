# Testing

Testing requirements and current setup for infrastructure validation.

## Requirements

### Pre-deployment Validation

- All required variables defined
- Network connectivity verified
- Dependencies resolved
- Service ports available

### Infrastructure Validation

- All services deployed correctly
- Health checks passing
- Backups functioning
- Alerts configured

### Manual Testing

- Service functionality verified
- Configuration correctness validated
- Integration between services confirmed

## Current Testing Setup

### Pre-commit Hooks

Configured in `.pre-commit-config.yaml`:

```bash
pre-commit run --all-files  # Run all checks locally
```

Checks performed:

- **shellcheck**: Shell script validation
- **yamllint**: YAML format validation
- **ansible-lint**: Ansible syntax and best practices
- **detect-private-key**: Accidental credential detection
- **jinja2-lint**: Jinja2 template validation

### Validation Playbook

Comprehensive infrastructure validation:

```bash
# Full validation
ansible-playbook -i inventory/production/hosts.yml \
  validate-infrastructure.yml --ask-vault-pass

# Specific validation type
ansible-playbook -i inventory/production/hosts.yml \
  validate-infrastructure.yml --ask-vault-pass -e validation_type=backup

# Quick mode
ansible-playbook -i inventory/production/hosts.yml \
  validate-infrastructure.yml --ask-vault-pass -e quick_mode=true
```

Validation types:

- `full` - Complete infrastructure validation
- `backup` - Backup configuration and connectivity
- `vault` - Vault variable completeness
- `pre_deployment` - Pre-flight checks
- `post_deployment` - Post-deployment verification
- `service_startup` - Service health checks
- `ssl_domain` - SSL certificate and domain validation

### Service Health Checks

Deployed roles include validation tasks that verify:

- Required variables are set
- Services are running
- Health endpoints responding
- Configuration correctness

## Future Testing

### Woodpecker CI on Codeberg

Testing infrastructure is being migrated to Woodpecker CI:

- Git-native CI/CD pipeline
- Automated test execution on push
- Self-hosted runner on infrastructure
- Detailed test reporting and logs

Migration status: Planned for implementation

## Manual Testing Procedures

### DNS Service Validation

```bash
# Test DNS resolution
dig @192.168.20.10 google.com

# Check Pi-hole admin interface
curl -I http://192.168.20.10/admin

# Test NTP service
ntpdate -q 192.168.20.10
```

### Music Stack Validation

```bash
# Test Navidrome endpoint
curl http://192.168.20.15:4545/health

# Check music library mount
ssh pi-music df -h /mnt/music
```

### Automation Stack Validation

```bash
# Test Traefik dashboard
curl -I https://traefik.yourdomain.com

# Check InfluxDB endpoint
curl http://192.168.20.20:8086/health

# Test Vaultwarden API
curl http://192.168.20.20:80/identity/connect/token -X POST
```

### Monitoring Stack Validation

```bash
# Test Prometheus targets
curl http://192.168.20.5:9090/api/v1/targets

# Check Grafana dashboards
curl http://admin:password@192.168.20.5:3000/api/dashboards/db

# Test Loki log ingestion
curl -H "Content-Type: application/json" -XPOST \
  "http://192.168.20.5:3100/loki/api/v1/push" \
  --data-raw '{"streams": [{"stream": {"test": "value"}, \
  "values": [["1670000000000000000", "test message"]]}]}'
```

### Backup Validation

```bash
# Check backup status
sudo systemctl status backup-coordinator

# List recent backups
sudo -u backup restic snapshots --repository [repo]

# Test restore operation
sudo -u backup restic restore latest --dry-run --repository [repo]
```

## Adding Tests

### Adding Validation Tasks

Add validation tasks to role `tasks/validate.yml`:

```yaml
- name: Validate required variables
  ansible.builtin.fail:
    msg: "{{ item }} must be defined"
  when: vars[item] is not defined
  loop:
    - vault_service_password
    - service_config_option
```

### Adding Health Checks

Health check tasks in role:

```yaml
- name: Check service health
  ansible.builtin.uri:
    url: "http://localhost:{{ service_port }}/health"
    status_code: 200
  retries: 3
  delay: 5
```

### Adding Backup Tests

Restore testing configuration in `group_vars/all/backup.yml`:

```yaml
restore_testing:
  enabled: true
  frequency: "weekly"
  test_percentage: 10
  performance_benchmarking: true
```
