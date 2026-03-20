# 1. Completely wipe the default (broken) sources
sudo rm -rf /etc/apt/sources.list /etc/apt/sources.list.d/*

# 2. Write a guaranteed working source list
sudo tee /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# 3. Force a refresh (Look for 'Get' lines in the output)
sudo apt-get update

# 4. Verify again
apt-cache policy zfsutils-linux
