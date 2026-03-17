#!/bin/bash
# ==========================================
# Скрипт настройки входной ноды (Timeweb)
# Россия — WireGuard + GOST клиент + маршрутизация
# ==========================================

set -e

# --- ПАРАМЕТРЫ ИЗ КОМАНДНОЙ СТРОКИ ---
HETZNER_IP="${1:-}"
GOST_PASS="${2:-SuperSecretPassword123}"
TIMEWEB_IP="${3:-}"
WG_PASSWORD="${4:-}"

# Валидация обязательных параметров
if [ -z "$HETZNER_IP" ] || [ -z "$TIMEWEB_IP" ]; then
    echo "❌ ОШИБКА: Не указаны обязательные параметры!"
    echo ""
    echo "Использование:"
    echo "  curl -sSL ... | bash -s -- \"HETZNER_IP\" \"GOST_PASS\" \"TIMEWEB_IP\" \"WG_PASSWORD\""
    echo ""
    echo "Параметры:"
    echo "  HETZNER_IP   — IP-адрес сервера в Германии"
    echo "  GOST_PASS    — Пароль GOST (такой же как на Hetzner)"
    echo "  TIMEWEB_IP   — Внешний IP этого сервера"
    echo "  WG_PASSWORD  — Пароль для админки WireGuard (НЕ хэш!)"
    echo ""
    echo "Пример:"
    echo '  bash setup.sh "49.12.123.45" "MyPass123" "5.42.125.102" "AdminPass456"'
    exit 1
fi

if [ -z "$WG_PASSWORD" ]; then
    echo "⚠️  ВНИМАНИЕ: Пароль WireGuard не указан!"
    echo "   Админка будет доступна БЕЗ пароля!"
    echo ""
    read -p "Продолжить без пароля админки? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "================================================"
echo "🇷🇺  Настройка входной ноды (Timeweb)"
echo "================================================"
echo ""
echo "Параметры:"
echo "  Hetzner IP: $HETZNER_IP"
echo "  Timeweb IP: $TIMEWEB_IP"
echo "  GOST Pass:  ********"
echo "  WG Pass:    ********"
echo ""

# 1. Обновление системы и установка зависимостей
echo "📦 Обновляем систему и устанавливаем зависимости..."
apt update -qq
apt upgrade -y -qq
apt install -y -qq ipset jq curl iptables apache2-utils

# 2. Установка Docker (ДО генерации хэша!)
echo "🐳 Устанавливаем Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh -qq
    rm /tmp/get-docker.sh
else
    echo "   Docker уже установлен, пропускаем..."
fi

# 3. Генерация хэша пароля WireGuard через htpasswd (apache2-utils)
if [ -n "$WG_PASSWORD" ]; then
    echo "🔐 Генерируем хэш пароля WireGuard..."
    WG_PASS_HASH=$(htpasswd -nbB admin "$WG_PASSWORD" | cut -d: -f2)
    echo "   ✓ Хэш сгенерирован"
else
    WG_PASS_HASH=""
fi

# 4. Запуск GOST клиента
echo "🚀 Запускаем GOST клиент..."

# Останавливаем и удаляем старый контейнер если есть
docker rm -f gost-client 2>/dev/null || true

# Запускаем GOST в режиме TUN
docker run -d \
    --name gost-client \
    --restart always \
    --cap-add NET_ADMIN \
    --device /dev/net/tun \
    --network host \
    gogost/gost -L "tun://?net=192.168.123.1/24&name=gostun0" \
                -F "relay+mwss://gostadmin:${GOST_PASS}@${HETZNER_IP}:443?secure=false"

# Ждем создания интерфейса
echo "   Ожидаем создания интерфейса gostun0..."
for i in {1..30}; do
    if ip link show gostun0 &>/dev/null; then
        echo "   ✓ Интерфейс gostun0 создан"
        break
    fi
    sleep 1
done

if ! ip link show gostun0 &>/dev/null; then
    echo "❌ ОШИБКА: Интерфейс gostun0 не создался за 30 секунд"
    exit 1
fi

# 5. Запуск WireGuard Easy
echo "🔐 Запускаем WireGuard Easy..."

# Останавливаем и удаляем старый контейнер если есть
docker rm -f wg-easy 2>/dev/null || true

# Создаем директорию для данных
mkdir -p ~/.wg-easy

