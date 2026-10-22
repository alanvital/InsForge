#!/bin/sh
# Drop to the `node` user, joining the Docker socket's group first if one is mounted.
#
# The compute Docker driver needs to reach /var/run/docker.sock, which is mode 660
# root:docker on Linux and root:root on Docker Desktop. The group id differs per host
# — 993 on Amazon Linux 2023, commonly 999 on Debian/Ubuntu, 0 on Docker Desktop — so
# it cannot be baked into the image, and asking an operator to supply it means a value
# they have to look up and can silently get wrong (a mismatched group is EACCES, which
# surfaces as "Docker never appears in the dashboard" rather than an error).
#
# The container can read the id off the socket instead. That is the whole reason this
# starts as root: get the group, join it, then hand off to `node` for everything after.
set -e

SOCKET="${DOCKER_SOCKET_PATH:-/var/run/docker.sock}"

# Only root can change group membership. A deployment that pins `user:` in its compose
# file has already decided who it runs as, so respect that and run the command as-is.
if [ "$(id -u)" = '0' ]; then
  # Volumes written by older releases that ran as root stay root-owned, and `node`
  # can then neither upload files nor rotate the log file (winston spins at 100% CPU
  # retrying the rename, so the migrate step never finishes). Hand them to `node`
  # once; later starts see the right owner and skip the recursive chown.
  for dir in "${STORAGE_DIR:-/insforge-storage}" "${LOGS_DIR:-/insforge-logs}"; do
    if [ -d "$dir" ] && [ "$(stat -c '%u' "$dir")" != "$(id -u node)" ]; then
      chown -R node:node "$dir"
    fi
  done

  if [ -S "$SOCKET" ]; then
    socket_gid="$(stat -c '%g' "$SOCKET")"

    if [ "$socket_gid" = '0' ]; then
      # Docker Desktop: the socket is root-owned, so the root group is the one to join.
      target_group='root'
    else
      # Reuse the group that already holds this id — addgroup fails on a duplicate id,
      # and an image that ships its own group at the same number is normal.
      target_group="$(getent group "$socket_gid" | cut -d: -f1)"
      if [ -z "$target_group" ]; then
        target_group='docker'
        addgroup -g "$socket_gid" "$target_group"
      fi
    fi

    # Idempotent: adduser on an existing member is a no-op that still exits 0.
    adduser node "$target_group" >/dev/null 2>&1 || true
  fi

  exec su-exec node "$@"
fi

exec "$@"
