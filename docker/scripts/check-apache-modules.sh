#!/usr/bin/env bash
# check-apache-modules.sh

set -euo pipefail

required=(rewrite headers expires)
enabled=$(apache2ctl -M 2>/dev/null | awk '{print $1}' | sed 's/_module//')

missing=()
for mod in "${required[@]}"; do
  echo "$enabled" | grep -q "^${mod}$" || missing+=("$mod")
done

if ((${#missing[@]})); then
  echo "WARN(12): Missing Apache modules: ${missing[*]}"
else
  echo "OK: All required Apache modules are enabled"
fi
exit 0
