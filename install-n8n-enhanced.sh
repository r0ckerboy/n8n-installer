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

# 1. Проверка доступных ресурсов
echo "Проверяем доступные ресурсы..."
FREE_MEM=$(free -m | awk '/Mem:/ {print $4}')
if [ "$FREE_MEM" -lt 500 ]; then
    echo -e "${RED}Недостаточно свободной памяти ($FREE_MEM MB). Требуется минимум 500 MB.${NC}"
    exit 1
fi
CPU_CORES=$(nproc)
if [ "$CPU_CORES" -lt 1 ]; then
    echo -e "${RED}Недостаточно CPU ядер ($CPU_CORES). Требуется минимум 1 ядро.${NC}"
    exit 1
fi
echo "Ресурсы: $FREE_MEM MB памяти, $CPU_CORES CPU ядер"

# 2. Обновление индексов пакетов
echo "Обновляем индексы пакетов..."
apt update > /root/update.log 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка обновления индексов пакетов (см. /root/update.log)${NC}"
    exit 1
fi

# 3. Установка необходимых пакетов
echo "Устанавливаем необходимые пакеты..."
apt install -y curl software-properties-common ca-certificates net-tools lsof > /root/utils_install.log 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка установки пакетов (см. /root/utils_install.log)${NC}"
    exit 1
fi

# 4. Импорт GPG-ключа Docker
echo "Импортируем GPG-ключ Docker..."
wget -qO- https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка импорта GPG-ключа Docker${NC}"
    exit 1
fi

# 5. Добавление репозитория Docker
echo "Добавляем репозиторий Docker..."
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка добавления репозитория Docker${NC}"
    exit 1
fi

# 6. Повторное обновление индексов
echo "Обновляем индексы пакетов после добавления репозитория..."
apt update >> /root/update.log 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка обновления индексов пакетов (см. /root/update.log)${NC}"
    exit 1
fi

# 7. Установка Docker
echo "Устанавливаем Docker..."
apt install -y docker-ce >> /root/utils_install.log 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка установки Docker (см. /root/utils_install.log)${NC}"
    exit 1
fi

# 8. Установка Docker Compose
echo "Устанавливаем Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.33.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка установки Docker Compose${NC}"
    exit 1
fi

# 9. Создание директорий
echo "Создаем необходимые директории..."
mkdir -p /root/n8n/.n8n /root/n8n/local-files /root/n8n/postgres /root/n8n/config /root/n8n/redis /root/n8n/backups /root/n8n/pgadmin
chmod -R 777 /root/n8n/local-files
chmod -R 700 /root/n8n/backups
chmod -R 777 /root/n8n/pgadmin

# 10. Полная очистка и настройка директории PostgreSQL
echo "Настраиваем директорию /root/n8n/postgres..."
rm -rf /root/n8n/postgres
mkdir -p /root/n8n/postgres
chmod 700 /root/n8n/postgres
chown 999:999 /root/n8n/postgres
if [ "$(ls -A /root/n8n/postgres)" ]; then
    echo -e "${RED}Ошибка: директория /root/n8n/postgres не пуста!${NC}"
    exit 1
fi
ls -ld /root/n8n/postgres

# 11. Исправление прав для n8n
echo "Настраиваем права для /root/n8n/.n8n..."
rm -rf /root/n8n/.n8n
mkdir -p /root/n8n/.n8n
chown 1000:1000 /root/n8n/.n8n
chmod 700 /root/n8n/.n8n
ls -ld /root/n8n/.n8n

