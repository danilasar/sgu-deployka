#!/bin/bash

set -e

read -r -p "Путь к устройству назначения (например, /dev/sda): " device
read -r -p "Путь к папке с образами (также поддерживается ftp://, ssh://, smb://user:pass@domain/): " source_dir
actionid=1
log_file=deploy.log

heading() {
	echo "# ------------------------------------------------------------ 
# $actionid. $1
# ------------------------------------------------------------"
	((actionid++))
}

log() {
	local status=$?
	local message=$1
	local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
	echo "[$timestamp] [$status] $message"
	echo "[$timestamp] [$status] $message" >> "$log_file"
	return "$status"
}

check_device() {
	if ! touch "$log_file" 2>/dev/null; then
		echo "Нет прав на запись в $log_file" >&2
		exit 1
	fi

	heading "Получение устройства и проверка"
	[ -b "$device" ] || { echo "Устройство $device не найдено"; exit 1; }
	log "Устройство $device обнаружено, начинаю развёртывание системы."
}

make_gpt() {
	heading "Создание разделов GPT с помощью parted"
	echo "Удаляю таблицу разделов"
	sgdisk --zap-all "$device"

	# Имена разделов
	local NAME1="Microsoft Reserved"
	local NAME2="Windows Recovery"
	local NAME3="EFI"
	local NAME4="Windows"
	local NAME5="Linux"
	local NAME6="Swap"

	log "Пересоздаю таблицу разделов GPT"
	parted -s "$device" mklabel gpt

	log "Создаю первый раздел (FAT32 LBA)"
	parted -s "$device" mkpart fat32 17408B 134235135B
	parted -s "$device" name 1 "\"$NAME1\""
	
	log "Создаю второй раздел (Windows Recovery)"
	parted -s "$device" mkpart ntfs 135266304B 689963007B
	parted -s "$device" name 2 "\"$NAME2\""
	
	log "Создаем третий раздел (EFI System Partition)"
	parted -s "$device" mkpart fat32 689963008B 794820607B
	parted -s "$device" name 3 "\"$NAME3\""
	parted -s "$device" set 3 boot on
	
	# Определяем оставшееся пространство
	log "Определяю размеры основных разделов"
	local TOTAL_SIZE=$(parted -s "$device" unit MiB print free | awk '/Free Space/ {print $2}' | tail -n 1 | sed 's/MiB//')
	local FREE_SIZE=$((TOTAL_SIZE - 758 - 8192 - 2))
	local SIZE4=$((FREE_SIZE / 2))
	local SIZE5=$SIZE4
	
	log "Создаю раздел с виндой"
	parted -s "$device" mkpart ntfs 794820608B $((758 + SIZE4))MiB
	parted -s "$device" name 4 "\"$NAME4\""
	parted -s "$device" set 4 msftdata on
	
	log "Создаю раздел с альтушкой"
	parted -s "$device" mkpart ext4 $((758 + 1 + SIZE4))MiB $((758 + SIZE4 + SIZE5))MiB
	parted -s "$device" name 5 "\"$NAME5\""
	
	log "Создаю раздел подкачки"
	parted -s "$device" mkpart linux-swap $((758 + 1 + SIZE4 + 1 + SIZE5))MiB 100%
	parted -s "$device" name 6 "\"$NAME6\""
	
	parted -s "$device" print
	
	log "Создание таблицы разделов завершено"
}

# ------------------------------------------------------------
# Функция копирования образов (локально/FTP/SSH/HTTP(S))
# ------------------------------------------------------------
copy_partition() {
  local partition_number=$1
  local image_source=$2

  log "Запиываю образ в раздел ${device}${partition_number}..."

  case "$image_source" in
    https://|http://*|ftp://*)
      curl -sSL "$image_source" | dd "of=${device}${partition_number}" bs=4M status=progress
      ;;
    ssh://*)
      ssh_user_host=$(echo "$image_source" | sed 's/ssh:\/\///; s/\// /')
      ssh "$ssh_user_host" "cat" | dd "of=${device}${partition_number}" bs=4M status=progress
      ;;
		smb://*)
			local user_pass_server=$(echo "$image_source" | sed 's/smb:\/\///; s/@/ /')
			local server_share_path=$(echo "$user_pass_server" | awk '{print $2')
			local user_pass=$(echo "$user_pass_server" | awk '{print $1}')

			# todo check is it correct parsing
			local server=$(echo "$server_share_path" | cut -d/ -f1)
			local share=$(echo "$server_share_path" | cut -d/ -f2)
			local path="/$(echo "$server_share_path" | cut -d/ -f3-)"
			local user=$(echo "$user_pass" | cut -d: -f1)
			local pass=$(echo "$user_pass" | cut -d: -f2-)

			log "Копирование с //${server}/${share}${path}"
			smbclient -U "$user"%"$pass" "//${server}/${share}${path}" \
				-c "get \"$path\" -" \
				| dd of="$partition" bs=4M status=progress

			: '
				Also alternative:
				mount -t cifs "//${server}/${share}" /mnt -o user="$user",pass="$pass"
				dd if=/mnt/${path} of="$partition"
				umount /mnt
			'
			;;
    *)
      dd "if=$image_source" "of=${device}${partition_number}" bs=4M status=progress
      ;;
  esac
}

