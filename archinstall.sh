#!/bin/bash

select_disk() {
    local disk_list=()
    local i=1

    while IFS= read -r line; do
        disk_list+=("$line")
        ((i++))
    done < <(lsblk -d -n -o NAME,TYPE,SIZE,MODEL | grep -E 'disk|raid' | grep -v "loop")

    if [ ${#disk_list[@]} -eq 0 ]; then
        echo "Disks not found!"
        exit 1
    fi

    echo -e "\n==== Disks ===="
    echo "   0. Cancel"
    for idx in "${!disk_list[@]}"; do
        num=$((idx + 1))
        printf "  %2d. %s\n" "$num" "${disk_list[$idx]}"
    done

    local choice
    while true; do
        read -p "Select disk (0-${#disk_list[@]}): " choice

        if [ "$choice" = "0" ]; then
            echo "Canceled."
            exit 1
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#disk_list[@]} ]; then
            selected_disk_info="${disk_list[$((choice-1))]}"
            selected_disk=$(echo "$selected_disk_info" | awk '{print $1}')

            if [[ ! "$selected_disk" =~ ^/dev/ ]]; then
                selected_disk="/dev/$selected_disk"
            fi

            echo -e "================="
            echo "Selected disk: $selected_disk"
            echo "   Info: $selected_disk_info"
            return 0
        else
            echo "Invalid choice! Please select 0-${#disk_list[@]}"
        fi
    done
}

confirm_selection() {
    local disk="$1"
    echo -e "\nWarning!! all data on $disk will be deleted."
    echo "Enter yes or YES for continue."

    local confirm
    read confirm
    if [ "${confirm^^}" = "YES" ]; then
        return 0
    else
        echo "Cancel."
        return 1
    fi
}

partition_disk() {
    local disk="$1"

    echo -e "\n==== Please wait until the partition preparation is complete ===="
    umount "$disk" 2>/dev/null || true
    vgchange -an --noudevsync vg0 2>/dev/null
    wipefs -a "$disk" || exit 1
    dd if=/dev/zero of="$disk" bs=512 count=2048 conv=fsync || exit 1

    parted --script "$disk" mklabel gpt || exit 1
    parted --script "$disk" mkpart fat32 1MiB 1025MiB || exit 1
    parted --script "$disk" set 1 esp on || exit 1
    parted --script "$disk" mkpart linux-swap 1025MiB 5121MiB || exit 1
    parted --script "$disk" set 2 swap on || exit 1
    parted --script "$disk" mkpart ext4 5121MiB 40GiB || exit 1
    parted --script "$disk" mkpart ext4 40GiB 100% || exit 1

    sync && sleep 4
    partprobe "$disk" && sleep 1

    if [ ! -b "${disk}1" ] || [ ! -b "${disk}2" ] || [ ! -b "${disk}3" ] || [ ! -b "${disk}4" ]; then
        echo "ERROR: Failed to create partitions."
        exit 1
    fi

    mkfs.fat -F32 "${disk}1" || exit 1
    mkswap "${disk}2" || exit 1
    swapon "${disk}2" || exit 1
    mkfs.ext4 -F "${disk}3" || exit 1
    mkfs.ext4 -F "${disk}4" || exit 1

    mount "${disk}3" /mnt || exit 1
    mkdir /mnt/home || exit 1
    mount "${disk}4" /mnt/home || exit 1
}

base_install() {
    local disk="$1"
    local vendor="unknown"
    if grep -qi "GenuineIntel" /proc/cpuinfo; then
        vendor="intel-ucode"
    elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
        vendor="amd-ucode"
    else
        echo "Skip ucode."
        exit 0
    fi

    pacstrap -K /mnt base base-devel linux linux-headers linux-firmware "$vendor" sudo nano || exit 1
    genfstab -U -p /mnt >> /mnt/etc/fstab

    cat > /mnt/chroot.sh <<'MNT_EOF'
    #!/bin/bash
    base_device=$(df -P / | awk 'NR==2 {sub(/[0-9]+$/, "", $1); print $1}')
    echo "$base_device"
    sleep 4

    echo "Enter root passowd:"
    passwd

    echo -e "\nEnter username"
    read username || exit 1
    useradd -m -g users -G wheel -s /bin/bash "$username" || exit 1
    passwd "$username"
    sed -i "/^root\s\+ALL=(ALL:ALL)\s\+ALL\$/a ${username} ALL=(ALL:ALL) ALL" /etc/sudoers
    pacman -Sy

    sed -i 's/^#en_US\.UTF-8/en_US.UTF-8/; s/^#ru_RU\.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    hwclock --systohc --utc

    echo "Enter host name: (pc name)"
    read hostpc || exit 1
    echo "$hostpc" > /etc/hostname
    pacman -S --noconfirm networkmanager || exit 1
    systemctl enable NetworkManager || exit 1
    mkdir /boot/efi || exit 1
    mount -o uid=0,gid=0,fmask=0077,dmask=0077 "${base_device}1" /boot/efi || exit 1


    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchLinux
    grub-mkconfig -o /boot/grub/grub.cfg
    sed -i -e 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=0/' -e 's/^GRUB_TIMEOUT_STYLE=.*$/GRUB_TIMEOUT_STYLE=hidden/' -e 's/^#*GRUB_DISABLE_OS_PROBER=.*$/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg

    cat > /home/$username/final.sh <<'FINAL_EOF'
#!/bin/bash

detect_gpu_vendor() {
    if command -v lspci &>/dev/null; then
        if lspci | grep -i "VGA\|3D\|Display" | grep -qi "nvidia"; then
            sudo pacman -S nvidia nvidia-utils lib32-nvidia-utils nvidia-settings
        elif lspci | grep -i "VGA\|3D\|Display" | grep -qi "amd\|radeon\|ati"; then
            sudo pacman -S --noconfirm mesa mesa-utils vulkan-radeon
        else
            echo "Unknown (lspci)"
        fi
    else
        echo "lspci not found."
    fi
}

install_i3() {
    sudo sed -i '/^#[[:space:]]*\[multilib\]$/{s/^#//; n; s/^#//}' /etc/pacman.conf
    sudo pacman -Sy
    sudo pacman -S --noconfirm xorg-server xorg-xinit xorg-setxkbmap xorg-xrandr xorg-xprop xorg-xinput xorg-xwd xdotool
    sudo pacman -S --noconfirm i3-wm i3status rofi
    sudo pacman -S --noconfirm picom udisks2 udiskie unrar unzip ntfs-3g usbutils dosfstools cifs-utils cryptsetup polkit gpicview alacritty openssh git wget pavucontrol pipewire pipewire-pulse pipewire-alsa ly xdg-user-dirs playerctl ufw man-db man-pages qalculate-gtk imagemagick xclip cups cups-browsed system-config-printer emacs papers
    sudo pacman -S --noconfirm fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-mozc

    sudo systemctl enable ufw
    sudo ufw enable
    sudo systemctl enable ly@tty1.service
    sudo usermod -aG audio,video,storage,render,disk $username

    sudo pacman -S --noconfirm lxappearance gtk3 gtk4 kvantum-qt5 qt5ct
    sudo pacman -S --noconfirm materia-gtk-theme adapta-gtk-theme papirus-icon-theme capitaine-cursors ttf-dejavu ttf-freefont ttf-liberation ttf-droid terminus-font noto-fonts noto-fonts-emoji ttf-ubuntu-font-family ttf-roboto ttf-roboto-mono noto-fonts-cjk

    show_menu() {
        echo "Please select one or more options (separated by spaces):"
        echo "1) Firefox"
        echo "2) Chromium"
        echo "3) File manager: thunar"
        echo "4) Steam, Spotify"
        echo "5) Media player: VLC"
        echo "6) Network tools: wireshark-qt traceroute nmap"
    }

    show_menu
    local user_input
    read -r user_input

    if [ -z "$user_input" ]; then
        echo "ERROR: no choice made"
        exit 1
    fi

    IFS=' ' read -ra choices <<< "$user_input"

    valid_choices=()

    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[1-6]$ ]]; then
            valid_choices+=("$choice")
        else
            echo "Warnings: '$choice' - invalid choice (valid numbers are 1-6)"
        fi
    done

    if [ ${#valid_choices[@]} -eq 0 ]; then
        echo "ERROR: No valid selections were made"
        exit 1
    fi

    unique_choices=($(echo "${valid_choices[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    echo ""
    echo "Your choice:"

    for choice in "${unique_choices[@]}"; do
        case $choice in
            1)
                echo "  - install Firefox"
                sudo pacman -S --noconfirm firefox
                ;;
            2)
                echo "  - install Chromium"
                sudo pacman -S --noconfirm chromium
                ;;
            3)
                echo "  - install File manager: thunar."
                sudo pacman -S --noconfirm thunar file-roller tumbler ffmpegthumbnailer thunar-archive-plugin thunar-volman
                ;;
            4)
                echo " - install Steam, Spotify "
                sudo pacman -S --noconfirm steam spotify-launcher
                ;;
            5)
                echo " - install VLC"
                sudo pacman -S --noconfirm vlc vlc-plugins-extra vlc-plugins-video-output vlc-plugin-x264 vlc-plugin-ffmpeg vlc-plugin-x265 vlc-plugin-x265
                ;;
            6)
                echo "  - install Network tools: wireshark-qt traceroute nmap"
                sudo pacman -S wireshark-qt traceroute nmap
                sudo usermod -aG wireshark $username
                ;;
        esac
    done
}

