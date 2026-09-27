#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout key.pem -out cert.pem -nodes -days 14 \
  -subj "/CN=benchmark" \
  -addext "subjectAltName=IP:10.0.0.1,IP:10.0.0.2,IP:127.0.0.1"

echo "regenerated $(pwd)/cert.pem + key.pem — valid 14 days; re-run before then."
