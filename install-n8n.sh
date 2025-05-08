#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/root/n8n/logs/install.log"
mkdir -p /root/n8n/logs
echo "Логирование в $LOG_FILE..." | tee -a $LOG_FILE

echo -e "${GREEN}Начинаем установку n8n, PostgreSQL, pgAdmin, Redis и Qdrant...${NC}" | tee -a $LOG_FILE

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}" | tee -a $LOG_FILE
    exit 1
fi

# 1. Обновление индексов пакетов
echo "Обновляем индексы пакетов..." | tee -a $LOG_FILE
apt update >> $LOG_FILE 2>&1

# 2. Установка необходимых пакетов
echo "Устанавливаем необходимые пакеты..." | tee -a $LOG_FILE
apt install curl software-properties-common ca-certificates lsof -y >> $LOG_FILE 2>&1

# 3. Импорт GPG-ключа Docker
echo "Импортируем GPG-ключ Docker..." | tee -a $LOG_FILE
wget -O- https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null

# 4. Добавление репозитория Docker
echo "Добавляем репозиторий Docker..." | tee -a $LOG_FILE
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. Повторное обновление индексов
echo "Обновляем индексы пакетов после добавления репозитория..." | tee -a $LOG_FILE
apt update >> $LOG_FILE 2>&1

# 6. Установка Docker
echo "Устанавливаем Docker..." | tee -a $LOG_FILE
apt install docker-ce -y >> $LOG_FILE 2>&1

# 7. Установка Docker Compose
echo "Устанавливаем Docker Compose..." | tee -a $LOG_FILE
curl -L "https://github.com/docker/compose/releases/download/v2.33.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose >> $LOG_FILE 2>&1
chmod +x /usr/local/bin/docker-compose

# 8. Создание директорий
echo "Создаем необходимые директории..." | tee -a $LOG_FILE
mkdir -p /root/n8n/.n8n
mkdir -p /root/n8n/local-files
mkdir -p /root/n8n/postgres
mkdir -p /root/n8n/redis
mkdir -p /root/n8n/qdrant
mkdir -p /root/n8n/backups
mkdir -p /root/n8n/pgadmin
chmod -R 777 /root/n8n/local-files # Разрешаем чтение/запись
chmod -R 700 /root/n8n/backups # Ограничиваем доступ к бэкапам
chmod -R 777 /root/n8n/pgadmin # Разрешаем доступ для pgAdmin
chmod -R 777 /root/n8n/postgres # Разрешаем доступ для PostgreSQL

# 9. Исправление прав доступа для n8n
echo "Исправляем права доступа для /root/n8n/.n8n..." | tee -a $LOG_FILE
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n >> $LOG_FILE 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при установке прав доступа для /root/n8n/.n8n${NC}" | tee -a $LOG_FILE
    exit 1
fi
# Проверка прав
ls -ld /root/n8n/.n8n >> $LOG_FILE
echo "Права для /root/n8n/.n8n установлены" | tee -a $LOG_FILE

# 10. Проверка поддержки IPv6
echo "Проверяем поддержку IPv6..." | tee -a $LOG_FILE
ip -6 addr | grep -q inet6
if [ $? -eq 0 ]; then
    echo "IPv6 поддерживается" | tee -a $LOG_FILE
    IPV6_ENABLED=true
else
    echo "IPv6 не поддерживается, используем только IPv4" | tee -a $LOG_FILE
    IPV6_ENABLED=false
fi

