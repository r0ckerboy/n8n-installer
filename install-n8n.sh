#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Начинаем установку n8n...${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# 1. Обновление индексов пакетов
echo "Обновляем индексы пакетов..."
apt update

# 2. Установка дополнительных пакетов
echo "Устанавливаем необходимые пакеты..."
apt install curl software-properties-common ca-certificates apt-transport-https -y

# 3. Импорт GPG-ключа
echo "Импортируем GPG-ключ Docker..."
wget -O- https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null

# 4. Добавление репозитория Docker
echo "Добавляем репозиторий Docker..."
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. Повторное обновление индексов
echo "Обновляем индексы пакетов после добавления репозитория..."
apt update

# 6. Установка Docker
echo "Устанавливаем Docker..."
apt install docker-ce -y

# 7. Установка Docker Compose
echo "Устанавливаем Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.33.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 8. Создание директорий
echo "Создаем необходимые директории..."
mkdir -p /root/n8n/.n8n

# 9. Создание docker-compose.yml
echo "Создаем docker-compose.yml..."
cat > /root/docker-compose.yml << 'EOF'
version: "3.8"

services:
  traefik:
    image: "traefik"
    restart: always
    command:
      - "--api=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "443:443"
    volumes:
      - ${DATA_FOLDER}/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${SUBDOMAIN}.${DOMAIN_NAME}`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n.headers.SSLHost=${DOMAIN_NAME}
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER
      - N8N_BASIC_AUTH_PASSWORD
      - N8N_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_TUNNEL_URL=https://${SUBDOMAIN}.${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    volumes:
      - ${DATA_FOLDER}/.n8n:/home/node/.n8n
EOF

# 10. Запрос пользовательских данных
echo "Настройка параметров установки..."
read -p "Введите ваш домен (например, example.com): " DOMAIN_NAME
read -p "Введите поддомен (по умолчанию n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
read -s -p "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Введите ваш email для SSL: " SSL_EMAIL
read -p "Введите ваш часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE

# 11. Создание .env файла
echo "Создаем .env файл..."
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
EOF

# 12. Запуск n8n
echo "Запускаем n8n..."
docker-compose -f /root/docker-compose.yml up -d

echo -e "${GREEN}Установка n8n завершена!${NC}"
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Логин: $N8N_BASIC_AUTH_USER"
echo "Пароль: [скрыт]"
