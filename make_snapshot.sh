#!/bin/bash
actionid=1
log_file=make_snapshot.log

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

setting_up() {
	heading "Настройка копирования"
	device=$(dialog --stdout --title "Исходное устройство" --fselect "/dev/" 14 88)
	destination_dir=$(dialog --stdout --title "Путь, куда сохранять:" --dselect "$(pwd)" 14 88)
	deviceids=$(dialog --checklist "Выбери разделы для копирования:" 20 88 5 \
		1 "Зарезервированный раздел windows" on \
		2 "Раздел восстановления windows" on \
		3 "Загрузочный раздел EFI" on \
		4 "NTFS-Раздел с windows" on \
		5 "ext4-раздел с Linux" on \
		3>&1 1>&2 2>&3
	)
	clear
}

check_device() {
	if ! touch "$log_file" 2>/dev/null; then
		echo "Нет прав на запись в $log_file" >&2
		exit 1
	fi

	heading "Получение устройства и проверка"
	[ -b "$device" ] || { echo "Устройство $device не найдено"; exit 1; }
	log "Устройство $device обнаружено, начинаю развёртывание системы."

	log "Будут сделаны снимки следующих устройств:"
	for i in $deviceids; do
		log "+ ${device}${i}"
	done

	log "Образы дисков будут сохранены по пути:"
	log "${destination_dir}"

	read -r -p 'Продолжить? [Д/н] ' choice
	case $(echo "$choice" | awk '{print tolower($0)}') in
		д|да|y|yes|yep|ага)
			echo 'Приступаю к копированию'
			;;
		*)
			echo "Прервано."
			exit 0
			;;
	esac
}

make_tar() {
	local device_part=$1
	local out=$2
	local temp_mnt="/mnt/tar"
	local output_file="${destination_dir}/${out}.tar.gz"
	
	log "Создаю папку $temp_mnt"
	mkdir -p "$temp_mnt"
	log "Монтирую $device_part в $temp_mnt"
	mount "$device_part" "$temp_mnt"
	log "Копирую $device_part в $output_file..."
	tar -cvpzf "$output_file" --one-file-system "$temp_mnt"
	log "Размонтирую $device_part и удаляю $temp_mnt"
	umount "$device_part"
	rmdir "$temp_mnt"
}

make_img() {
	local device_part=$1
	local out=$2
	local output_file="${destination_dir}/${out}.img"

	log "Копирую $device_part в $output_file..."
	dd if="$device_part" of="$output_file" bs=4M status=progress
}

make_backup() {
	heading "Создание снимков"
	for i in $deviceids; do
		local out=""
		log "Определяю имя файла для раздела ${i}"
		case "$i" in
			1) out="ms_reserved" ;;
			2) out="recovery" ;;
			3) out="efi" ;;
			4) out="windows" ;;
			5) out="linux" ;;
			*) log "Неизвестный дескриптор раздела: ${i}"; continue ;;
		esac

		local device_part="${device}${i}"

		log "Проверяю существование ${device_part}"
		if [ ! -b "$device_part" ]; then
			log "Устройство $device_part не найдено, пропускаю"
			continue
		fi


		if [ "$i" == 5 ]; then
			make_tar "$device_part" "$out"
		else
			make_img "$device_part" "$out"
		fi
	done
}

destruct() {
	log "Успешно!"
	unset actionid
	unset log_file
	unset destination_dir
	unset deviceids
}

setting_up
check_device
make_backup
destruct
