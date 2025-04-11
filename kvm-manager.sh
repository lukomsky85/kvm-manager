#!/bin/bash

# Полный скрипт для управления KVM с расширенными возможностями
# Поддерживает Debian/Ubuntu (deb) и CentOS/RHEL (rpm) системы
# Добавлена поддержка установки Proxmox VE

set -e

# Конфигурационные переменные
BACKUP_DIR="/var/lib/libvirt/backups"
CLUSTER_NAME="kvm_cluster"
NODE_USER="root"
SSH_KEY="/root/.ssh/id_rsa"
LOG_FILE="/var/log/kvm_manager.log"
SHARED_STORAGE="/mnt/kvm_shared"
NFS_SERVER=""
CEPH_CONF="/etc/ceph/ceph.conf"
VM_DEFAULT_DISK_SIZE="20G"
VM_DEFAULT_RAM="2048"
VM_DEFAULT_CPUS="2"
VM_DEFAULT_OS_TYPE="linux"
VM_DEFAULT_OS_VARIANT="ubuntu22.04"
ISO_DIR="/var/lib/libvirt/isos"
CEPH_POOL_NAME="libvirt-pool"
LVM_VG="kvm-vg"
ZFS_POOL="kvm-pool"
VERSION_CHECK_URL="https://api.github.com/repos/libvirt/libvirt/tags"
SCRIPT_VERSION="1.5.1"
API_PORT="8080"
MONITORING_INTERVAL="60"
OVIRT_ADMIN_PASSWORD=""
ENABLE_API="true"
PROXMOX_ADMIN_PASSWORD=""
PROXMOX_IFACE="eth0"
PROXMOX_IP=""
PROXMOX_NETMASK="24"
PROXMOX_GATEWAY=""
PROXMOX_DNS="8.8.8.8"
PROXMOX_HOSTNAME="proxmox"
PROXMOX_DOMAIN="local"
ENABLE_ZFS="true"
ENABLE_MONITORING="true"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функция логирования
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Определение типа пакетного менеджера
detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        echo "deb"
    elif command -v yum &> /dev/null; then
        echo "rpm"
    elif command -v dnf &> /dev/null; then
        echo "rpm"
    else
        echo "unknown"
    fi
}

# Установка пакетов
install_packages() {
    local pkg_manager=$(detect_pkg_manager)
    case $pkg_manager in
        "deb")
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        "rpm")
            if command -v dnf &> /dev/null; then
                dnf install -y "$@"
            else
                yum install -y "$@"
            fi
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
}

# Проверка и установка зависимостей
check_dependencies() {
    local pkg_manager=$(detect_pkg_manager)
    local required_pkgs=()
    local required_bins=("virsh" "qemu-img" "ssh-keygen" "ssh-keyscan" "virt-install")
    
    # Общие зависимости для всех функций
    local common_pkgs=(
        "jq"
        "curl"
        "libguestfs-tools"
    )

    case $pkg_manager in
        "deb")
            required_pkgs=(
                "libvirt-clients"
                "qemu-utils"
                "openssh-client"
                "libvirt-daemon-system"
                "qemu-kvm"
                "virtinst"
                "arp-scan"
                "genisoimage"
                "${common_pkgs[@]}"
                # LVM поддержка
                "lvm2"
                "thin-provisioning-tools"
                # ZFS поддержка
                "zfsutils-linux"
                # Мониторинг
                "sysstat"
                "prometheus-node-exporter"
                # Python
                "python3"
                "python3-pip"
                "python3-venv"
            )
            ;;
        "rpm")
            log "${YELLOW}Установка EPEL репозитория и обновление системы...${NC}"
            install_packages epel-release
            if command -v dnf &> /dev/null; then
                dnf update -y
                dnf install -y dnf-plugins-core
                dnf config-manager --enable powertools 2>/dev/null || true
            else
                yum update -y
            fi

            required_pkgs=(
                "libvirt-client"
                "qemu-img"
                "openssh-clients"
                "libvirt"
                "qemu-kvm"
                "virt-install"
                "arp-scan"
                "genisoimage"
                "${common_pkgs[@]}"
                # LVM поддержка
                "lvm2"
                "device-mapper-persistent-data"
                # Мониторинг
                "sysstat"
                "python3"
                "python3-pip"
            )

            # Добавляем node_exporter вместо prometheus-node_exporter
            if [[ "$ENABLE_MONITORING" == "true" ]]; then
                required_pkgs+=("node_exporter")
            fi

            # Добавляем ZFS только если включено
            if [[ "$ENABLE_ZFS" == "true" ]]; then
                # Добавляем репозиторий ZFS для CentOS/RHEL с исправлением GPG-ключа
                if ! rpm -q zfs-release &> /dev/null; then
                    log "${YELLOW}Добавление репозитория ZFS...${NC}"
                    
                    # Устанавливаем репозиторий без немедленного импорта ключа
                    dnf install -y https://zfsonlinux.org/epel/zfs-release-2-3$(rpm --eval "%{dist}").noarch.rpm --nogpgcheck
                    
                    # Альтернативный способ импорта ключа
                    rpm --import https://zfsonlinux.org/gpg.key 2>/dev/null || \
                    log "${YELLOW}Не удалось импортировать GPG-ключ ZFS, продолжаем без проверки подписи${NC}"
                fi
                required_pkgs+=("zfs")
            else
                log "${YELLOW}ZFS поддержка отключена${NC}"
            fi
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac

    # Проверка и установка пакетов
    local missing_pkgs=()
    for pkg in "${required_pkgs[@]}"; do
        if { [ "$pkg_manager" = "deb" ] && ! dpkg -l | grep -q "^ii  $pkg"; } ||
           { [ "$pkg_manager" = "rpm" ] && ! rpm -q "$pkg" &> /dev/null; }; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        log "${YELLOW}Установка недостающих пакетов: ${missing_pkgs[*]}${NC}"
        install_packages "${missing_pkgs[@]}" || {
            log "${RED}Не удалось установить некоторые пакеты${NC}"
            
            # Пропускаем проблемные пакеты
            for pkg in "${missing_pkgs[@]}"; do
                if ! { [ "$pkg_manager" = "deb" ] && dpkg -l | grep -q "^ii  $pkg"; } ||
                   { [ "$pkg_manager" = "rpm" ] && rpm -q "$pkg" &> /dev/null; }; then
                    log "${YELLOW}Пропуск проблемного пакета: $pkg${NC}"
                fi
            done
        }
    fi

    # Проверка ZFS kernel module
    if [[ "$ENABLE_ZFS" == "true" ]] && ! lsmod | grep -q zfs; then
        log "${YELLOW}ZFS kernel module не загружен. Попытка загрузки...${NC}"
        modprobe zfs || log "${RED}Не удалось загрузить ZFS модуль${NC}"
    fi

    # Проверка бинарных файлов
    local missing_bins=()
    for bin in "${required_bins[@]}"; do
        if ! command -v "$bin" &> /dev/null; then
            missing_bins+=("$bin")
        fi
    done

    if [ ${#missing_bins[@]} -ne 0 ]; then
        log "${RED}Отсутствуют необходимые компоненты: ${missing_bins[*]}${NC}"
        log "Попробуйте переустановить пакеты вручную:"
        if [ "$pkg_manager" = "deb" ]; then
            log "sudo apt-get install --reinstall ${required_pkgs[*]}"
        else
            log "sudo yum reinstall ${required_pkgs[*]}"
        fi
        exit 1
    fi
}

# Инициализация
init() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$ISO_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    # Проверка прав root
    if [ "$(id -u)" -ne 0 ]; then
        log "${RED}Этот скрипт должен запускаться с правами root${NC}"
        exit 1
    fi
    
    check_dependencies
}

