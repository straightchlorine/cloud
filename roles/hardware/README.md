# hardware

Detects the device's **hardware platform** from the `device_type` host var and
derives the matching resource-limit profile. Read-only.

## Usage

```yaml
- name: Detect hardware for resource allocation
  ansible.builtin.include_role:
    name: hardware
```

Requires `device_type` to be set in host_vars (e.g. `rpi4b`, `rpi3b`,
`debian_vm`, `arch_linux`) — deliberately **no auto-detection** fallback (a
wrong guess silently mis-sizes container limits).

## Facts published

| Variable           | Meaning                                                        |
|--------------------|----------------------------------------------------------------|
| `hardware_platform`| Platform key used for the profile lookup (`rpi4`, `rpi3`, `rpi2`, `pc`, `unknown`) |
| `hardware_details` | Live resource facts: `memory_mb`, `cpu_cores`, `cpu_count`, `vcpus` |
| `hardware_limits`  | Per-service resource profile for `hardware_platform` (from `hardware_profiles`) |

Consume `hardware_limits.traefik.memory` etc. when sizing container services.

## Configuration

`hardware_profiles` live in `defaults/main.yml` and are keyed by
`hardware_platform`; `unknown`/`rpi2` reuse a conservative profile.
