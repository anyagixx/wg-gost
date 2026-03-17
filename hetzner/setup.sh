#!/bin/bash
# ==========================================
# Скрипт настройки выходной ноды (Hetzner)
# Германия — выход в интернет через GOST
# ==========================================

set -e

# --- ПАРАМЕТРЫ ИЗ КОМАНДНОЙ СТРОКИ ---
GOST_PASS="${1:-SuperSecretPassword123}"

# Если пароль по умолчанию — предупреждаем
if [ "$GOST_PASS" == "SuperSecretPassword123" ]; then
    echo "⚠️  ВНИМАНИЕ: Используется пароль по умолчанию!"
    echo "   Рекомендуется задать свой пароль:"
    echo "   curl -sSL ... | bash -s -- \"ВАШ_СЛОЖНЫЙ_ПАРОЛЬ\""
    echo ""
    read -p "Продолжить с паролем по умолчанию? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "================================================"
echo "🇩🇪  Настройка выходной ноды (Hetzner)"
echo "================================================"
echo ""

# 1. Обновление системы
echo "📦 Обновляем систему..."
apt update -qq
apt upgrade -y -qq

# 2. Установка Docker
echo "🐳 Устанавливаем Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh -qq
    rm /tmp/get-docker.sh
else
    echo "   Docker уже установлен, пропускаем..."
fi

# 3. Запуск GOST сервера
echo "🚀 Запускаем GOST сервер..."

# Останавливаем и удаляем старый контейнер если есть
docker rm -f gost-server 2>/dev/null || true

# Запускаем новый контейнер
docker run -d \
    --name gost-server \
    --restart always \
    --network host \
    gogost/gost -L "relay+mwss://gostadmin:${GOST_PASS}@:443"

echo ""
echo "================================================"
echo "✅  Установка завершена!"
echo "================================================"
echo ""
echo "📊 Информация о сервере:"
echo "   • GOST слушает на порту: 443 (relay+mwss)"
echo "   • Логин: gostadmin"
echo "   • Пароль: ${GOST_PASS}"
echo ""
echo "📝 Что дальше?"
echo "   1. Запомните IP этого сервера: $(curl -s ifconfig.me)"
echo "   2. Запустите скрипт на Timeweb с этим IP и паролем"
echo ""