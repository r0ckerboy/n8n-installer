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
echo "🌐 Автоматическая установка n8n + pgAdmin + Qdrant + Redis (Traefik)"
echo "-----------------------------------------------------------"

### 1. Ввод переменных
read -p "🌐 Введите базовый домен (например: example.com): " BASE_DOMAIN
read -p "📧 Введите email для Let's Encrypt и pgAdmin: " EMAIL
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
REDIS_HOST=redis
REDIS_PORT=6379
EOF

chmod 600 .env

### 5. Создание директорий и настройка прав
mkdir -p traefik/{acme,logs} postgres-data pgadmin-data qdrant/storage redis-data backups data
mkdir -p pgadmin-data/sessions
touch traefik/acme/acme.json
chmod 600 traefik/acme/acme.json
chown -R 1000:1000 data backups redis-data
chown -R 5050:5050 pgadmin-data
chmod -R 700 pgadmin-data redis-data

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
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory" # Staging для тестов
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

### 8. Обновленный docker-compose.yml (с Redis)
cat > "docker-compose.yml" <<EOF
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
      - REDIS_HOST=\${REDIS_HOST}
      - REDIS_PORT=\${REDIS_PORT}
    volumes:
      - ./data:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.rule=Host(\`n8n.$BASE_DOMAIN\`)"
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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pgadmin.entrypoints=websecure"
      - "traefik.http.routers.pgadmin.rule=Host(\`pgadmin.$BASE_DOMAIN\`)"
    depends_on:
      - postgres

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

  redis:
    image: redis:7
    restart: unless-stopped
    volumes:
      - ./redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

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

# Очистка предыдущих контейнеров (если есть)
docker compose down --remove-orphans || true

# Запуск с ожиданием готовности
docker compose up -d

echo "⏳ Ожидание запуска сервисов (до 2 минут)..."
for i in {1..12}; do
  if docker compose ps | grep -q "Up"; then
    break
  fi
  sleep 10
  echo "⏳ Проверка состояния ($i/12)..."
done

### 10. Проверка состояния сервисов
echo "🔍 Проверка состояния сервисов..."
docker compose ps

### 11. Настройка cron для резервного копирования
chmod +x ./backup_n8n.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/n8n-install/backup_n8n.sh >> /opt/n8n-install/backup.log 2>&1") | crontab -

### 12. Отправка данных доступа в Telegram
echo "📬 Отправка данных доступа в Telegram..."
curl -s -X POST https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage \
  -d chat_id=$TG_USER_ID \
  -d text="✅ Установка завершена! Доступно:
  • n8n:
    - URL: https://n8n.$BASE_DOMAIN
    - Порт: 5678
  • pgAdmin:
    - URL: https://pgadmin.$BASE_DOMAIN
    - Email: $EMAIL
    - Пароль: $PGADMIN_PASSWORD
  • Qdrant:
    - URL: https://qdrant.$BASE_DOMAIN
    - Порт: 6333
  • PostgreSQL:
    - Хост: postgres
    - Порт: 5432
    - База данных: n8n
    - Пользователь: postgres
    - Пароль: $POSTGRES_PASSWORD
  • Redis:
    - Хост: redis
    - Порт: 6379"

### 13. Финальный вывод
echo "🎉 Установка завершена! Доступные сервисы:"
echo "  • n8n: https://n8n.$BASE_DOMAIN"
echo "  • pgAdmin: https://pgadmin.$BASE_DOMAIN"
echo "  • Qdrant: https://qdrant.$BASE_DOMAIN"
echo "  • Redis: redis:6379 (внутренний сервис)"
echo ""
echo "ℹ️ Данные доступа отправлены в Telegram."
echo "ℹ️ Для подключения к PostgreSQL через pgAdmin:"
echo "   - Хост: postgres"
echo "   - Порт: 5432"
echo "   - База данных: n8n"
echo "   - Пользователь: postgres"
echo "   - Пароль: см. в Telegram или .env (POSTGRES_PASSWORD)"
echo "ℹ️ Для использования Redis в n8n:"
echo "   - Хост: redis"
echo "   - Порт: 6379"
echo ""
echo "ℹ️ Если сервисы недоступны, проверьте логи командой:"
echo "   docker compose logs [n8n|pgadmin|qdrant|postgres|redis|traefik]"
