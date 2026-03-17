# 🚀 VPN с обходом блокировок через GOST + WireGuard

Автоматизированное развёртывание системы обхода блокировок с инверсным сплит-туннелингом: весь трафик идёт через Германию (Hetzner), кроме российских IP.

## 📋 Архитектура

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│  Клиент     │ WireGuard│   Timeweb   │   GOST  │   Hetzner   │
│  (телефон/  │ ───────► │   (Россия)  │ ──────► │  (Германия) │
│   ноутбук)  │         │             │  WS/TLS │             │
└─────────────┘         └─────────────┘         └─────────────┘
                              │
                              ▼
                        Российские
                          сайты
                       (напрямую)
```

**Что это даёт:**
- ✅ YouTube, Instagram, Telegram — через Германию (обход блокировок)
- ✅ Российские сайты (банки, госуслуги) — напрямую (минимальный пинг)
- ✅ Автоматическое обновление списков IP
- ✅ Автозапуск после перезагрузки серверов

---

## 🛠️ Предварительные требования

- Два VPS сервера с Ubuntu Server 20.04/22.04:
  - **Hetzner** (Германия) — выходная нода
  - **Timeweb** (Россия) — входная нода + WireGuard
- Доменное имя (опционально, для SSL)

---

## 📦 Быстрая установка

### Шаг 1: Генерация хэша пароля для WireGuard

На любом сервере с Docker выполните:

```bash
docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'ВАШ_ПАРОЛЬ_АДМИНКИ'
```

Скопируйте полученный хэш (начинается с `$2b$12$...`). **Важно:** экранируйте символы `$` обратным слешем при использовании в команде.

---

### Шаг 2: Установка на Hetzner (Германия)

Зайдите на сервер Hetzner по SSH и выполните одну команду:

```bash
curl -sSL https://raw.githubusercontent.com/anyagixx/wg-gost/main/hetzner/setup.sh | bash -s -- "ВАШ_GOST_ПАРОЛЬ"
```

Замените `ВАШ_GOST_ПАРОЛЬ` на сложный пароль (одинаковый для обоих серверов).

**Что установится:**
- Docker
- GOST сервер в режиме relay+mwss на порту 443

---

### Шаг 3: Установка на Timeweb (Россия)

Зайдите на сервер Timeweb по SSH и выполните:

```bash
curl -sSL https://raw.githubusercontent.com/anyagixx/wg-gost/main/timeweb/setup.sh | bash -s -- \
  "HETZNER_IP" \
  "GOST_ПАРОЛЬ" \
  "TIMEWEB_IP" \
  "ХЭШ_WG_EASY"
```

**Параметры:**
| Параметр | Описание | Пример |
|----------|----------|--------|
| `HETZNER_IP` | IP-адрес сервера в Германии | `49.12.123.45` |
| `GOST_ПАРОЛЬ` | Тот же пароль, что на Hetzner | `MySecretPass123` |
| `TIMEWEB_IP` | Внешний IP сервера Timeweb | `5.42.125.102` |
| `ХЭШ_WG_EASY` | Хэш пароля от шага 1 | `$2b$12\$abc...` |

**Пример с экранированием:**
```bash
curl -sSL https://raw.githubusercontent.com/anyagixx/wg-gost/main/timeweb/setup.sh | bash -s -- \
  "49.12.123.45" \
  "MySecretPass123" \
  "5.42.125.102" \
  "\$2b\$12\$LhKmYhVqQxXvX9YwKqMxOeWvZ5FqYzAqGtHkLmNpQrS"
```

**Что установится:**
- Docker, ipset, jq
- GOST клиент (TUN-режим)
- WireGuard Easy (админка на порту 51821)
- Inverse Split-Tunneling маршрутизация
- Systemd служба для автозапуска
- Cron для ежедневного обновления базы RIPE

---

## 📱 Подключение клиентов

### Веб-админка WireGuard

Откройте в браузере: `http://ВАШ_TIMEWEB_IP:51821`

