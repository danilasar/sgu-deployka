#!/bin/bash

set -e

device=$(dialog --stdout --title "Целевое устройство" --fselect "/dev/" 14 88)
source_dir=$(dialog --stdout --title "Исходные образы" --inputbox $'Поддерживаются:\n+ Путь к папке в файловой системе\n+ FTP, HTTP(S)\n+ Samba: smb://user:pass@domain/share/path' 14 88 "$(pwd)")
scenario_choice=$(dialog --stdout --title "Выбор сценрия" --radiolist "Выбери сценарий:" 14 88 4 \
    1 "Полное развёртывание системы" on \
    2 "Синхронизация файловых систем (В РАЗРАБОТКЕ)" off \
    3 "Свой сценарий" off)

scenario=""
case $scenario_choice in
	1)
		scenario=(check_device make_gpt copy_images resize_filesystems update_fstab update_efi connect_to_domain)
		;;
	2)
		scenario=(check_device sync_filesystems)
		;;
	3)
		scenario=$(dialog --stdout --title "Выбор действий" --checklist "Выбери нужные действия:" 15 50 8 \
			"check_device" "Проверить ввод" on \
			"make_gpt" "Пересоздать таблицу разделов" on \
			"copy_images" "Развернуть образы" on \
			"resize_filesystems" "Расширить файловые системы" on \
			"sync_filesystems" "Синхронизовать файловые системы (СКОРО ПОЯВИТСЯ)" off \
			"update_fstab" "Обновить fstab" on \
			"update_efi" "Обновить загрузочные записи" on \
			"connect_to_domain" "Прописать Альт в домен" off)
		;;
	*)
		exit 3
		;;
esac

if [[ " ${scenario[*]} " =~ " connect_to_domain " ]]; then
	MOUNT_POINT="/mnt/alt"
	NEW_HOSTNAME=$(dialog --stdout --title "Имя компьютера" --inputbox "Введите имя компьютера:" 14 88 "W12-")
	AD_DOMAIN=$(dialog --stdout --title "Домен" --inputbox "Введите домен:" 14 88 "main.sgu.ru")
	AD_ADMIN=$(dialog --stdout --title "Учётная запись" --inputbox "Введите учётную запись с правами присоединения к домену:" 14 88 "grigorevde")
	AD_PASSWORD=$(dialog --stdout --title "Пароль" --passwordbox "Введите пароль для учётной записи с правами присоединения к домену:" 14 88)
fi

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

chroot_exec() {
    chroot "$MOUNT_POINT" /bin/bash -c "$1"
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
	parted -s "$device" set 1 msftres on
	
	log "Создаю второй раздел (Windows Recovery)"
	parted -s "$device" mkpart ntfs 135266304B 689963007B
	parted -s "$device" name 2 "\"$NAME2\""
	parted -s "$device" set 2 diag on
	
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

    log "Расширение $partition (тип: ${fstype:-неизвестен})..."
    
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
            log "Неизвестный тип файловой системы: $fstype. Расширение невозможно!"
            return 1
            ;;
    esac
}

resize_filesystems() {
	heading "Расширение файловых систем"
	local windows_partition="${device}4"
	local linux_partition="${device}5"
	log "Расширяю $windows_partition"
	resize_fs "$windows_partition"
	log "Расширяю $linux_partition"
	resize_fs "$linux_partition"
}

sync_filesystems() {
	heading "Синхронизация файловых систем"
	echo "TODO"
}

