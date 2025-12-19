#!/usr/bin/env bash
set -e

# Создаём папку для логов, если её нет
mkdir -p /var/log

# Логируем всё в файл /var/log/setup_server.log
exec > >(tee -i /var/log/setup_server.log) 2>&1

# Проверяем, установлен ли git. Если нет — устанавливаем
if ! command -v git &> /dev/null; then
    echo "[+] Устанавливаем git..."
    if ! apt update -y; then
        echo "[!] Ошибка при обновлении пакетов (apt update)."
        exit 1
    fi
    if ! apt install -y git; then
        echo "[!] Ошибка при установке git."
        exit 1
    fi
fi

# ========== НАСТРОЙКИ ==========

# Берём имя пользователя из первого аргумента, если его нет — используем "user"
USER_NAME=${1:-"user"}

# Запрашиваем пароль у пользователя (не отображаем его при вводе)
read -s -p "Введите пароль для пользователя $USER_NAME: " USER_PASS
echo  # Переход на новую строку после ввода

# Добавление пользователя в группу sudo
usermod -aG sudo $USER_NAME

# Берём порт из второго аргумента, если его нет — используем 40024
SSH_PORT=${2:-"40024"}

# Проверяем, не занят ли SSH_PORT
if ss -tuln | grep -q ":$SSH_PORT "; then
    echo "[!] Порт $SSH_PORT уже занят! Выберите другой порт."
    exit 1
fi

PANEL_PORT=54321
INBOUND_PORTS="443 8443 2053"  # ПРОБЕЛЫ, не запятые!

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

# Проверяем, существует ли пользователь
if ! id "$USER_NAME" &>/dev/null; then
    echo "[+] Создаём пользователя $USER_NAME..."
    useradd -m -s /bin/bash "$USER_NAME"
else
    echo "[!] Пользователь $USER_NAME уже существует."
fi

# Меняем пароль (даже если пользователь существует)
echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"


# 2. ВРЕМЯ (фикс x509)
echo "[1/8] Время..."
timedatectl set-timezone Europe/Moscow
timedatectl set-ntp true
apt install -y ca-certificates
update-ca-certificates

# 3. Система
echo "[2/8] Обновление..."
apt update -y && apt upgrade -y -o Dpkg::Options::="--force-confold"

# 4. ПОЛЬЗОВАТЕЛЬ user
echo "[3/8] Пользователь $USER_NAME..."
id "$USER_NAME" &>/dev/null || useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"

mkdir -p "/home/$USER_NAME/.ssh"
cp /root/.ssh/authorized_keys "/home/$USER_NAME/.ssh/" 2>/dev/null || true
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"
chmod 700 "/home/$USER_NAME/.ssh"
chmod 600 "/home/$USER_NAME/.ssh/authorized_keys" 2>/dev/null || true

# 6. UFW ✅ ИСПРАВЛЕН
echo "[5/8] UFW..."
apt install -y ufw
ufw --force reset

# Добавляем порты из INBOUND_PORTS
for port in $INBOUND_PORTS; do
  ufw allow "$port/tcp"
done

# Остальные порты
ufw allow "$SSH_PORT/tcp"        # SSH
ufw allow 80/tcp                 # HTTP
ufw allow 8080/tcp               # доп. веб
ufw allow "$PANEL_PORT/tcp"      # ПАНЕЛЬ
ufw deny 22/tcp                  # закрываем старый SSH

ufw --force enable
echo "UFW статус:"
ufw status

# 9. Проверка
echo "  ufw status"