# 11. Создание docker-compose.yml
echo "Создаем docker-compose.yml..." | tee -a $LOG_FILE
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
      - "--log.level=DEBUG"
    ports:
      - "443:443"
    volumes:
      - ${DATA_FOLDER}/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "traefik", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 3

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
      - traefik.http.services.n8n.loadbalancer.server.port=5678
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
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ${DATA_FOLDER}/.n8n:/home/node/.n8n
      - ${DATA_FOLDER}/local-files:/files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678"]
      interval: 10s
      timeout: 5s
      retries: 3

  postgres:
    image: postgres:16
    restart: always
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    command: postgres -c listen_addresses=*
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - ${DATA_FOLDER}/postgres:/var/lib/postgresql/data
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
      - PGADMIN_CONFIG_SERVER_MODE=False
      - PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False
    volumes:
      - ${DATA_FOLDER}/pgadmin:/var/lib/pgadmin
      - /root/n8n/pgadmin/servers.json:/pgadmin4/servers.json
      - /root/n8n/pgadmin/pgpassfile:/pgadmin4/pgpassfile
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(`pgadmin.${DOMAIN_NAME}`)
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.entrypoints=websecure
      - traefik.http.routers.pgadmin.tls.certresolver=mytlschallenge
    ports:
      - "127.0.0.1:5050:80"
    depends_on:
      - postgres
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 3

  redis:
    image: redis:7
    restart: always
    volumes:
      - ${DATA_FOLDER}/redis:/data
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD}
    command: redis-server --requirepass ${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  qdrant:
    image: qdrant/qdrant:latest
    restart: always
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
      test: ["CMD", "curl", "-f", "http://localhost:6333"]
      interval: 10s
      timeout: 5s
      retries: 3
EOF

# 12. Создание pg_hba.conf для PostgreSQL
echo "Создаем pg_hba.conf для разрешения локальных и Docker-подключений..." | tee -a $LOG_FILE
cat > /root/n8n/postgres/pg_hba.conf << 'EOF'
# Разрешаем подключения от всех IP (IPv4)
host all all 0.0.0.0/0 md5
# Разрешаем подключения от всех IP (IPv6)
host all all ::/0 md5
# Разрешаем локальные подключения
local all all md5
# Разрешаем подключения внутри Docker-сети
host all all 172.0.0.0/8 md5
EOF

# 13. Запрос пользовательских данных
echo "Настройка параметров установки..." | tee -a $LOG_FILE
read -p "Введите ваш домен (например, example.com): " DOMAIN_NAME
read -p "Введите поддомен для n8n (по умолчанию: n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
read -s -p "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Введите пользователя PostgreSQL: " POSTGRES_USER
read -s -p "Введите пароль PostgreSQL: " POSTGRES_PASSWORD
echo
read -p "Введите email для pgAdmin: " PGADMIN_EMAIL
read -s -p "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo
read -p "Введите пароль Redis: " REDIS_PASSWORD
read -p "Введите ваш email для SSL: " SSL_EMAIL
read -p "Введите ваш часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE
read -p "Введите Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Введите Telegram Chat ID: " TELEGRAM_CHAT_ID

# 14. Создание servers.json для pgAdmin
echo "Создаем servers.json для автоматической настройки pgAdmin..." | tee -a $LOG_FILE
cat > /root/n8n/pgadmin/servers.json << EOF
{
  "Servers": {
    "1": {
      "Name": "n8n",
      "Group": "Servers",
      "Host": "postgres",
      "Port": 5432,
      "MaintenanceDB": "n8n",
      "Username": "${POSTGRES_USER}",
      "SSLMode": "prefer",
      "PassFile": "/pgadmin4/pgpassfile"
    }
  }
}
EOF
# Создание pgpassfile для хранения пароля
echo "postgres:5432:n8n:${POSTGRES_USER}:${POSTGRES_PASSWORD}" > /root/n8n/pgadmin/pgpassfile
chmod 600 /root/n8n/pgadmin/pgpassfile

# 15. Создание .env файла
echo "Создаем .env файл..." | tee -a $LOG_FILE
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

# 16. Проверка портов
echo "Проверяем доступность портов 443, 5678, 5432..." | tee -a $LOG_FILE
if netstat -tuln | grep -E ':443|:5678|:5432'; then
    echo -e "${RED}Порты 443, 5678 или 5432 заняты:${NC}" | tee -a $LOG_FILE
    lsof -i :443 >> $LOG_FILE 2>&1
    lsof -i :5678 >> $LOG_FILE 2>&1
    lsof -i :5432 >> $LOG_FILE 2>&1
    echo -e "${RED}Освободите порты и повторите запуск${NC}" | tee -a $LOG_FILE
    exit 1
fi
echo "Порты свободны" | tee -a $LOG_FILE

# 17. Запуск сервисов с исправлением прав
echo "Запускаем сервисы..." | tee -a $LOG_FILE
cd /root
# Остановка всех контейнеров
docker stop $(docker ps -q) 2>/dev/null || true
# Удаление всех контейнеров
docker rm -f $(docker ps -a -q) 2>/dev/null || true
# Повторное исправление прав
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n >> $LOG_FILE 2>&1
# Запуск
docker-compose up -d >> $LOG_FILE 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при запуске контейнеров${NC}" | tee -a $LOG_FILE
    echo "Проверяем статус контейнеров:" | tee -a $LOG_FILE
    docker ps -a >> $LOG_FILE
    echo "Логи проблемных контейнеров:" | tee -a $LOG_FILE
    for container in traefik n8n postgres pgadmin redis qdrant; do
        docker logs root_${container}_1 2>&1 | grep -i error >> $LOG_FILE
    done
    exit 1
fi

# 18. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..." | tee -a $LOG_FILE
docker ps -a | tee -a $LOG_FILE
if ! docker ps | grep -q "root_"; then
    echo -e "${RED}Контейнеры не запустились, проверьте логи в $LOG_FILE${NC}" | tee -a $LOG_FILE
    exit 1
fi

# 19. Проверка доступности n8n
echo "Проверяем доступность n8n..." | tee -a $LOG_FILE
sleep 10 # Даем время на запуск
curl -s -f http://127.0.0.1:5678 > /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}n8n доступен на http://127.0.0.1:5678${NC}" | tee -a $LOG_FILE
else
    echo -e "${RED}Ошибка: n8n не отвечает на http://127.0.0.1:5678${NC}" | tee -a $LOG_FILE
    echo "Логи n8n:" | tee -a $LOG_FILE
    docker logs root_n8n_1 | grep -i error | tee -a $LOG_FILE
    exit 1
fi

# 20. Проверка подключения к PostgreSQL
echo "Проверяем подключение к PostgreSQL..." | tee -a $LOG_FILE
docker exec -it root_postgres_1 psql -U ${POSTGRES_USER} -d n8n -c "SELECT 1" > /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}PostgreSQL работает и принимает подключения${NC}" | tee -a $LOG_FILE
else
    echo -e "${RED}Ошибка: PostgreSQL не принимает подключения${NC}" | tee -a $LOG_FILE
    echo "Логи PostgreSQL:" | tee -a $LOG_FILE
    docker logs root_postgres_1 | grep -i error | tee -a $LOG_FILE
    exit 1
