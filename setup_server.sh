#!/usr/bin/env bash
set -e

# Создаём папку для логов, если её нет
mkdir -p /var/log

# Логируем всё в файл /var/log/setup_server.log
exec > >(tee -i /var/log/setup_server.log) 2>&1

# Проверяем, установлен ли git. Если нет — устанавливаем
if ! command -v git &> /dev/null; then
    echo "[+] Устанавливаем git..."
    if ! apt update -y; then#!/usr/bin/env bash
set -e

# Создаём папку для логов, если её нет
mkdir -p /var/log

# Логируем всё в файл /var/log/setup_server.log
exec > >(tee -i /var/log/setup_server.log) 2>&1

echo "=== НАСТРОЙКА СЕРВЕРА ==="
echo "Скрипт настроит сервер с вашими параметрами"
echo "==========================================="
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

# ========== ИНТЕРАКТИВНЫЙ ВВОД ==========

echo ""
echo "--- ВВОД ПАРАМЕТРОВ ---"

# 1. Ввод имени пользователя
read -p "Введите имя пользователя [по умолчанию: user]: " USER_NAME_INPUT
USER_NAME=${USER_NAME_INPUT:-"user"}

# Проверяем, что имя пользователя валидное
if ! echo "$USER_NAME" | grep -q '^[a-z_][a-z0-9_-]*$'; then
    echo "[!] Ошибка: Имя пользователя должно содержать только строчные буквы, цифры, дефисы и подчёркивания"
    exit 1
fi

# Проверяем, не существует ли уже пользователь
if id "$USER_NAME" &>/dev/null; then
    echo "[!] Внимание: Пользователь '$USER_NAME' уже существует!"
    read -p "Продолжить с этим пользователем? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Прервано."
        exit 1
    fi
fi