custom_config() {
    # ========== DISK SETTINGS RULE ==========
    sudo tee /etc/polkit-1/rules.d/50-udisks2.rules > /dev/null <<'POLKIT_EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock-system" ||
         action.id == "org.freedesktop.udisks2.eject-media" ||
         action.id == "org.freedesktop.udisks2.eject-media-system" ||
         action.id == "org.freedesktop.udisks2.power-off-drive" ||
         action.id == "org.freedesktop.udisks2.loop-setup") &&
        subject.isInGroup("storage")) {
        return polkit.Result.YES;
    }
});
POLKIT_EOF

    # ========== WINDOWS DISK SUPPORT ==========
    sudo cat >> /etc/udisks2/udisks2.conf <<'UD_EOF'
default_modules="ntfs-3g"

mount_options=uid=1000,gid=1000,dmask=022,fmask=133,windows_names

[ntfs]
defaults=uid=1000,gid=1000,dmask=022,fmask=133,windows_names
allow=uid=,gid=,dmask=,fmask=,locale=,windows_names,compression,nocompression
UD_EOF

    # ========== SAMBA ==========
    sudo mkdir -p /mnt/samba
    sudo cat >> /etc/fstab <<'SMB_EOF'

# smb
//192.168.0.189/Files /mnt/samba cifs noauto,x-systemd.automount,x-systemd.idle-timeout=3min,_netdev,username=user2,password=21121,uid=1000,gid=1000,file_mode=0644,dir_mode=0755,vers=3.0 0 0
SMB_EOF

    # ========== DISABLE Display Power Management Signaling ==========
    sudo cat >> /etc/X11/xorg.conf.d/10-extensions.conf <<'XORG1_EOF'
