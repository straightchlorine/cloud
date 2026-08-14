# os

Discovers the device's **OS + CPU architecture in one go** and publishes them
as normalized `os_*` facts, so any other role can validate the OS and select
the correct binary/package architecture for a download without re-implementing
Ansible fact mapping.

## Usage

```yaml
# In any role/play that needs to know what OS/arch it is running on:
- name: Discover the device OS and architecture
  ansible.builtin.include_role:
    name: os
```

The role is read-only, idempotent and dependency-free — safe to include first.

## Facts published

| Variable             | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `os_family`          | OS family (e.g. `Debian`)                                            |
| `os_name`            | Distribution name (e.g. `Debian`)                                    |
| `os_version`         | Major version (e.g. `12`)                                            |
| `os_codename`        | Release codename (e.g. `bookworm`)                                   |
| `os_is_debian`       | `true` when the OS family is Debian                                  |
| `os_arch_machine`    | Ansible architecture fact (e.g. `aarch64`, `armv7l`, `x86_64`)       |
| `os_arch_raw`        | Raw `uname -m` value when available                                  |
| `os_arch_download`   | Canonical `linux-<arch>` download suffix (e.g. `amd64`, `arm64`, `armv7`) |
| `os_is_arm`          | `true` for any ARM architecture (use for "single arm binary" projects) |
| `os_is_64bit`        | `true` when the architecture is 64-bit                               |

## Example: download the right arch

```yaml
# node_exporter-style release (linux-arm64 / linux-amd64 / linux-armv7):
url: >-
  https://example.com/binary-linux-{{ os_arch_download }}

# pihole-exporter-style project that publishes a single linux-arm binary:
url: >-
  https://example.com/binary-linux-{{ 'arm' if os_is_arm else os_arch_download }}
```

## Configuration

`os_supported_families` and `os_arch_download_map` live in `defaults/main.yml`
and can be overridden per host if a device needs a different mapping.
