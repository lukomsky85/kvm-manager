#!/bin/bash

# Полный скрипт для управления KVM с возможностью создания ВМ
# Поддерживает Debian/Ubuntu (deb) и CentOS/RHEL (rpm) системы

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
VERSION_CHECK_URL="https://api.github.com/repos/libvirt/libvirt/tags"
SCRIPT_VERSION="1.3.0"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функция логирования
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
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
    
    # Выводим информацию
    echo -e "\n${YELLOW}Текущие версии:${NC}"
    echo -e "libvirt: ${GREEN}$current_libvirt${NC} (последняя: $latest_libvirt)"
    echo -e "QEMU: ${GREEN}$current_qemu${NC} (последняя: $latest_qemu)"
    echo -e "Ceph: ${GREEN}$current_ceph${NC} (последняя: $latest_ceph)"
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
                "libguestfs-tools"
                "jq"
                "curl"
            )
            ;;
        "rpm")
            required_pkgs=(
                "libvirt-client"
                "qemu-img"
                "openssh-clients"
                "libvirt"
                "qemu-kvm"
                "virt-install"
                "arp-scan"
                "genisoimage"
                "libguestfs-tools"
                "jq"
                "curl"
            )
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac

    # Проверка пакетов
    local missing_pkgs=()
    for pkg in "${required_pkgs[@]}"; do
        if { [ "$pkg_manager" = "deb" ] && ! dpkg -l | grep -q "^ii  $pkg"; } ||
           { [ "$pkg_manager" = "rpm" ] && ! rpm -q "$pkg" &> /dev/null; }; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        log "${YELLOW}Установка недостающих пакетов: ${missing_pkgs[*]}${NC}"
        install_packages "${missing_pkgs[@]}"
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

# Установка Ceph
install_ceph() {
    local pkg_manager=$(detect_pkg_manager)
    
    log "${YELLOW}Установка Ceph...${NC}"
    
    case $pkg_manager in
        "deb")
            # Для Ubuntu/Debian
            if ! grep -q "ceph" /etc/apt/sources.list.d/ceph.list 2>/dev/null; then
                wget -q -O- 'https://download.ceph.com/keys/release.asc' | apt-key add -
                echo "deb https://download.ceph.com/debian-luminous/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/ceph.list
                apt-get update
            fi
            install_packages ceph ceph-common radosgw
            ;;
        "rpm")
            # Для CentOS/RHEL
            if [ ! -f /etc/yum.repos.d/ceph.repo ]; then
                rpm -Uvh https://download.ceph.com/rpm-luminous/el7/noarch/ceph-release-1-1.el7.noarch.rpm
            fi
            install_packages ceph ceph-common
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
    
    log "${GREEN}Ceph установлен${NC}"
}