# Проверка новых версий
check_versions() {
    log "${YELLOW}Проверка актуальных версий...${NC}"
    
    # Проверяем версию libvirt
    local current_libvirt=$(virsh --version 2>/dev/null || echo "0.0.0")
    local latest_libvirt=$(curl -s $VERSION_CHECK_URL | jq -r '.[0].name' | sed 's/^v//')
    
    if [ "$latest_libvirt" = "null" ] || [ -z "$latest_libvirt" ]; then
        latest_libvirt="не удалось проверить"
    fi
    
    # Проверяем версию QEMU
    local current_qemu=$(qemu-system-x86_64 --version | head -n1 | awk '{print $4}' || echo "0.0.0")
    local latest_qemu=$(curl -s https://api.github.com/repos/qemu/qemu/tags | jq -r '.[0].name' | sed 's/^v//')
    
    if [ "$latest_qemu" = "null" ] || [ -z "$latest_qemu" ]; then
        latest_qemu="не удалось проверить"
    fi
    
    # Проверяем версию Ceph
    local current_ceph=$(ceph --version 2>/dev/null | awk '{print $3}' || echo "0.0.0")
    local latest_ceph=$(curl -s https://api.github.com/repos/ceph/ceph/tags | jq -r '.[0].name' | sed 's/^v//')
    
    if [ "$latest_ceph" = "null" ] || [ -z "$latest_ceph" ]; then
        latest_ceph="не удалось проверить"
    fi
    
    # Проверяем версию Proxmox
    local current_pve=$(pveversion 2>/dev/null | awk '{print $2}' || echo "не установлен")
    local latest_pve=$(curl -s https://api.github.com/repos/proxmox/pve-manager/tags | jq -r '.[0].name' | sed 's/^v//')
    
    if [ "$latest_pve" = "null" ] || [ -z "$latest_pve" ]; then
        latest_pve="не удалось проверить"
    fi
    
    # Выводим информацию
    echo -e "\n${YELLOW}Текущие версии:${NC}"
    echo -e "libvirt: ${GREEN}$current_libvirt${NC} (последняя: $latest_libvirt)"
    echo -e "QEMU: ${GREEN}$current_qemu${NC} (последняя: $latest_qemu)"
    echo -e "Ceph: ${GREEN}$current_ceph${NC} (последняя: $latest_ceph)"
    echo -e "Proxmox VE: ${GREEN}$current_pve${NC} (последняя: $latest_pve)"
    echo -e "Версия скрипта: ${GREEN}$SCRIPT_VERSION${NC}"
    
    # Проверка обновлений скрипта
    check_script_update
}

# Проверка обновлений скрипта
check_script_update() {
    local remote_version=$(curl -s https://raw.githubusercontent.com/lukomsky85/kvm-manager/main/kvm-manager.sh | grep "SCRIPT_VERSION=" | cut -d'"' -f2)
    
    if [ -z "$remote_version" ]; then
        log "${YELLOW}Не удалось проверить обновления скрипта${NC}"
        return
    fi
    
    if [ "$remote_version" != "$SCRIPT_VERSION" ]; then
        log "${YELLOW}Доступна новая версия скрипта ($remote_version)!${NC}"
        log "Обновить можно командой:"
        log "curl -s https://raw.githubusercontent.com/lukomsky85/kvm-manager/main/kvm-manager.sh > /tmp/kvm-manager.sh && sudo mv /tmp/kvm-manager.sh /usr/local/bin/kvm-manager && sudo chmod +x /usr/local/bin/kvm-manager"
    else
        log "${GREEN}Скрипт актуален (версия $SCRIPT_VERSION)${NC}"
    fi
}

# Настройка NFS сервера
setup_nfs_server() {
    log "${YELLOW}Настройка NFS сервера...${NC}"
    
    # Установка пакетов
    install_packages nfs-kernel-server
    
    # Создание директории для общего хранилища
    mkdir -p "$SHARED_STORAGE"
    chown nobody:nogroup "$SHARED_STORAGE"
    chmod 777 "$SHARED_STORAGE"
    
    # Настройка экспорта
    echo "$SHARED_STORAGE *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    
    # Перезапуск сервиса NFS
    systemctl restart nfs-kernel-server
    
    # Включение автозапуска
    systemctl enable nfs-kernel-server
    
    # Получение IP адреса сервера
    local server_ip=$(hostname -I | awk '{print $1}')
    NFS_SERVER="$server_ip"
    
    log "${GREEN}NFS сервер настроен. Директория: $SHARED_STORAGE${NC}"
    log "Для подключения с клиента используйте:"
    log "sudo mount $server_ip:$SHARED_STORAGE /mnt/nfs"
}

# Настройка NFS клиента
setup_nfs_client() {
    local server_ip=$1
    log "${YELLOW}Настройка NFS клиента для подключения к серверу $server_ip...${NC}"
    
    # Установка пакетов
    install_packages nfs-common
    
    # Создание точки монтирования
    local mount_point="/mnt/nfs"
    mkdir -p "$mount_point"
    
    # Монтирование NFS
    mount "$server_ip:$SHARED_STORAGE" "$mount_point"
    
    # Добавление в fstab для автоматического монтирования при загрузке
    echo "$server_ip:$SHARED_STORAGE $mount_point nfs rw,hard,intr 0 0" >> /etc/fstab
    
    log "${GREEN}NFS клиент настроен. Точка монтирования: $mount_point${NC}"
}

# Настройка кластера Ceph
setup_ceph_cluster() {
    local node_ip=$1
    shift
    local ceph_nodes=("$@")
    
    log "${YELLOW}Настройка кластера Ceph...${NC}"
    
    # Установка пакетов
    install_packages ceph ceph-common
    
    # Инициализация кластера
    ceph-deploy new "$node_ip"
    
    # Установка демонов
    ceph-deploy install "$node_ip" "${ceph_nodes[@]}"
    
    # Развертывание монитора
    ceph-deploy mon create-initial
    
    # Развертывание менеджера
    ceph-deploy mgr create "$node_ip"
    
    # Создание OSD (предполагается, что /dev/sdb доступен для использования)
    for node in "$node_ip" "${ceph_nodes[@]}"; do
        ceph-deploy osd create --data /dev/sdb "$node"
    done
    
    # Развертывание метаданных сервера
    ceph-deploy mds create "$node_ip"
    
    # Создание пула для libvirt
    ceph osd pool create "$CEPH_POOL_NAME" 128
    ceph osd pool application enable "$CEPH_POOL_NAME" rbd
    
    log "${GREEN}Кластер Ceph настроен. Пул $CEPH_POOL_NAME создан.${NC}"
}

# Интеграция Ceph с libvirt
setup_ceph_libvirt() {
    log "${YELLOW}Настройка интеграции Ceph с libvirt...${NC}"
    
    # Создание ключа для libvirt
    ceph auth get-or-create client.libvirt mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=$CEPH_POOL_NAME' > /etc/ceph/ceph.client.libvirt.keyring
    
    # Получение ключа
    local ceph_key=$(grep key /etc/ceph/ceph.client.libvirt.keyring | awk '{print $3}')
    
    # Создание секрета для libvirt
    cat > /tmp/secret.xml <<EOF
<secret ephemeral='no' private='no'>
  <usage type='ceph'>
    <name>client.libvirt secret</name>
  </usage>
</secret>
EOF
    
    virsh secret-define --file /tmp/secret.xml
    virsh secret-set-value --secret $(virsh secret-list | grep client.libvirt | awk '{print $1}') --base64 "$ceph_key"
    
    # Создание пула в libvirt
    cat > /tmp/ceph-pool.xml <<EOF
<pool type='rbd'>
  <name>$CEPH_POOL_NAME</name>
  <source>
    <name>$CEPH_POOL_NAME</name>
    <host name='$(hostname)' port='6789'/>
    <auth type='ceph' username='libvirt'>
      <secret uuid='$(virsh secret-list | grep client.libvirt | awk '{print $1}')'/>
    </auth>
  </source>
</pool>
EOF
    
    virsh pool-define /tmp/ceph-pool.xml
    virsh pool-start "$CEPH_POOL_NAME"
    virsh pool-autostart "$CEPH_POOL_NAME"
    
    log "${GREEN}Интеграция Ceph с libvirt завершена. Пул $CEPH_POOL_NAME доступен.${NC}"
}

# Настройка LVM хранилища
setup_lvm_storage() {
    log "${YELLOW}Настройка LVM хранилища...${NC}"
    
    # Проверяем доступные VG
    local vg_list=$(vgs --noheadings -o vg_name 2>/dev/null)
    
    if [ -z "$vg_list" ]; then
        log "${RED}Не найдено ни одной группы томов (VG)${NC}"
        log "Сначала создайте VG (например: vgcreate $LVM_VG /dev/sdX)"
        return 1
    fi
    
    echo -e "\n${YELLOW}Доступные группы томов:${NC}"
    echo "$vg_list"
    
    echo -n "Введите имя группы томов для использования [$LVM_VG]: "
    read selected_vg
    selected_vg=${selected_vg:-$LVM_VG}
    
    if ! vgs "$selected_vg" &> /dev/null; then
        log "${RED}Группа томов $selected_vg не существует${NC}"
        return 1
    fi
    
    # Создаем пул в libvirt
    if ! virsh pool-info "$selected_vg" &> /dev/null; then
        virsh pool-define-as --name "$selected_vg" --type logical --source-name "$selected_vg" --target /dev/"$selected_vg"
        virsh pool-start "$selected_vg"
        virsh pool-autostart "$selected_vg"
    fi
    
    log "${GREEN}LVM хранилище настроено. Группа томов: $selected_vg${NC}"
    log "Для создания тома: lvcreate -L 10G -n vm_disk $selected_vg"
}

# Настройка ZFS хранилища
setup_zfs_storage() {
    log "${YELLOW}Настройка ZFS хранилища...${NC}"
    
    # Проверяем доступные zpools
    local zpool_list=$(zpool list -H -o name 2>/dev/null)
    
    if [ -z "$zpool_list" ]; then
        log "${RED}Не найдено ни одного пула ZFS${NC}"
        log "Сначала создайте zpool (например: zpool create $ZFS_POOL /dev/sdX)"
        return 1
    fi
    
    echo -e "\n${YELLOW}Доступные пулы ZFS:${NC}"
    echo "$zpool_list"
    
    echo -n "Введите имя пула для использования [$ZFS_POOL]: "
    read selected_pool
    selected_pool=${selected_pool:-$ZFS_POOL}
    
    if ! zpool list "$selected_pool" &> /dev/null; then
        log "${RED}Пул $selected_pool не существует${NC}"
        return 1
    fi
    
    # Создаем пул в libvirt
    if ! virsh pool-info "$selected_pool" &> /dev/null; then
        virsh pool-define-as --name "$selected_pool" --type zfs --source-name "$selected_pool"
        virsh pool-start "$selected_pool"
        virsh pool-autostart "$selected_pool"
    fi
    
    log "${GREEN}ZFS хранилище настроено. Пул: $selected_pool${NC}"
    log "Для создания тома: zfs create -V 10G $selected_pool/vm_disk"
}

# Создание виртуальной машины
create_vm() {
    local vm_name=$1
    local vm_ram=$2
    local vm_cpus=$3
    local vm_disk_size=$4
    local vm_iso=$5
    local vm_network=$6
    local vm_storage=$7
    
    log "${YELLOW}Создание виртуальной машины $vm_name...${NC}"
    
    # Проверка существования VM
    if virsh dominfo "$vm_name" &>/dev/null; then
        log "${RED}Виртуальная машина с именем $vm_name уже существует${NC}"
        return 1
    fi
    
    # Проверка и скачивание ISO если нужно
    if [[ ! -f "$vm_iso" ]] && [[ "$vm_iso" =~ ^http ]]; then
        log "${YELLOW}Скачивание ISO образа...${NC}"
        wget -P "$ISO_DIR" "$vm_iso"
        local iso_name=$(basename "$vm_iso")
        vm_iso="$ISO_DIR/$iso_name"
    fi
    
    # Создание диска
    local disk_path=""
    case $vm_storage in
        "lvm")
            disk_path="/dev/$LVM_VG/$vm_name"
            lvcreate -L "$vm_disk_size" -n "$vm_name" "$LVM_VG"
            ;;
        "zfs")
            disk_path="/dev/zvol/$ZFS_POOL/$vm_name"
            zfs create -V "$vm_disk_size" "$ZFS_POOL/$vm_name"
            ;;
        "ceph")
            disk_path="rbd:$CEPH_POOL_NAME/$vm_name"
            rbd create "$CEPH_POOL_NAME/$vm_name" --size "$(echo $vm_disk_size | tr -d 'G')G"
            ;;
        *)
            disk_path="$SHARED_STORAGE/$vm_name.qcow2"
            qemu-img create -f qcow2 "$disk_path" "$vm_disk_size"
            ;;
    esac
    
    # Определяем доступные видео модели
    local video_model="virtio"
    if ! virsh domcapabilities | grep -q "<model type='virtio'/>"; then
        video_model="cirrus"
        log "${YELLOW}Модель virtio не доступна, используем cirrus${NC}"
    fi
    
    # Создание VM с проверенной видео моделью
    virt-install \
        --name "$vm_name" \
        --ram "$vm_ram" \
        --vcpus "$vm_cpus" \
        --disk path="$disk_path",bus=virtio \
        --network network="$vm_network" \
        --graphics spice \
        --video model="$video_model" \
        --cdrom "$vm_iso" \
        --os-type "$VM_DEFAULT_OS_TYPE" \
        --os-variant "$VM_DEFAULT_OS_VARIANT" \
        --boot cdrom \
        --noautoconsole
    
    if [ $? -ne 0 ]; then
        log "${RED}Ошибка при создании виртуальной машины${NC}"
        log "${YELLOW}Пробуем альтернативную конфигурацию без spice...${NC}"
        
        virt-install \
            --name "$vm_name" \
            --ram "$vm_ram" \
            --vcpus "$vm_cpus" \
            --disk path="$disk_path",bus=virtio \
            --network network="$vm_network" \
            --graphics vnc \
            --video model="$video_model" \
            --cdrom "$vm_iso" \
            --os-type "$VM_DEFAULT_OS_TYPE" \
            --os-variant "$VM_DEFAULT_OS_VARIANT" \
            --boot cdrom \
            --noautoconsole
    fi
    
    log "${GREEN}Виртуальная машина $vm_name успешно создана!${NC}"
}