# 2. Ввод пароля
while true; do
    read -s -p "Введите пароль для пользователя $USER_NAME: " USER_PASS
    echo
    if [ -z "$USER_PASS" ]; then
        echo "[!] Пароль не может быть пустым!"
        continue
    fi
    
    read -s -p "Повторите пароль: " USER_PASS_CONFIRM
    echo
    
    if [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; then
        echo "[!] Пароли не совпадают! Попробуйте снова."
    else
        break
    fi
done

# 3. Ввод SSH порта
echo ""
echo "Порты ниже 1024 требуют прав root, рекомендуемый диапазон: 1024-65535"
read -p "Введите порт для SSH [по умолчанию: 40024]: " SSH_PORT_INPUT
SSH_PORT=${SSH_PORT_INPUT:-"40024"}

# Проверяем, что порт валидный
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "[!] Ошибка: Порт должен быть числом от 1 до 65535"
    exit 1
fi

# Проверяем, не занят ли порт
if ss -tuln | grep -q ":$SSH_PORT\b"; then
    echo "[!] Ошибка: Порт $SSH_PORT уже занят!"
    echo "Занятые порты:"
    ss -tuln | grep LISTEN | head -10
    read -p "Попробовать другой порт? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Введите другой порт: " SSH_PORT
    else
        exit 1
    fi
fi

# 4. Выбор дополнительных портов
echo ""
echo "--- ДОПОЛНИТЕЛЬНЫЕ ПОРТЫ ---"
echo "Стандартные порты, которые будут открыты:"
echo "- HTTP: 80"
echo "- HTTPS: 443"
echo "- Доп. веб: 8080"

INBOUND_PORTS="443 8443 2053"

read -p "Добавить дополнительные порты? (y/n) [по умолчанию: n]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Введите дополнительные порты через пробел (например: 9000 9001 3000):"
    read EXTRA_PORTS_INPUT
    if [ -n "$EXTRA_PORTS_INPUT" ]; then
        INBOUND_PORTS="$INBOUND_PORTS $EXTRA_PORTS_INPUT"
    fi
fi

# 5. Подтверждение настроек
echo ""
echo "=== ПОДТВЕРЖДЕНИЕ НАСТРОЕК ==="
echo "Имя пользователя: $USER_NAME"
echo "SSH порт: $SSH_PORT"
echo "Порты для открытия: $SSH_PORT, 80, 443, 8080, $INBOUND_PORTS"
echo ""
read -p "Продолжить настройку? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Настройка отменена."
    exit 0
fi

# ========== ПРОВЕРКА ПРАВ ==========

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

# ========== ОСНОВНАЯ ЧАСТЬ ==========

echo "[1/8] Настройка времени..."
timedatectl set-timezone Europe/Moscow
timedatectl set-ntp true
apt install -y ca-certificates
update-ca-certificates

echo "[2/8] Обновление системы..."
apt update -y && apt upgrade -y -o Dpkg::Options::="--force-confold"

echo "[3/8] Создание пользователя $USER_NAME..."
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -s /bin/bash "$USER_NAME"
    echo "[✓] Пользователь $USER_NAME создан."
else
    echo "[!] Пользователь $USER_NAME уже существует, обновляем настройки."
fi

# Устанавливаем пароль
echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"

# Настраиваем SSH ключи
mkdir -p "/home/$USER_NAME/.ssh"
if [ -f "/root/.ssh/authorized_keys" ]; then
    cp /root/.ssh/authorized_keys "/home/$USER_NAME/.ssh/"
    chmod 600 "/home/$USER_NAME/.ssh/authorized_keys"
    echo "[✓] SSH ключи скопированы от root"
fi
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"
chmod 700 "/home/$USER_NAME/.ssh"

# Добавляем пользователя в sudoers без пароля
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"
chmod 440 "/etc/sudoers.d/$USER_NAME"

# 4. НАСТРОЙКА SSH
echo "[4/8] Настройка SSH на порту $SSH_PORT..."
SSH_CONFIG="/etc/ssh/sshd_config"

# Создаём резервную копию
BACKUP_FILE="$SSH_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
cp "$SSH_CONFIG" "$BACKUP_FILE"
echo "[+] Создана резервная копия: $BACKUP_FILE"

# Устанавливаем новый порт
if grep -q "^Port " "$SSH_CONFIG"; then
    sed -i "s/^Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
else
    sed -i "s/^#Port 22/Port $SSH_PORT/" "$SSH_CONFIG"
    if ! grep -q "^Port " "$SSH_CONFIG"; then
        echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    fi
fi

# Основные настройки безопасности
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$SSH_CONFIG"
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$SSH_CONFIG"
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' "$SSH_CONFIG"
sed -i 's/^#\?X11Forwarding .*/X11Forwarding no/' "$SSH_CONFIG"
sed -i 's/^#\?ClientAliveInterval .*/ClientAliveInterval 300/' "$SSH_CONFIG"
sed -i 's/^#\?ClientAliveCountMax .*/ClientAliveCountMax 2/' "$SSH_CONFIG"

# Разрешаем вход только для нашего пользователя
if ! grep -q "^AllowUsers " "$SSH_CONFIG"; then
    echo "AllowUsers $USER_NAME" >> "$SSH_CONFIG"
else
    if ! grep -q "$USER_NAME" "$SSH_CONFIG"; then
        sed -i "/^AllowUsers/ s/$/ $USER_NAME/" "$SSH_CONFIG"
    fi
fi

# Перезапускаем SSH
systemctl restart ssh

# Проверяем, что SSH слушает новый порт
echo "[+] Проверяем работу SSH..."
sleep 3
if ss -tlnp | grep -q ":$SSH_PORT "; then
    echo "[✓] SSH успешно запущен на порту $SSH_PORT"
else
    echo "[!] SSH не слушает порт $SSH_PORT. Проверяем..."
    
    # Пытаемся диагностировать проблему
    systemctl status ssh --no-pager
    
    # Восстанавливаем старый порт на время
    echo "[!] ВОССТАНОВЛЕНИЕ: временно используем порт 22..."
    cp "$BACKUP_FILE" "$SSH_CONFIG"
    systemctl restart ssh
    SSH_PORT=22
    echo "[!] Используйте порт 22 для подключения"
fi

# 5. НАСТРОЙКА UFW
echo "[5/8] Настройка фаервола (UFW)..."
apt install -y ufw

# Сбрасываем правила
echo "[+] Сброс правил фаервола..."
ufw --force disable 2>/dev/null || true

# Устанавливаем политики
ufw default deny incoming
ufw default allow outgoing

# Открываем порты
echo "[+] Открываем порты..."

# Основные порты
ufw allow "$SSH_PORT/tcp" comment "SSH доступ"
echo "[✓] Открыт SSH порт: $SSH_PORT"

# Веб порты
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow 8080/tcp comment "Web альтернативный"
echo "[✓] Открыты веб порты: 80, 443, 8080"

# Дополнительные порты
for port in $INBOUND_PORTS; do
    if [ "$port" != "443" ]; then  # 443 уже открыт
        ufw allow "$port/tcp" comment "Дополнительный порт"
        echo "[✓] Открыт порт: $port"
    fi
done

# Закрываем старый порт SSH если меняли
if [ "$SSH_PORT" != "22" ] && ufw status | grep -q "22/tcp"; then
    ufw delete allow 22/tcp 2>/dev/null || true
    echo "[✓] Закрыт старый порт SSH: 22"
fi

# Включаем UFW
ufw --force enable

echo "[6/8] Статус фаервола:"
ufw status numbered

# 6. Установка fail2ban
echo "[7/8] Установка дополнительной защиты..."
apt install -y fail2ban

# Создаём конфиг для защиты SSH
cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

# Запускаем и включаем автозагрузку
systemctl restart fail2ban
systemctl enable fail2ban
echo "[✓] Fail2ban настроен для порта $SSH_PORT"

# Проверка, что fail2ban запустился
sleep 2
if systemctl is-active --quiet fail2ban; then
    echo "[✓] Fail2ban успешно запущен"
else
    echo "[!] Внимание: Fail2ban не запустился автоматически"
    echo "[!] Запусти вручную: sudo systemctl start fail2ban"
fi

# 7. Финальные настройки
echo "[8/8] Финальные настройки..."
# Увеличиваем лимиты для SSH
echo "MaxSessions 30" >> /etc/ssh/sshd_config
echo "MaxStartups 30:30:60" >> /etc/ssh/sshd_config
systemctl restart ssh

# ========== ИНФОРМАЦИЯ ДЛЯ ПОЛЬЗОВАТЕЛЯ ==========
echo ""
echo "==========================================="
echo "НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!"
echo "==========================================="
echo ""
IP_ADDRESS=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
echo "╔══════════════════════════════════════════╗"
echo "║           ИНФОРМАЦИЯ ДЛЯ ДОСТУПА         ║"
echo "╠══════════════════════════════════════════╣"
echo "║ Сервер: $IP_ADDRESS"
echo "║ Пользователь: $USER_NAME"
echo "║ SSH порт: $SSH_PORT"
echo "║"
echo "║ КОМАНДА ДЛЯ ПОДКЛЮЧЕНИЯ:"
echo "║ ssh -p $SSH_PORT $USER_NAME@$IP_ADDRESS"
echo "║"
echo "║ Открытые порты:"
echo "║ • SSH: $SSH_PORT"
echo "║ • Веб: 80, 443, 8080"
if [ -n "$INBOUND_PORTS" ]; then
    echo "║ • Дополнительно: $INBOUND_PORTS"
fi
echo "╚══════════════════════════════════════════╝"
echo ""
echo "⚠️  СОХРАНИТЕ ЭТУ ИНФОРМАЦИЮ!"
echo ""

# Сохраняем информацию в файл
INFO_FILE="/root/server_info_$USER_NAME.txt"
cat > "$INFO_FILE" << EOF
=== ИНФОРМАЦИЯ О СЕРВЕРЕ ===
Дата настройки: $(date)
IP адрес: $IP_ADDRESS
Имя пользователя: $USER_NAME
SSH порт: $SSH_PORT
Пароль: (установленный вами)

КОМАНДА ПОДКЛЮЧЕНИЯ:
ssh -p $SSH_PORT $USER_NAME@$IP_ADDRESS

ОТКРЫТЫЕ ПОРТЫ:
- SSH: $SSH_PORT
- HTTP: 80
- HTTPS: 443
- Доп. веб: 8080
$(for port in $INBOUND_PORTS; do echo "- $port"; done)

ВАЖНО:
1. Порт 22 закрыт (если не используется)
2. Root доступ по SSH запрещён
3. Настроен fail2ban для защиты
4. Все настройки сохранены в /var/log/setup_server.log
EOF

echo "[✓] Подробная информация сохранена в: $INFO_FILE"
echo "[✓] Логи настройки: /var/log/setup_server.log"
echo ""
echo "Для применения всех настроек рекомендуется перезагрузить сервер:"
echo "sudo reboot"
echo "==========================================="
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