# Настройка Ceph кластера
setup_ceph_cluster() {
    local node_ip=$1
    local ceph_nodes=("${@:2}")
    
    log "${YELLOW}Настройка Ceph кластера...${NC}"
    
    # Проверяем установлен ли Ceph
    if ! command -v ceph &> /dev/null; then
        install_ceph
    fi
    
    # Создаем конфигурационный файл
    mkdir -p /etc/ceph
    cat > $CEPH_CONF <<EOF
[global]
fsid = $(uuidgen)
mon initial members = $(hostname -s)
mon host = $node_ip
public network = ${node_ip%.*}.0/24
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
osd journal size = 1024
osd pool default size = 3
osd pool default min size = 1
osd pool default pg num = 256
osd pool default pgp num = 256
osd crush chooseleaf type = 1
EOF
    
    # Создаем ключи
    ceph-authtool --create-keyring /tmp/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'
    ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
    ceph-authtool --create-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring --gen-key -n client.bootstrap-osd --cap mon 'profile bootstrap-osd' --cap mgr 'allow r'
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring
    
    # Настраиваем monmap
    monmaptool --create --add $(hostname -s) $node_ip --fsid $(grep fsid $CEPH_CONF | cut -d' ' -f3) /tmp/monmap
    
    # Создаем директории
    mkdir -p /var/lib/ceph/mon/ceph-$(hostname -s)
    mkdir -p /var/lib/ceph/osd
    
    # Запускаем монитор
    ceph-mon --mkfs -i $(hostname -s) --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring
    systemctl start ceph-mon@$(hostname -s)
    systemctl enable ceph-mon@$(hostname -s)
    
    # Добавляем OSD
    for disk in $(lsblk -dpn -o NAME | grep -v "/dev/[sv]da"); do
        ceph-volume lvm create --data $disk
    done
    
    # Если есть другие узлы, добавляем их в кластер
    if [ ${#ceph_nodes[@]} -gt 0 ]; then
        for node in "${ceph_nodes[@]}"; do
            ssh $node "$(declare -f install_ceph); install_ceph"
            scp $CEPH_CONF $node:$CEPH_CONF
            scp /etc/ceph/ceph.client.admin.keyring $node:/etc/ceph/
            
            ssh $node "ceph-mon --mkfs -i $(hostname -s) --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring"
            ssh $node "systemctl start ceph-mon@$(hostname -s)"
            ssh $node "systemctl enable ceph-mon@$(hostname -s)"
            
            for disk in $(ssh $node "lsblk -dpn -o NAME | grep -v '/dev/[sv]da'"); do
                ssh $node "ceph-volume lvm create --data $disk"
            done
        done
    fi
    
    # Создаем пул для libvirt
    ceph osd pool create $CEPH_POOL_NAME 128 128
    ceph osd pool application enable $CEPH_POOL_NAME rbd
    
    # Настраиваем права
    ceph auth get-or-create client.libvirt mon 'allow r' osd "allow class-read object_prefix rbd_children, allow rwx pool=$CEPH_POOL_NAME"
    
    log "${GREEN}Ceph кластер настроен${NC}"
    log "Для проверки выполните: ceph -s"
}

# Настройка интеграции Ceph с libvirt
setup_ceph_libvirt() {
    log "${YELLOW}Настройка интеграции Ceph с libvirt...${NC}"
    
    # Получаем ключ для libvirt
    local libvirt_key=$(ceph auth get-key client.libvirt)
    
    # Создаем секрет для libvirt
    cat > /tmp/secret.xml <<EOF
<secret ephemeral='no' private='no'>
  <usage type='ceph'>
    <name>client.libvirt secret</name>
  </usage>
</secret>
EOF
    
    virsh secret-define --file /tmp/secret.xml
    virsh secret-set-value --secret $(virsh secret-list | grep client.libvirt | awk '{print $1}') --base64 $libvirt_key
    
    # Создаем пул хранения
    cat > /tmp/ceph-pool.xml <<EOF
<pool type='rbd'>
  <name>$CEPH_POOL_NAME</name>
  <source>
    <name>$CEPH_POOL_NAME</name>
    <host name='$(hostname -s)' port='6789'/>
    <auth type='ceph' username='libvirt'>
      <secret uuid='$(virsh secret-list | grep client.libvirt | awk '{print $1}')'/>
    </auth>
  </source>
</pool>
EOF
    
    virsh pool-define /tmp/ceph-pool.xml
    virsh pool-start $CEPH_POOL_NAME
    virsh pool-autostart $CEPH_POOL_NAME
    
    log "${GREEN}Интеграция Ceph с libvirt настроена${NC}"
    log "Теперь можно создавать диски ВМ в Ceph:"
    log "virsh vol-create-as $CEPH_POOL_NAME vm-disk.qcow2 20G --format raw"
}

# Создание виртуальной машины
create_vm() {
    local vm_name=$1
    local vm_ram=$2
    local vm_cpus=$3
    local disk_size=$4
    local os_variant=$5
    local iso_path=$6
    local network=$7

    log "${YELLOW}Создание виртуальной машины ${vm_name}...${NC}"

    # Проверка существования ВМ
    if virsh list --all | grep -q " ${vm_name} "; then
        log "${RED}Виртуальная машина с именем ${vm_name} уже существует${NC}"
        return 1
    fi

    # Проверка ISO образа
    if [ ! -f "$iso_path" ]; then
        log "${RED}ISO образ не найден: ${iso_path}${NC}"
        return 1
    fi

    # Создание директории для дисков
    local vm_dir="/var/lib/libvirt/images/${vm_name}"
    mkdir -p "$vm_dir"

    # Создание диска
    local disk_path="${vm_dir}/${vm_name}.qcow2"
    qemu-img create -f qcow2 "$disk_path" "$disk_size"

    # Создание ВМ
    virt-install \
        --name "$vm_name" \
        --ram "$vm_ram" \
        --vcpus "$vm_cpus" \
        --disk path="$disk_path",size="$disk_size",format=qcow2 \
        --os-type "$VM_DEFAULT_OS_TYPE" \
        --os-variant "$os_variant" \
        --network "$network" \
        --graphics spice \
        --cdrom "$iso_path" \
        --noautoconsole

    if [ $? -eq 0 ]; then
        log "${GREEN}Виртуальная машина ${vm_name} успешно создана${NC}"
        log "Подключиться через virt-viewer: virt-viewer ${vm_name}"
        log "Или через консоль: virsh console ${vm_name}"
    else
        log "${RED}Ошибка при создании виртуальной машины ${vm_name}${NC}"
        return 1
    fi
}

# Интерфейс для создания ВМ
create_vm_ui() {
    echo -e "\n${YELLOW}Создание новой виртуальной машины${NC}"
    
    # Запрос параметров
    echo -n "Введите имя виртуальной машины: "
    read vm_name
    
    echo -n "Количество RAM (MB) [${VM_DEFAULT_RAM}]: "
    read vm_ram
    vm_ram=${vm_ram:-$VM_DEFAULT_RAM}
    
    echo -n "Количество CPU ядер [${VM_DEFAULT_CPUS}]: "
    read vm_cpus
    vm_cpus=${vm_cpus:-$VM_DEFAULT_CPUS}
    
    echo -n "Размер диска (например, 20G) [${VM_DEFAULT_DISK_SIZE}]: "
    read disk_size
    disk_size=${disk_size:-$VM_DEFAULT_DISK_SIZE}
    
    echo -n "Тип ОС (например, ubuntu22.04) [${VM_DEFAULT_OS_VARIANT}]: "
    read os_variant
    os_variant=${os_variant:-$VM_DEFAULT_OS_VARIANT}
    
    echo -n "Путь к ISO образу (например, ${ISO_DIR}/ubuntu.iso): "
    read iso_path
    
    echo -n "Сеть (по умолчанию: default): "
    read network
    network=${network:-"default"}
    
    # Проверка и создание ISO директории
    mkdir -p "$ISO_DIR"
    
    # Создание ВМ
    create_vm "$vm_name" "$vm_ram" "$vm_cpus" "$disk_size" "$os_variant" "$iso_path" "$network"
}

# Создание бекапа виртуальной машины
backup_vm() {
    local vm_name=$1
    local snapshot_name="backup_snapshot_$(date +%Y%m%d%H%M%S)"
    local backup_path="$BACKUP_DIR/$vm_name/$(date +%Y%m%d_%H%M%S)"
    
    log "${YELLOW}Начинаем бекап виртуальной машины $vm_name${NC}"
    
    # Проверяем существование VM
    if ! virsh dominfo "$vm_name" &> /dev/null; then
        log "${RED}Ошибка: Виртуальная машина $vm_name не найдена${NC}"
        return 1
    fi
    
    # Проверяем состояние VM
    local vm_state=$(virsh domstate "$vm_name")
    
    # Если VM запущена, создаем снепшот
    if [ "$vm_state" == "running" ]; then
        log "ВМ запущена, создаем снепшот..."
        virsh snapshot-create-as --domain "$vm_name" --name "$snapshot_name" --atomic --quiesce
        if [ $? -ne 0 ]; then
            log "${RED}Ошибка при создании снепшота${NC}"
            return 1
        fi
    fi
    
    # Создаем директорию для бекапа
    mkdir -p "$backup_path"
    
    # Получаем список дисков VM
    local disks=$(virsh domblklist "$vm_name" | awk 'NR>2 && $2 {print $2}')
    
    # Копируем конфигурацию VM
    log "Копируем XML конфигурацию..."
    virsh dumpxml "$vm_name" > "$backup_path/$vm_name.xml"
    
    # Копируем диски
    for disk in $disks; do
        local disk_name=$(basename "$disk")
        log "Копируем диск $disk_name..."
        qemu-img convert -O qcow2 "$disk" "$backup_path/$disk_name.qcow2"
    done
    
    # Если был создан снепшот, удаляем его
    if [ "$vm_state" == "running" ]; then
        log "Удаляем временный снепшот..."
        virsh snapshot-delete "$vm_name" "$snapshot_name" &> /dev/null
    fi
    
    log "${GREEN}Бекап виртуальной машины $vm_name успешно создан в $backup_path${NC}"
}

# Интерфейс для создания бекапа
backup_vm_ui() {
    echo -e "\n${YELLOW}Создание бекапа виртуальной машины${NC}"
    echo -n "Введите имя виртуальной машины для бекапа: "
    read vm_name
    backup_vm "$vm_name"
}

# Восстановление VM из бекапа
restore_vm() {
    local vm_name=$1
    local backup_path=$2
    
    log "${YELLOW}Начинаем восстановление $vm_name из $backup_path${NC}"
    
    # Проверяем существование бекапа
    if [ ! -d "$backup_path" ]; then
        log "${RED}Ошибка: Директория бекапа $backup_path не найдена${NC}"
        return 1
    fi
    
    # Проверяем XML файл
    if [ ! -f "$backup_path/$vm_name.xml" ]; then
        log "${RED}Ошибка: XML конфигурация не найдена${NC}"
        return 1
    fi
    
    # Удаляем VM если она уже существует
    if virsh dominfo "$vm_name" &> /dev/null; then
        log "ВМ уже существует, удаляем..."
        virsh destroy "$vm_name" &> /dev/null || true
        virsh undefine "$vm_name" --nvram
    fi
    
    # Регистрируем VM
    log "Восстанавливаем XML конфигурацию..."
    virsh define "$backup_path/$vm_name.xml"
    
    # Восстанавливаем диски
    local disks=$(virsh domblklist "$vm_name" | awk 'NR>2 && $2 {print $2}')
    
    for disk in $disks; do
        local disk_name=$(basename "$disk")
        if [ -f "$backup_path/$disk_name.qcow2" ]; then
            log "Восстанавливаем диск $disk_name..."
            qemu-img convert -O qcow2 "$backup_path/$disk_name.qcow2" "$disk"
        else
            log "${YELLOW}Предупреждение: Файл диска $disk_name.qcow2 не найден${NC}"
        fi
    done
    
    log "${GREEN}Виртуальная машина $vm_name успешно восстановлена${NC}"
}

# Интерфейс для восстановления
restore_vm_ui() {
    echo -e "\n${YELLOW}Восстановление виртуальной машины из бекапа${NC}"
    echo -n "Введите имя виртуальной машины для восстановления: "
    read vm_name
    echo -n "Введите путь к бекапу: "
    read backup_path
    restore_vm "$vm_name" "$backup_path"
}

# Поиск KVM хостов в локальной сети
discover_kvm_hosts() {
    log "${YELLOW}Поиск KVM хостов в локальной сети...${NC}"
    
    # Получаем локальную подсеть
    local subnet=$(ip route | awk '/src/ {print $1}' | head -1)
    
    if [ -z "$subnet" ]; then
        log "${RED}Не удалось определить локальную подсеть${NC}"
        return 1
    fi
    
    log "Сканируем подсеть $subnet..."
    
    # Используем arp-scan для поиска хостов
    local hosts=$(arp-scan --localnet --quiet --ignoredups | awk 'NR>2 {print $1}' | sort -u)
    
    if [ -z "$hosts" ]; then
        log "${YELLOW}Хосты не найдены${NC}"
        return 0
    fi
    
    log "Найдены хосты:"
    for host in $hosts; do
        # Проверяем, есть ли libvirt на хосте
        if ssh -o ConnectTimeout=5 -i $SSH_KEY $NODE_USER@$host "which virsh &> /dev/null"; then
            echo -e "${GREEN}$host - KVM хост${NC}"
        else
            echo "$host"
        fi
    done
}

# Настройка SSH ключей для кластера
setup_ssh_keys() {
    log "${YELLOW}Настройка SSH ключей для кластера...${NC}"
    
    if [ ! -f "$SSH_KEY" ]; then
        log "Генерация SSH ключа..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q
    fi
    
    # Добавляем ключ в authorized_keys
    cat "${SSH_KEY}.pub" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    
    log "${GREEN}SSH ключи настроены${NC}"
}

# Добавление узла в кластер
add_node_to_cluster() {
    local node_ip=$1
    
    log "${YELLOW}Добавление узла $node_ip в кластер...${NC}"
    
    # Проверяем доступность узла
    if ! ping -c 1 -W 2 "$node_ip" &> /dev/null; then
        log "${RED}Узел $node_ip недоступен${NC}"
        return 1
    fi
    
    # Копируем SSH ключ
    log "Копируем SSH ключ на узел $node_ip..."
    ssh-copy-id -i "$SSH_KEY" "$NODE_USER@$node_ip"
    
    # Проверяем наличие libvirt на узле
    if ! ssh -i "$SSH_KEY" "$NODE_USER@$node_ip" "which virsh &> /dev/null"; then
        log "${RED}Libvirt не установлен на узле $node_ip${NC}"
        return 1
    fi
    
    # Добавляем узел в список известных хостов
    ssh-keyscan "$node_ip" >> ~/.ssh/known_hosts
    
    log "${GREEN}Узел $node_ip успешно добавлен в кластер${NC}"
}

# Создание кластера KVM хостов
create_cluster() {
    local nodes=("$@")
    
    if [ ${#nodes[@]} -eq 0 ]; then
        log "${RED}Не указаны узлы для кластера${NC}"
        return 1
    fi
    
    log "${YELLOW}Создание кластера KVM из ${#nodes[@]} узлов...${NC}"
    
    # Настраиваем SSH ключи
    setup_ssh_keys
    
    # Добавляем каждый узел в кластер
    for node in "${nodes[@]}"; do
        add_node_to_cluster "$node"
    done
    
    log "${GREEN}Кластер KVM успешно создан${NC}"
    log "Для управления узлами используйте: virsh -c qemu+ssh://user@node/system"
}

# Интерфейс для создания кластера
create_cluster_ui() {
    echo -e "\n${YELLOW}Создание кластера KVM${NC}"
    echo -n "Введите IP адреса узлов через пробел: "
    read -a nodes
    create_cluster "${nodes[@]}"
}

# Меню настройки хранилища
storage_menu() {
    while true; do
        echo -e "\n${YELLOW}Настройка общего хранилища${NC}"
        echo "1) Настроить NFS сервер"
        echo "2) Настроить NFS клиент"
        echo "3) Установить и настроить Ceph"
        echo "4) Настроить интеграцию Ceph с libvirt"
        echo "5) Вернуться в главное меню"
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
            5) return ;;
            *) log "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# Настройка NFS сервера
setup_nfs_server() {
    log "${YELLOW}Настройка NFS сервера...${NC}"
    
    local pkg_manager=$(detect_pkg_manager)
    
    case $pkg_manager in
        "deb")
            install_packages nfs-kernel-server
            ;;
        "rpm")
            install_packages nfs-utils
            systemctl enable --now nfs-server
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
    
    # Общая часть настройки
    mkdir -p "$SHARED_STORAGE"
    chown nobody:nogroup "$SHARED_STORAGE"
    chmod 777 "$SHARED_STORAGE"
    
    echo "$SHARED_STORAGE *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    
    if [ "$pkg_manager" = "deb" ]; then
        systemctl restart nfs-kernel-server
    else
        exportfs -a
        systemctl restart nfs-server
    fi
    
    NFS_SERVER=$(hostname -I | awk '{print $1}')
    log "${GREEN}NFS сервер настроен. Экспортируется: $SHARED_STORAGE${NC}"
    log "Используйте этот IP для подключения клиентов: $NFS_SERVER"
}

# Настройка NFS клиента
setup_nfs_client() {
    local nfs_server=$1
    local pkg_manager=$(detect_pkg_manager)
    
    log "${YELLOW}Настройка NFS клиента для подключения к $nfs_server...${NC}"
    
    case $pkg_manager in
        "deb")
            install_packages nfs-common
            ;;
        "rpm")
            install_packages nfs-utils
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
    
    mkdir -p "$SHARED_STORAGE"
    
    if ! grep -qs "$SHARED_STORAGE" /proc/mounts; then
        mount "$nfs_server:$SHARED_STORAGE" "$SHARED_STORAGE"
        echo "$nfs_server:$SHARED_STORAGE $SHARED_STORAGE nfs auto,nofail,noatime,nolock,intr,tcp,actimeo=1800 0 0" >> /etc/fstab
    fi
    
    if ! virsh pool-list --all | grep -q shared_storage; then
        virsh pool-define-as --name shared_storage --type dir --target "$SHARED_STORAGE"
        virsh pool-build shared_storage
        virsh pool-start shared_storage
        virsh pool-autostart shared_storage
    fi
    
    log "${GREEN}NFS клиент настроен. Общее хранилище доступно в $SHARED_STORAGE${NC}"
}