# Создание VM через UI
create_vm_ui() {
    echo -e "\n${YELLOW}Создание новой виртуальной машины${NC}"
    
    # Получение параметров
    echo -n "Введите имя виртуальной машины: "
    read vm_name
    
    echo -n "Введите объем RAM (MB) [$VM_DEFAULT_RAM]: "
    read vm_ram
    vm_ram=${vm_ram:-$VM_DEFAULT_RAM}
    
    echo -n "Введите количество CPU [$VM_DEFAULT_CPUS]: "
    read vm_cpus
    vm_cpus=${vm_cpus:-$VM_DEFAULT_CPUS}
    
    echo -n "Введите размер диска [$VM_DEFAULT_DISK_SIZE]: "
    read vm_disk_size
    vm_disk_size=${vm_disk_size:-$VM_DEFAULT_DISK_SIZE}
    
    echo -n "Введите путь к ISO образу или URL для скачивания: "
    read vm_iso
    
    echo -n "Введите имя сети (default): "
    read vm_network
    vm_network=${vm_network:-"default"}
    
    echo -n "Выберите тип хранилища (local/lvm/zfs/ceph) [local]: "
    read vm_storage
    vm_storage=${vm_storage:-"local"}
    
    # Создание VM
    create_vm "$vm_name" "$vm_ram" "$vm_cpus" "$vm_disk_size" "$vm_iso" "$vm_network" "$vm_storage"
}

