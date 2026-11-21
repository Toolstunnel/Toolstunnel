#!/usr/bin/env bash
# Toolstunnel installer - run as root.
set -eu

# >>> Change Toolstunnel to your GitHub username <<<
REPO_RAW="https://raw.githubusercontent.com/Toolstunnel/Toolstunnel/main"

[[ $EUID -eq 0 ]] || { echo "Please run as root (sudo)."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required. Install it first: apt-get install -y curl"; exit 1; }

mkdir -p /opt/toolstunnel
curl -fsSL --retry 3 -o /opt/toolstunnel/toolstunnel.sh "$REPO_RAW/toolstunnel.sh"
bash -n /opt/toolstunnel/toolstunnel.sh || { echo "Downloaded script is invalid."; exit 1; }
chmod +x /opt/toolstunnel/toolstunnel.sh
ln -sf /opt/toolstunnel/toolstunnel.sh /usr/local/bin/toolstunnel

echo "Installed. Starting the menu... (next time just run: toolstunnel)"
exec /opt/toolstunnel/toolstunnel.sh