# Настройка live миграции
setup_live_migration() {
    log "${YELLOW}Настройка live migration...${NC}"
    
    local pkg_manager=$(detect_pkg_manager)
    
    # Настройка libvirt
    sed -i '/^#listen_tls = /c\listen_tls = 0' /etc/libvirt/libvirtd.conf
    sed -i '/^#listen_tcp = /c\listen_tcp = 1' /etc/libvirt/libvirtd.conf
    sed -i '/^#auth_tcp = /c\auth_tcp = "none"' /etc/libvirt/libvirtd.conf
    
    if [ "$pkg_manager" = "deb" ]; then
        sed -i '/^LIBVIRTD_ARGS=/c\LIBVIRTD_ARGS="--listen"' /etc/default/libvirtd
    else
        echo 'LIBVIRTD_ARGS="--listen"' > /etc/sysconfig/libvirtd
    fi
    
    # Настройка QEMU
    sed -i '/^#user = /c\user = "root"' /etc/libvirt/qemu.conf
    sed -i '/^#group = /c\group = "root"' /etc/libvirt/qemu.conf
    
    # Перезапуск служб
    systemctl restart libvirtd
    
    # Открытие портов в firewall (для RPM-систем)
    if [ "$pkg_manager" = "rpm" ]; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --add-port=16509/tcp --permanent
            firewall-cmd --add-port=16514/tcp --permanent
            firewall-cmd --reload
        fi
    fi
    
    log "${GREEN}Настройка live migration завершена${NC}"
    log "Для миграции используйте: virsh migrate --live --verbose vm_name qemu+ssh://target_host/system"
}

