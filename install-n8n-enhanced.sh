#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Начинаем установку n8n, PostgreSQL, pgAdmin и Redis...${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# Проверка наличия Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker не установлен. Устанавливаем...${NC}"
    apt update
    apt install docker-ce -y
fi

# Проверка наличия Docker Compose
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}Docker Compose не установлен. Устанавливаем...${NC}"
    curl -L "https://github.com/docker/compose/releases/download/v2.33.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Проверка занятых портов
echo "Проверяем доступность портов 443, 8080, 5432..."
if netstat -tuln | grep -E ':443|:8080|:5432' > /dev/null; then
    echo -e "${RED}Один или несколько портов (443, 8080, 5432) заняты. Пожалуйста, освободите их.${NC}"
    exit 1
fi

# Предупреждение об очистке данных
echo -e "${RED}ВНИМАНИЕ: Существующие данные PostgreSQL будут удалены. Сделать бэкап? (y/n)${NC}"
read -p "Ваш выбор: " BACKUP_CHOICE
if [ "$BACKUP_CHOICE" = "y" ]; then
    echo "Создаем бэкап PostgreSQL..."
    mkdir -p /root/n8n/backups
    if docker ps -a --format '{{.Names}}' | grep -q postgres; then
        source /root/.env 2>/dev/null || true
        docker exec -e PGPASSWORD=${POSTGRES_PASSWORD:-postgres} postgres pg_dump -U ${POSTGRES_USER:-postgres} n8n > /root/n8n/backups/postgres_backup_$(date +%Y%m%d_%H%M%S).sql
        echo -e "${GREEN}Бэкап сохранен в /root/n8n/backups${NC}"
    else
        echo -e "${RED}Контейнер postgres не найден, бэкап не создан${NC}"
    fi
fi

# Остановка и удаление существующих контейнеров
echo "Останавливаем и удаляем существующие контейнеры..."
cd /root
docker-compose down 2>/dev/null || true
docker rm -f $(docker ps -a -q -f name=n8n) 2>/dev/null || true

