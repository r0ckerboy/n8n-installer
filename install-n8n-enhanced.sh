#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Начинаем установку n8n, PostgreSQL, Redis и pgAdmin...${NC}"

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
apt install curl software-properties-common ca-certificates net-tools lsof -y

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
mkdir -p /root/n8n/postgres
mkdir -p /root/n8n/redis
mkdir -p /root/n8n/backups
mkdir -p /root/n8n/pgadmin
chmod -R 777 /root/n8n/local-files # Разрешаем чтение/запись
chmod -R 700 /root/n8n/backups # Ограничиваем доступ к бэкапам
chmod -R 777 /root/n8n/pgadmin # Разрешаем доступ для pgAdmin

# 9. Очистка директории PostgreSQL
echo "Очищаем директорию /root/n8n/postgres для новой инициализации..."
rm -rf /root/n8n/postgres/*
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при очистке директории /root/n8n/postgres${NC}"
    exit 1
fi

# 10. Исправление прав доступа для n8n заранее
echo "Исправляем права доступа для /root/n8n/.n8n..."
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chmod n8nio/base:16 -R 600 /home/node/.n8n
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при установке прав доступа для /root/n8n/.n8n${NC}"
    exit 1
fi
# Проверка прав
ls -ld /root/n8n/.n8n
echo "Права для /root/n8n/.n8n установлены"

# 11. Создание docker-compose.yml
echo "Создаем docker-compose.yml..."
cat > /root/docker-compose.yml << 'EOF'
version: '3.8'
services:
  traefik:
    image: traefik
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
    networks:
      - n8n-network

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
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_LOG_LEVEL=debug
    volumes:
      - ${DATA_FOLDER}/.n8n:/home/node/.n8n
      - ${DATA_FOLDER}/local-files:/files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  postgres:
    image: postgres:16
    restart: always
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
      - LC_ALL=en_US.UTF-8
      - LC_CTYPE=en_US.UTF-8
    ports:
      - "5432:5432"
    volumes:
      - ${DATA_FOLDER}/postgres:/var/lib/postgresql/data
      - /root/n8n/postgres/pg_hba.conf:/docker-entrypoint-initdb.d/pg_hba.conf
      - /root/n8n/postgres/postgresql.conf:/docker-entrypoint-initdb.d/postgresql.conf
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d n8n"]
      interval: 5s
      timeout: 10s
      retries: 12
    networks:
      - n8n-network

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
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(`pgadmin.${DOMAIN_NAME}`)
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.entrypoints=websecure
      - traefik.http.routers.pgadmin.tls.certresolver=mytlschallenge
    ports:
      - "127.0.0.1:5050:80"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - n8n-network

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
      interval: 5s
      timeout: 10s
      retries: 12
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
EOF

# 12. Создание pg_hba.conf для PostgreSQL
echo "Создаем pg_hba.conf для разрешения локальных подключений..."
cat > /root/n8n/postgres/pg_hba.conf << 'EOF'
# Разрешаем локальные подключения
local all all md5
host all all 127.0.0.1/32 md5
host all all ::1/128 md5
# Разрешаем подключения из Docker-сети
host all all 0.0.0.0/0 md5
EOF

# 13. Создание postgresql.conf для PostgreSQL
echo "Создаем postgresql.conf для разрешения подключений..."
cat > /root/n8n/postgres/postgresql.conf << 'EOF'
listen_addresses = '*'
EOF

# 14. Проверка портов
echo "Проверяем доступность портов 443, 5678 и 5050..."
if netstat -tuln | grep -E '443|5678|5050'; then
    echo -e "${RED}Порты 443, 5678 или 5050 заняты!${NC}"
    echo "Детали занятых портов:"
    lsof -i :443
    lsof -i :5678
    lsof -i :5050
    echo -e "${RED}Для освобождения портов выполните следующие действия:${NC}"
    echo "1. Найдите PID процессов, использующих порты, с помощью 'lsof -i :443', 'lsof -i :5678', 'lsof -i :5050'."
    echo "2. Завершите процессы командой 'kill -9 <PID>'."
    echo "3. Если порты используются веб-сервером (например, nginx, apache), остановите его:"
    echo "   systemctl stop nginx"
    echo "   systemctl stop apache2"
    echo "4. Если порты используются Docker-контейнерами, остановите их:"
    echo "   docker ps -a"
    echo "   docker stop <container_name>"
    echo "5. Повторно запустите скрипт после освобождения портов."
    exit 1
else
    echo "Порты свободны"
fi

# 15. Запрос пользовательских данных
echo "Настройка параметров установки..."
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

# 16. Создание .env файла
echo "Создаем .env файл..."
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_DEFAULT_PASSWORD=$PGADMIN_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

# 17. Запуск сервисов с исправлением прав
echo "Запускаем сервисы..."
cd /root
# Остановка всех контейнеров
docker stop $(docker ps -q) 2>/dev/null || true
# Повторное исправление прав
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chmod n8nio/base:16 -R 600 /home/node/.n8n
# Запуск
docker-compose up -d
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при запуске контейнеров${NC}"
    echo "Логи PostgreSQL для диагностики:"
    docker logs root_postgres_1
    echo "Логи n8n для диагностики:"
    docker logs root_n8n_1
    echo "Логи Redis для диагностики:"
    docker logs root_redis_1
    exit 1
fi

# 18. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
docker ps -a
echo "Если контейнеры не запущены, проверьте логи с помощью: docker logs <container_name>"

# 19. Проверка подключения к PostgreSQL
echo "Проверяем подключение к PostgreSQL из контейнера n8n..."
docker exec root_n8n_1 psql -h postgres -U ${POSTGRES_USER} -d n8n -c "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к PostgreSQL из n8n${NC}"
    echo "Логи PostgreSQL:"
    docker logs root_postgres_1
    echo "Логи n8n:"
    docker logs root_n8n_1
    exit 1
else
    echo -e "${GREEN}Подключение к PostgreSQL успешно${NC}"
fi

# 20. Проверка подключения к Redis
echo "Проверяем подключение к Redis из контейнера n8n..."
docker exec root_n8n_1 redis-cli -h redis -a ${REDIS_PASSWORD} ping > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к Redis из n8n${NC}"
    echo "Логи Redis:"
    docker logs root_redis_1
    echo "Логи n8n:"
    docker logs root_n8n_1
    exit 1
else
    echo -e "${GREEN}Подключение к Redis успешно${NC}"
fi

# 21. Проверка доступности n8n
echo "Проверяем доступность n8n..."
sleep 15 # Даем больше времени на запуск
curl -s -f http://127.0.0.1:5678/healthz > /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}n8n доступен на http://127.0.0.1:5678${NC}"
else
    echo -e "${RED}Ошибка: n8n не отвечает на http://127.0.0.1:5678${NC}"
    echo "Логи n8n:"
    docker logs root_n8n_1
    echo "Логи PostgreSQL:"
    docker logs root_postgres_1
    echo "Логи Redis:"
    docker logs root_redis_1
    exit 1
fi

# 22. Проверка логов Traefik
echo "Проверяем логи Traefik для диагностики..."
docker logs root_traefik_1 | grep -i error
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах Traefik, проверьте выше${NC}"
fi

# 23. Проверка логов PostgreSQL
echo "Проверяем логи PostgreSQL для диагностики..."
docker logs root_postgres_1 | grep -i error
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах PostgreSQL, проверьте выше${NC}"
fi

# 24. Проверка логов Redis
echo "Проверяем логи Redis для диагностики..."
docker logs root_redis_1 | grep -i error
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах Redis, проверьте выше${NC}"
fi

# 25. Создание скрипта бэкапа
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
            # Проверяем возраст сообщения (примерно через дату файла)
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

echo -e "${GREEN}Начинаем создание бэкапов...${NC}"
send_telegram_message "🟢 Начинаем создание бэкапов для n8n..."

# Бэкап PostgreSQL
echo "Создаем бэкап PostgreSQL..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD root_postgres_1 pg_dump -U $POSTGRES_USER $POSTGRES_DB > $BACKUP_DIR/postgres_$TIMESTAMP.sql
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап PostgreSQL успешно создан: postgres_$TIMESTAMP.sql${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/postgres_$TIMESTAMP.sql" "PostgreSQL backup: postgres_$TIMESTAMP.sql")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/postgres_message_ids.txt
        send_telegram_message "✅ Бэкап PostgreSQL отправлен в Telegram: postgres_$TIMESTAMP.sql"
    else
        echo -e "${RED}Ошибка при отправке бэкапа PostgreSQL в Telegram${NC}"
        send_telegram_message "❌ Ошибка при отправке бэкапа PostgreSQL в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа PostgreSQL${NC}"
    send_telegram_message "❌ Ошибка при создании бэкапа PostgreSQL"
    exit 1
fi

# Бэкап Redis
echo "Создаем бэкап Redis..."
docker cp root_redis_1:/data/dump.rdb $BACKUP_DIR/redis_$TIMESTAMP.rdb
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

# Удаление старых сообщений в Telegram
echo "Удаляем старые бэкапы из Telegram (старше 4 недель)..."
delete_old_telegram_messages "postgres"
delete_old_telegram_messages "redis"

# Удаление старых бэкапов локально (старше 4 недель)
echo "Удаляем локальные бэкапы старше 4 недель..."
find $BACKUP_DIR -type f -name "*.sql" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.rdb" -mtime +28 -delete

echo -e "${GREEN}Бэкапы успешно созданы и отправлены в Telegram!${NC}"
send_telegram_message "🎉 Бэкапы успешно завершены и отправлены в Telegram!"
EOF

# 26. Создание скрипта обновления с бэкапом
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
# Удаляем все контейнеры n8n (включая остановленные)
docker rm -f $(docker ps -a -q -f name=n8n) 2>/dev/null || true
docker image prune -f

# Исправляем права перед запуском
echo "Исправляем права доступа для /root/n8n/.n8n..."
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chmod n8nio/base:16 -R 600 /home/node/.n8n

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

# 27. Настройка прав и cron
echo "Настраиваем бэкапы и автообновление..."
chmod +x /root/backup-n8n.sh
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/backup-n8n.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

echo -e "${GREEN}Установка n8n, PostgreSQL, Redis и pgAdmin завершена!${NC}"
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Доступ к PostgreSQL: localhost:5432 (используйте psql или клиент PostgreSQL)"
echo "Доступ к pgAdmin: https://pgadmin.$DOMAIN_NAME"
echo "Логин n8n: $N8N_BASIC_AUTH_USER"
echo "Логин pgAdmin: $PGADMIN_EMAIL"
echo "Пароли: [скрыты]"
echo "Папка для файлов: /root/n8n/local-files (доступна в n8n как /files/)"
echo "Папка для бэкапов: /root/n8n/backups"
echo "Бэкапы настроены на каждую субботу в 23:00, отправка в Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo "Автообновление настроено на каждое воскресенье в 00:00, с удалением старых контейнеров n8n"
echo "Уведомления и бэкапы отправляются в Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo -e "${GREEN}Для подключения к PostgreSQL используйте: psql -h localhost -U $POSTGRES_USER -d n8n${NC}"
echo -e "${GREEN}В pgAdmin настройте сервер: Host=postgres, Port=5432, Username=$POSTGRES_USER, Database=n8n${NC}"
echo -e "${GREEN}Бэкапы хранятся в Telegram, скачивайте их из чата (Chat ID: $TELEGRAM_CHAT_ID)${NC}"
