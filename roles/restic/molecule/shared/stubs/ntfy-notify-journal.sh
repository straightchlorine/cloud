#!/bin/sh
# The notify units have a private /tmp and a read-only /, so the journal carries the messages.
logger -t molecule-ntfy "$1|$3"
logger -t molecule-ntfy-body "$1|$(printf '%s' "$2" | tr '\n' '^')"