# Создание бекапа VM
backup_vm() {
    local vm_name=$1
    
    log "${YELLOW}Создание бекапа виртуальной машины $vm_name...${NC}"
    
    # Проверка существования VM
    if ! virsh dominfo "$vm_name" &>/dev/null; then
        log "${RED}Виртуальная машина с именем $vm_name не существует${NC}"
        return 1
    fi
    
    # Создание директории для бекапа
    local backup_dir="$BACKUP_DIR/$vm_name/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Дамп конфигурации XML
    virsh dumpxml "$vm_name" > "$backup_dir/$vm_name.xml"
    
    # Получение информации о дисках
    local disks=$(virsh domblklist "$vm_name" | awk 'NR>2 && $2 {print $2}')
    
    # Копирование дисков
    for disk in $disks; do
        local disk_name=$(basename "$disk")
        log "${YELLOW}Копирование диска $disk_name...${NC}"
        
        if [[ "$disk" =~ /dev/ ]]; then
            # Для блочных устройств используем dd
            dd if="$disk" of="$backup_dir/$disk_name.img" bs=4M status=progress
        else
            # Для файловых образов просто копируем
            cp "$disk" "$backup_dir/$disk_name"
        fi
    done
    
    # Создание архива
    tar -czvf "$backup_dir.tar.gz" -C "$backup_dir" .
    
    # Удаление временных файлов
    rm -rf "$backup_dir"
    
    log "${GREEN}Бекап виртуальной машины $vm_name успешно создан: $backup_dir.tar.gz${NC}"
}

