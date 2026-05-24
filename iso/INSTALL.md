# unrawk manual install

The form installer covers the supported path: single disk, GPT, ESP +
LUKS-wrapped root, ext4 or btrfs. For variations the form deliberately
doesn't support — separate /home, swap, btrfs subvolumes, dual-boot,
wifi-before-install, custom partition layouts — open a shell from the
installer's header action (or Super+T) and follow this crib sheet.

This file ships to `/root/INSTALL.md` on the live ISO via step 8's ISO
bundling. Source of truth is the unrawk-installer repo; keep them in
lockstep with `installer-overview.md`.

## Set these once

```bash
DISK=/dev/sda                       # verify: lsblk -dn -o NAME,SIZE,MODEL
HOSTNAME=unrawk
USER=paths
TZ=America/New_York                 # see /usr/share/zoneinfo
KMAP=us                             # see /usr/share/kbd/keymaps
LANG=en_US.UTF-8                    # locale; pick one valid on the target
FS=ext4                             # ext4 | btrfs (or anything mkfs.* supports)
REPO=https://repo.unrawk.example    # unrawk xbps repo URL
```

## 1. Partition (GPT: ESP + LUKS container)

```bash
parted -s $DISK mklabel gpt
parted -s $DISK mkpart ESP fat32 1MiB 513MiB
parted -s $DISK set 1 esp on
parted -s $DISK mkpart cryptroot 513MiB 100%
```

## 2. LUKS

```bash
cryptsetup luksFormat ${DISK}2      # prompts for the passphrase
cryptsetup open ${DISK}2 cryptroot  # prompts again
```

## 3. Filesystems

```bash
mkfs.fat -F32 ${DISK}1
mkfs.$FS    /dev/mapper/cryptroot
```

## 4. Mount

```bash
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot/efi
mount ${DISK}1 /mnt/boot/efi
```

## 5. Install base + unrawk

```bash
xbps-install -Sy -R $REPO -r /mnt base-system unrawk-base
```

## 6. Chroot configure

```bash
echo "$HOSTNAME" > /mnt/etc/hostname

ESP_UUID=$(blkid  -s UUID -o value ${DISK}1)
LUKS_UUID=$(blkid -s UUID -o value ${DISK}2)

cat > /mnt/etc/fstab <<EOF
UUID=$ESP_UUID  /boot/efi  vfat  defaults  0 2
/dev/mapper/cryptroot  /  $FS  defaults  0 1
EOF

echo "cryptroot  UUID=$LUKS_UUID  none  luks" > /mnt/etc/crypttab

echo "LANG=$LANG"    > /mnt/etc/locale.conf
echo "KEYMAP=$KMAP"  > /mnt/etc/vconsole.conf
ln -sf /usr/share/zoneinfo/$TZ /mnt/etc/localtime

xchroot /mnt useradd -mG wheel $USER
xchroot /mnt passwd $USER
xchroot /mnt passwd -l root

cat > /mnt/etc/default/grub <<EOF
GRUB_ENABLE_CRYPTODISK=y
GRUB_CMDLINE_LINUX="rd.luks.uuid=$LUKS_UUID"
EOF

# nvidia? Add nvidia-drm.modeset=1 to the kernel cmdline:
#   sed -i 's/GRUB_CMDLINE_LINUX="/&nvidia-drm.modeset=1 /' /mnt/etc/default/grub

xchroot /mnt grub-install --target=x86_64-efi \
                          --efi-directory=/boot/efi \
                          --bootloader-id=unrawk
xchroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Rebuild initramfs against the actual kernel pkg name (linux6.x etc).
LINUX_PKG=$(xbps-query -r /mnt -p pkgver linux | cut -d- -f1)
xchroot /mnt xbps-reconfigure -f "$LINUX_PKG"

# Conditional: nvidia GPU detected?
# xchroot /mnt xbps-install -y nvidia
```

## 7. Unmount and reboot

```bash
umount /mnt/boot/efi
umount /mnt
sync
reboot
```

Eject the ISO before grub hands off.

---

## Variations the form doesn't cover

### Separate /home (btrfs subvolumes)

After step 3, before step 4, lay out subvolumes:

```bash
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

mount -o subvol=@     /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home /mnt/boot/efi
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mount ${DISK}1                              /mnt/boot/efi
```

Then in step 6, the `/mnt/etc/fstab` for the rootfs entries becomes:

```
/dev/mapper/cryptroot  /      btrfs  subvol=@,defaults      0 1
/dev/mapper/cryptroot  /home  btrfs  subvol=@home,defaults  0 2
```

### Swap (random-key, no hibernate)

Add a swap partition in step 1 (e.g. as `p3`), then in step 6 append:

```bash
echo "swap  ${DISK}3  /dev/urandom  swap" >> /mnt/etc/crypttab
echo "/dev/mapper/swap  none  swap  defaults  0 0" >> /mnt/etc/fstab
```

### Dual-boot (preserve existing OS + ESP)

Skip step 1 entirely. Use the existing ESP at `/dev/<existing-esp>`
(typically a Windows install's). Create only `cryptroot` in unused
space. In step 4, mount the existing ESP instead of `${DISK}1`. Make
sure the existing OS's grub or boot manager will detect unrawk's grub
afterwards, or chain manually.

### Wifi before install

The installer assumes ethernet. From the shell:

```bash
iwctl
[iwctl]# station <iface> connect <ssid>
[iwctl]# exit
```

Confirm with `ping -c1 1.1.1.1`, then continue from step 1.

### Different repo

Swap `$REPO` for a local mirror or alternate URL. `xbps-install` only
needs to reach it for step 5.
