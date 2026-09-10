#! /bin/bash

sudo pacman -S --noconfirm firefox

## sudo pacman -S --noconfirm thunar file-roller tumbler ffmpegthumbnailer thunar-archive-plugin thunar-volman

# install VLC
sudo pacman -S --noconfirm vlc vlc-plugins-extra vlc-plugins-video-output vlc-plugin-x264 vlc-plugin-ffmpeg vlc-plugin-x265 vlc-plugin-x265

install Network tools:
sudo pacman -S wireshark-qt traceroute nmap
sudo usermod -aG wireshark $username

sudo pacman -S --noconfirm cups cups-browsed system-config-printer