# Создание бекапа через UI
backup_vm_ui() {
    echo -e "\n${YELLOW}Создание бекапа виртуальной машины${NC}"
    
    # Список доступных VM
    echo -e "\n${YELLOW}Доступные виртуальные машины:${NC}"
    virsh list --all
    
    echo -n "Введите имя виртуальной машины для бекапа: "
    read vm_name
    
    backup_vm "$vm_name"
}

# Восстановление VM из бекапа
restore_vm() {
    local backup_file=$1
    
    log "${YELLOW}Восстановление виртуальной машины из бекапа $backup_file...${NC}"
    
    # Проверка существования файла
    if [ ! -f "$backup_file" ]; then
        log "${RED}Файл бекапа $backup_file не найден${NC}"
        return 1
    fi
    
    # Временная директория для распаковки
    local temp_dir=$(mktemp -d)
    
    # Распаковка архива
    tar -xzvf "$backup_file" -C "$temp_dir"
    
    # Поиск XML файла
    local xml_file=$(find "$temp_dir" -name "*.xml" | head -n 1)
    
    if [ -z "$xml_file" ]; then
        log "${RED}Не найден XML файл конфигурации в бекапе${NC}"
        return 1
    fi
    
    # Имя VM из XML
    local vm_name=$(grep "<name>" "$xml_file" | sed 's/.*<name>\(.*\)<\/name>.*/\1/')
    
    # Проверка существования VM
    if virsh dominfo "$vm_name" &>/dev/null; then
        log "${YELLOW}Виртуальная машина $vm_name уже существует. Удаление...${NC}"
        virsh destroy "$vm_name" 2>/dev/null || true
        virsh undefine "$vm_name" --nvram
    fi
    
    # Восстановление дисков
    for disk in $(find "$temp_dir" -type f ! -name "*.xml"); do
        local disk_name=$(basename "$disk")
        local disk_ext="${disk_name##*.}"
        
        if [ "$disk_ext" == "img" ]; then
            # Восстановление блочного устройства
            local target_disk=$(grep -A1 "$disk_name" "$xml_file" | grep "<target" | sed 's/.*dev="\([^"]*\)".*/\1/')
            if [ -n "$target_disk" ]; then
                local lv_path="/dev/$LVM_VG/$vm_name"
                if [ -e "$lv_path" ]; then
                    dd if="$disk" of="$lv_path" bs=4M status=progress
                else
                    log "${RED}Целевое устройство $lv_path не найдено${NC}"
                fi
            fi
        else
            # Копирование файлового образа
            cp "$disk" "$SHARED_STORAGE/"
        fi
    done
    
    # Восстановление конфигурации
    virsh define "$xml_file"
    
    # Очистка
    rm -rf "$temp_dir"
    
    log "${GREEN}Виртуальная машина $vm_name успешно восстановлена!${NC}"
}

# Восстановление через UI
restore_vm_ui() {
    echo -e "\n${YELLOW}Восстановление виртуальной машины из бекапа${NC}"
    
    # Список доступных бекапов
    echo -e "\n${YELLOW}Доступные бекапы:${NC}"
    find "$BACKUP_DIR" -name "*.tar.gz" | nl
    
    echo -n "Введите номер бекапа для восстановления: "
    read backup_num
    
    local backup_file=$(find "$BACKUP_DIR" -name "*.tar.gz" | sed -n "${backup_num}p")
    
    if [ -z "$backup_file" ]; then
        log "${RED}Неверный номер бекапа${NC}"
        return 1
    fi
    
    restore_vm "$backup_file"
}

# Поиск KVM хостов в сети
discover_kvm_hosts() {
    log "${YELLOW}Поиск KVM хостов в локальной сети...${NC}"
    
    # Установка arp-scan если нужно
    if ! command -v arp-scan &>/dev/null; then
        install_packages arp-scan
    fi
    
    # Получение списка хостов
    local hosts=$(arp-scan --localnet | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $1}')
    
    # Проверка каждого хоста
    for host in $hosts; do
        if nc -zv "$host" 16509 2>/dev/null; then
            log "${GREEN}Найден KVM хост: $host${NC}"
            virsh -c "qemu+tcp://$host/system" list --all
        fi
    done
}

# Создание SSH ключей
generate_ssh_key() {
    if [ ! -f "$SSH_KEY" ]; then
        log "${YELLOW}Генерация SSH ключа...${NC}"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N ""
    fi
}

