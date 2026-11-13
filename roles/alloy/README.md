# alloy

Grafana Alloy on RPM hosts: ships the systemd journal to the fleet Loki and, with
`alloy_metrics_enabled`, host metrics to the fleet Prometheus, both over the tailnet.

## Why a sub-role of honeypot

The CentOS Stream honeypot is the only host that runs it. `roles/honeypot` includes this role
(`honeypot_alloy_enabled`) and passes `alloy_textfile_directory`, so the honeypot's own metric files
reach Prometheus. It is dnf-only: the repository task uses `yum_repository` and the package task `dnf`,
so it does not run on the Debian fleet, which scrapes node exporters instead.

## Inputs

`alloy_loki_url` (full push path, validated), `alloy_journal_units`, `alloy_metrics_enabled`,
`alloy_prometheus_url`, `alloy_textfile_directory`; the rest are in `defaults/main.yml`. The Loki and
Prometheus sinks are NodePorts on the tailnet address in `alloy_fleet_address`, plain HTTP because
WireGuard encrypts the hop.

## Tests

No molecule scenario, and the honeypot scenarios leave `honeypot_alloy_enabled` off; `validate.yml` is the only
automated gate.