# Установка Proxmox VE
install_proxmox() {
    log "${YELLOW}Установка Proxmox VE...${NC}"
    
    local pkg_manager=$(detect_pkg_manager)
    
    case $pkg_manager in
        "deb")
            # Проверяем, является ли система Debian
            if ! grep -q "Debian" /etc/os-release; then
                log "${RED}Proxmox VE официально поддерживается только на Debian${NC}"
                return 1
            fi

            # Добавляем репозиторий Proxmox
            echo "deb http://download.proxmox.com/debian/pve $(grep "VERSION_CODENAME=" /etc/os-release | cut -d= -f2) pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list

            # Добавляем GPG ключ
            wget https://enterprise.proxmox.com/debian/proxmox-release-$(grep "VERSION_CODENAME=" /etc/os-release | cut -d= -f2).gpg -O /etc/apt/trusted.gpg.d/proxmox-release.gpg
            
            # Обновляем и устанавливаем
            apt-get update
            apt-get install -y proxmox-ve postfix open-iscsi
            
            # Настройка postfix
            debconf-set-selections <<< "postfix postfix/mailname string $(hostname -f)"
            debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
            ;;
        "rpm")
            log "${RED}Proxmox VE не поддерживается на RPM-системах${NC}"
            return 1
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
    
    log "${GREEN}Proxmox VE установлен. Доступен через web-интерфейс: https://$(hostname -I | awk '{print $1}'):8006${NC}"
    log "Рекомендуется перезагрузить систему после установки"
}