Section "Extensions"
    Option "DPMS" "false"
EndSection
XORG1_EOF

     # ========== DISABLE SLEEP ==========
     sudo cat >> /etc/X11/xorg.conf.d/10-serverflags.conf <<'XORG2_EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
EndSection
XORG2_EOF

    # ========== SIMPLE SCREENSHOT ==========
    sudo cat > /usr/local/bin/custom_screenshot.sh <<'SCREEN_EOF'
#!/bin/bash
mkdir -p "$HOME/Pictures/Screenshots"

tmp_png="/tmp/freeze_$$.png"
import -window root "$tmp_png"

if [ ! -f "$tmp_png" ]; then
    exit 1
fi

if command -v feh >/dev/null 2>&1; then
    feh -FZY "$tmp_png" &
    FEH_PID=$!
    sleep 0.5
fi

filename="$HOME/Pictures/Screenshots/screenshot_$(date +%Y%m%d_%H%M%S).png"
import "$filename"

if [ ! -f "$filename" ]; then
    [ ! -z "$FEH_PID" ] && kill $FEH_PID 2>/dev/null
    rm "$tmp_png"
    exit 1
fi

[ ! -z "$FEH_PID" ] && kill $FEH_PID 2>/dev/null

rm "$tmp_png" 2>/dev/null

