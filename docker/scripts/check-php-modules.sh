#!/usr/bin/env bash
# check-php-modules.sh — list required PHP extensions and warn if any are missing

set -euo pipefail

# Extensions MediaWiki usually expects
required=(intl gd exif zip mbstring xml opcache curl json mysqli fileinfo)

# Get current PHP modules
current=$(php -m | sort)

# Track missing ones
missing=()
for ext in "${required[@]}"; do
  echo "$current" | grep -qi "^${ext}$" || missing+=("$ext")
done

if ((${#missing[@]})); then
  echo "WARN(11): Missing PHP extensions: ${missing[*]}"
else
  echo "OK: All required PHP extensions are present"
fi

# Always exit 0 (diagnostic only)
exit 0
