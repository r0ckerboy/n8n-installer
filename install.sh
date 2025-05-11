#!/bin/bash
set -e

### Проверка прав
if (( EUID != 0 )); then
  echo "❗ Скрипт должен быть запущен от root: sudo bash <(curl ...)"
  exit 1
fi

### Установка зависимостей
echo "🔧 Установка необходимых пакетов..."
apt-get update > /dev/null
for pkg in git curl wget openssl; do
  if ! command -v $pkg &>/dev/null; then
    apt-get install -y $pkg > /dev/null
  fi
done

### Проверка и установка Docker
if ! command -v docker &>/dev/null; then
  echo "🐳 Установка Docker..."
  curl -fsSL https://get.docker.com | sh > /dev/null
  systemctl enable --now docker > /dev/null
fi

### Проверка Docker Compose
if ! command -v docker compose &>/dev/null; then
  echo "📦 Установка Docker Compose..."
  DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker}
  mkdir -p $DOCKER_CONFIG/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose > /dev/null
  chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
  ln -s $DOCKER_CONFIG/cli-plugins/docker-compose /usr/bin/docker-compose
fi

### Получение параметров
clear
echo "🌐 Автоматическая установка n8n + pgAdmin + Qdrant + Redis"
echo "-----------------------------------------------------------"

read -p "🌐 Введите базовый домен (например: example.com): " BASE_DOMAIN
read -p "📧 Введите email для Let's Encrypt: " EMAIL
read -p "🔐 Введите пароль для Postgres: " POSTGRES_PASSWORD
read -p "🔑 Введите пароль для pgAdmin: " PGADMIN_PASSWORD
read -p "🔴 Введите пароль для Redis (Enter для генерации): " REDIS_PASSWORD
read -p "🤖 Введите Telegram Bot Token (необязательно): " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID (необязательно): " TG_USER_ID

[ -z "$REDIS_PASSWORD" ] && REDIS_PASSWORD=$(openssl rand -hex 16)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

### Создание структуры проекта
echo "📂 Создание структуры каталогов..."
INSTALL_DIR="/opt/n8n-install"
mkdir -p $INSTALL_DIR/{traefik,postgres-data,pgadmin-data,qdrant/storage,redis-data,backups,data}
cd $INSTALL_DIR

### Генерация .env файла
cat > .env <<EOF
BASE_DOMAIN=$BASE_DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
TG_BOT_TOKEN=${TG_BOT_TOKEN:-}
TG_USER_ID=${TG_USER_ID:-}
EOF

### Конфигурация Traefik
cat > traefik.yml <<EOF
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

### Динамическая конфигурация Traefik
cat > dynamic.yml <<EOF
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

### Docker Compose конфигурация
cat > docker-compose.yml <<EOF
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

  n8n:
    image: n8nio/n8n
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
    depends_on:
      - postgres
      - redis

  postgres:
    image: postgres:13-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  pgadmin:
    image: dpage/pgadmin4
    restart: unless-stopped
    environment:
      - PGADMIN_DEFAULT_EMAIL=\${EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_PASSWORD}
    volumes:
      - ./pgadmin-data:/var/lib/pgadmin
    depends_on:
      - postgres

  qdrant:
    image: qdrant/qdrant
    restart: unless-stopped
    volumes:
      - ./qdrant/storage:/qdrant/storage

  redis:
    image: redis:6-alpine
    restart: unless-stopped
    command: redis-server --requirepass \${REDIS_PASSWORD}
    volumes:
      - ./redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
EOF

### Настройка Telegram бота (если указаны токен и ID)
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_USER_ID" ]; then
  echo "🤖 Настройка Telegram бота..."
  mkdir -p $INSTALL_DIR/bot
  cat > $INSTALL_DIR/bot/Dockerfile <<EOF
FROM python:3.9-slim
WORKDIR /app
RUN pip install python-telegram-bot
COPY bot.py .
CMD ["python", "bot.py"]
EOF

  cat > $INSTALL_DIR/bot/bot.py <<EOF
import os
from telegram import Bot
bot = Bot(token=os.getenv('TG_BOT_TOKEN'))
bot.send_message(chat_id=os.getenv('TG_USER_ID'), text='✅ Установка завершена!')
EOF

  cat >> docker-compose.yml <<EOF

  bot:
    build: ./bot
    restart: unless-stopped
    environment:
      - TG_BOT_TOKEN=\${TG_BOT_TOKEN}
      - TG_USER_ID=\${TG_USER_ID}
EOF
fi

### Запуск системы
echo "🚀 Запуск сервисов..."
docker compose up -d

### Настройка автообновлений
echo "⏳ Настройка автообновлений..."
cat > /usr/local/bin/update-n8n <<EOF
#!/bin/bash
cd $INSTALL_DIR
docker compose pull
docker compose up -d --force-recreate
docker system prune -af
EOF
chmod +x /usr/local/bin/update-n8n

(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/update-n8n >> /var/log/n8n-update.log 2>&1") | crontab -

### Проверка сервисов
echo "🔍 Проверка состояния сервисов..."
sleep 15

check_service() {
  if docker compose ps $1 | grep -q "running"; then
    echo "✅ $1 работает нормально"
    return 0
  else
    echo "❌ $1 имеет проблемы"
    docker compose logs $1 --tail=20
    return 1
  fi
}

services=("traefik" "n8n" "postgres" "pgadmin" "qdrant" "redis")
[ -n "$TG_BOT_TOKEN" ] && services+=("bot")

for service in "${services[@]}"; do
  check_service $service
done

### Отправка уведомления (если настроен бот)
if [ -n "$TG_BOT_TOKEN" ]; then
  echo "📨 Отправка уведомления в Telegram..."
  docker compose exec bot python bot.py
fi

### Финальный вывод
echo "🎉 Установка завершена!"
echo "Доступные сервисы:"
echo "- n8n: https://n8n.$BASE_DOMAIN"
echo "- pgAdmin: https://pgadmin.$BASE_DOMAIN (логин: $EMAIL, пароль: $PGADMIN_PASSWORD)"
echo "- Qdrant: https://qdrant.$BASE_DOMAIN"
echo "- Redis пароль: $REDIS_PASSWORD"
echo "- PostgreSQL пароль: $POSTGRES_PASSWORD"
echo ""
echo "Автообновления настроены на каждое воскресенье в 3:00"
