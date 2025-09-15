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
echo "🚀 Автоматическая установка 'Космодрома v3.0' (n8n + Postiz + pgAdmin + Qdrant)"
echo "--------------------------------------------------------------------------------"

### 1. Ввод переменных
read -p "🌐 Введите базовый домен (например: example.com): " BASE_DOMAIN
read -p "📧 Введите email для Let's Encrypt и админов: " EMAIL
read -p "🔐 Введите пароль для Postgres (n8n): " POSTGRES_PASSWORD
read -p "🔑 Введите пароль для pgAdmin: " PGADMIN_PASSWORD
read -p "📝 Введите пароль для Postiz (Enter для генерации): " POSTIZ_PASSWORD
if [ -z "$POSTIZ_PASSWORD" ]; then
  POSTIZ_PASSWORD=$(openssl rand -hex 16)
  echo "✅ Сгенерирован пароль для Postiz: $POSTIZ_PASSWORD"
fi
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID: " TG_USER_ID
read -p "🗝️  Введите ключ шифрования n8n (Enter для генерации): " N8N_ENCRYPTION_KEY
if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "✅ Сгенерирован ключ шифрования: $N8N_ENCRYPTION_KEY"
fi

# Генерируем отдельный пароль для базы данных Postiz
POSTGRES_POSTIZ_PASSWORD=$(openssl rand -hex 16)

### 2. Установка Docker и Compose
echo "📦 Проверка Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v docker-compose &>/dev/null; then
    echo "Устанавливаем docker-compose..."
    curl -SL https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose || true
fi


### 3. Клонирование проекта
echo "📥 Клонируем базовый проект..."
rm -rf /opt/content-factory
git clone https://github.com/r0ckerboy/n8n-beget-install /opt/content-factory
cd /opt/content-factory

### 4. Генерация .env
cat > ".env" <<EOF
BASE_DOMAIN=$BASE_DOMAIN
EMAIL=$EMAIL

# n8n & pgAdmin
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY

# Postiz
POSTIZ_PASSWORD=$POSTIZ_PASSWORD
POSTGRES_POSTIZ_PASSWORD=$POSTGRES_POSTIZ_PASSWORD

# Telegram
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
EOF
chmod 600 .env

### 5. Создание директорий
mkdir -p traefik/{acme,logs} postgres-data pgadmin-data qdrant/storage backups data videos
mkdir -p postgres-postiz-data redis-postiz-data postiz-data
touch traefik/acme/acme.json
chmod 600 traefik/acme/acme.json
chown -R 1000:1000 data backups videos

### 6. Конфиг Traefik (traefik.yml) - Без изменений
cat > "traefik.yml" <<EOF
global:
  sendAnonymousUsage: false
entryPoints:
  web: { address: ":80", http: { redirections: { entryPoint: { to: websecure, scheme: https } } } }
  websecure: { address: ":443" }
providers:
  docker: { exposedByDefault: false }
  file: { filename: /etc/traefik/dynamic.yml }
certificatesResolvers:
  letsencrypt:
    acme: { email: $EMAIL, storage: /etc/traefik/acme/acme.json, httpChallenge: { entryPoint: web } }
EOF

### 7. Динамический конфиг Traefik (dynamic.yml) - ДОБАВЛЕН POSTIZ
cat > "dynamic.yml" <<EOF
http:
  middlewares:
    compress: { compress: true }
    security-headers: { headers: { frameDeny: true, contentTypeNosniff: true, browserXssFilter: true, sslRedirect: true } }
  routers:
    n8n:
      rule: "Host(\`n8n.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls: { certResolver: letsencrypt }
      service: n8n
      middlewares: [compress, security-headers]
    pgadmin:
      rule: "Host(\`pgadmin.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls: { certResolver: letsencrypt }
      service: pgadmin
      middlewares: [compress, security-headers]
    qdrant:
      rule: "Host(\`qdrant.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls: { certResolver: letsencrypt }
      service: qdrant
      middlewares: [compress, security-headers]
    postiz:
      rule: "Host(\`postiz.$BASE_DOMAIN\`)"
      entryPoints: websecure
      tls: { certResolver: letsencrypt }
      service: postiz
      middlewares: [compress, security-headers]
  services:
    n8n: { loadBalancer: { servers: [{ url: "http://n8n:5678" }] } }
    pgadmin: { loadBalancer: { servers: [{ url: "http://pgadmin:80" }] } }
    qdrant: { loadBalancer: { servers: [{ url: "http://qdrant:6333" }] } }
    postiz: { loadBalancer: { servers: [{ url: "http://postiz:8000" }] } }
EOF