copy_images() {
	heading "Копирование образов"
	log "ms_reserved.img..."
	copy_partition 1 "$source_dir/ms_reserved.img"
	log "recovery.img..."
	copy_partition 2 "$source_dir/recovery.img"
	log "efi.img..."
	copy_partition 3 "$source_dir/efi.img"
	log "windows.img..."
	copy_partition 4 "$source_dir/windows.img"
	log "linux.img..."
	copy_partition 5 "$source_dir/linux.img"
}

# Функция расширения ФС
resize_fs() {
    local partition=$1
    local fstype=$(blkid -s TYPE -o value "$partition")

    echo "Расширение $partition (тип: ${fstype:-неизвестен})..."
    
    case $fstype in
        ext4)
            e2fsck -f -y "$partition" || true
            resize2fs "$partition"
            ;;
        ntfs)
            yes | ntfsfix "$partition" || true
            yes | ntfsresize -f -b -P "$partition" || true
            ;;
        *)
            echo "Неизвестный тип ФС: $fstype. Расширение невозможно!"
            return 1
            ;;
    esac
}

resize_filesystems() {
	heading "Расширение файловых систем"
	local windows_partition="${device}4"
	local linux_partition="${device}5"
	echo "Расширяю $windows_partition"
	resize_fs "$windows_partition"
	echo "Расширяю $linux_partition"
	resize_fs "$linux_partition"
}

update_fstab() {
	heading "Обновление fstab"
	linux_part="${device}5"
	efi_part="${device}3"
	swap_part="${device}6"

	echo "Монтирую разделы"
	mount "$linux_part" /mnt
	mount "$efi_part" /mnt/boot/efi

	echo "Генерую новый fstab"
	{
  	echo "# /etc/fstab"
	  echo "UUID=$(blkid -s UUID -o value "$efi_part")  /boot/efi  vfat  umask=0077  0  1"
  	echo "UUID=$(blkid -s UUID -o value "$linux_part")  /  ext4  defaults  0  1"
	  echo "UUID=$(blkid -s UUID -o value "$swap_part")  none  swap  sw  0  0"
	} | tee /mnt/etc/fstab

	echo "Размонтирую разделы"
	umount "$efi_part"
	umount "$linux_part"
}

update_efi() {
	heading "Добавление загрузчика Альт Линукса в EFI"
	
	efi_mount="/mnt"
	shim_path="$efi_mount/EFI/altlinux/shimx64.efi"
	echo "Монтирую EFI-раздел в $efi_mount"
	mount "${device}3" $efi_mount
	
	echo "Проверяю существование shim"
	[ -f "$shim_path" ] || {
		echo "$shim_path не найден"
		exit 2
	}
	
	set +e

	echo "Проверяю существование загрузочной записи"
	existing_entry=$(efibootmgr -v | grep -i "Alt Linux" | grep -Eo 'Boot[0-9A-F]{4}')
	echo "$existing_entry"
	
	if [ -n "$existing_entry" ]; then
		echo "Найдена загрузочная запись: $existing_entry"
		bootnum=${existing_entry#Boot}
	else
		echo "Не нашёл, создаю новую загрузочную запись"
		new_entry=$(efibootmgr \
			--create \
			--disk "$device" \
			--part 3 \
			--loader "\\EFI\\altlinux\\shimx64.efi" \
			--label "Alt Linux" \
			--verbose 2>&1 | grep -oP 'Boot\K[0-9A-F]{4}' \
		)
	
		[ -n "$new_entry" ] || {
			echo "Не удалось создать запись EFI"
			exit 3
		}
	
		bootnum=${new_entry##* }
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
	efibootmgr
}


check_device
make_gpt
copy_images
resize_filesystems
update_fstab
update_efi