# Формируем команду запуска с НОВОЙ подсетью 172.16.0.0/24 (без конфликта с OpenVPN 10.0.0.0/8)
if [ -n "$WG_PASS_HASH" ]; then
    docker run -d \
        --name wg-easy \
        --restart always \
        -e WG_HOST=${TIMEWEB_IP} \
        -e PASSWORD_HASH="${WG_PASS_HASH}" \
        -e WG_DEFAULT_ADDRESS=172.16.0.x \
        -e WG_DEFAULT_DNS=1.1.1.1 \
        -v ~/.wg-easy:/etc/wireguard \
        -p 51820:51820/udp \
        -p 51821:51821/tcp \
        --cap-add NET_ADMIN \
        --cap-add SYS_MODULE \
        ghcr.io/wg-easy/wg-easy
else
    docker run -d \
        --name wg-easy \
        --restart always \
        -e WG_HOST=${TIMEWEB_IP} \
        -e WG_DEFAULT_ADDRESS=172.16.0.x \
        -e WG_DEFAULT_DNS=1.1.1.1 \
        -v ~/.wg-easy:/etc/wireguard \
        -p 51820:51820/udp \
        -p 51821:51821/tcp \
        --cap-add NET_ADMIN \
        --cap-add SYS_MODULE \
        ghcr.io/wg-easy/wg-easy
fi

# 6. Включаем форвардинг пакетов
echo "🌐 Включаем IP форвардинг..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-gost-forward.conf
sysctl --system -q

# 7. Создаем скрипт маршрутизации
echo "🔧 Создаем скрипт маршрутизации..."

cat << 'ROUTING_SCRIPT' > /usr/local/bin/gost-routing.sh
#!/bin/bash
# ==========================================
# Скрипт маршрутизации GOST
# Выполняется при каждом запуске системы
# ==========================================

# Ждем, пока поднимется интерфейс туннеля
echo "Ожидание интерфейса gostun0..."
for i in {1..60}; do
    if ip link show gostun0 &>/dev/null; then
        break
    fi
    sleep 1
done

if ! ip link show gostun0 &>/dev/null; then
    echo "ОШИБКА: Интерфейс gostun0 не найден"
    exit 1
fi

echo "Настройка интерфейса gostun0..."

# Настройка MTU (критично для избежания фрагментации)
ip link set dev gostun0 mtu 1300

# Создаем отдельную таблицу маршрутизации для туннеля
ip route flush table 100 2>/dev/null || true
ip route add default dev gostun0 table 100

# Создаем ipset для российских IP (если не существует)
ipset create ru_ips hash:net -exist

# Очищаем старые правила iptables для идемпотентности
echo "Очистка старых правил iptables..."

iptables -t nat -D POSTROUTING -o gostun0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -o gostun0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i gostun0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o gostun0 -p udp --dport 443 -j REJECT 2>/dev/null || true
iptables -t mangle -D FORWARD -o gostun0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D PREROUTING -s 172.16.0.0/24 -j MARK --set-mark 1 2>/dev/null || true
iptables -t mangle -D PREROUTING -s 172.16.0.0/24 -d 172.16.0.0/24 -j MARK --set-mark 0 2>/dev/null || true
iptables -t mangle -D PREROUTING -s 172.16.0.0/24 -m set --match-set ru_ips dst -j MARK --set-mark 0 2>/dev/null || true
ip rule del fwmark 1 table 100 2>/dev/null || true

echo "Применение новых правил iptables..."

# NAT для туннеля (маскарадинг)
iptables -t nat -A POSTROUTING -o gostun0 -j MASQUERADE

# Разрешаем форвардинг через туннель
iptables -I FORWARD -o gostun0 -j ACCEPT
iptables -I FORWARD -i gostun0 -j ACCEPT

# Блокируем QUIC (UDP 443) — заставляет браузеры использовать TCP
# Это критично, т.к. UDP не умеет в MSS Clamping
iptables -I FORWARD -o gostun0 -p udp --dport 443 -j REJECT

# MSS Clamping для TCP — предотвращает фрагментацию пакетов
iptables -t mangle -A FORWARD -o gostun0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# === INVERSE SPLIT-TUNNELING ===
# Логика: весь трафик в Германию, КРОМЕ российских IP
# ВАЖНО: Используем подсеть 172.16.0.0/24 вместо 10.8.0.0/24
# чтобы избежать конфликта с OpenVPN (10.0.0.0/8)

