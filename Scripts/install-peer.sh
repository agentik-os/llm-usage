#!/bin/sh
set -eu
connector_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$connector_dir/quotabar-peer.py" install
