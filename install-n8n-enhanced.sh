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

# Запрос данных у пользователя
get_user_input() {
    echo -e "${YELLOW}Введите параметры для установки:${NC}"
    read -p "Домен (например, example.com): " DOMAIN_NAME
    read -p "Поддомен для n8n (по умолчанию n8n): " SUBDOMAIN
    SUBDOMAIN=${SUBDOMAIN:-n8n}
    read -p "Логин для n8n: " N8N_BASIC_AUTH_USER
    read -s -p "Пароль для n8n: " N8N_BASIC_AUTH_PASSWORD
    echo
    read -p "Email для SSL: " SSL_EMAIL
    read -p "Часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE

    # Параметры PostgreSQL
    echo -e "\n${YELLOW}Настройки PostgreSQL:${NC}"
    read -p "Пользователь PostgreSQL (по умолчанию n8n): " DB_USER
    DB_USER=${DB_USER:-n8n}
    read -s -p "Пароль PostgreSQL: " DB_PASSWORD
    echo
    read -p "Имя базы данных (по умолчанию n8n): " DB_NAME
    DB_NAME=${DB_NAME:-n8n}

    # Параметры Redis
    echo -e "\n${YELLOW}Настройки Redis:${NC}"
    read -s -p "Пароль Redis: " REDIS_PASSWORD
    echo

    # Параметры pgAdmin
    echo -e "\n${YELLOW}Настройки pgAdmin:${NC}"
    read -p "Email для pgAdmin: " PGADMIN_EMAIL
    read -s -p "Пароль для pgAdmin: " PGADMIN_PASSWORD
    echo

    # Параметры Telegram для бэкапов
    echo -e "\n${YELLOW}Настройки Telegram для бэкапов:${NC}"
    read -p "Токен Telegram бота: " TELEGRAM_BOT_TOKEN
    read -p "ID чата Telegram: " TELEGRAM_CHAT_ID
}

# Установка зависимостей
install_dependencies() {
    log "Обновляем пакеты..."
    apt update && apt upgrade -y
    check_error "Ошибка обновления пакетов"

    log "Устанавливаем необходимые пакеты..."
    apt install -y curl software-properties-common ca-certificates \
                  apt-transport-https git jq net-tools
    check_error "Ошибка установки пакетов"
}