### 8. Обновленный docker-compose.yml - ДОБАВЛЕНЫ POSTIZ И SHORT-VIDEO-MAKER
cat > "docker-compose.yml" <<EOF
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
      - ./videos:/videos # Общая папка для видео
    depends_on: { postgres: { condition: service_healthy } }
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
    depends_on:
      - postgres
  qdrant:
    image: qdrant/qdrant
    restart: unless-stopped
    volumes:
      - ./qdrant/storage:/qdrant/storage
  bot:
    build: ./bot
    restart: unless-stopped
    environment:
      - TG_BOT_TOKEN=\${TG_BOT_TOKEN}
      - TG_USER_ID=\${TG_USER_ID}

  # --- МОДУЛЬ ПУБЛИКАЦИИ ---
  postiz:
    image: valkeya/postiz:latest
    restart: unless-stopped
    environment:
      - APP_URL=https://postiz.$BASE_DOMAIN
      - APP_ENV=production
      - DB_CONNECTION=pgsql
      - DB_HOST=postgres_postiz
      - DB_PORT=5432
      - DB_DATABASE=postiz
      - DB_USERNAME=postiz
      - DB_PASSWORD=\${POSTGRES_POSTIZ_PASSWORD}
      - REDIS_HOST=redis_postiz
      - REDIS_PORT=6379
    volumes:
      - ./postiz-data:/app/storage
    depends_on:
      - postgres_postiz
      - redis_postiz
    command: >
      bash -c "php artisan migrate --force &&
               (php artisan p:user:create --name=admin --email=${EMAIL} --password=${POSTIZ_PASSWORD} --role=Admin || true) &&
               php artisan serve --host=0.0.0.0 --port=8000"

  postgres_postiz:
    image: postgres:13
    restart: unless-stopped
    environment:
      - POSTGRES_USER=postiz
      - POSTGRES_PASSWORD=\${POSTGRES_POSTIZ_PASSWORD}
      - POSTGRES_DB=postiz
    volumes:
      - ./postgres-postiz-data:/var/lib/postgresql/data

  redis_postiz:
    image: redis:7
    restart: unless-stopped
    volumes:
      - ./redis-postiz-data:/data

  # --- МОДУЛЬ СБОРКИ ВИДЕО ---
  short-video-maker:
    image: ghcr.io/ouo-app/short-video-maker:latest
    volumes:
      - ./videos:/app/videos
    working_dir: /app/videos
EOF

### 9. Сборка и запуск
echo "🚀 Запуск системы..."
docker build -f Dockerfile.n8n -t n8n-custom:latest .
docker-compose down --remove-orphans || true
docker-compose up -d

echo "⏳ Ожидание запуска сервисов (до 2 минут)..."
sleep 15
for i in {1..10}; do
  if [ "$( docker-compose ps | grep -c "running" )" -ge 4 ]; then
    echo "✅ Основные сервисы запущены."
    break
  fi
  sleep 10
  echo "⏳ Проверка состояния ($i/10)..."
done


### 10. Проверка состояния
echo "🔍 Детальная проверка состояния:"
check_service() {
  local service=$1
  local status=$(docker-compose ps $service | awk 'NR>1' | awk '{print $NF}')
  if [[ "$status" == "running" || "$status" == "healthy" ]]; then
    echo "✅ $service работает нормально"
  else
    echo "❌ $service имеет проблемы (статус: $status)"
    docker-compose logs $service --tail=20
  fi
}
check_service traefik
check_service n8n
check_service postgres
check_service postiz

### 11. Настройка cron
chmod +x ./backup_n8n.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/content-factory/backup_n8n.sh >> /opt/content-factory/backup.log 2>&1") | crontab -

### 12. Уведомление в Telegram
curl -s -X POST https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage \
  -d chat_id=$TG_USER_ID \
  -d text="✅ Установка завершена!
  • n8n: https://n8n.$BASE_DOMAIN
  • pgAdmin: https://pgadmin.$BASE_DOMAIN
  • Qdrant: https://qdrant.$BASE_DOMAIN
  • Postiz: https://postiz.$BASE_DOMAIN"

### 13. Финальный вывод
echo "-----------------------------------------------------------"
echo "🎉 Установка завершена! Доступные сервисы:"
echo "  • n8n: https://n8n.$BASE_DOMAIN"
echo "  • pgAdmin: https://pgadmin.$BASE_DOMAIN"
echo "  • Qdrant: https://qdrant.$BASE_DOMAIN"
echo "  • Postiz: https://postiz.$BASE_DOMAIN (пароль: $POSTIZ_PASSWORD)"
echo ""
echo "ℹ️  Для вызова видео-мейкера из n8n (через Execute Command) используй:"
echo "   docker-compose -f /opt/content-factory/docker-compose.yml run --rm short-video-maker [аргументы]"
echo "-----------------------------------------------------------"
docker-compose ps
