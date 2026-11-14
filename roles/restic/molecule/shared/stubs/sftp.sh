#!/bin/sh
# The check reads its batch from stdin; the reply is chosen by /run/molecule-sftp.
cat > /dev/null
case "$(cat /run/molecule-sftp)" in
  fail) echo "Connection closed" >&2; exit 1 ;;
  garbage) echo "df: not supported" ;;
  *) echo "        Size         Used        Avail       (root)    %Capacity"
     cat /run/molecule-sftp ;;
esac