# Настройка кластера
create_cluster() {
    local nodes=("$@")
    
    log "${YELLOW}Настройка кластера KVM...${NC}"
    
    # Генерация SSH ключа если нужно
    generate_ssh_key
    
    # Добавление ключа на все узлы
    for node in "${nodes[@]}"; do
        log "${YELLOW}Настройка узла $node...${NC}"
        ssh-copy-id -i "$SSH_KEY.pub" "$NODE_USER@$node"
        
        # Установка необходимых пакетов
        ssh "$NODE_USER@$node" "$(typeset -f install_packages); install_packages libvirt-clients libvirt-daemon-system qemu-kvm virtinst"
        
        # Настройка libvirt
        ssh "$NODE_USER@$node" "sed -i 's/#listen_tls = 1/listen_tls = 0/' /etc/libvirt/libvirtd.conf"
        ssh "$NODE_USER@$node" "sed -i 's/#listen_tcp = 1/listen_tcp = 1/' /etc/libvirt/libvirtd.conf"
        ssh "$NODE_USER@$node" "sed -i 's/#auth_tcp = \"sasl\"/auth_tcp = \"none\"/' /etc/libvirt/libvirtd.conf"
        ssh "$NODE_USER@$node" "systemctl restart libvirtd"
    done
    
    # Создание SSH конфига для кластера
    cat > ~/.ssh/config <<EOF
Host $CLUSTER_NAME
    User $NODE_USER
    IdentityFile $SSH_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    
    for node in "${nodes[@]}"; do
        echo "    Hostname $node" >> ~/.ssh/config
    done
    
    log "${GREEN}Кластер $CLUSTER_NAME успешно настроен!${NC}"
    log "Для управления кластером используйте:"
    log "virsh -c qemu+ssh://$CLUSTER_NAME/system list --all"
}

# Создание кластера через UI
create_cluster_ui() {
    echo -e "\n${YELLOW}Создание кластера KVM${NC}"
    
    echo -n "Введите IP адреса узлов через пробел: "
    read -a nodes
    
    if [ ${#nodes[@]} -eq 0 ]; then
        log "${RED}Не указаны узлы кластера${NC}"
        return 1
    fi
    
    create_cluster "${nodes[@]}"
}

# Настройка live миграции
setup_live_migration() {
    log "${YELLOW}Настройка live миграции...${NC}"
    
    # Настройка libvirtd.conf
    sed -i 's/#listen_tls = 1/listen_tls = 0/' /etc/libvirt/libvirtd.conf
    sed -i 's/#listen_tcp = 1/listen_tcp = 1/' /etc/libvirt/libvirtd.conf
    sed -i 's/#auth_tcp = \"sasl\"/auth_tcp = \"none\"/' /etc/libvirt/libvirtd.conf
    
    # Настройка параметров миграции
    echo 'uri_default = "qemu+tcp://%s/system"' >> /etc/libvirt/libvirt.conf
    
    # Перезапуск службы
    systemctl restart libvirtd
    
    log "${GREEN}Live миграция настроена. Пример использования:${NC}"
    log "virsh migrate --live vm_name qemu+tcp://destination_host/system"
}

# Запуск REST API
start_api() {
    log "${YELLOW}Запуск REST API сервера...${NC}"
    
    # Создаем виртуальное окружение Python
    if [ ! -d "/opt/kvm-api/venv" ]; then
        python3 -m venv /opt/kvm-api/venv
        source /opt/kvm-api/venv/bin/activate
        pip install flask flask-cors
        deactivate
    fi
    
    # Создаем файл API
    cat > /opt/kvm-api/api.py <<EOF
from flask import Flask, jsonify
import subprocess
import json

app = Flask(__name__)

@app.route('/api/vms', methods=['GET'])
def list_vms():
    try:
        result = subprocess.run(['virsh', 'list', '--all'], capture_output=True, text=True)
        return jsonify({"status": "success", "data": result.stdout})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)})

@app.route('/api/vms/<string:vm_name>', methods=['GET'])
def vm_info(vm_name):
    try:
        result = subprocess.run(['virsh', 'dominfo', vm_name], capture_output=True, text=True)
        return jsonify({"status": "success", "data": result.stdout})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$API_PORT)
EOF

    # Создаем systemd сервис
    cat > /etc/systemd/system/kvm-api.service <<EOF
[Unit]
Description=KVM Manager API
After=network.target

[Service]
User=root
WorkingDirectory=/opt/kvm-api
ExecStart=/opt/kvm-api/venv/bin/python /opt/kvm-api/api.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now kvm-api
    
    log "${GREEN}REST API запущен на порту $API_PORT${NC}"
    log "Пример запроса: curl http://localhost:$API_PORT/api/vms"
}

# Мониторинг ресурсов
start_monitoring() {
    log "${YELLOW}Запуск мониторинга ресурсов...${NC}"
    
    # Создаем директорию для скриптов мониторинга
    mkdir -p /opt/kvm-monitoring
    
    # Создаем скрипт сбора метрик
    cat > /opt/kvm-monitoring/collect_metrics.sh <<EOF
#!/bin/bash

while true; do
    # Собираем метрики
    TIMESTAMP=\$(date +%s)
    VM_LIST=\$(virsh list --name | grep -v "^$")
    
    for VM in \$VM_LIST; do
        CPU_USAGE=\$(virsh dominfo \$VM | grep "CPU usage" | awk '{print \$3\$4}')
        MEM_USAGE=\$(virsh dommemstat \$VM | grep "rss" | awk '{print \$2}')
        
        echo "\$TIMESTAMP,\$VM,CPU,\$CPU_USAGE" >> /var/log/kvm_metrics.csv
        echo "\$TIMESTAMP,\$VM,MEM,\$MEM_USAGE" >> /var/log/kvm_metrics.csv
    done
    
    sleep $MONITORING_INTERVAL
done
EOF

    chmod +x /opt/kvm-monitoring/collect_metrics.sh
    
    # Создаем systemd сервис
    cat > /etc/systemd/system/kvm-monitoring.service <<EOF
[Unit]
Description=KVM Monitoring Service
After=network.target

[Service]
User=root
ExecStart=/opt/kvm-monitoring/collect_metrics.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now kvm-monitoring
    
    log "${GREEN}Мониторинг запущен. Данные сохраняются в /var/log/kvm_metrics.csv${NC}"
}

