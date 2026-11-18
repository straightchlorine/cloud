# alloy

Grafana Alloy on RPM hosts: ships the systemd journal to the fleet Loki and, with
`alloy_metrics_enabled`, host metrics to the fleet Prometheus, both over the tailnet.

## Why a sub-role of honeypot

The CentOS Stream honeypot is the only host that runs it. `roles/honeypot` includes this role
(`honeypot_alloy_enabled`) and passes `alloy_textfile_directory`, so the honeypot's own metric files
reach Prometheus. It installs through `yum_repository` and `ansible.builtin.dnf` only, so it cannot run on
Debian, Arch or Gentoo hosts; the Debian fleet is scraped through node exporters instead. Forwarding
from the other hosts is planned, not implemented.

## Inputs

`alloy_loki_url` (full push path, validated), `alloy_journal_units`, `alloy_metrics_enabled`,
`alloy_prometheus_url`, `alloy_textfile_directory`; the rest are in `defaults/main.yml`. The Loki and
Prometheus sinks are NodePorts on the tailnet address in `alloy_fleet_address`, plain HTTP because
WireGuard encrypts the hop.

## Tests

No molecule scenario covers it: the honeypot scenarios run selected task files, not `main.yml`, so
`honeypot_alloy_enabled` is never exercised. `validate.yml` (full push URLs, absolute textfile path) and the
post-deploy readiness, sink and textfile checks in `tasks/main.yml` are the only gates.
