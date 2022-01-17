#!/bin/bash

if [[ $# -eq 0 ]]; then
   pacman -Sy --noconfirm archlinux-keyring
   timedatectl set-ntp true

   # disk partitioning setup
   # 1:   1  GB EFI partition
   # 2:   .. GB Encrypted root partition LUKS
   # 3:   50 GB Linux From Scratch partition
   parted -s -a optimal -- /dev/nvme0n1 \
       mklabel gpt \
       mkpart primary fat32 0% 1GB \
       mkpart primary 1GB -50GB \
       mkpart primary -50GB 100% \
       set 1 esp on

   # LUKS full disk encryption
   cryptsetup -y -v luksFormat /dev/nvme0n1p2
   cryptsetup open /dev/nvme0n1p2 cryptroot

   # LVM
   # 1:   48  GB Swap partition
   # 2:   128 GB Root partition
   # 3:   ..  GB Home partition
   pvcreate /dev/mapper/cryptroot
   vgcreate vg0 /dev/mapper/cryptroot
   lvcreate --size  48G vg0 --name swap
   lvcreate --size 128G vg0 --name root
   lvcreate --extents 100%FREE vg0 --name home

   # create file systems
   mkfs.fat -F32 /dev/nvme0n1p1
   mkfs.ext4 /dev/vg0/root
   mkfs.ext4 /dev/vg0/home
   mkswap /dev/vg0/swap

   # mount partitions
   mount /dev/vg0/root /mnt
   mkdir /mnt/boot
   mkdir /mnt/home
   mount /dev/nvme0n1p1 /mnt/boot
   mount /dev/vg0/home /mnt/home
   swapon /dev/vg0/swap

   # installation
   pacstrap /mnt base linux linux-firmware intel-ucode \
       lvm2 parted iproute2 openssh vim dhclient \
       cryptsetup man-db man-pages texinfo usbutils \
       zsh fzf ripgrep base-devel git nmap bluez-utils \
       sudo networkmanager \
       xorg plasma plasma-wayland-session kde-applications \
       firefox vlc keepassxc
       
   genfstab -U /mnt >> /mnt/etc/fstab

   SCRIPTNAME=$(basename $0)
   cp $0 /mnt/
   arch-chroot /mnt /$SCRIPTNAME 1
   
   rm /mnt/$SCRIPTNAME
   umount /mnt/home
   umount /mnt/boot
   umount /mnt
else
    # timezone
    ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
    hwclock --systohc

    # localization
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/#de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo 'LANG=de_DE.UTF-8' >> /etc/locale.conf
    echo 'LANGUAGE=en_US.UTF-8' >> /etc/locale.conf
    echo 'KEYMAP=de-latin1' >> /etc/vconsole.conf

    # network configuration
    HOSTNAMEFILE=/etc/hostname
    HOSTSFILE=/etc/hosts
    HOSTNAME='jtp'
    echo "$HOSTNAME" > $HOSTNAMEFILE
    echo "127.0.0.1        localhost" >> $HOSTSFILE
    echo "::1              localhost" >> $HOSTSFILE
    echo "127.0.0.1        $HOSTNAME.localdomain $HOSTNAME" >> $HOSTSFILE
    
    # add and configure users
    useradd -U -G wheel --create-home --shell /usr/bin/zsh julius
    sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

    # configure zsh
    su julius -c 'curl -L -o /home/juliuszint/.zshrc https://raw.githubusercontent.com/juliuszint/dotfiles/master/zsh/.zshrc'
    su julius -c 'RUNZSH=no KEEP_ZSHRC=yes curl -L http://install.ohmyz.sh | sh'
    rm /home/julius/.zshrc.pre-oh-my-zsh
    chmod 600 /home/julius/.zshrc
    
    # enable KDE systemd units
    systemctl enable sddm.service
    systemctl enable NetworkManager.service

    # create unified kernel image to boot
    sed -i -E 's/^MODULES=\([a-z ]*\)$/MODULES=(i915)' /etc/mkinitcpio.conf
    sed -i -E 's/^HOOKS=\([a-z ]+\)$/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
    _BLKUUID=$(lsblk -n -o UUID /dev/nvme0n1p2 | tail -n 1)
    echo "options rd.luks.name=$_BLKUUID=cryptroot root=/dev/vg0/root resume=/dev/vg0/swap bgrt_disable" > /etc/kernel/cmdline
    _PRESET_FILE=/etc/mkinitcpio.d/linux.preset
    sed -i '10d' $_PRESET_FILE
    sed -i '13d' $_PRESET_FILE
    sed -i '5i ALL_microcode=(/boot/*-ucode.img)' $_PRESET_FILE
    sed -i '11i default_efi_image="/boot/EFI/Linux/archlinux-linux.efi"' $_PRESET_FILE
    sed -i '12i default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"' $_PRESET_FILE
    sed -i '15i fallback_efi_image="/boot/EFI/Linux/archlinux-linux-fallback.efi"' $_PRESET_FILE
    sed -i '16i fallback_options="-S autodetect --splash /usr/share/systemd/bootctl/splash-arch.bmp"' $_PRESET_FILE
    mkinitcpio -P
    
    printf 'Change juliuss password....\n'
    passwd julius
fi