update_fstab() {
	heading "Обновление fstab"
	linux_part="${device}5"
	efi_part="${device}3"
	swap_part="${device}6"

	log "Монтирую разделы"
	mount "$linux_part" /mnt
	mount "$efi_part" /mnt/boot/efi

	log "Генерую новый fstab"
	{
  	echo "# /etc/fstab
proc		/proc			proc	nosuid,noexec,gid=proc				0 0
devpts		/dev/pts		devpts  nosuid,noexec,gid=tty,mode=620,ptmxmode=0666	0 0
tmpfs		/tmp			tmpfs	nosuid						0 0
UUID=$(blkid -s UUID -o value "$efi_part")		/boot/efi		vfat		umask=0077	0 1
UUID=$(blkid -s UUID -o value "$linux_part")		/		ext4		defaults	0 1
UUID=$(blkid -s UUID -o value "$swap_part")		none		swap		sw	0 0"
	} | tee /mnt/etc/fstab

	log "Размонтирую разделы"
	umount "$efi_part"
	umount "$linux_part"
}

update_efi() {
	heading "Добавление загрузчика Альт Линукса в EFI"
	
	local efi_mount="/mnt"
	local shim_path="$efi_mount/EFI/altlinux/shimx64.efi"
	log "Монтирую EFI-раздел в $efi_mount"
	mount "${device}3" $efi_mount
	
	log "Проверяю существование shim"
	[ -f "$shim_path" ] || {
		log "$shim_path не найден"
		exit 2
	}
	
	set +e

	log "Проверяю существование загрузочной записи"
	local existing_entry=$(efibootmgr -v | grep -i "Alt Linux" | grep -Eo 'Boot[0-9A-F]{4}')
	
	if [ -n "$existing_entry" ]; then
		log "Найдена загрузочная запись: $existing_entry"
		bootnum=${existing_entry#Boot}
	else
		log "Не нашёл, создаю новую загрузочную запись"
		efibootmgr \
			--create \
			--disk "$device" \
			--part 3 \
			--loader "\\EFI\\altlinux\\shimx64.efi" \
			--label "Alt Linux" \
			--verbose 2>&1 | grep -oP 'Boot\K[0-9A-F]{4}'
		local new_entry=$(efibootmgr -v | grep -i "Alt Linux" | grep -Eo 'Boot[0-9A-F]{4}')
	
		[ -n "$new_entry" ] || {
			log "Не удалось создать запись EFI"
			exit 3
		}
	
		bootnum=${new_entry#Boot}
	fi
	
	log "Размонтирую EFI-раздел"
	umount $efi_mount
	
	log "Получаю порядок загрузки"
	local current_order=$(efibootmgr  | grep "BootOrder:" | cut -d: -f2 | tr -d ' ')
	
	log "Формирую новый порядок загрузки"
	local new_order="$bootnum,$(echo "$current_order" | \
		tr ',' '\n' | \
		grep -vx "$bootnum" | \
		tr '\n' ',' | \
		sed 's/,$//' \
	)"
	
	log "Сохраняю новый порядок"
	efibootmgr --bootorder "$new_order"

	log "Работа с загрузочными записями завершена"
}

connect_to_domain() {
	heading "Подключение к домену"

	log "Монтирую раздел $TARGET_PARTITION..."
	mkdir -p "$MOUNT_POINT"
	mount "${device}5" "$MOUNT_POINT"

	log "Устанавливаю hostname: $NEW_HOSTNAME..."
	log "$NEW_HOSTNAME" | sudo tee "${MOUNT_POINT}/etc/hostname" > /dev/null
	sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" "${MOUNT_POINT}/etc/hosts"

	log "Присоединяюсь к домену"
	chroot_exec "echo '$AD_PASSWORD' | realm join --user '$AD_ADMIN' $AD_DOMAIN"

	log "Настраиваю SSSD"
	cp "${MOUNT_POINT}/etc/sssd/sssd.conf" "${MOUNT_POINT}/etc/sssd/sssd.conf.bak"
	sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' "${MOUNT_POINT}/etc/sssd/sssd.conf"

	log "Проверяю присоединение к домену..."
	chroot_exec "realm list"

	log "Размонтирую систему..."
	umount "$MOUNT_POINT"
}

for cmd in ${scenario[@]}; do
	$cmd
done
