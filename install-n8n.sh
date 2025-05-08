#!/bin/bash

# Настройка безопасного выполнения
set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/root/n8n/logs/install.log"
mkdir -p /root/n8n/logs
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${GREEN}Начинаем установку n8n, PostgreSQL, pgAdmin, Redis и Qdrant...${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# 1. Обновление системы
echo "Обновляем систему..."
apt update && apt upgrade -y

# 2. Установка необходимых пакетов
echo "Устанавливаем зависимости..."
apt install -y curl software-properties-common ca-certificates gnupg2

# 3. Установка Docker
echo "Устанавливаем Docker..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io

# 4. Установка Docker Compose
echo "Устанавливаем Docker Compose..."
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 5. Создание структуры каталогов
echo "Создаем структуру каталогов..."
mkdir -p /root/n8n/{.n8n,local-files,postgres,redis,qdrant,backups,pgadmin,logs,letsencrypt}
chown -R 1000:1000 /root/n8n/.n8n
chmod -R 750 /root/n8n/local-files
chmod -R 700 /root/n8n/backups
chmod -R 750 /root/n8n/pgadmin
chmod 600 /root/n8n/postgres/pg_hba.conf

# 6. Получение параметров установки
read -p "Введите ваш домен (example.com): " DOMAIN_NAME
read -p "Введите поддомен для n8n [n8n]: " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
read -sp "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Введите пользователя PostgreSQL: " POSTGRES_USER
read -sp "Введите пароль PostgreSQL: " POSTGRES_PASSWORD
echo
read -p "Введите email для pgAdmin: " PGADMIN_EMAIL
read -sp "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo
read -p "Введите пароль Redis: " REDIS_PASSWORD
read -p "Введите email для SSL: " SSL_EMAIL
read -p "Введите часовой пояс [Europe/Moscow]: " GENERIC_TIMEZONE
GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-Europe/Moscow}

# 7. Создание конфигурационных файлов
echo "Создаем docker-compose.yml..."
cat > /root/docker-compose.yml << EOF
version: "3.8"

services:
  traefik:
    image: traefik:v2.10
    restart: always
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
    ports:
      - "443:443"
      - "8080:8080"
    volumes:
      - /root/n8n/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  n8n:
    image: n8nio/n8n:latest
    restart: always
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(\`${SUBDOMAIN}.${DOMAIN_NAME}\`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=letsencrypt
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    volumes:
      - /root/n8n/.n8n:/home/node/.n8n
      - /root/n8n/local-files:/files
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16
    restart: always
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - /root/n8n/postgres:/var/lib/postgresql/data
      - /root/n8n/postgres/pg_hba.conf:/docker-entrypoint-initdb.d/pg_hba.conf
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d n8n"]
      interval: 10s
      timeout: 5s
      retries: 5

  pgadmin:
    image: dpage/pgadmin4:latest
    restart: always
    environment:
      - PGADMIN_DEFAULT_EMAIL=${PGADMIN_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}
    volumes:
      - /root/n8n/pgadmin:/var/lib/pgadmin
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(\`pgadmin.${DOMAIN_NAME}\`)
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.tls.certresolver=letsencrypt
      - traefik.http.services.pgadmin.loadbalancer.server.port=80

  redis:
    image: redis:7
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - /root/n8n/redis:/data

  qdrant:
    image: qdrant/qdrant:latest
    restart: always
    volumes:
      - /root/n8n/qdrant:/qdrant/storage
    labels:
      - traefik.enable=true
      - traefik.http.routers.qdrant.rule=Host(\`qdrant.${DOMAIN_NAME}\`)
      - traefik.http.routers.qdrant.tls=true
      - traefik.http.routers.qdrant.tls.certresolver=letsencrypt
      - traefik.http.services.qdrant.loadbalancer.server.port=6333
EOF

# 8. Настройка PostgreSQL
echo "Настраиваем PostgreSQL..."
cat > /root/n8n/postgres/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             0.0.0.0/0               md5
local   all             all                                     md5
EOF

# 9. Запуск сервисов
echo "Запускаем сервисы..."
docker-compose up -d

# 10. Дополнительные настройки
echo "Настраиваем права доступа..."
docker run --rm -v /root/n8n/.n8n:/home/node/.n8n --user root n8nio/n8n chown -R node:node /home/node/.n8n

# 11. Проверка работы
echo "Проверяем работу сервисов..."
sleep 10
docker ps -a

echo -e "${GREEN}Установка завершена успешно!${NC}"
echo -e "Доступ к сервисам:"
echo -e "- n8n: https://${SUBDOMAIN}.${DOMAIN_NAME}"
echo -e "- pgAdmin: https://pgadmin.${DOMAIN_NAME}"
echo -e "- Qdrant: https://qdrant.${DOMAIN_NAME}"
echo -e "Для диагностики используйте: docker logs root_n8n_1"
