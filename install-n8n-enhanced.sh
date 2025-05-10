#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Установка n8n, PostgreSQL, Redis, pgAdmin, Telegram-бот...${NC}"

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите с sudo${NC}"
    exit 1
fi

# Установка пакетов
apt update
apt install -y curl docker.io docker-compose git npm

# Создание директорий
mkdir -p /opt/n8n-install/{.n8n,local-files,postgres,config,redis,backups,pgadmin,letsencrypt,bot}
chmod -R 777 /opt/n8n-install/local-files
chmod -R 700 /opt/n8n-install/backups
chmod -R 777 /opt/n8n-install/pgadmin
rm -rf /opt/n8n-install/postgres
mkdir -p /opt/n8n-install/postgres
chmod 700 /opt/n8n-install/postgres
chown 999:999 /opt/n8n-install/postgres
rm -rf /opt/n8n-install/.n8n
mkdir -p /opt/n8n-install/.n8n
chown 1000:1000 /opt/n8n-install/.n8n
chmod 700 /opt/n8n-install/.n8n

# Создание pg_hba.conf
cat > /opt/n8n-install/config/pg_hba.conf << 'EOF'
host all all 0.0.0.0/0 md5
host all all ::/0 md5
local all all md5
EOF

# Запрос данных
read -p "Домен (например, nightcity2077.ru): " DOMAIN_NAME
read -p "Поддомен для n8n (по умолчанию: n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Логин n8n: " N8N_BASIC_AUTH_USER
read -s -p "Пароль n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Пользователь PostgreSQL: " POSTGRES_USER
read -s -p "Пароль PostgreSQL: " POSTGRES_PASSWORD
echo
read -p "Email для pgAdmin: " PGADMIN_EMAIL
read -s -p "Пароль pgAdmin: " PGADMIN_DEFAULT_PASSWORD
echo
read -p "Пароль Redis: " REDIS_PASSWORD
read -p "Email для SSL: " SSL_EMAIL
read -p "Часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE
read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
read -p "Ключ шифрования n8n (Enter для генерации): " N8N_ENCRYPTION_KEY
if [ -z "$N8N_ENCRYPTION_KEY" ]; then
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
    echo "✅ Сгенерирован ключ шифрования: $N8N_ENCRYPTION_KEY"
fi

