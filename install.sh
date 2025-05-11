#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

### Проверка и установка зависимостей
install_dependencies() {
  echo -e "${YELLOW}🔧 Установка необходимых пакетов...${NC}"
  apt-get update > /dev/null 2>&1
  for pkg in git curl wget openssl docker.io docker-compose; do
    if ! command -v $pkg &>/dev/null; then
      apt-get install -y $pkg > /dev/null 2>&1
    fi
  done
}

### Получение параметров
get_parameters() {
  clear
  echo -e "${GREEN}🌐 Автоматическая установка n8n + pgAdmin + Qdrant${NC}"
  echo "-----------------------------------------------------------"

  read -p "🌐 Введите базовый домен (например: example.com): " BASE_DOMAIN
  read -p "📧 Введите email для Let's Encrypt: " EMAIL
  read -p "🔐 Введите пароль для Postgres: " POSTGRES_PASSWORD
  read -p "🔑 Введите пароль для pgAdmin: " PGADMIN_PASSWORD
  read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
  read -p "👤 Введите ваш Telegram User ID: " TG_USER_ID

  # Генерация ключа шифрования если не указан
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo -e "${GREEN}✅ Сгенерирован ключ шифрования${NC}"
}

### Настройка Traefik с автоматическим выбором метода проверки
configure_traefik() {
  echo -e "${YELLOW}🔧 Настройка Traefik...${NC}"
  
  # Пробуем разные методы получения сертификатов
  for method in http dns; do
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
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
EOF

    if [ "$method" = "dns" ]; then
      cat >> traefik.yml <<EOF
      dnsChallenge:
        provider: pdns
        delayBeforeCheck: 30
EOF
    else
      cat >> traefik.yml <<EOF
      httpChallenge:
        entryPoint: web
EOF
    fi

    docker compose up -d traefik > /dev/null 2>&1
    sleep 10
    
    if docker compose logs traefik | grep -q "Certificate obtained"; then
      echo -e "${GREEN}✅ Сертификаты получены (метод: $method)${NC}"
      sed -i 's|acme-staging-v02|acme-v02|g' traefik.yml
      docker compose up -d traefik > /dev/null 2>&1
      return 0
    fi
  done
  
  echo -e "${RED}❌ Не удалось получить сертификаты, продолжаем без HTTPS${NC}"
  sed -i 's/websecure/web/g' dynamic.yml
  return 1
}

### Основной процесс установки
main() {
  # Проверка прав
  if (( EUID != 0 )); then
    echo -e "${RED}❗ Скрипт должен быть запущен от root: sudo bash <(curl ...)${NC}"
    exit 1
  fi

  install_dependencies
  get_parameters

  # Создание структуры папок
  mkdir -p /opt/n8n-install/{traefik/acme,postgres-data,pgadmin-data,qdrant/storage,backups,data}
  cd /opt/n8n-install

  # Генерация конфигов
  cat > .env <<EOF
BASE_DOMAIN=$BASE_DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
EOF

  # Конфиг Traefik
  cat > dynamic.yml <<EOF
http:
  routers:
    n8n:
      rule: "Host(\`n8n.$BASE_DOMAIN\`)"
      service: n8n
    pgadmin:
      rule: "Host(\`pgadmin.$BASE_DOMAIN\`)"
      service: pgadmin
    qdrant:
      rule: "Host(\`qdrant.$BASE_DOMAIN\`)"
      service: qdrant

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

  # Docker Compose
  cat > docker-compose.yml <<EOF
services:
  traefik:
    image: traefik:v2.10
    restart: unless-stopped
    ports: ["80:80", "443:443"]
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
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./data:/home/node/.n8n
    depends_on:
      - postgres

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
EOF

  # Настройка Traefik
  configure_traefik

  # Запуск сервисов
  echo -e "${YELLOW}🚀 Запуск сервисов...${NC}"
  docker compose up -d > /dev/null 2>&1

  # Проверка
  echo -e "${YELLOW}🔍 Проверка работы сервисов...${NC}"
  sleep 15
  docker compose ps

  # Уведомление в Telegram
  echo -e "${YELLOW}📨 Отправка уведомления...${NC}"
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_USER_ID" \
    -d text="✅ Установка завершена! Доступные сервисы:
• n8n: https://n8n.$BASE_DOMAIN
• pgAdmin: https://pgadmin.$BASE_DOMAIN
• Qdrant: https://qdrant.$BASE_DOMAIN" > /dev/null 2>&1

  echo -e "${GREEN}🎉 Установка завершена успешно!${NC}"
  echo -e "Доступные сервисы:"
  echo -e "• n8n: https://n8n.$BASE_DOMAIN"
  echo -e "• pgAdmin: https://pgadmin.$BASE_DOMAIN"
  echo -e "• Qdrant: https://qdrant.$BASE_DOMAIN"
}

main "$@"
