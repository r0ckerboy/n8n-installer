#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для логирования
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Функция для проверки ошибок
check_error() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка: $1${NC}"
        exit 1
    fi
}

echo -e "${GREEN}Начинаем установку n8n с PostgreSQL, Redis и pgAdmin...${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# 1. Обновление индексов пакетов
log "Обновляем индексы пакетов..."
apt update
check_error "Не удалось обновить индексы пакетов"

# 2. Установка дополнительных пакетов
log "Устанавливаем необходимые пакеты..."
apt install -y curl software-properties-common ca-certificates apt-transport-https git jq
check_error "Не удалось установить дополнительные пакеты"

# 3. Импорт GPG-ключа Docker
log "Импортируем GPG-ключ Docker..."
wget -O- https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null
check_error "Не удалось импортировать GPG-ключ Docker"

# 4. Добавление репозитория Docker
log "Добавляем репозиторий Docker..."
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
check_error "Не удалось добавить репозиторий Docker"

# 5. Повторное обновление индексов
log "Обновляем индексы пакетов после добавления репозитория..."
apt update
check_error "Не удалось обновить индексы пакетов"

# 6. Установка Docker
log "Устанавливаем Docker..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
check_error "Не удалось установить Docker"

# 7. Установка Docker Compose
log "Устанавливаем Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
check_error "Не удалось установить Docker Compose"

# 8. Создание директорий
log "Создаем необходимые директории..."
mkdir -p /root/n8n/{.n8n,local-files,postgres-data,redis-data,backups}
chmod -R 777 /root/n8n/local-files
check_error "Не удалось создать директории"

# 9. Создание docker-compose.yml
log "Создаем docker-compose.yml..."
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

  postgres:
    image: postgres:14
    restart: always
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - ${DATA_FOLDER}/postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:6
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ${DATA_FOLDER}/redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  pgadmin:
    image: dpage/pgadmin4
    restart: always
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASSWORD}
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(`pgadmin.${DOMAIN_NAME}`)
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.entrypoints=websecure
      - traefik.http.routers.pgadmin.tls.certresolver=mytlschallenge
    depends_on:
      - postgres

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
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${DB_NAME}
      - DB_POSTGRESDB_USER=${DB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_PASSWORD}
      - N8N_REDIS_HOST=redis
      - N8N_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${SUBDOMAIN}.${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    volumes:
      - ${DATA_FOLDER}/.n8n:/home/node/.n8n
      - ${DATA_FOLDER}/local-files:/files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF

# 10. Запрос пользовательских данных
log "Настройка параметров установки..."
read -p "Введите ваш домен (например, example.com): " DOMAIN_NAME
read -p "Введите поддомен для n8n (по умолчанию n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Введите логин для n8n: " N8N_BASIC_AUTH_USER
read -s -p "Введите пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Введите ваш email для SSL: " SSL_EMAIL
read -p "Введите ваш часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE

# Параметры PostgreSQL
read -p "Введите имя пользователя PostgreSQL (по умолчанию n8n): " DB_USER
DB_USER=${DB_USER:-n8n}
read -s -p "Введите пароль PostgreSQL: " DB_PASSWORD
echo
read -p "Введите имя базы данных PostgreSQL (по умолчанию n8n): " DB_NAME
DB_NAME=${DB_NAME:-n8n}

# Параметры Redis
read -s -p "Введите пароль для Redis: " REDIS_PASSWORD
echo

# Параметры pgAdmin
read -p "Введите email для pgAdmin: " PGADMIN_EMAIL
read -s -p "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo

# 11. Создание .env файла
log "Создаем .env файл..."
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
REDIS_PASSWORD=$REDIS_PASSWORD
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
EOF

# 12. Удаление старых контейнеров n8n (если есть)
log "Проверяем и удаляем старые контейнеры n8n..."
OLD_CONTAINERS=$(docker ps -a --filter "ancestor=n8nio/n8n" --format "{{.ID}}")
if [ ! -z "$OLD_CONTAINERS" ]; then
    log "Найдены старые контейнеры n8n, удаляем..."
    docker stop $OLD_CONTAINERS
    docker rm $OLD_CONTAINERS
fi

# 13. Запуск сервисов
log "Запускаем сервисы..."
cd /root
docker-compose up -d
check_error "Не удалось запустить сервисы"

# 14. Исправление прав доступа
log "Исправляем права доступа для n8n..."
docker-compose stop n8n
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/n8n -R node:node /home/node/.n8n
log "Перезапускаем n8n..."
docker-compose up -d

# 15. Создание скрипта для автообновления
log "Создаем скрипт обновления n8n..."
cat > /root/update-n8n.sh << 'EOF'
#!/bin/bash

# Логирование
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "Начинаем обновление n8n..."

# Останавливаем и удаляем старые контейнеры n8n
OLD_CONTAINERS=$(docker ps -a --filter "ancestor=n8nio/n8n" --format "{{.ID}}")
if [ ! -z "$OLD_CONTAINERS" ]; then
    log "Найдены старые контейнеры n8n, удаляем..."
    docker stop $OLD_CONTAINERS
    docker rm $OLD_CONTAINERS
fi

# Обновляем контейнеры
cd /root
docker-compose pull
docker-compose down
docker-compose up -d

# Исправляем права доступа
docker-compose stop n8n
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/n8n -R node:node /home/node/.n8n
docker-compose up -d

log "Обновление n8n завершено!"
EOF

chmod +x /root/update-n8n.sh

# 16. Настройка автообновления через cron
log "Настраиваем автообновление на воскресенье в 00:00..."
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh >> /root/n8n-update.log 2>&1") | crontab -

# 17. Создание скрипта для бэкапа
log "Создаем скрипт бэкапа..."
read -p "Введите токен Telegram бота: " TELEGRAM_BOT_TOKEN
read -p "Введите ID чата Telegram для уведомлений: " TELEGRAM_CHAT_ID

cat > /root/n8n-backup.sh << EOF
#!/bin/bash

# Параметры
BACKUP_DIR="/root/n8n/backups"
DATE=\$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="\$BACKUP_DIR/n8n-backup-\$DATE.tar.gz"
LOG_FILE="/root/n8n-backup.log"
MAX_BACKUPS=4

# Логирование
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] \$1" >> \$LOG_FILE
}

