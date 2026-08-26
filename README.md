# Infrastructure Automation

[![Build Status](https://ci.codextechnologies.org/api/badges/2/status.svg)](https://ci.codextechnologies.org/repos/2)

Ansible-based homelab deployment.

**Repository:**
[Codeberg](https://codeberg.org/piotrkrzysztof/cloud) (primary) ·
[GitHub](https://github.com/straightchlorine/cloud) (mirror)

## Architecture

```mermaid
graph TB
    subgraph VLAN["Services VLAN - (192.168.20.0/24)"]
        direction LR
        dns["<b>pi-dns</b><br/>Pi-hole + NTP"]
        music["<b>pi-music</b><br/>Navidrome + yt-dlp + Beets"]
        automation["<b>pi-automation</b><br/>Vaultwarden + Firefly III<br/> + MariaDB + Watchtower"]
        monitoring["<b>debian-monitoring</b><br/>Grafana + Prometheus<br/>Loki + Alertmanager"]
    end
    backup["Backup Coordinator<br/>(Restic -> Hetzner)"]
    cloudflare["Cloudflare<br/>(DNS + SSL)"]

    VLAN -->|Backups| backup
    VLAN -->|DNS/Certs| cloudflare
    dns -.->|Metrics| monitoring
    music -.->|Metrics| monitoring
    automation -.->|Metrics| monitoring
```

## Quick Start

```bash
just setup          # Create venv, install deps, collections, hooks
just deploy         # Full infrastructure (with confirmation)
just lint           # Ansible-lint + yamllint
just test           # Molecule tests (all roles)
just validate full  # End-to-end infrastructure validation
```

### Deploy Individual Services

```bash
just deploy-service playbooks/music-stack.yml
just deploy-service playbooks/automation-stack.yml
```

Or directly:

```bash
ansible-playbook -i inventory/production/hosts.yml \
  playbooks/site.yml --limit dns --ask-vault-pass
```

## Roles

```
roles/
├── common/              # Docker, packages, network facts, backup
├── dns/                 # Pi-hole DNS + Chrony NTP
├── music-stack/         # Navidrome + yt-dlp + Beets
├── automation/          # Vaultwarden + Firefly III + MariaDB + Watchtower
├── monitoring/          # Grafana + Prometheus + Loki + Alertmanager
├── backup/              # Restic multi-tier backup (standalone + coordinator)
├── backup-system/       # Enterprise backup coordinator
├── firewall/            # UFW configuration
└── prometheus-exporters/ # Node, Docker, Pi-hole, Pi hardware exporters
```

## Configuration

All secrets live in `inventory/production/group_vars/all/vault.yml`. See
[vault.yml.example](inventory/production/group_vars/vault.yml.example).

Host-specific config: `inventory/production/host_vars/{hostname}.yml`