# 12. Создание docker-compose.yml
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
    command: ["sh", "-c", "sleep 30 && /docker-entrypoint.sh"]
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
      - LANG=C.UTF-8
    ports:
      - "5432:5432"
    volumes:
      - ${DATA_FOLDER}/postgres:/var/lib/postgresql/data
      - ${DATA_FOLDER}/config/pg_hba.conf:/docker-entrypoint-initdb.d/pg_hba.conf
    logging:
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d n8n"]
      interval: 5s
      timeout: 10s
      retries: 20
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
    networks:
      - n8n-network

  pgadmin:
    image: dpage/pgadmin4:latest
    restart: always
    environment:
      - PGADMIN_DEFAULT_EMAIL=${PGADMIN_EMAIL:-admin@example.com}
      - PGADMIN_DEFAULT_PASSWORD=${PGADMIN_DEFAULT_PASSWORD:-admin}
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
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 128M
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
EOF

# 13. Создание pg_hba.conf
echo "Создаем pg_hba.conf для PostgreSQL..."
mkdir -p /root/n8n/config
cat > /root/n8n/config/pg_hba.conf << 'EOF'
host all all 0.0.0.0/0 md5
host all all ::/0 md5
local all all md5
EOF

# 14. Проверка портов
echo "Проверяем доступность портов 443, 5432, 5678, 5050..."
if netstat -tuln | grep -E ':443|:5432|:5678|:5050'; then
    echo -e "${RED}Один или несколько портов (443, 5432, 5678, 5050) заняты!${NC}"
    lsof -i :443
    lsof -i :5432
    lsof -i :5678
    lsof -i :5050
    echo -e "${RED}Освободите порты и перезапустите скрипт.${NC}"
    exit 1
fi

# 15. Запрос пользовательских данных
echo "Настройка параметров установки..."
read -p "Введите ваш домен (например, nightcity2077.ru): " DOMAIN_NAME
read -p "Введите поддомен для n8n (по умолчанию: n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
read -s -p "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Введите пользователя PostgreSQL (буквы и цифры, макс. 32): " POSTGRES_USER
read -s -p "Введите пароль PostgreSQL (буквы и цифры, макс. 32): " POSTGRES_PASSWORD
echo
read -p "Введите email для pgAdmin: " PGADMIN_EMAIL
read -s -p "Введите пароль для pgAdmin: " PGADMIN_DEFAULT_PASSWORD
echo
read -p "Введите пароль Redis (буквы и цифры, макс. 32): " REDIS_PASSWORD
read -p "Введите ваш email для SSL: " SSL_EMAIL
read -p "Введите часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE
read -p "Введите Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Введите Telegram Chat ID: " TELEGRAM_CHAT_ID

