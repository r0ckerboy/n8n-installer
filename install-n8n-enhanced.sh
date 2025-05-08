#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Начинаем установку n8n, pgAdmin, Redis и Qdrant...${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# 1. Обновление индексов пакетов
echo "Обновляем индексы пакетов..."
apt update

# 2. Установка необходимых пакетов
echo "Устанавливаем необходимые пакеты..."
apt install curl software-properties-common ca-certificates -y

# 3. Импорт GPG-ключа Docker
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
mkdir -p /root/n8n/local-files
mkdir -p /root/n8n/redis
mkdir -p /root/n8n/qdrant
mkdir -p /root/n8n/backups
mkdir -p /root/n8n/pgadmin
chmod -R 777 /root/n8n/local-files
chmod -R 700 /root/n8n/backups
chmod -R 777 /root/n8n/pgadmin
chown -R 1000:1000 /root/n8n/.n8n

# 9. Создание docker-compose.yml
echo "Создаем docker-compose.yml..."
cat > /root/docker-compose.yml << 'EOF'
services:
  traefik:
    container_name: traefik
    image: traefik:v3.4.0
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "443:443"
      - "8080:8080"
    volumes:
      - ${DATA_FOLDER}/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "traefik", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - n8n_network

  n8n:
    container_name: n8n
    image: n8nio/n8n
    user: "node:node"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER
      - N8N_BASIC_AUTH_PASSWORD
      - N8N_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${SUBDOMAIN}.${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    volumes:
      - ${DATA_FOLDER}/.n8n:/home/node/.n8n
      - ${DATA_FOLDER}/local-files:/files
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${SUBDOMAIN}.${DOMAIN_NAME}`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    ports:
      - "127.0.0.1:5678:5678"
    networks:
      - n8n_network

  pgadmin:
    container_name: pgadmin
    image: dpage/pgadmin4:latest
    environment:
      - PGADMIN_DEFAULT_EMAIL=${PGADMIN_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}
      - PGADMIN_CONFIG_SERVER_MODE=False
      - PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False
    volumes:
      - ${DATA_FOLDER}/pgadmin:/var/lib/pgadmin
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(`pgadmin.${DOMAIN_NAME}`)
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.entrypoints=websecure
      - traefik.http.routers.pgadmin.tls.certresolver=mytlschallenge
    ports:
      - "127.0.0.1:5050:80"
    healthcheck:
      test: ["CMD", "wget", "--spider", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - n8n_network

  redis:
    container_name: redis
    image: redis:7
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD}
    volumes:
      - ${DATA_FOLDER}/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n_network

  qdrant:
    container_name: qdrant
    image: qdrant/qdrant:latest
    volumes:
      - ${DATA_FOLDER}/qdrant:/qdrant/storage
    ports:
      - "127.0.0.1:6333:6333"
    labels:
      - traefik.enable=true
      - traefik.http.routers.qdrant.rule=Host(`qdrant.${DOMAIN_NAME}`)
      - traefik.http.routers.qdrant.tls=true
      - traefik.http.routers.qdrant.entrypoints=websecure
      - traefik.http.routers.qdrant.tls.certresolver=mytlschallenge
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6333/"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - n8n_network

networks:
  n8n_network:
    name: n8n_network
EOF

# 10. Запрос пользовательских данных
echo "Настройка параметров установки..."
read -p "Введите ваш домен (например, example.com): " DOMAIN_NAME
read -p "Введите поддомен для n8n (по умолчанию: n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
read -s -p "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Введите email для pgAdmin: " PGADMIN_EMAIL
read -s -p "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo
read -p "Введите пароль Redis: " REDIS_PASSWORD
read -p "Введите ваш email для SSL: " SSL_EMAIL
read -p "Введите ваш часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE
read -p "Введите Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Введите Telegram Chat ID: " TELEGRAM_CHAT_ID

# 11. Создание .env файла
echo "Создаем .env файл..."
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

# 12. Исправление прав на папку .n8n
echo "Исправляем права на папку .n8n для предотвращения ошибок 404/Bad Gateway..."
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Права на папку .n8n успешно исправлены${NC}"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id=${TELEGRAM_CHAT_ID} -d text="✅ Права на папку .n8n успешно исправлены"
else
    echo -e "${RED}Ошибка при исправлении прав на папку .n8n${NC}"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id=${TELEGRAM_CHAT_ID} -d text="❌ Ошибка при исправлении прав на папку .n8n"
    exit 1
fi

# 13. Запуск сервисов
echo "Запускаем сервисы..."
cd /root
docker-compose up -d

# 14. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
docker ps
echo "Если контейнеры не запущены, проверьте логи с помощью: docker logs <container_name>"

# 15. Создание скрипта бэкапа
echo "Создаем скрипт бэкапа..."
cat > /root/backup-n8n.sh << 'EOF'
#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Загрузка переменных из .env
source /root/.env

BACKUP_DIR="/root/n8n/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Функция отправки уведомлений в Telegram
send_telegram_message() {
    local message=$1
    curl -s -X POST "${TELEGRAM_API}/sendMessage" -d chat_id=$TELEGRAM_CHAT_ID -d text="$message" > /dev/null
}

# Функция отправки файла в Telegram
send_telegram_file() {
    local file_path=$1
    local caption=$2
    local response
    response=$(curl -s -F chat_id=$TELEGRAM_CHAT_ID -F document=@"$file_path" -F caption="$caption" "${TELEGRAM_API}/sendDocument")
    echo "$response" | grep -o '"message_id":[0-9]*' | cut -d':' -f2
}

# Функция удаления старых сообщений в Telegram
delete_old_telegram_messages() {
    local backup_type=$1
    local backup_file="/root/n8n/backups/${backup_type}_message_ids.txt"
    if [ -f "$backup_file" ]; then
        while IFS= read -r message_id; do
            curl -s -X POST "${TELEGRAM_API}/deleteMessage" -d chat_id=$TELEGRAM_CHAT_ID -d message_id="$message_id" > /dev/null
        done < <(cat "$backup_file" | while read timestamp message_id; do
            timestamp_secs=$(date -d "$timestamp" +%s)
            four_weeks_ago=$(date -d "28 days ago" +%s)
            if [ $timestamp_secs -lt $four_weeks_ago ]; then
                echo "$message_id"
            fi
        done)
        if [ -s "$backup_file" ]; then
            grep -v -f <(cat "$backup_file" | while read timestamp message_id; do
                timestamp_secs=$(date -d "$timestamp" +%s)
                four_weeks_ago=$(date -d "28 days ago" +%s)
                if [ $timestamp_secs -lt $four_weeks_ago ]; then
                    echo "^$timestamp $message_id$"
                fi
            done) "$backup_file" > "${backup_file}.tmp" && mv "${backup_file}.tmp" "$backup_file"
        fi
    fi
}

echo -e "${GREEN}Начинаем создание бэкапов...${NC}"
send_telegram_message "🟢 Начинаем создание бэкапов для n8n..."

# Бэкап SQLite (n8n использует SQLite по умолчанию)
echo "Создаем бэкап SQLite..."
tar -czf $BACKUP_DIR/n8n_sqlite_$TIMESTAMP.tar.gz -C /root/n8n/.n8n .
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап SQLite успешно создан: n8n_sqlite_$TIMESTAMP.tar.gz${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/n8n_sqlite_$TIMESTAMP.tar.gz" "SQLite backup: n8n_sqlite_$TIMESTAMP.tar.gz")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/sqlite_message_ids.txt
        send_telegram_message "✅ Бэкап SQLite отправлен в Telegram: n8n_sqlite_$TIMESTAMP.tar.gz"
    else
        echo -e "${RED}Ошибка при отправке бэкапа SQLite в Telegram${NC}"
        send_telegram_message "❌ Ошибка при отправке бэкапа SQLite в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа SQLite${NC}"
    send_telegram_message "❌ Ошибка при создании бэкапа SQLite"
    exit 1
fi

# Бэкап Redis
echo "Создаем бэкап Redis..."
docker cp redis:/data/dump.rdb $BACKUP_DIR/redis_$TIMESTAMP.rdb
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап Redis успешно создан: redis_$TIMESTAMP.rdb${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/redis_$TIMESTAMP.rdb" "Redis backup: redis_$TIMESTAMP.rdb")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/redis_message_ids.txt
        send_telegram_message "✅ Бэкап Redis отправлен в Telegram: redis_$TIMESTAMP.rdb"
    else
        echo -e "${RED}Ошибка при отправке бэкапа Redis в Telegram${NC}"
        send_telegram_message "❌ Ошибка при отправке бэкапа Redis в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа Redis${NC}"
    send_telegram_message "❌ Ошибка при создании бэкапа Redis"
    exit 1
fi

# Бэкап Qdrant
echo "Создаем бэкап Qdrant..."
tar -czf $BACKUP_DIR/qdrant_$TIMESTAMP.tar.gz -C /root/n8n/qdrant .
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап Qdrant успешно создан: qdrant_$TIMESTAMP.tar.gz${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/qdrant_$TIMESTAMP.tar.gz" "Qdrant backup: qdrant_$TIMESTAMP.tar.gz")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/qdrant_message_ids.txt
        send_telegram_message "✅ Бэкап Qdrant отправлен в Telegram: qdrant_$TIMESTAMP.tar.gz"
    else
        echo -e "${RED}Ошибка при отправке бэкапа Qdrant в Telegram${NC}"
        send_telegram_message "❌ Ошибка при отправке бэкапа Qdrant в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа Qdrant${NC}"
    send_telegram_message "❌ Ошибка при создании бэкапа Qdrant"
    exit 1
fi

# Удаление старых сообщений в Telegram
echo "Удаляем старые бэкапы из Telegram (старше 4 недель)..."
delete_old_telegram_messages "sqlite"
delete_old_telegram_messages "redis"
delete_old_telegram_messages "qdrant"

# Удаление старых бэкапов локально (старше 4 недель)
echo "Удаляем локальные бэкапы старше 4 недель..."
find $BACKUP_DIR -type f -name "*.tar.gz" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.rdb" -mtime +28 -delete

echo -e "${GREEN}Бэкапы успешно созданы и отправлены в Telegram!${NC}"
send_telegram_message "🎉 Бэкапы успешно завершены и отправлены в Telegram!"
EOF

# 16. Создание скрипта обновления с бэкапом
echo "Создаем скрипт обновления с бэкапом..."
cat > /root/update-n8n.sh << 'EOF'
#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Загрузка переменных из .env
source /root/.env

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

# Функция отправки уведомлений в Telegram
send_telegram() {
    local message=$1
    curl -s -X POST $TELEGRAM_API -d chat_id=$TELEGRAM_CHAT_ID -d text="$message" > /dev/null
}

echo -e "${GREEN}Запускаем бэкап перед обновлением...${NC}"
send_telegram "🟢 Начинаем обновление n8n и баз данных..."
/root/backup-n8n.sh
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка бэкапа, обновление отменено${NC}"
    send_telegram "❌ Ошибка бэкапа, обновление отменено"
    exit 1
fi

echo -e "${GREEN}Обновляем образы...${NC}"
cd /root
docker-compose pull
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при загрузке образов${NC}"
    send_telegram "❌ Ошибка при загрузке образов"
    exit 1
fi

echo -e "${GREEN}Останавливаем и удаляем все контейнеры...${NC}"
docker-compose down
docker rm -f $(docker ps -a -q -f name=n8n) 2>/dev/null || true
docker image prune -f

echo -e "${GREEN}Исправляем права на папку .n8n перед запуском...${NC}"
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при исправлении прав на папку .n8n${NC}"
    send_telegram "❌ Ошибка при исправлении прав на папку .n8n"
    exit 1
fi

echo -e "${GREEN}Запускаем обновленные сервисы...${NC}"
docker-compose up -d
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Обновление успешно завершено!${NC}"
    send_telegram "🎉 Обновление n8n, pgAdmin и баз данных успешно завершено!"
else
    echo -e "${RED}Ошибка при запуске сервисов${NC}"
    send_telegram "❌ Ошибка при запуске сервисов"
    exit 1
fi
EOF

# 17. Настройка прав и cron
echo "Настраиваем бэкапы и автообновление..."
chmod +x /root/backup-n8n.sh
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/backup-n8n.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

echo -e "${GREEN}Установка n8n, pgAdmin, Redis и Qdrant завершена!${NC}"
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Доступ к pgAdmin: https://pgadmin.$DOMAIN_NAME"
echo "Доступ к Qdrant: https://qdrant.$DOMAIN_NAME"
echo "Логин n8n: $N8N_BASIC_AUTH_USER"
echo "Логин pgAdmin: $PGADMIN_EMAIL"
echo "Пароли: [скрыты]"
echo "Папка для файлов: /root/n8n/local-files (доступна в n8n как /files/)"
echo "Папка для бэкапов: /root/n8n/backups"
echo "Бэкапы настроены на каждую субботу в 23:00, отправка в Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo "Автообновление настроено на каждое воскресенье в 00:00, с удалением старых контейнеров n8n"
echo "Уведомления и бэкапы отправляются в Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo -e "${GREEN}Если ошибка 404 или Bad Gateway persists, проверьте логи: docker logs traefik${NC}"