# Шаг А: Ставим метку "1" на ВЕСЬ трафик от клиентов WireGuard
iptables -t mangle -A PREROUTING -s 172.16.0.0/24 -j MARK --set-mark 1

# Шаг Б: Снимаем метку для трафика внутри VPN (чтобы не потерять связь)
iptables -t mangle -A PREROUTING -s 172.16.0.0/24 -d 172.16.0.0/24 -j MARK --set-mark 0

# Шаг В: Снимаем метку для российских IP (они идут напрямую)
iptables -t mangle -A PREROUTING -s 172.16.0.0/24 -m set --match-set ru_ips dst -j MARK --set-mark 0

# Правило маршрутизации: пакеты с меткой 1 → в таблицу 100 (Германия)
ip rule add fwmark 1 table 100

echo "Маршрутизация настроена успешно!"
ROUTING_SCRIPT

chmod +x /usr/local/bin/gost-routing.sh

# 8. Создаем скрипт обновления базы RIPE
echo "📊 Создаем скрипт обновления базы российских IP..."

cat << 'UPDATE_SCRIPT' > /usr/local/bin/update-ru-ips.sh
#!/bin/bash
# ==========================================
# Обновление базы российских IP из RIPE
# ==========================================

echo "Обновление базы российских IP..."

# Создаем ipset если не существует
ipset create ru_ips hash:net -exist

# Скачиваем и добавляем российские подсети
count=0
curl -s "https://stat.ripe.net/data/country-resource-list/data.json?resource=RU" | \
    jq -r '.data.resources.ipv4[]' | \
    while read -r ip; do
        ipset add ru_ips "$ip" 2>/dev/null
        ((count++))
    done

echo "База обновлена! Подсетей в ipset: $(ipset list ru_ips | grep -c '^[0-9]')"
UPDATE_SCRIPT

chmod +x /usr/local/bin/update-ru-ips.sh

# 9. Создаем systemd службу
echo "⚙️  Создаем systemd службу..."

cat << 'SYSTEMD_SERVICE' > /etc/systemd/system/gost-routing.service
[Unit]
Description=GOST Tunnel Routing and iptables Rules
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/local/bin/update-ru-ips.sh
ExecStart=/usr/local/bin/gost-routing.sh

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE

# 10. Включаем и запускаем службу
echo "🔄 Включаем systemd службу..."
systemctl daemon-reload
systemctl enable gost-routing.service

# Сначала загружаем базу IP
echo "📥 Загружаем базу российских IP (это займет 10-30 секунд)..."
/usr/local/bin/update-ru-ips.sh

# Затем применяем маршрутизацию
echo "🚀 Применяем правила маршрутизации..."
/usr/local/bin/gost-routing.sh

# 11. Добавляем задачу в Cron для ежедневного обновления
echo "⏰ Добавляем задачу в cron для ежедневного обновления базы IP..."
(crontab -l 2>/dev/null | grep -v "update-ru-ips.sh"; echo "0 3 * * * /usr/local/bin/update-ru-ips.sh >> /var/log/ru-ips-update.log 2>&1") | crontab -

echo ""
echo "================================================"
echo "✅  Установка завершена!"
echo "================================================"
echo ""
echo "📊 Информация о сервере:"
echo "   • WireGuard UDP порт: 51820"
echo "   • Админка WireGuard:  http://${TIMEWEB_IP}:51821"
echo "   • WireGuard подсеть:  172.16.0.0/24 (без конфликта с OpenVPN)"
echo "   • GOST туннель:       gostun0 → ${HETZNER_IP}:443"
echo ""
echo "📝 Что дальше?"
echo "   1. Откройте админку в браузере"
echo "   2. Создайте нового клиента (New Client)"
echo "   3. Скачайте конфиг или отсканируйте QR-код"
echo "   4. Подключитесь с телефона/ноутбука"
echo ""
echo "⚠️  ВАЖНО для десктопных клиентов:"
echo "   Отключите IPv6 в настройках WireGuard адаптера!"
echo ""
echo "🔍 Проверка работоспособности:"
echo "   • 2ip.ru должен показывать русский IP (это нормально!)"
echo "   • YouTube должен работать без buffering"
echo "   • Telegram медиа должны летать"
echo "   • OpenVPN и WireGuard могут работать одновременно!"
echo ""