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
`rpizero2w`, `debian`, `debian_vm`, `cloud_vm`, `arch_linux`; the full list is
`hardware_device_platforms`) - deliberately **no auto-detection** fallback (a wrong
guess silently mis-sizes container limits). An unlisted `device_type` fails the role
with the list of valid ones.

## Facts published

| Variable           | Meaning                                                        |
|--------------------|----------------------------------------------------------------|
| `hardware_platform`| Platform key used for the profile lookup (`rpi4`, `rpi3`, `rpi2`, `rpizero2w`, `pc`) |
| `hardware_details` | Live resource facts: `memory_mb`, `cpu_cores`, `cpu_count`, `vcpus` |
| `hardware_limits`  | Per-service resource profile for `hardware_platform` (from `hardware_profiles`) |

Consume `hardware_limits.navidrome.memory` etc. when sizing container services (media is the
only consumer; add a service to every platform profile when a new role reads one).

## Configuration

`hardware_profiles` live in `defaults/main.yml` and are keyed by
`hardware_platform`; `rpizero2w` is sized for a 512MB board (an eighth of an
rpi4), and `rpi2` uses a conservative profile.
