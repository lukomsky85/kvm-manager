#!/bin/bash

# Полный скрипт для управления KVM с расширенными возможностями
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
LVM_VG="kvm-vg"
ZFS_POOL="kvm-pool"
VERSION_CHECK_URL="https://api.github.com/repos/libvirt/libvirt/tags"
SCRIPT_VERSION="1.4.0"
API_PORT="8080"
MONITORING_INTERVAL="60"
OVIRT_ADMIN_PASSWORD=""

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
                # ZFS поддержка (из ZFS репозитория)
                "zfs"
                # Мониторинг
                "sysstat"
                "prometheus-node_exporter"
            )
            ;;
        *)
            log "${RED}Неизвестный пакетный менеджер${NC}"
            return 1
            ;;
    esac

    # API зависимости (Python3)
    if [[ "$ENABLE_API" == "true" ]]; then
        required_pkgs+=(
            "python3"
            "python3-pip"
            "python3-venv"
        )
        required_bins+=(
            "python3"
            "pip3"
        )
    fi

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
        install_packages "${missing_pkgs[@]}"
    fi

    # Проверка ZFS kernel module
    if ! lsmod | grep -q zfs; then
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
    echo "11) Проверить версии компонентов"
    echo "12) Выход"
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
            11) check_versions ;;
            12) exit 0 ;;
            *) log "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# Запуск
main