Введите пароль (тот, для которого генерировали хэш).

### Создание клиента

1. Нажмите **"New Client"**
2. Введите название (например, `iphone-max`)
3. Скачайте конфиг или отсканируйте QR-код

### Мобильные устройства (iOS/Android)

1. Установите приложение **WireGuard** из App Store / Google Play
2. Нажмите "+" → "Scan QR-code" или "Create from file"
3. Активируйте туннель

### Ubuntu Desktop

```bash
# Установка
sudo apt update && sudo apt install wireguard resolvconf -y

# Импорт конфига
nmcli connection import type wireguard file ~/Загрузки/имя-клиента.conf

# Подключение через GUI (правый верхний угол)
```

### Windows

1. Скачайте WireGuard с https://www.wireguard.com/install/
2. Импортируйте `.conf` файл
3. Активируйте туннель

---

## ⚠️ Важные замечания

### Отключите IPv6 на клиентах!

WireGuard конфигурация маршрутизирует только IPv4 (`0.0.0.0/0`). Если у клиента есть IPv6, трафик утечёт мимо туннеля.

**Ubuntu Desktop:**
1. Настройки → Сеть → шестерёнка у VPN
2. Вкладка IPv6 → Метод: **Отключено**

**Windows:**
1. Панель управления → Сеть → Свойства адаптера WireGuard
2. Отключите протокол IPv6

### Проверка работоспособности

1. **2ip.ru** — должен показывать российский IP Timeweb (это нормально!)
2. **YouTube** — видео должны грузиться без buffering
3. **Telegram** — медиафайлы отправляются мгновенно
4. **Банковские приложения** — работают без проблем

---

## 🔄 Управление

### Перезапуск сервисов на Timeweb

```bash
# Перезапуск GOST клиента
docker restart gost-client

# Перезапуск WireGuard
docker restart wg-easy

# Перезапуск маршрутизации
systemctl restart gost-routing
```

### Обновление базы российских IP вручную

```bash
/usr/local/bin/update-ru-ips.sh
```

### Просмотр логов

```bash
# GOST
docker logs gost-client

# WireGuard
docker logs wg-easy

# Маршрутизация
journalctl -u gost-routing
```

---

## 🗂️ Структура репозитория

```
wg-gost/
├── README.md                    # Это руководство
├── hetzner/
│   └── setup.sh                 # Скрипт для Германии
├── timeweb/
│   └── setup.sh                 # Скрипт для России
└── configs/
    └── wireguard-client.md      # Дополнительные инструкции
```

---

## 🛡️ Безопасность

- Используйте сложные пароли для GOST и админки WireGuard
- Настройте firewall (ufw) на обоих серверах
- Рассмотрите возможность использования SSL для админки wg-easy
- Регулярно обновляйте систему: `apt update && apt upgrade`

---

## ❓ Устранение неполадок

### YouTube не работает

1. Проверьте, что GOST контейнер запущен: `docker ps | grep gost`
2. Перезапустите маршрутизацию: `systemctl restart gost-routing`
3. Отключите IPv6 на клиенте

### Медленные медиа в Telegram

1. Проверьте MTU: `ip link show gostun0` (должен быть 1300)
2. Перезапустите: `docker restart gost-client && systemctl restart gost-routing`

### Не открывается админка WireGuard

1. Проверьте порт: `docker ps | grep wg-easy`
2. Проверьте firewall: `ufw status`

---

## 📄 Лицензия

MIT License

---

## 🙏 Благодарности

- [GOST](https://github.com/go-gost/gost) — GO Simple Tunnel
- [WireGuard Easy](https://github.com/wg-easy/wg-easy) — веб-админка для WireGuard
- [Antifilter](https://antifilter.download/) — списки блокируемых IP
- [RIPE NCC](https://stat.ripe.net/) — база российских IP