# Очистка существующих данных
echo "Очищаем существующие данные..."
rm -rf /root/n8n/postgres/* /root/n8n/letsencrypt/* /root/n8n/.n8n/*
docker volume rm n8n_postgres_data 2>/dev/null || true

# Создание директорий
echo "Создаем необходимые директории..."
mkdir -p /root/n8n/.n8n /root/n8n/local-files /root/n8n/postgres /root/n8n/redis /root/n8n/backups /root/n8n/pgadmin
chmod -R 777 /root/n8n/local-files /root/n8n/pgadmin
chmod -R 700 /root/n8n/backups
chown -R 1000:1000 /root/n8n/.n8n /root/n8n/redis
chmod -R 777 /root/n8n/redis

# Создание docker-compose.yml
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
      - "--entrypoints.postgres.address=:5432"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
      - "--log.level=DEBUG"
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
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
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
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
    ports:
      - "127.0.0.1:5678:5678"
    networks:
      - n8n_network

  postgres:
    container_name: postgres
    image: postgres:16
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - /root/n8n/postgres/pg_hba.conf:/docker-entrypoint-initdb.d/pg_hba.conf
    labels:
      - traefik.enable=true
      - traefik.tcp.routers.postgres.rule=HostSNI(`pg.${DOMAIN_NAME}`)
      - traefik.tcp.routers.postgres.entrypoints=postgres
      - traefik.tcp.routers.postgres.tls=true
      - traefik.tcp.routers.postgres.tls.certresolver=mytlschallenge
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
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
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--spider", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks:
      - n8n_network

  redis:
    container_name: redis
    image: redis:7
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ${DATA_FOLDER}/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a ${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n_network

volumes:
  postgres_data:

networks:
  n8n_network:
    name: n8n_network
EOF

# Создание pg_hba.conf для PostgreSQL
echo "Создаем pg_hba.conf для разрешения подключений..."
cat > /root/n8n/postgres/pg_hba.conf << 'EOF'
# Разрешаем подключения от всех IP
host all all 0.0.0.0/0 md5
# Разрешаем локальные подключения
local all all md5
EOF

# Запрос пользовательских данных с валидацией
echo "Настройка параметров установки..."
while true; do
    read -p "Введите ваш домен (например, example.com): " DOMAIN_NAME
    if [[ $DOMAIN_NAME =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then break; else echo -e "${RED}Неверный формат домена${NC}"; fi
done
read -p "Введите поддомен для n8n (по умолчанию: n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
while true; do
    read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
    if [ -n "$N8N_BASIC_AUTH_USER" ]; then break; else echo -e "${RED}Логин не может быть пустым${NC}"; fi
done
read -s -p "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
while true; do
    read -p "Введите пользователя PostgreSQL: " POSTGRES_USER
    if [ -n "$POSTGRES_USER" ]; then break; else echo -e "${RED}Пользователь не может быть пустым${NC}"; fi
done
read -s -p "Введите пароль PostgreSQL: " POSTGRES_PASSWORD
echo
while true; do
    read -p "Введите email для pgAdmin: " PGADMIN_EMAIL
    if [[ $PGADMIN_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then break; else echo -e "${RED}Неверный формат email${NC}"; fi
done
read -s -p "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo
while true; do
    read -p "Введите пароль Redis: " REDIS_PASSWORD
    if [ -n "$REDIS_PASSWORD" ]; then break; else echo -e "${RED}Пароль не может быть пустым${NC}"; fi
done
while true; do
    read -p "Введите ваш email для SSL: " SSL_EMAIL
    if [[ $SSL_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then break; else echo -e "${RED}Неверный формат email${NC}"; fi
done
read -p "Введите ваш часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE
GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-UTC}
read -p "Введите Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Введите Telegram Chat ID: " TELEGRAM_CHAT_ID

# Создание .env файла
echo "Создаем .env файл..."
cat > /root/.env << EOF
# Путь к данным
DATA_FOLDER=/root/n8n/

# Домен и поддомен
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN

# Настройки n8n
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD

# Настройки PostgreSQL
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# Настройки pgAdmin
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_PASSWORD=$PGADMIN_PASSWORD

# Настройки Redis
REDIS_PASSWORD=$REDIS_PASSWORD

# SSL и часовой пояс
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE

# Telegram уведомления
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

# Запуск сервисов
echo "Запускаем сервисы..."
cd /root
docker-compose up -d

# Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
sleep 10
docker ps
if docker ps -a --format '{{.Names}} {{.Status}}' | grep -v "healthy" | grep -E "n8n|postgres|redis|pgadmin|traefik"; then
    echo -e "${RED}Некоторые контейнеры не в состоянии healthy. Проверяйте логи:${NC}"
fi

# Проверка логов
echo "Проверяем логи сервисов для диагностики..."
docker logs traefik > /root/n8n/traefik.log 2>&1
docker logs n8n > /root/n8n/n8n.log 2>&1
docker logs postgres > /root/n8n/postgres.log 2>&1
docker logs pgadmin > /root/n8n/pgadmin.log 2>&1
docker logs redis > /root/n8n/redis.log 2>&1
echo -e "${GREEN}Логи сохранены в /root/n8n/*.log${NC}"

# Проверка маршрутов Traefik
echo "Проверяем маршруты Traefik..."
curl -s http://localhost:8080/api/http/routers | grep -E "n8n|pgadmin" || echo -e "${RED}Маршруты Traefik не найдены. Проверьте конфигурацию.${NC}"

# Проверка DNS
echo "Проверяем DNS-записи..."
nslookup $SUBDOMAIN.$DOMAIN_NAME || echo -e "${RED}DNS для $SUBDOMAIN.$DOMAIN_NAME не настроен${NC}"
nslookup pgadmin.$DOMAIN_NAME || echo -e "${RED}DNS для pgadmin.$DOMAIN_NAME не настроен${NC}"
nslookup pg.$DOMAIN_NAME || echo -e "${RED}DNS для pg.$DOMAIN_NAME не настроен${NC}"

# Создание скрипта бэкапа
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
    local backup_file="/root/n8n/backups/${1}_message_ids.txt"
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
        grep -v -f <(cat "$backup_file" | while read timestamp message_id; do
            timestamp_secs=$(date -d "$timestamp" +%s)
            four_weeks_ago=$(date -d "28 days ago" +%s)
            if [ $timestamp_secs -lt $four_weeks_ago ]; then
                echo "^$timestamp $message_id$"
            fi
        done) "$backup_file" > "${backup_file}.tmp" && mv "${backup_file}.tmp" "$backup_file"
    fi
}

echo -e "${GREEN}Начинаем создание бэкапов...${NC}"
send_telegram_message "🟢 Начинаем создание бэкапов для n8n..."

docker exec -e PGPASSWORD=$POSTGRES_PASSWORD postgres pg_dump -U $POSTGRES_USER $POSTGRES_DB > $BACKUP_DIR/postgres_$TIMESTAMP.sql
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап PostgreSQL создан: postgres_$TIMESTAMP.sql${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/postgres_$TIMESTAMP.sql" "PostgreSQL backup: postgres_$TIMESTAMP.sql")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/postgres_message_ids.txt
        send_telegram_message "✅ Бэкап PostgreSQL отправлен"
    else
        echo -e "${RED}Ошибка отправки PostgreSQL в Telegram${NC}"
        send_telegram_message "❌ Ошибка отправки PostgreSQL"
    fi
else
    echo -e "${RED}Ошибка создания бэкапа PostgreSQL${NC}"
    send_telegram_message "❌ Ошибка создания PostgreSQL"
    exit 1
fi

docker cp redis:/data/dump.rdb $BACKUP_DIR/redis_$TIMESTAMP.rdb
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап Redis создан: redis_$TIMESTAMP.rdb${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/redis_$TIMESTAMP.rdb" "Redis backup: redis_$TIMESTAMP.rdb")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/redis_message_ids.txt
        send_telegram_message "✅ Бэкап Redis отправлен"
    else
        echo -e "${RED}Ошибка отправки Redis в Telegram${NC}"
        send_telegram_message "❌ Ошибка отправки Redis"
    fi
else
    echo -e "${RED}Ошибка создания бэкапа Redis${NC}"
    send_telegram_message "❌ Ошибка создания Redis"
    exit 1
fi

echo "Удаляем старые бэкапы из Telegram (старше 4 недель)..."
delete_old_telegram_messages "postgres"
delete_old_telegram_messages "redis"

echo "Удаляем локальные бэкапы старше 4 недель..."
find $BACKUP_DIR -type f -name "*.sql" -mtime +28 -delete
find $BACKUP_DIR -type f -name "*.rdb" -mtime +28 -delete

echo -e "${GREEN}Бэкапы завершены!${NC}"
send_telegram_message "🎉 Бэкапы завершены"
EOF

# Создание скрипта обновления
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

echo -e "${GREEN}Запускаем сервисы...${NC}"
docker-compose up -d
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Обновление завершено!${NC}"
    send_telegram "🎉 Обновление завершено"
else
    echo -e "${RED}Ошибка запуска сервисов${NC}"
    send_telegram "❌ Ошибка запуска сервисов"
    exit 1
fi
EOF

# Настройка прав и cron
echo "Настраиваем бэкапы и автообновление..."
chmod +x /root/backup-n8n.sh
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/backup-n8n.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

# Финальный вывод
echo -e "${GREEN}Установка завершена!${NC}"
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Доступ к pgAdmin: https://pgadmin.$DOMAIN_NAME"
echo "Доступ к PostgreSQL: pg.$DOMAIN_NAME:5432 (psql -h pg.$DOMAIN_NAME -U $POSTGRES_USER -d n8n)"
echo "Логин n8n: $N8N_BASIC_AUTH_USER"
echo "Логин pgAdmin: $PGADMIN_EMAIL"
echo "Пароли: [скрыты]"
echo "Папка файлов: /root/n8n/local-files (в n8n: /files/)"
echo "Папка бэкапов: /root/n8n/backups"
echo "Логи: /root/n8n/*.log"
echo "Бэкапы: каждую субботу в 23:00, Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo "Обновления: каждое воскресенье в 00:00"
echo -e "${GREEN}Проверка ошибок:${NC}"
echo "1. Логи: docker logs traefik, docker logs n8n, docker logs postgres, docker logs pgadmin, docker logs redis"
echo "2. Статус: docker ps"
echo "3. Маршруты Traefik: curl http://localhost:8080/api/http/routers"
echo "4. Тест доступа: curl -I https://$SUBDOMAIN.$DOMAIN_NAME"
echo -e "${RED}Если 404, проверьте DNS (nslookup $SUBDOMAIN.$DOMAIN_NAME) и логи Traefik${NC}"
