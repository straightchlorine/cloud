#!/bin/sh
d=/run/molecule-nmcli
[ ! -e "$d/rc" ] || { echo "Error: NetworkManager is not running." >&2; exit "$(cat "$d/rc")"; }
# The arguments are checked, so a changed command line in the engine fails here.
case "$*" in
  "--terse --escape no --fields NAME,TYPE connection show --active") cat "$d/connections" ;;
  "--terse --escape no --fields GENERAL.METERED,GENERAL.CONNECTION device show") cat "$d/devices" ;;
  *) echo "unexpected nmcli arguments: $*" >&2; exit 2 ;;
esac