# Установка oVirt Engine (упрощенная версия)
install_ovirt() {
    log "${YELLOW}Установка oVirt Engine...${NC}"
    
    local pkg_manager=$(detect_pkg_manager)
    
    case $pkg_manager in
        "rpm")
            # Проверяем, не установлен ли уже oVirt
            if rpm -q ovirt-engine &>/dev/null; then
                log "${YELLOW}oVirt Engine уже установлен${NC}"
                return 0
            fi

            # Упрощённая установка для CentOS/RHEL 8+
            if grep -q "CentOS Linux 8" /etc/centos-release || grep -q "Red Hat Enterprise Linux 8" /etc/redhat-release; then
                log "${GREEN}Обнаружена CentOS/RHEL 8+, используем упрощённую установку${NC}"
                
                # Устанавливаем необходимые репозитории
                dnf install -y centos-release-ovirt45
                dnf install -y https://resources.ovirt.org/pub/yum-repo/ovirt-release44.rpm
                
                # Отключаем модуль postgresql для правильной установки
                dnf module -y disable postgresql
                
                # Устанавливаем оVirt Engine с автоматической настройкой
                dnf install -y ovirt-engine
                
                # Генерируем случайный пароль, если не задан
                if [ -z "$OVIRT_ADMIN_PASSWORD" ]; then
                    OVIRT_ADMIN_PASSWORD=$(openssl rand -base64 12)
                    log "${YELLOW}Сгенерирован случайный пароль admin: $OVIRT_ADMIN_PASSWORD${NC}"
                fi
                
                # Автоматическая настройка с минимальными параметрами
                engine-setup --accept-defaults \
                    --admin-password="$OVIRT_ADMIN_PASSWORD" \
                    --config-append=/etc/ovirt-engine-setup.conf.d/10-setup-answers.conf
                
                # Сохраняем пароль в файл
                echo "Admin password: $OVIRT_ADMIN_PASSWORD" > /etc/ovirt-engine/credentials.txt
                chmod 600 /etc/ovirt-engine/credentials.txt
                
                # Включаем и запускаем сервисы
                systemctl enable --now ovirt-engine
                systemctl enable --now httpd
                
                log "${GREEN}oVirt Engine успешно установлен!${NC}"
                log "Доступ через веб-интерфейс: https://$(hostname -f)/ovirt-engine"
                log "Логин: admin"
                log "Пароль: $OVIRT_ADMIN_PASSWORD (также сохранен в /etc/ovirt-engine/credentials.txt)"
                return 0
            fi

            # Стандартная установка для других версий
            if [ ! -f /etc/yum.repos.d/ovirt.repo ]; then
                dnf install -y https://resources.ovirt.org/pub/yum-repo/ovirt-release44.rpm
                dnf install -y ovirt-engine
                
                log "${YELLOW}Запуск интерактивной настройки oVirt Engine...${NC}"
                log "Для автоматической установки примите значения по умолчанию (нажимайте Enter)"
                engine-setup
            else
                log "${YELLOW}oVirt Engine уже установлен${NC}"
            fi
            ;;
        "deb")
            log "${RED}oVirt Engine не поддерживается на DEB-системах${NC}"
            log "Используйте CentOS/RHEL 8+ для установки oVirt"
            return 1
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
    
    log "${GREEN}oVirt Engine установлен. Доступен через web-интерфейс: https://$(hostname -I | awk '{print $1}'):443${NC}"
    log "Для доступа используйте:"
    log "Логин: admin"
    log "Пароль: указанный при установке (хранится в /etc/ovirt-engine/credentials.txt)"
}

