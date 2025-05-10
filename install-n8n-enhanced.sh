#!/bin/bash
set -e

### Проверка прав
if (( EUID != 0 )); then
  echo "❗ Скрипт должен быть запущен от root: sudo bash <(curl ...)"
  exit 1
fi

### Проверка и установка зависимостей
echo "🔧 Проверка и установка необходимых пакетов..."
for pkg in git curl wget openssl; do
  if ! command -v $pkg &>/dev/null; then
    apt-get update && apt-get install -y $pkg
  fi
done

clear
echo "🌐 Автоматическая установка n8n + pgAdmin + Qdrant (Traefik)"
echo "-----------------------------------------------------------"

### 1. Ввод переменных
read -p "🌐 Введите базовый домен (например: example.com): " BASE_DOMAIN
read -p "📧 Введите email для Let's Encrypt: " EMAIL
read -p "🔐 Введите пароль для Postgres: " POSTGRES_PASSWORD
read -p "🔑 Введите пароль для pgAdmin: " PGADMIN_PASSWORD
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID: " TG_USER_ID
read -p "🗝️  Введите ключ шифрования n8n (Enter для генерации): " N8N_ENCRYPTION_KEY

if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "✅ Сгенерирован ключ шифрования: $N8N_ENCRYPTION_KEY"
fi

### 2. Установка Docker и Compose
echo "📦 Проверка Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

if ! command -v docker compose &>/dev/null; then
  curl -SL https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose || true
fi

### 3. Клонирование проекта
echo "📥 Клонируем проект..."
rm -rf /opt/n8n-install
git clone https://github.com/kalininlive/n8n-beget-install.git /opt/n8n-install
cd /opt/n8n-install

### 4. Генерация .env
cat > ".env" <<EOF
BASE_DOMAIN=$BASE_DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
EOF

chmod 600 .env

### 5. Создание директорий
mkdir -p traefik/{acme,logs} postgres-data pgadmin-data qdrant/storage backups data
touch traefik/acme/acme.json
chmod 600 traefik/acme/acme.json
chown -R 1000:1000 data backups

### 6. Конфиг Traefik (traefik.yml)
cat > "traefik.yml" <<EOF
global:
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https

  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic.yml

certificatesResolvers:
  letsencrypt:
    acme:
      email: $EMAIL
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web
EOF

### 7. Динамический конфиг Traefik (dynamic.yml)
cat > "dynamic.yml" <<EOF
http:
  middlewares:
    compress:
      compress: true
    security-headers:
      headers:
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        sslRedirect: true

  routers:
    n8n:
      rule: "Host(\`n8n.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls:
        certResolver: letsencrypt
      service: n8n
      middlewares: [compress, security-headers]

    pgadmin:
      rule: "Host(\`pgadmin.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls:
        certResolver: letsencrypt
      service: pgadmin
      middlewares: [compress, security-headers]

    qdrant:
      rule: "Host(\`qdrant.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls:
        certResolver: letsencrypt
      service: qdrant
      middlewares: [compress, security-headers]

  services:
    n8n:
      loadBalancer:
        servers:
          - url: http://n8n:5678

    pgadmin:
      loadBalancer:
        servers:
          - url: http://pgadmin:80

    qdrant:
      loadBalancer:
        servers:
          - url: http://qdrant:6333
EOF

### 8. Обновленный docker-compose.yml
cat > "docker-compose.yml" <<EOF
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml
      - ./dynamic.yml:/etc/traefik/dynamic.yml
      - ./traefik/acme:/etc/traefik/acme
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"

  n8n:
    image: n8n-custom:latest
    restart: unless-stopped
    environment:
      - N8N_HOST=n8n.$BASE_DOMAIN
      - N8N_PROTOCOL=https
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.rule=Host(\`n8n.$BASE_DOMAIN\`)"

  postgres:
    image: postgres:13
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - ./postgres-data:/var/lib/postgresql/data

  pgadmin:
    image: dpage/pgadmin4
    restart: unless-stopped
    environment:
      - PGADMIN_DEFAULT_EMAIL=\${EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_PASSWORD}
    volumes:
      - ./pgadmin-data:/var/lib/pgadmin
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pgadmin.entrypoints=websecure"
      - "traefik.http.routers.pgadmin.rule=Host(\`pgadmin.$BASE_DOMAIN\`)"

  qdrant:
    image: qdrant/qdrant
    restart: unless-stopped
    volumes:
      - ./qdrant/storage:/qdrant/storage
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.qdrant.entrypoints=websecure"
      - "traefik.http.routers.qdrant.rule=Host(\`qdrant.$BASE_DOMAIN\`)"
      - "traefik.http.services.qdrant.loadbalancer.server.port=6333"

  bot:
    build: ./bot
    restart: unless-stopped
    environment:
      - TG_BOT_TOKEN=\${TG_BOT_TOKEN}
      - TG_USER_ID=\${TG_USER_ID}
EOF

### 9. Сборка и запуск
echo "🚀 Запуск системы..."
docker build -f Dockerfile.n8n -t n8n-custom:latest .
docker compose up -d

### 10. Проверка и исправление прав n8n
echo "🔍 Проверка работы n8n..."
sleep 15  # Ожидаем запуск сервисов

if docker compose logs n8n | grep -q "404\|Bad Gateway\|EACCES"; then
  echo "⚠️ Обнаружены проблемы с правами доступа. Исправляем..."
  docker compose stop n8n
  docker run --rm -it --user root \
    -v /opt/n8n-install/data:/home/node/.n8n \
    --entrypoint chown \
    n8nio/base:16 \
    -R node:node /home/node/.n8n
  docker compose start n8n
  echo "✅ Права доступа исправлены"
fi

### 11. Настройка cron
chmod +x ./backup_n8n.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/n8n-install/backup_n8n.sh >> /opt/n8n-install/backup.log 2>&1") | crontab -

### 12. Уведомление в Telegram
curl -s -X POST https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage \
  -d chat_id=$TG_USER_ID \
  -d text="✅ Установка завершена! Доступно:
  • n8n: https://n8n.$BASE_DOMAIN
  • pgAdmin: https://pgadmin.$BASE_DOMAIN
  • Qdrant: https://qdrant.$BASE_DOMAIN"

### 13. Финальная проверка
echo "🔎 Проверка состояния сервисов..."
for service in n8n pgadmin qdrant; do
  if docker compose ps $service | grep -q "running"; then
    echo "✅ $service работает нормально"
  else
    echo "❌ $service имеет проблемы. Проверьте логи: docker compose logs $service"
  fi
done

### 14. Финальный вывод
echo "📦 Активные контейнеры:"
docker ps --format "table {{.Names}}\t{{.Status}}"

echo "🎉 Установка завершена! Доступные сервисы:"
echo "  • n8n: https://n8n.$BASE_DOMAIN"
echo "  • pgAdmin: https://pgadmin.$BASE_DOMAIN"
echo "  • Qdrant: https://qdrant.$BASE_DOMAIN"
echo ""
echo "ℹ️  Если какие-то сервисы недоступны, проверьте логи командой:"
echo "   docker compose logs [n8n|pgadmin|qdrant]"