if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -t image/png -i "$filename"
    echo -n "$filename" | xclip -selection primary
fi
SCREEN_EOF
    sudo chmod +x /usr/local/bin/custom_screenshot.sh

    # ========== ROFI THEM ==========
    wget -P  /usr/share/rofi/themes/ https://raw.githubusercontent.com/yan-hidden/myconfig/refs/heads/main/spotlight-dark.rasi

ROFI_EOF
}

username="$SUDO_USER"

if [[ $EUID -ne 0 ]]; then
    echo "Please run the script from root." >&2
    exit 1
fi

detect_gpu_vendor

if ! install_i3; then
    echo "ERROR: Cancel."
    exit 1
fi

custom_config

# ========== USER SETUP ==========
cat > /home/$username/user_config.sh <<'CONF_EOF'
#!/bin/bash

xdg-user-dirs-update
systemctl --user enable pipewire pipewire-pulse wireplumber

# ========== BASH_PROFILE ==========
cat >> /home/$USER/.bash_profile <<'BASHPROF_EOF'
export PATH="~/.local/bin:$PATH"
BASHPROF_EOF

mkdir -p /home/$USER/.local/bin

# ========== XSESSION ==========
cat > /home/$USER/.xsession <<'XSESSION_EOF'
#!/bin/sh

# Set some XDG_* variables
export XDG_SESSION_DESKTOP=i3
export XDG_CURRENT_DESKTOP=i3

# cursor
export XCURSOR_THEME=Capitaine
export XCURSOR_SIZE=24

# GTK
export GTK_THEME=Materia-dark
export GTK_ICON_THEME=Papirus-Dark
# GTK3 apps try to contact org.a11y.Bus. Disable that.
export NO_AT_BRIDGE=1

# QT5
export QT_QPA_PLATFORMTHEME=qt5ct
export QT_STYLE_OVERRIDE=kvantum-dark
export GTK_APPLICATION_PREFER_DARK_THEME=1

# render
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb

# Electron
export ELECTRON_TRASH=gio
export ELECTRON_FORCE_DARK_MODE=1

# languages
export GTK_IM_MODULE=fcitx5
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5
export INPUT_METHOD=fcitx5
export SDL_IM_MODULE=fcitx5
export GLFW_IM_MODULE=ibus

exec i3
XSESSION_EOF
chmod +x /home/$USER/.xsession

# ========== UDISKIE TREE ==========
mkdir -p /home/$USER/.config/udiskie
cat > /home/$USER/.config/udiskie/config.yml <<'UDISK_EOF'
program_options:
  tray: auto
  menu: flat
  automount: false
  notify: true
  password_cache: false
  password_prompt: builtin:gui

device_config:
  - ignore: false
    automount: false
    skip: true

  - is_luks: true
    decrypt: true
    ignore: false
    automount: false

  - is_filesystem: true
    ignore: false
    automount: false

notifications:
  timeout: 3
  device_mounted: 3
  device_unmounted: 3
  device_added: 3
  device_removed: 3

quickmenu_actions:
  - mount
  - unmount
  - unlock
  - eject
  - detach
UDISK_EOF

# ========== QT ==========
mkdir -p /home/$USER/.config/qt5ct
cat > /home/$USER/.config/qt5ct/qt5ct.conf <<'QT_EOF'
[Appearance]
color_scheme_path=/usr/share/qt5ct/colors/darker.conf
custom_palette=true
icon_theme=Papirus-Dark
standard_dialogs=default
style=kvantum-dark

[Fonts]
fixed="Sans Serif,9,-1,5,50,0,0,0,0,0"
general="Sans Serif,9,-1,5,50,0,0,0,0,0"