# Установка Proxmox VE
install_proxmox() {
    log "${YELLOW}Начало установки Proxmox VE...${NC}"
    
    # Проверяем, что система Debian-based
    if ! command -v apt-get &> /dev/null; then
        log "${RED}Proxmox VE можно установить только на Debian-based системах${NC}"
        return 1
    fi
    
    # Проверяем, что не установлен Proxmox
    if dpkg -l | grep -q pve-manager; then
        log "${YELLOW}Proxmox VE уже установлен${NC}"
        return 0
    fi
    
    # Получаем параметры сети
    echo -e "\n${YELLOW}Настройка сети Proxmox VE${NC}"
    
    # Определяем интерфейс по умолчанию
    local default_iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    PROXMOX_IFACE=${PROXMOX_IFACE:-$default_iface}
    
    echo -n "Введите сетевой интерфейс [$PROXMOX_IFACE]: "
    read iface
    PROXMOX_IFACE=${iface:-$PROXMOX_IFACE}
    
    # Получаем текущий IP
    local current_ip=$(ip -o -4 addr show $PROXMOX_IFACE | awk '{print $4}' | cut -d'/' -f1)
    
    echo -n "Введите IP адрес [$current_ip]: "
    read ip
    PROXMOX_IP=${ip:-$current_ip}
    
    echo -n "Введите маску сети (24, 16 и т.д.) [$PROXMOX_NETMASK]: "
    read netmask
    PROXMOX_NETMASK=${netmask:-$PROXMOX_NETMASK}
    
    # Получаем текущий шлюз
    local current_gw=$(ip route | grep default | awk '{print $3}')
    
    echo -n "Введите шлюз [$current_gw]: "
    read gw
    PROXMOX_GATEWAY=${gw:-$current_gw}
    
    echo -n "Введите DNS сервер [$PROXMOX_DNS]: "
    read dns
    PROXMOX_DNS=${dns:-$PROXMOX_DNS}
    
    echo -n "Введите имя хоста [$PROXMOX_HOSTNAME]: "
    read hostname
    PROXMOX_HOSTNAME=${hostname:-$PROXMOX_HOSTNAME}
    
    echo -n "Введите домен [$PROXMOX_DOMAIN]: "
    read domain
    PROXMOX_DOMAIN=${domain:-$PROXMOX_DOMAIN}
    
    # Генерируем случайный пароль для root, если не задан
    if [ -z "$PROXMOX_ADMIN_PASSWORD" ]; then
        PROXMOX_ADMIN_PASSWORD=$(openssl rand -base64 12)
        log "${YELLOW}Сгенерирован пароль root: $PROXMOX_ADMIN_PASSWORD${NC}"
    fi
    
    # Настраиваем hosts
    echo "127.0.0.1 localhost.localdomain localhost
$PROXMOX_IP $PROXMOX_HOSTNAME.$PROXMOX_DOMAIN $PROXMOX_HOSTNAME" > /etc/hosts
    
    # Настраиваем hostname
    echo "$PROXMOX_HOSTNAME" > /etc/hostname
    hostname "$PROXMOX_HOSTNAME"
    
    # Настраиваем сеть
    cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $PROXMOX_IFACE
iface $PROXMOX_IFACE inet static
    address $PROXMOX_IP/$PROXMOX_NETMASK
    gateway $PROXMOX_GATEWAY
    dns-nameservers $PROXMOX_DNS
EOF
    
    # Перезапускаем сеть
    systemctl restart networking
    
    # Добавляем репозиторий Proxmox
    echo "deb http://download.proxmox.com/debian/pve $(lsb_release -cs) pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
    
    # Добавляем ключ
    wget https://enterprise.proxmox.com/debian/proxmox-release-$(lsb_release -cs).gpg -O /etc/apt/trusted.gpg.d/proxmox-release-$(lsb_release -cs).gpg
    
    # Обновляем пакеты
    apt-get update
    apt-get upgrade -y
    
    # Устанавливаем Proxmox VE
    DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve postfix open-iscsi
    
    # Настраиваем postfix
    echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
    echo "postfix postfix/mailname string $PROXMOX_HOSTNAME" | debconf-set-selections
    
    # Устанавливаем дополнительные пакеты
    apt-get install -y zfsutils-linux
    
    # Меняем пароль root
    echo "root:$PROXMOX_ADMIN_PASSWORD" | chpasswd
    
    # Удаляем ненужные пакеты
    apt-get remove -y os-prober
    
    # Очищаем
    apt-get autoremove -y
    
    log "${GREEN}Proxmox VE успешно установлен!${NC}"
    log "Доступ через веб-интерфейс: https://$PROXMOX_IP:8006"
    log "Логин: root"
    log "Пароль: $PROXMOX_ADMIN_PASSWORD"
    
    # Сохраняем пароль в файл
    echo "Proxmox VE credentials:" > /root/proxmox_credentials.txt
    echo "URL: https://$PROXMOX_IP:8006" >> /root/proxmox_credentials.txt
    echo "Username: root" >> /root/proxmox_credentials.txt
    echo "Password: $PROXMOX_ADMIN_PASSWORD" >> /root/proxmox_credentials.txt
    chmod 600 /root/proxmox_credentials.txt
    
    # Перезагружаем систему
    log "${YELLOW}Система будет перезагружена через 10 секунд...${NC}"
    sleep 10
    reboot
}

# Обновленное меню хранилища
storage_menu() {
    while true; do
        echo -e "\n${YELLOW}Настройка хранилища${NC}"
        echo "1) Настроить NFS сервер"
        echo "2) Настроить NFS клиент"
        echo "3) Установить и настроить Ceph"
        echo "4) Настроить интеграцию Ceph с libvirt"
        echo "5) Настроить LVM хранилище"
        echo "6) Настроить ZFS хранилище"
        echo "7) Вернуться в главное меню"
        echo -n "Выберите опцию: "
        
        read option
        case $option in
            1) setup_nfs_server ;;
            2) 
                echo -n "Введите IP NFS сервера: "
                read nfs_server
                setup_nfs_client "$nfs_server" 
                ;;
            3) 
                echo -n "Введите IP этого узла: "
                read node_ip
                echo -n "Введите IP других узлов Ceph через пробел (если есть): "
                read -a ceph_nodes
                setup_ceph_cluster "$node_ip" "${ceph_nodes[@]}"
                ;;
            4) setup_ceph_libvirt ;;
            5) setup_lvm_storage ;;
            6) setup_zfs_storage ;;
            7) return ;;
            *) log "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# Обновленное главное меню
show_menu() {
    echo -e "\n${YELLOW}Меню управления KVM (версия $SCRIPT_VERSION):${NC}"
    echo "1) Создать виртуальную машину"
    echo "2) Создать бекап виртуальной машины"
    echo "3) Восстановить виртуальную машину из бекапа"
    echo "4) Найти KVM хосты в сети"
    echo "5) Создать кластер KVM"
    echo "6) Настроить хранилище"
    echo "7) Настроить live миграцию ВМ"
    echo "8) Запустить REST API"
    echo "9) Запустить мониторинг ресурсов"
    echo "10) Установить oVirt Engine"
    echo "11) Установить Proxmox VE"
    echo "12) Проверить версии компонентов"
    echo "13) Выход"
    echo -n "Выберите опцию: "
}

# Главная функция
main() {
    init
    
    while true; do
        show_menu
        read option
        
        case $option in
            1) create_vm_ui ;;
            2) backup_vm_ui ;;
            3) restore_vm_ui ;;
            4) discover_kvm_hosts ;;
            5) create_cluster_ui ;;
            6) storage_menu ;;
            7) setup_live_migration ;;
            8) start_api ;;
            9) start_monitoring ;;
            10) install_ovirt ;;
            11) install_proxmox ;;
            12) check_versions ;;
            13) exit 0 ;;
            *) log "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# Запуск
main "$@"