# Проверка учетных данных
if ! [[ "$POSTGRES_USER" =~ ^[a-zA-Z0-9]+$ ]] || [ ${#POSTGRES_USER} -gt 32 ]; then
    echo -e "${RED}Ошибка: POSTGRES_USER должен содержать только буквы и цифры, до 32 символов${NC}"
    exit 1
fi
if ! [[ "$POSTGRES_PASSWORD" =~ ^[a-zA-Z0-9]+$ ]] || [ ${#POSTGRES_PASSWORD} -gt 32 ]; then
    echo -e "${RED}Ошибка: POSTGRES_PASSWORD должен содержать только буквы и цифры, до 32 символов${NC}"
    exit 1
fi
if ! [[ "$REDIS_PASSWORD" =~ ^[a-zA-Z0-9]+$ ]] || [ ${#REDIS_PASSWORD} -gt 32 ]; then
    echo -e "${RED}Ошибка: REDIS_PASSWORD должен содержать только буквы и цифры, до 32 символов${NC}"
    exit 1
fi
if [ -z "$PGADMIN_EMAIL" ] || [ -z "$PGADMIN_DEFAULT_PASSWORD" ]; then
    echo -e "${RED}Ошибка: PGADMIN_EMAIL и PGADMIN_DEFAULT_PASSWORD не могут быть пустыми${NC}"
    exit 1
fi

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
PGADMIN_DEFAULT_PASSWORD=$PGADMIN_DEFAULT_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

# 17. Создание Docker-сети
echo "Создаем Docker-сеть n8n-network..."
docker network create n8n-network 2>/dev/null || true

# 18. Запуск сервисов
echo "Запускаем сервисы..."
cd /root
docker stop $(docker ps -q) 2>/dev/null || true
docker rm $(docker ps -a -q) 2>/dev/null || true
docker system prune -f 2>/dev/null || true
rm -rf /root/n8n/postgres
mkdir -p /root/n8n/postgres
chmod 700 /root/n8n/postgres
chown 999:999 /root/n8n/postgres
sleep 2
if [ "$(ls -A /root/n8n/postgres)" ]; then
    echo -e "${RED}Ошибка: директория /root/n8n/postgres не пуста перед запуском!${NC}"
    exit 1
fi
ls -ld /root/n8n/postgres
docker-compose up -d
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при запуске контейнеров${NC}"
    docker ps -a
    docker logs root-postgres-1
    docker logs root-n8n-1
    exit 1
fi

# 19. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
docker ps -a

# 20. Ожидание инициализации
echo "Ожидаем инициализации сервисов (90 секунд)..."
sleep 90

# 21. Проверка подключения к PostgreSQL
echo "Проверяем подключение к PostgreSQL..."
docker exec root-postgres-1 psql -U ${POSTGRES_USER} -d n8n -c "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к PostgreSQL${NC}"
    docker logs root-postgres-1
    ls -la /root/n8n/postgres
    exit 1
fi
echo -e "${GREEN}Подключение к PostgreSQL успешно${NC}"

# 22. Проверка подключения к Redis
echo "Проверяем подключение к Redis..."
docker exec root-redis-1 redis-cli -a ${REDIS_PASSWORD} ping > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к Redis${NC}"
    docker logs root-redis-1
    exit 1
fi
echo -e "${GREEN}Подключение к Redis успешно${NC}"

# 23. Проверка доступности n8n
echo "Проверяем доступность n8n..."
curl -s -f http://127.0.0.1:5678/healthz > /dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: n8n не отвечает на http://127.0.0.1:5678${NC}"
    docker logs root-n8n-1 | grep -i "error.*postgres"
    exit 1
fi
echo -e "${GREEN}n8n доступен на http://127.0.0.1:5678${NC}"

# 24. Проверка доступности pgAdmin
echo "Проверяем доступность pgAdmin..."
curl -s -f http://127.0.0.1:5050 > /dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: pgAdmin не отвечает на http://127.0.0.1:5050${NC}"
    docker logs root-pgadmin-1
    exit 1
fi
echo -e "${GREEN}pgAdmin доступен на http://127.0.0.1:5050${NC}"

# 25. Проверка логов Traefik
echo "Проверяем логи Traefik..."
docker logs root-traefik-1 | grep -i error
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах Traefik${NC}"
fi

# 26. Создание скрипта бэкапа
echo "Создаем скрипт бэкапа..."
cat > /root/backup-n8n.sh << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
source /root/.env
BACKUP_DIR="/root/n8n/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
POSTGRES_DB="n8n"
send_telegram_message() {
    curl -s -X POST "${TELEGRAM_API}/sendMessage" -d chat_id=$TELEGRAM_CHAT_ID -d text="$1" > /dev/null
}
send_telegram_file() {
    local response=$(curl -s -F chat_id=$TELEGRAM_CHAT_ID -F document=@"$1" -F caption="$2" "${TELEGRAM_API}/sendDocument")
    echo "$response" | grep -o '"message_id":[0-9]*' | cut -d':' -f2
}
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
echo "Создаем бэкап PostgreSQL..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD root-postgres-1 pg_dump -U $POSTGRES_USER $POSTGRES_DB > $BACKUP_DIR/postgres_$TIMESTAMP.sql
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап PostgreSQL создан: postgres_$TIMESTAMP.sql${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/postgres_$TIMESTAMP.sql" "PostgreSQL backup: postgres_$TIMESTAMP.sql")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/postgres_message_ids.txt
        send_telegram_message "✅ Бэкап PostgreSQL отправлен"
    else
        send_telegram_message "❌ Ошибка отправки бэкапа PostgreSQL"
    fi
else
    echo -e "${RED}Ошибка создания бэкапа PostgreSQL${NC}"
    send_telegram_message "❌ Ошибка создания бэкапа PostgreSQL"
    exit 1
fi
echo "Создаем бэкап Redis..."
docker cp root-redis-1:/data/dump.rdb $BACKUP_DIR/redis_$TIMESTAMP.rdb
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап Redis создан: redis_$TIMESTAMP.rdb${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/redis_$TIMESTAMP.rdb" "Redis backup: redis_$TIMESTAMP.rdb")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/redis_message_ids.txt
        send_telegram_message "✅ Бэкап Redis отправлен"
    else
        send_telegram_message "❌ Ошибка отправки бэкапа Redis"
    fi
else
    echo -e "${RED}Ошибка создания бэкапа Redis${NC}"
    send_telegram_message "❌ Ошибка создания бэкапа Redis"
    exit 1
fi
echo "Удаляем старые бэкапы из Telegram..."
delete_old_telegram_messages "postgres"
delete_old_telegram_messages "redis"
echo "Удаляем локальные бэкапы старше 4 недель..."
find $BACKUP_DIR -type f -name "*.sql" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.rdb" -mtime +28 -delete
echo -e "${GREEN}Бэкапы созданы и отправлены!${NC}"
send_telegram_message "🎉 Бэкапы завершены!"
EOF

# 27. Создание скрипта обновления
echo "Создаем скрипт обновления..."
cat > /root/update-n8n.sh << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
source /root/.env
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
send_telegram() {
    curl -s -X POST $TELEGRAM_API -d chat_id=$TELEGRAM_CHAT_ID -d text="$1" > /dev/null
}
echo -e "${GREEN}Запускаем бэкап...${NC}"
send_telegram "🟢 Начинаем обновление n8n..."
/root/backup-n8n.sh
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка бэкапа${NC}"
    send_telegram "❌ Ошибка бэкапа"
    exit 1
fi
echo -e "${GREEN}Обновляем образы...${NC}"
cd /root
docker-compose pull
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка загрузки образов${NC}"
    send_telegram "❌ Ошибка загрузки образов"
    exit 1
fi
echo -e "${GREEN}Останавливаем контейнеры...${NC}"
docker-compose down
docker rm -f $(docker ps -a -q -f name=n8n) 2>/dev/null || true
docker image prune -f
rm -rf /root/n8n/postgres
mkdir -p /root/n8n/postgres
chmod 700 /root/n8n/postgres
chown 999:999 /root/n8n/postgres
rm -rf /root/n8n/.n8n
mkdir -p /root/n8n/.n8n
chown 1000:1000 /root/n8n/.n8n
chmod 700 /root/n8n/.n8n
echo -e "${GREEN}Запускаем сервисы...${NC}"
docker-compose up -d
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Обновление завершено!${NC}"
    send_telegram "🎉 Обновление завершено!"
else
    echo -e "${RED}Ошибка запуска сервисов${NC}"
    send_telegram "❌ Ошибка запуска сервисов"
    exit 1
fi
EOF

# 28. Настройка прав и cron
echo "Настраиваем бэкапы и автообновление..."
chmod +x /root/backup-n8n.sh
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/backup-n8n.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

# 29. Финальная проверка
echo -e "${GREEN}Установка завершена!${NC}"
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Доступ к pgAdmin: https://pgadmin.$DOMAIN_NAME"
echo "Логин n8n: $N8N_BASIC_AUTH_USER"
echo "Логин pgAdmin: $PGADMIN_EMAIL"
echo "Бэкапы: каждую субботу в 23:00"
echo "Обновления: каждое воскресенье в 00:00"
echo -e "${GREEN}Настройте pgAdmin: Host=postgres, Port=5432, Username=$POSTGRES_USER, Database=n8n${NC}"
