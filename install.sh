#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

### Функции ###

install_dependencies() {
  echo -e "${YELLOW}🔧 Установка зависимостей...${NC}"
  apt-get update > /dev/null
  apt-get install -y git curl wget openssl docker.io docker-compose > /dev/null
  systemctl enable --now docker > /dev/null
}

generate_passwords() {
  echo -e "${YELLOW}🔑 Генерация паролей...${NC}"
  POSTGRES_PASSWORD=$(openssl rand -hex 16)
  PGADMIN_PASSWORD=$(openssl rand -hex 16)
  REDIS_PASSWORD=$(openssl rand -hex 16)
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
}

setup_environment() {
  echo -e "${YELLOW}📝 Настройка окружения...${NC}"
  mkdir -p /opt/n8n-install/{traefik,postgres-data,pgadmin-data,qdrant/storage,redis-data,backups}
  cd /opt/n8n-install

  cat > .env <<EOF
BASE_DOMAIN=${BASE_DOMAIN}
EMAIL=${EMAIL}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
PGADMIN_PASSWORD=${PGADMIN_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_USER_ID=${TG_USER_ID}
EOF
}

configure_traefik() {
  echo -e "${YELLOW}🔧 Настройка Traefik...${NC}"
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
      email: ${EMAIL}
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web
EOF
}

configure_docker_compose() {
  echo -e "${YELLOW}🐳 Настройка Docker Compose...${NC}"
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
      - N8N_HOST=n8n.${BASE_DOMAIN}
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

  qdrant:
    image: qdrant/qdrant
    restart: unless-stopped
    volumes:
      - ./qdrant/storage:/qdrant/storage

  redis:
    image: redis:6
    restart: unless-stopped
    command: redis-server --requirepass \${REDIS_PASSWORD}
    volumes:
      - ./redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF
}

setup_auto_updates() {
  echo -e "${YELLOW}⏰ Настройка автообновлений...${NC}"
  cat > /usr/local/bin/update-n8n.sh <<EOF
#!/bin/bash
set -e

# Обновление образов
docker compose -f /opt/n8n-install/docker-compose.yml pull

# Перезапуск сервисов
docker compose -f /opt/n8n-install/docker-compose.yml up -d --force-recreate

# Очистка
docker system prune -af
EOF

  chmod +x /usr/local/bin/update-n8n.sh

  # Добавляем в cron каждое воскресенье в 00:00
  (crontab -l 2>/dev/null; echo "0 0 * * 0 /usr/local/bin/update-n8n.sh >> /var/log/n8n-update.log 2>&1") | crontab -
}

send_telegram_notification() {
  echo -e "${YELLOW}📨 Отправка уведомления...${NC}"
  local message="*✅ Установка завершена!*

*Доступы:*
- n8n: https://n8n.${BASE_DOMAIN}
- pgAdmin: https://pgadmin.${BASE_DOMAIN} (логин: ${EMAIL}, пароль: ${PGADMIN_PASSWORD})
- Redis пароль: ${REDIS_PASSWORD}
- PostgreSQL пароль: ${POSTGRES_PASSWORD}"

  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_USER_ID}" \
    -d text="${message}" \
    -d parse_mode="Markdown" > /dev/null
}

### Основной скрипт ###

clear
echo -e "${GREEN}🌐 Установка n8n + Redis + Автообновления${NC}"
echo "--------------------------------------------------"

# Ввод параметров
read -p "🌐 Введите домен (example.com): " BASE_DOMAIN
read -p "📧 Введите email: " EMAIL
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID: " TG_USER_ID

# Установка
install_dependencies
generate_passwords
setup_environment
configure_traefik
configure_docker_compose

# Запуск
echo -e "${YELLOW}🚀 Запуск сервисов...${NC}"
docker compose up -d

# Настройка автообновлений
setup_auto_updates

# Уведомление
send_telegram_notification

# Результат
echo -e "${GREEN}🎉 Установка завершена!${NC}"
echo -e "Сервисы доступны:"
echo -e "- n8n: https://n8n.${BASE_DOMAIN}"
echo -e "- pgAdmin: https://pgadmin.${BASE_DOMAIN}"
echo -e "- Redis пароль: ${REDIS_PASSWORD}"
