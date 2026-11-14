#!/bin/sh
printf '%s|%s\n' "$1" "$3" >> /run/molecule-ntfy.log
printf '%s|%s\n' "$1" "$(printf '%s' "$2" | tr '\n' '^')" >> /run/molecule-ntfy-body.log