[Interface]
activate_item_on_single_click=1
buttonbox_layout=0
cursor_flash_time=1000
dialog_buttons_have_icons=1
double_click_interval=400
gui_effects=@Invalid()
keyboard_scheme=2
menus_have_icons=true
show_shortcuts_in_context_menus=true
stylesheets=@Invalid()
toolbutton_style=4
underline_shortcut=1
wheel_scroll_lines=3

[SettingsWindow]
geometry=@ByteArray(\x1\xd9\xd0\xcb\0\x3\0\0\0\0\x4\x92\0\0\0\0\0\0\t\xff\0\0\x5\x88\0\0\0\x2\0\0\0\x14\0\0\t\xfd\0\0\x5\x86\0\0\0\0\x2\0\0\0\n\0\0\0\x4\x94\0\0\0\x14\0\0\t\xfd\0\0\x5\x86)

[Troubleshooting]
force_raster_widgets=1
ignored_applications=@Invalid()
QT_EOF

# ========== GTK ==========
mkdir -p /home/$USER/.config/gtk-3.0
cat > /home/$USER/.config/gtk-3.0/settings.ini <<'GTK_EOF'
[Settings]
gtk-theme-name=Materia-dark
gtk-icon-theme-name=Papirus-Dark
gtk-application-prefer-dark-theme=1
gtk-font-name=Adwaita Sans 11
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=0
gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=0
gtk-menu-images=0
gtk-enable-event-sounds=1
gtk-enable-input-feedback-sounds=1
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintmedium
GTK_EOF

# ========== USER CUSTOM SETTINGS ==========
# ========== ROFI SELECT CUSTOM THEM ==========
mkdir -p /home/$USER/.config/rofi
cat > /home/$USER/.config/rofi/config.rasi <<'ROFIHOME_EOF'
@theme "/usr/share/rofi/themes/spotlight-dark.rasi"
ROFIHOME_EOF

# ========== PICOM ==========
wget -P /home/$USER/.config/ https://raw.githubusercontent.com/yan-hidden/myconfig/refs/heads/main/picom.conf

# ========== I3 STATUS ==========
wget -P /home/$USER/.config/ https://raw.githubusercontent.com/yan-hidden/myconfig/refs/heads/main/i3status.conf

# ========== I3 CONFIG ==========
mkdir -p /home/$USER/.config/i3
wget -P /home/$USER/.config/i3/ https://raw.githubusercontent.com/yan-hidden/myconfig/refs/heads/main/config

# ========== EMACS CONFIG ==========
mkdir -p /home/$USER/.emacs.d
wget -P /home/$USER/.emacs.d https://raw.githubusercontent.com/Kupanko/myconfig/refs/heads/main/.emacs.d/{init,yka-lib}.el

CONF_EOF

chown $username:users /home/$username/user_config.sh
chmod +x /home/$username/user_config.sh

runuser -l $username -c '/home/$USER/user_config.sh'

rm /home/$username/user_config.sh
rm /home/$username/final.sh

echo "Installation complete, reboot PC."
FINAL_EOF

    chmod +x /home/$username/final.sh
    sleep 5
    exit
MNT_EOF
    chmod +x /mnt/chroot.sh
    arch-chroot -S /mnt /bin/bash -c "/chroot.sh"
    rm /mnt/chroot.sh
    umount -R /mnt
}

echo "==== Start install ===="

if ! ping -c 3 -w 3 8.8.8.8 &> /dev/null; then
    echo "Internet is not connected, check your connection!"
    exit 1
fi

echo "Internet connected"
echo -e "\n==== Select Disk ===="
select_disk

if [ -z "${selected_disk:-}" ]; then
    echo "ERROR: No disk selected!" >&2
    exit 1
fi

if ! confirm_selection "$selected_disk_info"; then
    echo "Operation cancelled by user."
    exit 0
fi

if ! partition_disk "$selected_disk"; then
    echo "ERROR: Disk partitioning failed!" >&2
    exit 1
fi

if ! base_install "$selected_disk"; then
    echo "ERROR: Cancel."
    exit 1
fi

echo -e "\n==== Installation complete. reboot PC ===="
echo "Final disk partitions:"
lsblk
