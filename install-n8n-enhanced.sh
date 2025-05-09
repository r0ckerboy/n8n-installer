#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Начинаем установку n8n с SQLite (без PostgreSQL и Redis)...${NC}"

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
mkdir -p /root/n8n/backups
mkdir -p /root/n8n/pgadmin
chmod -R 777 /root/n8n/local-files # Разрешаем чтение/запись
chmod -R 700 /root/n8n/backups # Ограничиваем доступ к бэкапам
chmod -R 777 /root/n8n/pgadmin # Разрешаем доступ для pgAdmin

# 9. Исправление прав доступа для n8n заранее
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

# 10. Создание docker-compose.yml с n8n и Traefik
echo "Создаем docker-compose.yml..."
cat > /root/docker-compose.yml << 'EOF'
version: '3.8'
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
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_LOG_LEVEL=debug
    volumes:
      - ${DATA_FOLDER}/.n8n:/home/node/.n8n
      - ${DATA_FOLDER}/local-files:/files
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678"]
      interval: 10s
      timeout: 5s
      retries: 5
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
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
EOF

# 11. Проверка портов
echo "Проверяем доступность портов 443 и 5678..."
if netstat -tuln | grep -E '443|5678'; then
    echo -e "${RED}Порты 443 или 5678 заняты!${NC}"
    echo "Детали занятых портов:"
    lsof -i :443
    lsof -i :5678
    echo -e "${RED}Для освобождения портов выполните следующие действия:${NC}"
    echo "1. Найдите PID процессов, использующих порты, с помощью 'lsof -i :443' и 'lsof -i :5678'."
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

# 12. Запрос пользовательских данных
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
read -p "Введите ваш email для SSL: " SSL_EMAIL
read -p "Введите ваш часовой пояс (например, Europe/Moscow): " GENERIC_TIMEZONE
read -p "Введите Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Введите Telegram Chat ID: " TELEGRAM_CHAT_ID

# 13. Создание .env файла
echo "Создаем .env файл..."
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_DEFAULT_PASSWORD=$PGADMIN_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

# 14. Запуск сервисов с исправлением прав
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
    echo "Логи n8n для диагностики:"
    docker logs root_n8n_1
    exit 1
fi

# 15. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
docker ps -a
echo "Если контейнеры не запущены, проверьте логи с помощью: docker logs <container_name>"

# 16. Проверка доступности n8n
echo "Проверяем доступность n8n..."
sleep 15 # Даем время на запуск
curl -s -f http://127.0.0.1:5678 > /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}n8n доступен на http://127.0.0.1:5678${NC}"
else
    echo -e "${RED}Ошибка: n8n не отвечает на http://127.0.0.1:5678${NC}"
    echo "Логи n8n:"
    docker logs root_n8n_1
    echo "Логи Traefik:"
    docker logs root_traefik_1
    exit 1
fi

# 17. Проверка логов Traefik
echo "Проверяем логи Traefik для диагностики..."
docker logs root_traefik_1 | grep -i error
if [ $? -eq 0 ]; then
    echo -e "${RED}Обнаружены ошибки в логах Traefik, проверьте выше${NC}"
fi

# 18. Создание скрипта бэкапа
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

# Бэкап SQLite
echo "Создаем бэкап SQLite..."
cp /root/n8n/.n8n/database.sqlite $BACKUP_DIR/n8n_sqlite_$TIMESTAMP.sqlite
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Бэкап SQLite успешно создан: n8n_sqlite_$TIMESTAMP.sqlite${NC}"
    message_id=$(send_telegram_file "$BACKUP_DIR/n8n_sqlite_$TIMESTAMP.sqlite" "SQLite backup: n8n_sqlite_$TIMESTAMP.sqlite")
    if [ -n "$message_id" ]; then
        echo "$(date +%Y-%m-%d) $message_id" >> /root/n8n/backups/sqlite_message_ids.txt
        send_telegram_message "✅ Бэкап SQLite отправлен в Telegram: n8n_sqlite_$TIMESTAMP.sqlite"
    else
        echo -e "${RED}Ошибка при отправке бэкапа SQLite в Telegram${NC}"
        send_telegram_message "❌ Ошибка при отправке бэкапа SQLite в Telegram"
    fi
else
    echo -e "${RED}Ошибка при создании бэкапа SQLite${NC}"
    send_telegram_message "❌ Ошибка при создании бэкапа SQLite"
    exit 1
fi

# Удаление старых сообщений в Telegram
echo "Удаляем старые бэкапы из Telegram (старше 4 недель)..."
delete_old_telegram_messages "sqlite"

# Удаление старых бэкапов локально (старше 4 недель)
echo "Удаляем локальные бэкапы старше 4 недель..."
find $BACKUP_DIR -type f -name "*.sqlite" -mtime +28 -delete

echo -e "${GREEN}Бэкапы успешно созданы и отправлены в Telegram!${NC}"
send_telegram_message "🎉 Бэкапы успешно завершены и отправлены в Telegram!"
EOF

# 19. Создание скрипта обновления с бэкапом
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
send_telegram "🟢 Начинаем обновление n8n..."
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
    send_telegram "🎉 Обновление n8n успешно завершено!"
else
    echo -e "${RED}Ошибка при запуске сервисов${NC}"
    send_telegram "❌ Ошибка при запуске сервисов"
    exit 1
fi
EOF

# 20. Настройка прав и cron
echo "Настраиваем бэкапы и автообновление..."
chmod +x /root/backup-n8n.sh
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 23 * * 6 /root/backup-n8n.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

echo -e "${GREEN}Установка n8n завершена!${NC}"
echo "Доступ к n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Логин n8n: $N8N_BASIC_AUTH_USER"
echo "Пароль: [скрыт]"
echo "Папка для файлов: /root/n8n/local-files (доступна в n8n как /files/)"
echo "Папка для бэкапов: /root/n8n/backups"
echo "Бэкапы настроены на каждую субботу в 23:00, отправка в Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo "Автообновление настроено на каждое воскресенье в 00:00, с удалением старых контейнеров n8n"
echo "Уведомления и бэкапы отправляются в Telegram (Chat ID: $TELEGRAM_CHAT_ID)"
echo -e "${GREEN}Примечание: n8n использует SQLite, хранящуюся в /root/n8n/.n8n/database.sqlite${NC}"