# Отправка сообщения в Telegram
send_telegram() {
    local message="\$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="\$message" \
        >> \$LOG_FILE 2>&1
}

log "Начинаем бэкап n8n..."

# Создаем бэкап
tar -czvf \$BACKUP_FILE /root/n8n/.n8n /root/n8n/postgres-data /root/n8n/redis-data >> \$LOG_FILE 2>&1

if [ \$? -eq 0 ]; then
    log "Бэкап успешно создан: \$BACKUP_FILE"
    send_telegram "✅ Бэкап n8n успешно создан: \$BACKUP_FILE"
    
    # Отправка бэкапа в Telegram (если меньше 50MB)
    BACKUP_SIZE=\$(stat -c%s "\$BACKUP_FILE")
    if [ \$BACKUP_SIZE -lt 50000000 ]; then
        log "Пытаемся отправить бэкап в Telegram..."
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"\$BACKUP_FILE" \
            -F caption="Бэкап n8n от \$DATE" \
            >> \$LOG_FILE 2>&1
        
        if [ \$? -eq 0 ]; then
            log "Бэкап успешно отправлен в Telegram"
        else
            log "Не удалось отправить бэкап в Telegram (слишком большой?)"
        fi
    else
        log "Бэкап слишком большой для отправки в Telegram (>50MB)"
        send_telegram "⚠ Бэкап слишком большой для отправки (>50MB). Скачайте его вручную с сервера."
    fi
    
    # Удаляем старые бэкапы
    BACKUP_COUNT=\$(ls -1 \$BACKUP_DIR/*.tar.gz 2>/dev/null | wc -l)
    if [ \$BACKUP_COUNT -gt \$MAX_BACKUPS ]; then
        log "Удаляем старые бэкапы..."
        ls -t \$BACKUP_DIR/*.tar.gz | tail -n +\$(expr \$MAX_BACKUPS + 1) | xargs rm -f
    fi
else
    log "Ошибка при создании бэкапа!"
    send_telegram "❌ Ошибка при создании бэкапа n8n! Проверьте лог: \$LOG_FILE"
    exit 1
fi

log "Бэкап завершен"
EOF

chmod +x /root/n8n-backup.sh

# 18. Настройка бэкапов через cron (каждую субботу в 23:00)
log "Настраиваем бэкапы каждую субботу в 23:00..."
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/n8n-backup.sh >> /root/n8n-backup.log 2>&1") | crontab -

# 19. Завершение установки
echo -e "${GREEN}\nУстановка завершена успешно!${NC}"
echo -e "${YELLOW}Доступ к сервисам:${NC}"
echo -e "n8n: ${GREEN}https://$SUBDOMAIN.$DOMAIN_NAME${NC}"
echo -e "pgAdmin: ${GREEN}https://pgadmin.$DOMAIN_NAME${NC}"
echo -e "Логин pgAdmin: ${YELLOW}$PGADMIN_EMAIL${NC}"
echo -e "Пароль pgAdmin: [скрыт]"
echo -e "\n${YELLOW}Данные для подключения к PostgreSQL:${NC}"
echo -e "Хост: ${GREEN}postgres${NC}"
echo -e "База данных: ${GREEN}$DB_NAME${NC}"
echo -e "Пользователь: ${GREEN}$DB_USER${NC}"
echo -e "Пароль: [скрыт]"
echo -e "\n${YELLOW}Папки:${NC}"
echo -e "Данные n8n: ${GREEN}/root/n8n/.n8n${NC}"
echo -e "Файлы: ${GREEN}/root/n8n/local-files${NC}"
echo -e "Данные PostgreSQL: ${GREEN}/root/n8n/postgres-data${NC}"
echo -e "Данные Redis: ${GREEN}/root/n8n/redis-data${NC}"
echo -e "Бэкапы: ${GREEN}/root/n8n/backups${NC}"
echo -e "\n${YELLOW}Автоматизация:${NC}"
echo -e "Обновление: каждое воскресенье в 00:00"
echo -e "Бэкапы: каждую субботу в 23:00 с отправкой в Telegram"