# Установка oVirt Engine
install_ovirt() {
    log "${YELLOW}Установка oVirt Engine...${NC}"
    
    local pkg_manager=$(detect_pkg_manager)
    
    case $pkg_manager in
        "rpm")
            if [ ! -f /etc/yum.repos.d/ovirt.repo ]; then
                yum install -y https://resources.ovirt.org/pub/yum-repo/ovirt-release44.rpm
                yum install -y ovirt-engine
                engine-setup
            else
                log "${YELLOW}oVirt Engine уже установлен${NC}"
            fi
            ;;
        "deb")
            log "${RED}oVirt Engine не поддерживается на DEB-системах${NC}"
            return 1
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac
    
    log "${GREEN}oVirt Engine установлен. Доступен через web-интерфейс: https://$(hostname -I | awk '{print $1}'):443${NC}"
}

# Обновленное главное меню
show_menu() {
    echo -e "\n${YELLOW}Меню управления KVM (версия $SCRIPT_VERSION):${NC}"
    echo "1) Создать виртуальную машину"
    echo "2) Создать бекап виртуальной машины"
    echo "3) Восстановить виртуальную машину из бекапа"
    echo "4) Найти KVM хосты в сети"
    echo "5) Создать кластер KVM"
    echo "6) Настроить общее хранилище"
    echo "7) Настроить live миграцию ВМ"
    echo "8) Установить Proxmox VE"
    echo "9) Установить oVirt Engine"
    echo "10) Проверить версии компонентов"
    echo "11) Выход"
    echo -n "Выберите опцию: "
}

# Инициализация
init() {
    # Проверка прав
    if [ "$(id -u)" -ne 0 ]; then
        log "${RED}Скрипт требует root-прав${NC}"
        exit 1
    fi
    
    # Создание директорий
    mkdir -p "$BACKUP_DIR" "$ISO_DIR" "$SHARED_STORAGE"
    touch "$LOG_FILE"
    
    # Проверка зависимостей
    check_dependencies
    
    # Проверка работы libvirt
    if ! systemctl is-active --quiet libvirtd; then
        log "${YELLOW}Запуск службы libvirtd...${NC}"
        systemctl start libvirtd
        systemctl enable libvirtd
    fi
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
            8) install_proxmox ;;
            9) install_ovirt ;;
            10) check_versions ;;
            11) exit 0 ;;
            *) log "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# Запуск
main