# Установка Docker и Docker Compose
install_docker() {
    log "Устанавливаем Docker..."
    # Удаляем старые версии
    apt remove -y docker docker-engine docker.io containerd runc

    # Устанавливаем зависимости
    apt install -y ca-certificates curl gnupg lsb-release

    # Добавляем GPG ключ Docker
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    check_error "Ошибка добавления GPG ключа Docker"

    # Добавляем репозиторий Docker
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    check_error "Ошибка добавления репозитория Docker"

    # Устанавливаем Docker
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    check_error "Ошибка установки Docker"

    # Установка Docker Compose
install_docker_compose() {
    log "Устанавливаем Docker Compose..."
    
    # Проверяем, установлен ли уже docker-compose
    if [ -x "$(command -v docker-compose)" ]; then
        log "Docker Compose уже установлен, пропускаем установку"
        return 0
    fi

    # Устанавливаем последнюю версию Docker Compose
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # Создаем симлинк только если он не существует
    if [ ! -f /usr/bin/docker-compose ]; then
        ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi
    
    # Проверяем установку
    docker-compose --version
    check_error "Ошибка установки Docker Compose"
}
    
# Настройка окружения
setup_environment() {
    log "Создаем необходимые директории..."
    mkdir -p /root/n8n/{.n8n,local-files,postgres-data,redis-data,backups,initdb}
    chmod -R 777 /root/n8n/local-files
    
    # Очищаем предыдущие данные PostgreSQL (если есть)
    rm -rf /root/n8n/postgres-data/*
    
    # Создаем скрипт инициализации PostgreSQL
    cat > /root/n8n/initdb/init.sql << EOF
CREATE DATABASE ${DB_NAME};
CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASSWORD}';
ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF
    
    # Устанавливаем правильные права
    chown -R 999:999 /root/n8n/postgres-data
    chmod -R 750 /root/n8n/postgres-data
}

# Создание docker-compose.yml
create_docker_compose() {
    log "Создаем docker-compose.yml..."
    cat > /root/docker-compose.yml << EOF


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
      - \${DATA_FOLDER}/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  postgres:
    image: postgres:14-alpine
    restart: always
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_HOST_AUTH_METHOD: trust
    volumes:
      - \${DATA_FOLDER}/postgres-data:/var/lib/postgresql/data
      - \${DATA_FOLDER}/initdb:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 10s
      retries: 20

  redis:
    image: redis:6-alpine
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - \${DATA_FOLDER}/redis-data:/data
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
      - traefik.http.routers.pgadmin.rule=Host(\`pgadmin.\${DOMAIN_NAME}\`)
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
      - traefik.http.routers.n8n.rule=Host(\`\${SUBDOMAIN}.\${DOMAIN_NAME}\`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n.headers.SSLHost=\${DOMAIN_NAME}
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${DB_NAME}
      - DB_POSTGRESDB_USER=\${DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASSWORD}
      - N8N_REDIS_HOST=redis
      - N8N_REDIS_PASSWORD=\${REDIS_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - N8N_HOST=\${SUBDOMAIN}.\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://\${SUBDOMAIN}.\${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
    volumes:
      - \${DATA_FOLDER}/.n8n:/home/node/.n8n
      - \${DATA_FOLDER}/local-files:/files
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
}

# Создание .env файла
create_env_file() {
    log "Создаем .env файл..."
    cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=${DOMAIN_NAME}
SUBDOMAIN=${SUBDOMAIN}
N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
SSL_EMAIL=${SSL_EMAIL}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
REDIS_PASSWORD=${REDIS_PASSWORD}
PGADMIN_EMAIL=${PGADMIN_EMAIL}
PGADMIN_PASSWORD=${PGADMIN_PASSWORD}
EOF
}

# Проверка состояния PostgreSQL
check_postgres() {
    log "Проверяем состояние PostgreSQL..."
    local timeout=120
    local start_time=$(date +%s)
    
    while ! docker exec root-postgres-1 pg_isready -U ${DB_USER} -d ${DB_NAME} >/dev/null 2>&1; do
        if [ $(($(date +%s) - start_time)) -gt $timeout ]; then
            log "Таймаут ожидания PostgreSQL"
            docker logs root-postgres-1
            return 1
        fi
        sleep 5
        log "Ожидаем запуска PostgreSQL..."
    done
    
    log "PostgreSQL готов к работе"
    return 0
}

# Запуск сервисов
start_services() {
    log "Запускаем сервисы..."
    cd /root
    
    # Временный запуск без healthcheck для инициализации PostgreSQL
    sed -i '/condition: service_healthy/d' docker-compose.yml
    docker-compose up -d postgres
    
    # Ждем инициализации PostgreSQL
    check_postgres || {
        log "Проблемы с PostgreSQL, пытаемся восстановить..."
        docker-compose stop postgres
        docker-compose rm -f postgres
        rm -rf /root/n8n/postgres-data/*
        docker-compose up -d postgres
        check_postgres || {
            echo -e "${RED}Не удалось запустить PostgreSQL${NC}"
            exit 1
        }
    }
    
    # Полный запуск всех сервисов
    docker-compose up -d
    
    # Исправляем права доступа для n8n
    log "Исправляем права доступа..."
    docker-compose stop n8n
    docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/n8n -R node:node /home/node/.n8n
    docker-compose up -d
    
    # Включаем аутентификацию PostgreSQL
    docker exec root-postgres-1 psql -U ${DB_USER} -d ${DB_NAME} -c "ALTER SYSTEM SET host_auth_method TO 'md5';"
    docker-compose restart postgres
}

# Настройка автообновления
setup_auto_update() {
    log "Настраиваем автообновление..."
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
    (crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh >> /root/n8n-update.log 2>&1") | crontab -
}

# Настройка бэкапов
setup_backups() {
    log "Настраиваем систему бэкапов..."
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
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \\
        -d chat_id="${TELEGRAM_CHAT_ID}" \\
        -d text="\$message" \\
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
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \\
            -F chat_id="${TELEGRAM_CHAT_ID}" \\
            -F document=@"\$BACKUP_FILE" \\
            -F caption="Бэкап n8n от \$DATE" \\
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
    (crontab -l 2>/dev/null; echo "0 23 * * 6 /root/n8n-backup.sh >> /root/n8n-backup.log 2>&1") | crontab -
}

# Вывод информации после установки
show_summary() {
    echo -e "${GREEN}\nУстановка завершена успешно!${NC}"
    echo -e "${YELLOW}Доступ к сервисам:${NC}"
    echo -e "n8n: ${GREEN}https://${SUBDOMAIN}.${DOMAIN_NAME}${NC}"
    echo -e "pgAdmin: ${GREEN}https://pgadmin.${DOMAIN_NAME}${NC}"
    echo -e "Логин pgAdmin: ${YELLOW}${PGADMIN_EMAIL}${NC}"
    echo -e "Пароль pgAdmin: [скрыт]"
    echo -e "\n${YELLOW}Данные PostgreSQL:${NC}"
    echo -e "Хост: ${GREEN}postgres${NC}"
    echo -e "База: ${GREEN}${DB_NAME}${NC}"
    echo -e "Пользователь: ${GREEN}${DB_USER}${NC}"
    echo -e "Пароль: [скрыт]"
    echo -e "\n${YELLOW}Автоматизация:${NC}"
    echo -e "Обновление: каждое воскресенье в 00:00"
    echo -e "Бэкапы: каждую субботу в 23:00 (Telegram уведомления)"
    echo -e "\n${GREEN}Готово!${NC}"
}

# Главная функция
main() {
    echo -e "${GREEN}=== Установка n8n с PostgreSQL, Redis и pgAdmin ===${NC}"
    
    # Проверка прав root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Запустите скрипт с правами root: sudo ./install-n8n.sh${NC}"
        exit 1
    fi

    get_user_input
    install_dependencies
    install_docker
    setup_environment
    create_docker_compose
    create_env_file
    start_services
    setup_auto_update
    setup_backups
    show_summary
}

# Запуск главной функции
main