fi

# 21. Проверка локального подключения к PostgreSQL
echo "Проверяем локальное подключение к PostgreSQL (127.0.0.1:5432)..." | tee -a $LOG_FILE
timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/5432" 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Порт 5432 доступен на 127.0.0.1${NC}" | tee -a $LOG_FILE
else
    echo -e "${RED}Ошибка: порт 5432 недоступен на 127.0.0.1${NC}" | tee -a $LOG_FILE
    docker logs root_postgres_1 | grep -i error | tee -a $LOG_FILE
fi

# 22. Проверка логов Traefik
echo "Проверяем логи Traefik для диагностики..." | tee -a $LOG_FILE
docker logs root_traefik_1 | grep -i error | tee -a $LOG_FILE
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах Traefik, проверьте $LOG_FILE${NC}" | tee -a $LOG_FILE
fi

# 23. Проверка логов PostgreSQL
echo "Проверяем логи PostgreSQL для диагностики..." | tee -a $LOG_FILE
docker logs root_postgres_1 | grep -i error | tee -a $LOG_FILE
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах PostgreSQL, проверьте $LOG_FILE${NC}" | tee -a $LOG_FILE
fi

# 24. Создание скрипта бэкапа
echo "Создаем скрипт бэкапа..." | tee -a $LOG_FILE
cat > /root/backup-n8n.sh << 'EOF'
#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/root/n8n/logs/backup.log"
mkdir -p /root/n8n/logs

# Загрузка переменных из .env
source /root/.env

BACKUP_DIR="/root/n8n/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
POSTGRES_DB="n8n"

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
    # Извлечение message_id из ответа
    echo "$response" | grep -o '"message_id":[0-9]*' | cut -d':' -f2
}

