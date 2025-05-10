#!/bin/bash

# Цветной вывод
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Этот скрипт должен выполняться от имени root${NC}"
    exit 1
fi

# 2. Запрос пользовательских данных
echo "Настройка установки n8n, Qdrant и pgAdmin..."
read -p "Введите домен (например, nightcity2077.ru): " DOMAIN_NAME
read -p "Введите email для SSL и pgAdmin (например, admin@nightcity2077.ru): " EMAIL
read -sp "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo
read -p "Введите Telegram Bot Token (например, 123456:ABC-DEF): " TELEGRAM_TOKEN
read -p "Введите Telegram Chat ID (например, -123456789): " TELEGRAM_CHAT_ID

# Установка поддоменов по умолчанию
SUBDOMAIN=n8n
QDRANT_SUBDOMAIN=qdrant

# Проверка ввода
if [ -z "$DOMAIN_NAME" ] || [ -z "$EMAIL" ] || [ -z "$PGADMIN_PASSWORD" ] || [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo -e "${RED}Все поля обязательны${NC}"
    exit 1
fi

# 3. Обновление системы
echo "Обновляем систему..."
# Проверка доступности репозиториев
if ! ping -c 1 archive.ubuntu.com > /dev/null 2>&1; then
    echo -e "${RED}Репозитории Ubuntu недоступны${NC}"
    exit 1
fi
# Выполнение с таймаутом и повторами
timeout 300 apt update -o Acquire::Retries=3 > /root/update.log 2>&1 &
wait $!
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка обновления системы (см. /root/update.log)${NC}"
    exit 1
fi
timeout 600 apt upgrade -y -o Acquire::Retries=3 >> /root/update.log 2>&1 &
wait $!
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка обновления системы (см. /root/update.log)${NC}"
    exit 1
fi
echo -e "${GREEN}Система обновлена${NC}"

# 4. Установка утилит
echo "Устанавливаем необходимые утилиты..."
apt install -y curl nano dnsutils python3 python3-pip > /dev/null 2>&1
pip3 install python-telegram-bot --break-system-packages > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка установки утилит${NC}"
    exit 1
else
    echo -e "${GREEN}Утилиты установлены${NC}"
fi

# 5. Установка Docker
echo "Устанавливаем Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh > /dev/null 2>&1
    sh get-docker.sh > /dev/null 2>&1
    rm get-docker.sh
    usermod -aG docker $USER > /dev/null 2>&1
    echo -e "${GREEN}Docker установлен${NC}"
else
    echo -e "${GREEN}Docker уже установлен${NC}"
fi

# 6. Установка Docker Compose
echo "Устанавливаем Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose > /dev/null 2>&1
    chmod +x /usr/local/bin/docker-compose > /dev/null 2>&1
    echo -e "${GREEN}Docker Compose установлен${NC}"
else
    echo -e "${GREEN}Docker Compose уже установлен${NC}"
fi

# 7. Установка таймзоны
echo "Устанавливаем таймзону Europe/Moscow..."
timedatectl set-timezone Europe/Moscow
echo -e "${GREEN}Таймзона установлена${NC}"

# 8. Создание директорий
echo "Создаем необходимые директории..."
mkdir -p /root/n8n/{postgres,redis,letsencrypt,qdrant,backups} > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания директорий${NC}"
    exit 1
else
    echo -e "${GREEN}Директории созданы${NC}"
fi

# 9. Генерация безопасных паролей
echo "Генерируем безопасные пароли..."
POSTGRES_PASSWORD=$(openssl rand -base64 12)
REDIS_PASSWORD=$(openssl rand -base64 12)
N8N_AUTH_PASSWORD=$(openssl rand -base64 12)

# 10. Создание или обновление .env файла
echo "Создаем/обновляем файл .env..."
cat > /root/.env <<EOL
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
REDIS_PASSWORD=${REDIS_PASSWORD}
SUBDOMAIN=${SUBDOMAIN}
DOMAIN_NAME=${DOMAIN_NAME}
EMAIL=${EMAIL}
PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}
QDRANT_PORT=6333
QDRANT_SUBDOMAIN=${QDRANT_SUBDOMAIN}
DATA_FOLDER=/root/n8n
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=${N8N_AUTH_PASSWORD}
TELEGRAM_TOKEN=${TELEGRAM_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TZ=Europe/Moscow
EOL
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания .env файла${NC}"
    exit 1
else
    echo -e "${GREEN}.env файл создан${NC}"
fi

# 11. Загрузка переменных окружения
echo "Загружаем переменные окружения..."
source /root/.env
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$REDIS_PASSWORD" ]; then
    echo -e "${RED}Ошибка: переменные окружения не загружены${NC}"
    exit 1
else
    echo -e "${GREEN}Переменные окружения загружены${NC}"
fi

# 12. Проверка DNS
echo "Проверяем DNS записи..."
for domain in "${SUBDOMAIN}.${DOMAIN_NAME}" "pgadmin.${DOMAIN_NAME}" "${QDRANT_SUBDOMAIN}.${DOMAIN_NAME}"; do
    if ! dig +short "$domain" | grep -q "45.38.143.115"; then
        echo -e "${RED}DNS запись для $domain не указывает на 45.38.143.115${NC}"
        echo "Пожалуйста, обновите A-запись в панели управления доменом."
        exit 1
    else
        echo -e "${GREEN}DNS для $domain корректен${NC}"
    fi
done

# 13. Создание docker-compose.yml
echo "Создаем docker-compose.yml..."
cat > /root/docker-compose.yml <<EOL
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
      - "--certificatesresolvers.mytlschallenge.acme.email=\${EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "443:443"
    volumes:
      - \${DATA_FOLDER}/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - TZ=\${TZ}
    healthcheck:
      test: ["CMD", "traefik", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - n8n-network

  postgres:
    image: postgres:16
    restart: always
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=\${TZ}
    volumes:
      - \${DATA_FOLDER}/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "\${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - n8n-network

  redis:
    image: redis:7
    restart: always
    command: redis-server --requirepass \${REDIS_PASSWORD}
    environment:
      - TZ=\${TZ}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=\${SUBDOMAIN}.\${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=\${N8N_BASIC_AUTH_ACTIVE}
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - N8N_RUNNERS_ENABLED=true
      - TZ=\${TZ}
    volumes:
      - \${DATA_FOLDER}/.n8n:/home/node/.n8n
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(\`\${SUBDOMAIN}.\${DOMAIN_NAME}\`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    depends_on:
      - postgres
      - redis
    networks:
      - n8n-network

  pgadmin:
    image: dpage/pgadmin4
    restart: always
    ports:
      - "5050:80"
    environment:
      - PGADMIN_DEFAULT_EMAIL=\${EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_DEFAULT_PASSWORD}
      - TZ=\${TZ}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(\`pgadmin.\${DOMAIN_NAME}\`)
      - traefik.http.routers.pgadmin.entrypoints=websecure
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.tls.certresolver=mytlschallenge
    depends_on:
      - postgres
    mem_limit: 256m
    mem_reservation: 128m
    cpus: 0.25
    networks:
      - n8n-network

  qdrant:
    image: qdrant/qdrant:latest
    restart: always
    ports:
      - "\${QDRANT_PORT}:6333"
    volumes:
      - \${DATA_FOLDER}/qdrant:/qdrant/storage
    environment:
      - QDRANT__STORAGE__STORAGE_MODE=mmap
      - QDRANT__CLUSTER__ENABLED=false
      - QDRANT__SERVICE__HTTP_PORT=6333
      - TZ=\${TZ}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6333/readyz"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.qdrant.rule=Host(\`\${QDRANT_SUBDOMAIN}.\${DOMAIN_NAME}\`)
      - traefik.http.routers.qdrant.entrypoints=websecure
      - traefik.http.routers.qdrant.tls=true
      - traefik.http.routers.qdrant.tls.certresolver=mytlschallenge
      - traefik.http.services.qdrant.loadbalancer.server.port=6333
    mem_limit: 512m
    mem_reservation: 256m
    cpus: 0.5
    networks:
      - n8n-network

  telegram-bot:
    image: python:3.9-slim
    restart: always
    volumes:
      - \${DATA_FOLDER}/backups:/app/backups
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - TELEGRAM_TOKEN=\${TELEGRAM_TOKEN}
      - TELEGRAM_CHAT_ID=\${TELEGRAM_CHAT_ID}
      - TZ=\${TZ}
    working_dir: /app
    command: ["python3", "telegram_bot.py"]
    depends_on:
      - postgres
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
EOL
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания docker-compose.yml${NC}"
    exit 1
else
    echo -e "${GREEN}docker-compose.yml создан${NC}"
fi

# 14. Создание скрипта Telegram-бота
echo "Создаем скрипт Telegram-бота..."
cat > /root/n8n/telegram_bot.py <<EOL
import telegram
from telegram.ext import Application, CommandHandler
import os
import subprocess
import datetime

# Настройка Telegram-бота
TOKEN = os.getenv("TELEGRAM_TOKEN")
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")

async def start(update, context):
    await update.message.reply_text("Бот для управления n8n и Qdrant. Доступные команды:\n/backup - Создать бэкап PostgreSQL\n/logs - Показать последние логи")

async def backup(update, context):
    if str(update.message.chat_id) != CHAT_ID:
        await update.message.reply_text("Доступ запрещён")
        return
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_file = f"/app/backups/n8n_backup_{timestamp}.sql"
    try:
        subprocess.run(["docker", "exec", "root-postgres-1", "pg_dump", "-U", "n8n", "n8n"], capture_output=True, text=True, check=True)
        with open(backup_file, "w") as f:
            f.write(subprocess.run(["docker", "exec", "root-postgres-1", "pg_dump", "-U", "n8n", "n8n"], capture_output=True, text=True, check=True).stdout)
        await context.bot.send_document(chat_id=CHAT_ID, document=open(backup_file, "rb"), caption=f"Бэкап PostgreSQL {timestamp}")
    except Exception as e:
        await update.message.reply_text(f"Ошибка создания бэкапа: {str(e)}")

async def logs(update, context):
    if str(update.message.chat_id) != CHAT_ID:
        await update.message.reply_text("Доступ запрещён")
        return
    services = ["n8n", "qdrant", "pgadmin", "traefik"]
    for service in services:
        try:
            logs = subprocess.run(["docker", "logs", f"root-{service}-1", "--tail", "50"], capture_output=True, text=True, check=True).stdout
            await update.message.reply_text(f"Логи {service}:\n{logs[:4000]}")
        except Exception as e:
            await update.message.reply_text(f"Ошибка получения логов {service}: {str(e)}")

def main():
    application = Application.builder().token(TOKEN).build()
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("backup", backup))
    application.add_handler(CommandHandler("logs", logs))
    application.run_polling()

if __name__ == "__main__":
    main()
EOL
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания telegram_bot.py${NC}"
    exit 1
else
    echo -e "${GREEN}telegram_bot.py создан${NC}"
fi

# 15. Создание скрипта бэкапа
echo "Создаем скрипт бэкапа..."
cat > /root/n8n/backup.sh <<EOL
#!/bin/bash
source /root/.env
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="/root/n8n/backups/n8n_backup_\${TIMESTAMP}.sql"
docker exec root-postgres-1 pg_dump -U n8n n8n > \${BACKUP_FILE}
curl -F "chat_id=\${TELEGRAM_CHAT_ID}" -F document=@\${BACKUP_FILE} "https://api.telegram.org/bot\${TELEGRAM_TOKEN}/sendDocument"
EOL
chmod +x /root/n8n/backup.sh
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания backup.sh${NC}"
    exit 1
else
    echo -e "${GREEN}backup.sh создан${NC}"
fi

# 16. Создание скрипта обновления
echo "Создаем скрипт обновления..."
cat > /root/n8n/update.sh <<EOL
#!/bin/bash
cd /root
docker-compose down
docker pull n8nio/n8n
docker pull qdrant/qdrant:latest
docker-compose up -d
EOL
chmod +x /root/n8n/update.sh
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания update.sh${NC}"
    exit 1
else
    echo -e "${GREEN}update.sh создан${NC}"
fi

# 17. Настройка cron для бэкапов и обновлений
echo "Настраиваем cron..."
(crontab -l 2>/dev/null; echo "0 2 * * 6 /root/n8n/backup.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 3 * * 0 /root/n8n/update.sh") | crontab -
echo -e "${GREEN}Cron настроен (бэкапы по субботам 02:00, обновления по воскресеньям 03:00)${NC}"

# 18. Исправление настроек Redis
echo "Исправляем настройки Redis..."
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
sysctl vm.overcommit_memory=1 > /dev/null 2>&1
echo -e "${GREEN}Настройки Redis исправлены${NC}"

# 19. Запуск Docker Compose
echo "Запускаем Docker Compose..."
docker-compose up -d > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка запуска Docker Compose${NC}"
    docker-compose logs
    exit 1
else
    echo -e "${GREEN}Docker Compose запущен${NC}"
fi

# 20. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
sleep 5
docker ps -a
if [ $(docker ps -q | wc -l) -ne 7 ]; then
    echo -e "${RED}Не все контейнеры запущены${NC}"
    docker ps -a
    exit 1
else
    echo -e "${GREEN}Все контейнеры запущены${NC}"
fi

# 21. Проверка готовности сервисов
echo "Ожидаем готовности сервисов..."
timeout=120
elapsed=0
for service in n8n pgadmin qdrant; do
    case $service in
        n8n)
            port=5678
            endpoint="/healthz"
            ;;
        pgadmin)
            port=5050
            endpoint=""
            ;;
        qdrant)
            port=6333
            endpoint="/readyz"
            ;;
    esac
    echo "Проверяем $service на порту $port..."
    while ! curl -s -f http://127.0.0.1:$port$endpoint > /dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
            echo -e "${RED}Ошибка: $service не запустился за $timeout секунд${NC}"
            echo "Логи $service:"
            docker logs root-${service}-1 2>/dev/null || echo "Контейнер root-${service}-1 отсутствует"
            exit 1
        fi
        echo "Ожидаем $service ($elapsed/$timeout секунд)..."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo -e "${GREEN}service готов${NC}"
    elapsed=0
done

# 22. Проверка подключения к PostgreSQL
echo "Проверяем подключение к PostgreSQL..."
docker exec root-postgres-1 psql -U ${POSTGRES_USER} -d n8n -c "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к PostgreSQL${NC}"
    echo "Логи PostgreSQL:"
    docker logs root-postgres-1
    exit 1
else
    echo -e "${GREEN}Подключение к PostgreSQL успешно${NC}"
fi

# 23. Проверка подключения к Redis
echo "Проверяем подключение к Redis..."
docker exec root-redis-1 redis-cli -a ${REDIS_PASSWORD} ping > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к Redis${NC}"
    echo "Логи Redis:"
    docker logs root-redis-1
    exit 1
else
    echo -e "${GREEN}Подключение к Redis успешно${NC}"
fi

# 24. Проверка внешнего доступа
echo "Проверяем внешний доступ..."
curl -k -s -f https://${SUBDOMAIN}.${DOMAIN_NAME}/healthz > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: n8n не доступен по https://${SUBDOMAIN}.${DOMAIN_NAME}${NC}"
else
    echo -e "${GREEN}n8n доступен по https://${SUBDOMAIN}.${DOMAIN_NAME}${NC}"
fi

curl -k -s -f https://pgadmin.${DOMAIN_NAME} > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: pgAdmin не доступен по https://pgadmin.${DOMAIN_NAME}${NC}"
else
    echo -e "${GREEN}pgAdmin доступен по https://pgadmin.${DOMAIN_NAME}${NC}"
fi

curl -k -s -f https://${QDRANT_SUBDOMAIN}.${DOMAIN_NAME}/readyz > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: Qdrant не доступен по https://${QDRANT_SUBDOMAIN}.${DOMAIN_NAME}${NC}"
else
    echo -e "${GREEN}Qdrant доступен по https://${QDRANT_SUBDOMAIN}.${DOMAIN_NAME}${NC}"
fi

# 25. Вывод учётных данных
echo -e "${GREEN}Установка завершена успешно!${NC}"
echo "Доступ к сервисам:"
echo "  n8n: https://${SUBDOMAIN}.${DOMAIN_NAME} (логин: admin, пароль: ${N8N_AUTH_PASSWORD})"
echo "  pgAdmin: https://pgadmin.${DOMAIN_NAME} (email: ${EMAIL}, пароль: ${PGADMIN_DEFAULT_PASSWORD})"
echo "  Qdrant: https://${QDRANT_SUBDOMAIN}.${DOMAIN_NAME}"
echo "Telegram-бот:"
echo "  Токен: ${TELEGRAM_TOKEN}"
echo "  Chat ID: ${TELEGRAM_CHAT_ID}"
echo "  Команды: /backup, /logs"
echo -e "${GREEN}Сохраните учётные данные в безопасном месте!${NC}"