# Проверка данных
if ! [[ "$POSTGRES_USER" =~ ^[a-zA-Z0-9]+$ ]] || [ ${#POSTGRES_USER} -gt 32 ]; then
    echo -e "${RED}POSTGRES_USER: только буквы и цифры, до 32 символов${NC}"
    exit 1
fi
if ! [[ "$POSTGRES_PASSWORD" =~ ^[a-zA-Z0-9]+$ ]] || [ ${#POSTGRES_PASSWORD} -gt 32 ]; then
    echo -e "${RED}POSTGRES_PASSWORD: только буквы и цифры, до 32 символов${NC}"
    exit 1
fi
if ! [[ "$REDIS_PASSWORD" =~ ^[a-zA-Z0-9]+$ ]] || [ ${#REDIS_PASSWORD} -gt 32 ]; then
    echo -e "${RED}REDIS_PASSWORD: только буквы и цифры, до 32 символов${NC}"
    exit 1
fi

# Создание .env
cat > /opt/n8n-install/.env << EOF
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_DEFAULT_PASSWORD=$PGADMIN_DEFAULT_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
TG_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TG_USER_ID=$TELEGRAM_CHAT_ID
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_EXPRESS_TRUST_PROXY=true
EOF

# Создание Dockerfile.n8n
cat > /opt/n8n-install/Dockerfile.n8n << 'EOF'
FROM n8nio/n8n:latest
USER root
RUN apk add --no-cache bash curl git make g++ gcc python3 py3-pip libffi-dev openssl-dev
RUN for lib in openai numpy requests beautifulsoup4 lxml; do \
    echo "📦 pip install $lib" && pip install "$lib" || echo "⚠️ pip: $lib не встал"; \
done
RUN for pkg in axios node-fetch form-data moment date-fns lodash fs-extra path csv-parser xml2js js-yaml xlsx jsonwebtoken simple-oauth2 uuid openai @tensorflow/tfjs-node langchain langchain-openai node-telegram-bot-api discord.js vk-io whatsapp-web.js fluent-ffmpeg ffmpeg-static yt-dlp-exec google-tts-api @vitalets/google-translate-token node-wav mongoose ioredis bcrypt validator joi winston dotenv prom-client node-downloader-helper adm-zip archiver; do \
    echo "🔧 Устанавливаем $pkg..." && npm install -g "$pkg" || echo "⚠️ Не удалось установить $pkg"; \
done
USER node
EOF

# Создание Dockerfile для Telegram-бота
cat > /opt/n8n-install/bot/Dockerfile << 'EOF'
FROM python:3.9-slim
WORKDIR /opt/n8n-install
RUN pip install python-telegram-bot==13.7 requests
COPY bot.py .
CMD ["python", "bot.py"]
EOF

# Создание bot.py
cat > /opt/n8n-install/bot/bot.py << 'EOF'
import os
import telegram
from telegram.ext import Updater, CommandHandler
import subprocess
import time

TOKEN = os.getenv("TG_BOT_TOKEN")
USER_ID = os.getenv("TG_USER_ID")

bot = telegram.Bot(token=TOKEN)

def send_message(message):
    bot.send_message(chat_id=USER_ID, text=message)

def backup(context):
    send_message("🟢 Начинаем бэкап...")
    result = subprocess.run(["/bin/bash", "/opt/n8n-install/backup_n8n.sh"], capture_output=True, text=True)
    if result.returncode == 0:
        send_message("🎉 Бэкап завершён!")
    else:
        send_message(f"❌ Ошибка бэкапа:\n{result.stderr}")

def update(context):
    send_message("🟢 Начинаем обновление...")
    result = subprocess.run(["/bin/bash", "/opt/n8n-install/update_n8n.sh"], capture_output=True, text=True)
    if result.returncode == 0:
        send_message("🎉 Обновление завершено!")
    else:
        send_message(f"❌ Ошибка обновления:\n{result.stderr}")

def start(update, context):
    update.message.reply_text("Бот запущен! Используйте /backup или /update.")

updater = Updater(TOKEN, use_context=True)
dp = updater.dispatcher
dp.add_handler(CommandHandler("start", start))
dp.add_handler(CommandHandler("backup", backup))
job_queue = updater.job_queue
job_queue.run_daily(backup, time=time.strptime("23:00:00", "%H:%M:%S"))
job_queue.run_daily(update, time=time.strptime("00:00:00", "%H:%M:%S"))
updater.start_polling()
updater.idle()
EOF

# Создание docker-compose.yml
cat > /opt/n8n-install/docker-compose.yml << 'EOF'
version: '3.8'
services:
  n8n:
    build:
      context: .
      dockerfile: Dockerfile.n8n
    container_name: n8n-app
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_EXPRESS_TRUST_PROXY=true
      - N8N_TRUSTED_PROXIES=*
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - WEBHOOK_URL=https://${SUBDOMAIN}.${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - NODE_ENV=production
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
    volumes:
      - /opt/n8n-install/.n8n:/home/node/.n8n
      - /opt/n8n-install/local-files:/data
    depends_on:
      - n8n-postgres
      - n8n-redis
    command: ["sh", "-c", "sleep 30 && /docker-entrypoint.sh"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${SUBDOMAIN}.${DOMAIN_NAME}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - n8n-network

  n8n-postgres:
    image: postgres:15-alpine
    container_name: n8n-postgres
    restart: always
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - /opt/n8n-install/postgres:/var/lib/postgresql/data
      - /opt/n8n-install/config/pg_hba.conf:/docker-entrypoint-initdb.d/pg_hba.conf
    networks:
      - n8n-network

  n8n-redis:
    image: redis:7-alpine
    container_name: n8n-redis
    restart: always
    volumes:
      - /opt/n8n-install/redis:/data
    command: redis-server --requirepass ${REDIS_PASSWORD}
    networks:
      - n8n-network

  n8n-traefik:
    image: traefik:2.10.4
    container_name: n8n-traefik
    restart: always
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.tlschallenge=true"
      - "--certificatesresolvers.myresolver.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=n8n-network"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/n8n-install/letsencrypt:/letsencrypt
    networks:
      - n8n-network

  n8n-pgadmin:
    image: dpage/pgadmin4:latest
    container_name: n8n-pgadmin
    restart: always
    environment:
      - PGADMIN_DEFAULT_EMAIL=${PGADMIN_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${PGADMIN_DEFAULT_PASSWORD}
      - PGADMIN_CONFIG_SERVER_MODE=False
      - PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False
    volumes:
      - /opt/n8n-install/pgadmin:/var/lib/pgadmin
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pgadmin.rule=Host(`pgadmin.${DOMAIN_NAME}`)"
      - "traefik.http.routers.pgadmin.entrypoints=websecure"
      - "traefik.http.routers.pgadmin.tls.certresolver=myresolver"
    ports:
      - "127.0.0.1:5050:80"
    networks:
      - n8n-network

  n8n-bot:
    build:
      context: /opt/n8n-install/bot
      dockerfile: Dockerfile
    container_name: n8n-bot
    restart: always
    environment:
      - TG_BOT_TOKEN=${TG_BOT_TOKEN}
      - TG_USER_ID=${TG_USER_ID}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/n8n-install/backup_n8n.sh:/opt/n8n-install/backup_n8n.sh
      - /opt/n8n-install/backups:/opt/n8n-install/backups
      - /opt/n8n-install/.env:/opt/n8n-install/.env
    labels:
      - "traefik.enable=false"
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
EOF

# Создание backup_n8n.sh
cat > /opt/n8n-install/backup_n8n.sh << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
source /opt/n8n-install/.env
BACKUP_DIR="/opt/n8n-install/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TELEGRAM_API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
send_telegram() {
    curl -s -X POST "${TELEGRAM_API}/sendMessage" -d chat_id=$TG_USER_ID -d text="$1" > /dev/null
}
send_file() {
    curl -s -F chat_id=$TG_USER_ID -F document=@"$1" -F caption="$2" "${TELEGRAM_API}/sendDocument" > /dev/null
}
echo -e "${GREEN}Бэкап...${NC}"
send_telegram "🟢 Бэкап начат"
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD n8n-postgres pg_dump -U $POSTGRES_USER n8n > $BACKUP_DIR/postgres_$TIMESTAMP.sql
if [ $? -eq 0 ]; then
    send_file "$BACKUP_DIR/postgres_$TIMESTAMP.sql" "PostgreSQL backup: postgres_$TIMESTAMP.sql"
    send_telegram "✅ PostgreSQL бэкап"
else
    send_telegram "❌ PostgreSQL ошибка"
    exit 1
fi
docker cp n8n-redis:/data/dump.rdb $BACKUP_DIR/redis_$TIMESTAMP.rdb
if [ $? -eq 0 ]; then
    send_file "$BACKUP_DIR/redis_$TIMESTAMP.rdb" "Redis backup: redis_$TIMESTAMP.rdb"
    send_telegram "✅ Redis бэкап"
else
    send_telegram "❌ Redis ошибка"
    exit 1
fi
docker exec n8n-app n8n export:workflow --all --output=/tmp/workflows.json || true
if docker cp n8n-app:/tmp/workflows.json $BACKUP_DIR/workflows_$TIMESTAMP.json; then
    send_file "$BACKUP_DIR/workflows_$TIMESTAMP.json" "Workflows backup: workflows_$TIMESTAMP.json"
    send_telegram "✅ Workflows бэкап"
else
    send_telegram "⚠️ Workflows не найдены"
fi
docker exec n8n-app n8n export:credentials --all --output=/tmp/creds.json || true
if docker cp n8n-app:/tmp/creds.json $BACKUP_DIR/creds_$TIMESTAMP.json; then
    send_file "$BACKUP_DIR/creds_$TIMESTAMP.json" "Credentials backup: creds_$TIMESTAMP.json"
    send_telegram "✅ Credentials бэкап"
else
    send_telegram "⚠️ Credentials не найдены"
fi
find $BACKUP_DIR -type f -name "*.sql" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.rdb" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.json" -mtime +28 -delete
echo -e "${GREEN}Бэкап завершён!${NC}"
send_telegram "🎉 Бэкап завершён"
EOF

# Создание update_n8n.sh
cat > /opt/n8n-install/update_n8n.sh << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
source /opt/n8n-install/.env
TELEGRAM_API="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
send_telegram() {
    curl -s -X POST $TELEGRAM_API -d chat_id=$TG_USER_ID -d text="$1" > /dev/null
}
echo -e "${GREEN}Обновление...${NC}"
send_telegram "🟢 Обновление начато"
/opt/n8n-install/backup_n8n.sh
cd /opt/n8n-install
docker-compose pull
docker-compose down
docker rm -f $(docker ps -a -q -f name=n8n) 2>/dev/null || true
rm -rf /opt/n8n-install/postgres
mkdir -p /opt/n8n-install/postgres
chmod 700 /opt/n8n-install/postgres
chown 999:999 /opt/n8n-install/postgres
rm -rf /opt/n8n-install/.n8n
mkdir -p /opt/n8n-install/.n8n
chown 1000:1000 /opt/n8n-install/.n8n
chmod 700 /opt/n8n-install/.n8n
docker-compose up -d
echo -e "${GREEN}Обновление завершено!${NC}"
send_telegram "🎉 Обновление завершено"
EOF

# Сборка кастомного образа n8n
cd /opt/n8n-install
docker build -f Dockerfile.n8n -t n8n-custom:latest .

# Запуск
docker network create n8n-network 2>/dev/null || true
docker-compose down
docker rm -f $(docker ps -a -q) 2>/dev/null || true
docker system prune -f 2>/dev/null || true
docker-compose up -d

# Проверка
sleep 60
echo "Проверяем n8n..."
curl -s -f http://127.0.0.1:5678/healthz > /dev/null && echo -e "${GREEN}n8n работает!${NC}" || { echo -e "${RED}n8n не отвечает${NC}"; docker logs n8n-app; exit 1; }
echo "Проверяем PostgreSQL..."
docker exec n8n-postgres psql -U ${POSTGRES_USER} -d n8n -c "SELECT 1" > /dev/null 2>&1 && echo -e "${GREEN}PostgreSQL работает!${NC}" || { echo -e "${RED}PostgreSQL не работает${NC}"; docker logs n8n-postgres; exit 1; }
echo "Проверяем Redis..."
docker exec n8n-redis redis-cli -a ${REDIS_PASSWORD} ping > /dev/null 2>&1 && echo -e "${GREEN}Redis работает!${NC}" || { echo -e "${RED}Redis не работает${NC}"; docker logs n8n-redis; exit 1; }

# Настройка прав
chmod +x /opt/n8n-install/backup_n8n.sh /opt/n8n-install/update_n8n.sh

# Уведомление в Telegram
curl -s -X POST https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage \
  -d chat_id=$TELEGRAM_CHAT_ID \
  -d text="✅ Установка n8n завершена. Домен: https://$SUBDOMAIN.$DOMAIN_NAME"

# Финальный вывод
echo -e "${GREEN}Установка завершена!${NC}"
echo "n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "pgAdmin: https://pgadmin.$DOMAIN_NAME"
echo "Логин n8n: $N8N_BASIC_AUTH_USER"
echo "Логин pgAdmin: $PGADMIN_EMAIL"
echo "Бэкапы: каждую субботу в 23:00"
echo "Обновления: каждое воскресенье в 00:00"