# Функция удаления старых сообщений в Telegram
delete_old_telegram_messages() {
    local backup_type=$1
    local backup_file="/root/n8n/backups/${backup_type}_message_ids.txt"
    if [ -f "$backup_file" ]; then
        while IFS= read -r message_id; do
            # Проверяем возраст сообщения
            curl -s -X POST "${TELEGRAM_API}/deleteMessage" -d chat_id=$TELEGRAM_CHAT_ID -d message_id="$message_id" > /dev/null
        done < <(cat "$backup_file" | while read timestamp message_id; do
            timestamp_secs=$(date -d "$timestamp" +%s)
            four_weeks_ago=$(date -d "28 days ago" +%s)
            if [ $timestamp_secs -lt $four_weeks_ago ]; then
                echo "$message_id"
            fi
        done)
        # Обновляем файл, удаляя старые записи
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

echo -e "${GREEN}Начинаем создание бэкапов...${NC}" | tee -a $LOG_FILE
send_telegram_message "🟢 Начинаем создание бэкапов для n8n..."

# Бэкап PostgreSQL
echo "Создаем бэкап PostgreSQL..." | tee -a $LOG_FILE
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD root_postgres_1 pg_dump -U $POSTGRES_USER $POSTGRES_DB > $BACKUP_DIR/postgres_$TIMESTAMP.sql
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап PostgreSQL успешно создан: postgres_$TIMESTAMP.sql${NC}" | tee -a $LOG_FILE
    message_id=$(send_telegram_file "$BACKUP_DIR/postgres_$TIMESTAMP.sql" "PostgreSQL backup: postgres_$TIMESTAMP.sql")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/postgres_message_ids.txt
        send_telegram_message "✅ Бэкап PostgreSQL отправлен в Telegram: postgres_$TIMESTAMP.sql"
    else
        echo -e "${RED}Ошибка при отправке бэкапа PostgreSQL в Telegram${NC}" | tee -a $LOG_FILE
        send_telegram_message "❌ Ошибка при отправке бэкапа PostgreSQL в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа PostgreSQL${NC}" | tee -a $LOG_FILE
    send_telegram_message "❌ Ошибка при создании бэкапа PostgreSQL"
    exit 1
fi

# Бэкап Redis
echo "Создаем бэкап Redis..." | tee -a $LOG_FILE
docker cp root_redis_1:/data/dump.rdb $BACKUP_DIR/redis_$TIMESTAMP.rdb
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап Redis успешно создан: redis_$TIMESTAMP.rdb${NC}" | tee -a $LOG_FILE
    message_id=$(send_telegram_file "$BACKUP_DIR/redis_$TIMESTAMP.rdb" "Redis backup: redis_$TIMESTAMP.rdb")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/redis_message_ids.txt
        send_telegram_message "✅ Бэкап Redis отправлен в Telegram: redis_$TIMESTAMP.rdb"
    else
        echo -e "${RED}Ошибка при отправке бэкапа Redis в Telegram${NC}" | tee -a $LOG_FILE
        send_telegram_message "❌ Ошибка при отправке бэкапа Redis в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа Redis${NC}" | tee -a $LOG_FILE
    send_telegram_message "❌ Ошибка при создании бэкапа Redis"
    exit 1
fi

# Бэкап Qdrant
echo "Создаем бэкап Qdrant..." | tee -a $LOG_FILE
tar -czf $BACKUP_DIR/qdrant_$TIMESTAMP.tar.gz -C /root/n8n/qdrant .
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап Qdrant успешно создан: qdrant_$TIMESTAMP.tar.gz${NC}" | tee -a $LOG_FILE
    message_id=$(send_telegram_file "$BACKUP_DIR/qdrant_$TIMESTAMP.tar.gz" "Qdrant backup: qdrant_$TIMESTAMP.tar.gz")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/qdrant_message_ids.txt
        send_telegram_message "✅ Бэкап Qdrant отправлен в Telegram: qdrant_$TIMESTAMP.tar.gz"
    else
        echo -e "${RED}Ошибка при отправке бэкапа Qdrant в Telegram${NC}" | tee -a $LOG_FILE
        send_telegram_message "❌ Ошибка при отправке бэкапа Qdrant в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа Qdrant${NC}" | tee -a $LOG_FILE
    send_telegram_message "❌ Ошибка при создании бэкапа Qdrant"
    exit 1
fi

# Удаление старых сообщений в Telegram
echo "Удаляем старые бэкапы из Telegram (старше 4 недель)..." | tee -a $LOG_FILE
delete_old_telegram_messages "postgres"
delete_old_telegram_messages "redis"
delete_old_telegram_messages "qdrant"

# Удаление старых бэкапов локально (старше 4 недель)
echo "Удаляем локальные бэкапы старше 4 недель..." | tee -a $LOG_FILE
find $BACKUP_DIR -type f -name "*.sql" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.rdb" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.tar.gz" -mtime +28 -delete

echo -e "${GREEN}Бэкапы успешно созданы и отправлены в Telegram!${NC}" | tee -a $LOG_FILE
send_telegram_message "🎉 Бэкапы успешно завершены и отправлены в Telegram!"
EOF

# 25. Создание скрипта обновления с бэкапом
echo "Создаем скрипт обновления с бэкапом..." | tee -a $LOG_FILE
cat > /root/update-n8n.sh << 'EOF'
#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Логирование
LOG_FILE="/root/n8n/logs/update.log"
mkdir -p /root/n8n/logs

# Загрузка переменных из .env
source /root/.env

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

# Функция отправки уведомлений в Telegram
send_telegram() {
    local message=$1
    curl -s -X POST $TELEGRAM_API -d chat_id=$TELEGRAM_CHAT_ID -d text="$message" > /dev/null
}

echo -e "${GREEN}Запускаем бэкап перед обновлением...${NC}" | tee -a $LOG_FILE
send_telegram "🟢 Начинаем обновление n8n и баз данных..."
/root/backup-n8n.sh
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка бэкапа, обновление отменено${NC}" | tee -a $LOG_FILE
    send_telegram "❌ Ошибка бэкапа, обновление отменено"
    exit 1
fi

echo -e "${GREEN}Обновляем образы...${NC}" | tee -a $LOG_FILE
cd /root
docker-compose pull >> $LOG_FILE 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при загрузке образов${NC}" | tee -a $LOG_FILE
    send_telegram "❌ Ошибка при загрузке образов"
    exit 1
fi

echo -e "${GREEN}Останавливаем и удаляем все контейнеры...${NC}" | tee -a $LOG_FILE
docker-compose down >> $LOG_FILE 2>&1
# Удаляем все контейнеры n8n (включая остановленные)
docker rm -f $(docker ps -a -q -f name=n8n) 2>/dev/null || true
docker image prune -f >> $LOG_FILE 2>&1

# Исправляем права перед запуском
echo "Исправляем права доступа для /root/n8n/.n8n..." | tee -a $LOG_FILE
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n >> $LOG_FILE 2>&1

echo -e "${GREEN}Запускаем обновленные сервисы...${NC}" | tee -a $LOG_FILE
docker-compose up -d >> $LOG_FILE 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Обновление успешно завершено!${NC}" | tee -a $LOG_FILE
    send_telegram "🎉 Обновление n8n, pgAdmin и баз данных успешно завершено!"
else
    echo -e "${RED}Ошибка при запуске сервисов${NC}" | tee -a $LOG_FILE
    send_telegram "❌ Ошибка при запуске сервисов"
    exit 1
fi
EOF

# 26. Настройка прав и cron
echo "Настраиваем бэкапы и автообновление..." | tee -a $LOG_FILE
chmod +x /root/backup-n8n.sh
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/backup-n8n.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

# 27. Открытие порта 5432 в файрволе
echo "Открываем порт 5432 в файрволе..." | tee -a $LOG_FILE
ufw allow 5432/tcp > /dev/null 2>&1 || echo "ufw не установлен, пропускаем" | tee -a $LOG_FILE

echo -e "${GREEN}Установка n8n, PostgreSQL, pgAdmin, Redis и Qdrant завершена!${NC}" | tee -a $LOG_FILE
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME" | tee -a $LOG_FILE
echo "Доступ к PostgreSQL: 127.0.0.1:5432 (используйте psql или клиент PostgreSQL)" | tee -a $LOG_FILE
echo "Доступ к pgAdmin: https://pgadmin.$DOMAIN_NAME" | tee -a $LOG_FILE
echo "Доступ к Qdrant: https://qdrant.$DOMAIN_NAME" | tee -a $LOG_FILE
echo "Логин n8n: $N8N_BASIC_AUTH_USER" | tee -a $LOG_FILE
echo "Логин pgAdmin: $PGADMIN_EMAIL" | tee -a $LOG_FILE
echo "Пароли: [скрыты]" | tee -a $LOG_FILE
echo "Папка для файлов: /root/n8n/local-files (доступна в n8n как /files/)" | tee -a $LOG_FILE
echo "Папка для бэкапов: /root/n8n/backups" | tee -a $LOG_FILE
echo "Логи установки: $LOG_FILE" | tee -a $LOG_FILE
echo "Бэкапы настроены на каждую субботу в 23:00, отправка в Telegram (Chat ID: $TELEGRAM_CHAT_ID)" | tee -a $LOG_FILE
echo "Автообновление настроено на каждое воскресенье в 00:00, с удалением старых контейнеров n8n" | tee -a $LOG_FILE
echo "Уведомления и бэкапы отправляются в Telegram (Chat ID: $TELEGRAM_CHAT_ID)" | tee -a $LOG_FILE
echo -e "${GREEN}Для подключения к PostgreSQL используйте: psql -h 127.0.0.1 -U $POSTGRES_USER -d n8n${NC}" | tee -a $LOG_FILE
echo -e "${GREEN}В pgAdmin сервер уже настроен (Name: n8n, Host: postgres, Username: $POSTGRES_USER, Database: n8n)${NC}" | tee -a $LOG_FILE
echo -e "${GREEN}Бэкапы хранятся в Telegram, скачивайте их из чата (Chat ID: $TELEGRAM_CHAT_ID)${NC}" | tee -a $LOG_FILE
echo -e "${GREEN}Если возникает 404/Bad Gateway, проверьте логи: docker logs root_n8n_1, docker logs root_traefik_1, $LOG_FILE${NC}" | tee -a $LOG_FILE
echo -e "${GREEN}Если ошибка подключения к PostgreSQL, проверьте: docker logs root_postgres_1, $LOG_FILE${NC}" | tee -a $LOG_FILE
