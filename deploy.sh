#!/bin/bash

set -e

read -r -p "Путь к устройству назначения (например, /dev/sda): " device
read -r -p "Путь к папке с efi файлами (также поддерживается ftp://, ssh://): " source_dir

echo "# ------------------------------------------------------------ 
# 1. Получение устройства и проверка 
# ------------------------------------------------------------"
[ -b "$device" ] || { echo "Устройство $device не найдено"; exit 1; }
echo "Устройство $device обнаружено, начинаю развёртывание системы."

echo "# ------------------------------------------------------------
# 2. Создание разделов GPT с помощью sgdisk
# ------------------------------------------------------------"
echo "Удаляю таблицу разделов"
sgdisk --zap-all "$device"

# Типы разделов:
# EF00 - EFI
# 0C01 - Microsoft Reserved
# 2700 - Windows Recovery
# 0700 - NTFS
# 8300 - Linux
# 8200 - Swap

echo "Создаю новую таблицу разделов"
sgdisk --align-end=optimal \
  --new=1:0:+128M   --typecode=1:0C01  --change-name=1:"Microsoft Reserved" \
  --new=2:0:+529M   --typecode=2:2700  --change-name=2:"Recovery" \
  --new=3:0:+100M   --typecode=3:EF00  --change-name=3:"EFI" \
  --new=4:0:+50%    --typecode=4:0700  --change-name=4:"Windows" \
  --new=5:0:-8G     --typecode=5:8300  --change-name=5:"Linux" \
  --new=6:0:0       --typecode=6:8200  --change-name=6:"Swap" \
  "$device"

# ------------------------------------------------------------
# Функция копирования образов (локально/FTP/SSH)
# ------------------------------------------------------------
copy_partition() {
  local partition_number=$1
  local image_source=$2

  echo "[!] Запись образа в раздел ${device}${partition_number}..."

  case "$image_source" in
    ftp://*)
      curl -s "$image_source" | dd "of=${device}${partition_number}" bs=4M status=progress
      ;;
    ssh://*)
      ssh_user_host=$(echo "$image_source" | sed 's/ssh:\/\///; s/\// /')
      ssh "$ssh_user_host" "cat" | dd "of=${device}${partition_number}" bs=4M status=progress
      ;;
    *)
      dd "if=$image_source" "of=${device}${partition_number}" bs=4M status=progress
      ;;
  esac
}

echo "# ------------------------------------------------------------
# 3. Копирование образов
# ------------------------------------------------------------"

echo "ms_reserved.img..."
copy_partition 1 "$device/ms_reserved.img"
echo "recovery.img..."
copy_partition 2 "$device/recovery.img"
echo "efi.img..."
copy_partition 3 "$device/efi.img"
echo "windows.img..."
copy_partition 4 "$device/windows.img"
echo "linux.img..."
copy_partition 5 "$device/linux.img"

echo "# ------------------------------------------------------------
# 4. Обновление fstab
# ------------------------------------------------------------"
linux_part="${device}5"
efi_part="${device}3"
swap_part="${device}6"

echo "Монтирую разделы"
mount "$linux_part" /mnt
mount "$efi_part" /mnt/boot/efi

echo "Генерую новый fstab"
{
  echo "# /etc/fstab"
  echo "UUID=$(sudo blkid -s UUID -o value "$efi_part")  /boot/efi  vfat  umask=0077  0  1"
  echo "UUID=$(sudo blkid -s UUID -o value "$linux_part")  /  ext4  defaults  0  1"
  echo "UUID=$(sudo blkid -s UUID -o value "$swap_part")  none  swap  sw  0  0"
} | tee /mnt/etc/fstab

echo "Размонтирую разделы"
umount "$efi_part"
umount "$linux_part"

echo "# ------------------------------------------------------------
# 5. Добавление загрузчика Альт Линукса в EFI
# ------------------------------------------------------------"

efi_mount="/mnt"
shim_path="$efi_mount/EFI/altlinux/shimx.64.efi"
echo "Монтирую EFI-раздел в $efi_mount"
mount "${device}3" $efi_mount

echo "Проверяю существование shim"
[ -f "$shim_path" ] || {
	echo "$shim_path не найден"
	exit 2
}

echo "Проверяю существование загрузочной записи"
existing_entry=$(efibootmgr -v | grep -i "Alt Linux" | grep -Eo 'Boot[0-9A-F]{4}')

if [ -n "$existing_entry" ]; then
	echo "Найдена загрузочная запись: $existing_entry"
	bootnum=${existing_entry}
else
	echo "Не нашёл, создаю новую загрузочную запись"
	new_entry=$(efibootmgr \
		--create \
		--disk "$device" \
		--part 3 \
		--loader "\\EFI\\altlinux\\shimx64.efi" \
		--label "Alt Linux" \
		--verbose 2>&1 | grep -Eo 'Boot[0-9A-F]{4}' \
	)

	[ -n "$new_entry" ] || {
		echo "Не удалось создать запись EFI"
		exit 3
	}

	bootnum=${new_entry#Boot}
fi

echo "Размонтирую EFI-раздел"
umount $efi_mount

echo "Получаю порядок загрузки"
current_order=$(efibootmgr  | grep "BootOrder:" | cut -d: -f2 | tr -d ' ')

echo "Формирую новый порядок загрузки"
new_order="$bootnum,$(echo "$current_order" | \
	tr ',' '\n' | \
	grep -vx "$bootnum" | \
	tr '\n' ',' | \
	sed 's/,$//' \
)"

echo "Сохраняю новый порядок"
efibootmgr --bootorder "$new_order"

echo "Текущая конфигурация загрузки:"
efibootmgr | grep -v "BootOrder:"
