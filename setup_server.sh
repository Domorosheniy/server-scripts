#!/usr/bin/env bash
set -e

# Создаём папку для логов, если её нет
mkdir -p /var/log

# Логируем всё в файл /var/log/setup_server.log
exec > >(tee -i /var/log/setup_server.log) 2>&1

echo "=== НАЧАЛО НАСТРОЙКИ СЕРВЕРА ==="
date

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

# Берём порт из второго аргумента, если его нет — используем 40024
SSH_PORT=${2:-"40024"}

PANEL_PORT=54321
INBOUND_PORTS="443 8443 2053"  # ПРОБЕЛЫ, не запятые!

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

# Проверяем, не занят ли SSH_PORT
echo "[1/8] Проверка порта $SSH_PORT..."
if ss -tuln | grep -q ":$SSH_PORT "; then
    echo "[!] Порт $SSH_PORT уже занят! Выберите другой порт."
    exit 1
fi

# ========== ОСНОВНАЯ ЧАСТЬ ==========

# 1. ВРЕМЯ (фикс x509)
echo "[2/8] Настройка времени..."
timedatectl set-timezone Europe/Moscow
timedatectl set-ntp true
apt install -y ca-certificates
update-ca-certificates

# 2. Обновление системы
echo "[3/8] Обновление системы..."
apt update -y && apt upgrade -y -o Dpkg::Options::="--force-confold"

# 3. Создание пользователя
echo "[4/8] Настройка пользователя $USER_NAME..."
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -s /bin/bash "$USER_NAME"
    echo "[+] Пользователь $USER_NAME создан."
else
    echo "[!] Пользователь $USER_NAME уже существует."
fi

# Устанавливаем пароль
echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"

# Настраиваем SSH ключи
mkdir -p "/home/$USER_NAME/.ssh"
if [ -f "/root/.ssh/authorized_keys" ]; then
    cp /root/.ssh/authorized_keys "/home/$USER_NAME/.ssh/"
    chmod 600 "/home/$USER_NAME/.ssh/authorized_keys"
fi
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"
chmod 700 "/home/$USER_NAME/.ssh"

# 4. НАСТРОЙКА SSH - ИСПРАВЛЕННАЯ ЧАСТЬ!
echo "[5/8] Настройка SSH на порту $SSH_PORT..."
SSH_CONFIG="/etc/ssh/sshd_config"

# Создаём резервную копию
cp "$SSH_CONFIG" "$SSH_CONFIG.backup.$(date +%s)"

# Устанавливаем новый порт
if grep -q "^Port " "$SSH_CONFIG"; then
    sed -i "s/^Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
else
    # Если нет строки Port, добавляем
    sed -i "s/^#Port 22/Port $SSH_PORT/" "$SSH_CONFIG"
    if ! grep -q "^Port " "$SSH_CONFIG"; then
        echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    fi
fi

# Разрешаем аутентификацию по ключам
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$SSH_CONFIG"
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$SSH_CONFIG"

# Разрешаем вход для нового пользователя
if ! grep -q "^AllowUsers " "$SSH_CONFIG"; then
    echo "AllowUsers $USER_NAME" >> "$SSH_CONFIG"
else
    if ! grep -q "$USER_NAME" "$SSH_CONFIG"; then
        sed -i "/^AllowUsers/ s/$/ $USER_NAME/" "$SSH_CONFIG"
    fi
fi

# Закрываем вход для root (рекомендуется)
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' "$SSH_CONFIG"

# Перезапускаем SSH ДО настройки фаервола
systemctl restart ssh

# Проверяем, что SSH слушает новый порт
echo "[+] Проверяем работу SSH..."
sleep 2
if ss -tlnp | grep -q ":$SSH_PORT "; then
    echo "[✓] SSH успешно запущен на порту $SSH_PORT"
else
    echo "[!] SSH не слушает порт $SSH_PORT. Проверьте конфигурацию."
    echo "[!] ВОССТАНОВЛЕНИЕ: временно оставляем порт 22 открытым..."
    sed -i "s/^Port $SSH_PORT/Port 22/" "$SSH_CONFIG"
    systemctl restart ssh
    SSH_PORT=22
fi

# 5. НАСТРОЙКА UFW
echo "[6/8] Настройка фаервола (UFW)..."
apt install -y ufw

# Сбрасываем правила (аккуратно)
ufw --force disable || true

# Устанавливаем политики по умолчанию
ufw default deny incoming
ufw default allow outgoing

# Открываем порты В ПОРЯДКЕ ВАЖНОСТИ:
# 1. Сначала SSH порт - КРИТИЧЕСКИ ВАЖНО!
ufw allow "$SSH_PORT/tcp"
echo "[+] Открыт порт SSH: $SSH_PORT"

# 2. Остальные порты
for port in $INBOUND_PORTS; do
    ufw allow "$port/tcp"
    echo "[+] Открыт порт: $port"
done

ufw allow 80/tcp                 # HTTP
ufw allow 8080/tcp               # доп. веб
ufw allow "$PANEL_PORT/tcp"      # ПАНЕЛЬ

# Закрываем старый порт SSH (если он не 22)
if [ "$SSH_PORT" != "22" ]; then
    ufw deny 22/tcp
    echo "[+] Закрыт старый порт SSH: 22"
fi

# Включаем UFW
ufw --force enable

echo "[7/8] Статус фаервола:"
ufw status numbered

# 6. Установка fail2ban (опционально, но рекомендуется)
echo "[8/8] Установка дополнительной защиты..."
apt install -y fail2ban

# Создаём конфиг для защиты SSH
cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

systemctl restart fail2ban

# ========== ФИНАЛЬНАЯ ИНФОРМАЦИЯ ==========
echo "==========================================="
echo "НАСТРОЙКА ЗАВЕРШЕНА!"
echo "==========================================="
echo "Сервер: $(hostname -I | awk '{print $1}')"
echo "SSH порт: $SSH_PORT"
echo "Пользователь: $USER_NAME"
echo "Пароль: (установленный вами)"
echo ""
echo "ДЛЯ ПОДКЛЮЧЕНИЯ:"
echo "ssh -p $SSH_PORT $USER_NAME@$(curl -s ifconfig.me)"
echo ""
echo "Открытые порты:"
echo "- SSH: $SSH_PORT"
echo "- Веб: 80, 8080"
echo "- Панель: $PANEL_PORT"
echo "- Дополнительно: $INBOUND_PORTS"
echo "==========================================="

# Сохраняем информацию в файл
INFO_FILE="/root/server_info.txt"
cat > "$INFO_FILE" << EOF
Серверная информация:
IP: $(curl -s ifconfig.me)
SSH порт: $SSH_PORT
Пользователь: $USER_NAME
Пароль: (установлен вами)
Дата настройки: $(date)
EOF

echo "[✓] Информация сохранена в $INFO_FILE"
