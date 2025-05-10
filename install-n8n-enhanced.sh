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

# 2. Обновление системы
echo "Обновляем систему..."
apt update > /dev/null 2>&1
apt upgrade -y > /dev/null 2>&1
echo -e "${GREEN}Система обновлена${NC}"

# 3. Установка утилит
echo "Устанавливаем необходимые утилиты..."
apt install -y curl nano dnsutils > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка установки утилит${NC}"
    exit 1
else
    echo -e "${GREEN}Утилиты установлены${NC}"
fi

# 4. Установка Docker
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

# 5. Установка Docker Compose
echo "Устанавливаем Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose > /dev/null 2>&1
    chmod +x /usr/local/bin/docker-compose > /dev/null 2>&1
    echo -e "${GREEN}Docker Compose установлен${NC}"
else
    echo -e "${GREEN}Docker Compose уже установлен${NC}"
fi

# 6. Создание директорий
echo "Создаем необходимые директории..."
mkdir -p /root/n8n/{postgres,redis,letsencrypt,qdrant} > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания директорий${NC}"
    exit 1
else
    echo -e "${GREEN}Директории созданы${NC}"
fi

# 7. Генерация безопасных паролей
echo "Генерируем безопасные пароли..."
POSTGRES_PASSWORD=$(openssl rand -base64 12)
REDIS_PASSWORD=$(openssl rand -base64 12)
PGADMIN_PASSWORD=$(openssl rand -base64 12)

# 8. Создание или обновление .env файла
echo "Создаем/обновляем файл .env..."
cat > /root/.env <<EOL
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
REDIS_PASSWORD=${REDIS_PASSWORD}
SUBDOMAIN=n8n
DOMAIN_NAME=nightcity2077.ru
PGADMIN_EMAIL=admin@nightcity2077.ru
PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}
QDRANT_PORT=6333
QDRANT_SUBDOMAIN=qdrant
DATA_FOLDER=/root/n8n
EOL
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка создания .env файла${NC}"
    exit 1
else
    echo -e "${GREEN}.env файл создан${NC}"
fi

# 9. Загрузка переменных окружения
echo "Загружаем переменные окружения..."
source /root/.env
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$REDIS_PASSWORD" ]; then
    echo -e "${RED}Ошибка: переменные окружения не загружены${NC}"
    exit 1
else
    echo -e "${GREEN}Переменные окружения загружены${NC}"
fi

# 10. Создание docker-compose.yml
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
      - "--certificatesresolvers.mytlschallenge.acme.email=${PGADMIN_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
      - "--log.level=DEBUG"
    ports:
      - "443:443"
    volumes:
      - \${DATA_FOLDER}/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
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
      - N8N_RUNNERS_ENABLED=true
    volumes:
      - \${DATA_FOLDER}/.n8n:/home/node/.n8n
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`\${SUBDOMAIN}.\${DOMAIN_NAME}`)
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
      - PGADMIN_DEFAULT_EMAIL=\${PGADMIN_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_DEFAULT_PASSWORD}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(`pgadmin.\${DOMAIN_NAME}`)
      - traefik.http.routers.pgadmin.entrypoints=websecure
      - traefik.http.routers.pgadmin.tls=true
      - traefik.http.routers.pgadmin.tls.certresolver=mytlschallenge
    depends_on:
      - postgres
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
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6333/readyz"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.qdrant.rule=Host(`\${QDRANT_SUBDOMAIN}.\${DOMAIN_NAME}`)
      - traefik.http.routers.qdrant.entrypoints=websecure
      - traefik.http.routers.qdrant.tls=true
      - traefik.http.routers.qdrant.tls.certresolver=mytlschallenge
      - traefik.http.services.qdrant.loadbalancer.server.port=6333
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

# 11. Исправление предупреждения Redis
echo "Исправляем настройки Redis..."
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
sysctl vm.overcommit_memory=1 > /dev/null 2>&1
echo -e "${GREEN}Настройки Redis исправлены${NC}"

# 12. Запуск Docker Compose
echo "Запускаем Docker Compose..."
docker-compose up -d > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка запуска Docker Compose${NC}"
    docker-compose logs
    exit 1
else
    echo -e "${GREEN}Docker Compose запущен${NC}"
fi

# 13. Проверка статуса контейнеров
echo "Проверяем статус контейнеров..."
sleep 5
docker ps -a
if [ $(docker ps -q | wc -l) -ne 6 ]; then
    echo -e "${RED}Не все контейнеры запущены${NC}"
    docker ps -a
    exit 1
else
    echo -e "${GREEN}Все контейнеры запущены${NC}"
fi

# 14. Проверка готовности сервисов
echo "Ожидаем готовности сервисов..."
timeout=120
elapsed=0
for service in n8n pgadmin qdrant; do
    case $service in
        n8n)
            port=5678
            ;;
        pgadmin)
            port=5050
            ;;
        qdrant)
            port=6333
            ;;
    esac
    echo "Проверяем $service на порту $port..."
    while ! curl -s -f http://127.0.0.1:$port/healthz > /dev/null 2>&1 && ! curl -s -f http://127.0.0.1:$port/readyz > /dev/null 2>&1; do
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
    echo -e "${GREEN}$service готов${NC}"
    elapsed=0
done

# 15. Проверка подключения к PostgreSQL
echo "Проверяем подключение к PostgreSQL из контейнера postgres..."
docker exec root-postgres-1 psql -U ${POSTGRES_USER} -d n8n -c "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к PostgreSQL${NC}"
    echo "Логи PostgreSQL:"
    docker logs root-postgres-1 2>/dev/null || echo "Контейнер root-postgres-1 отсутствует"
    exit 1
else
    echo -e "${GREEN}Подключение к PostgreSQL успешно${NC}"
fi

# 16. Проверка подключения к Redis
echo "Проверяем подключение к Redis из контейнера redis..."
docker exec root-redis-1 redis-cli -a ${REDIS_PASSWORD} ping > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка подключения к Redis${NC}"
    echo "Логи Redis:"
    docker logs root-redis-1 2>/dev/null || echo "Контейнер root-redis-1 отсутствует"
    exit 1
else
    echo -e "${GREEN}Подключение к Redis успешно${NC}"
fi

# 17. Проверка доступности n8n
echo "Проверяем доступность n8n..."
curl -s -f http://127.0.0.1:5678/healthz > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: n8n не отвечает на http://127.0.0.1:5678${NC}"
    echo "Логи n8n:"
    docker logs root-n8n-1 2>/dev/null || echo "Контейнер root-n8n-1 отсутствует"
    exit 1
else
    echo -e "${GREEN}n8n доступен${NC}"
fi

# 18. Проверка доступности pgAdmin
echo "Проверяем доступность pgAdmin..."
curl -s -f http://127.0.0.1:5050 > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: pgAdmin не отвечает на http://127.0.0.1:5050${NC}"
    echo "Логи pgAdmin:"
    docker logs root-pgadmin-1 2>/dev/null || echo "Контейнер root-pgadmin-1 отсутствует"
    exit 1
else
    echo -e "${GREEN}pgAdmin доступен${NC}"
fi

# 19. Проверка доступности Qdrant
echo "Проверяем доступность Qdrant..."
curl -s -f http://127.0.0.1:${QDRANT_PORT}/readyz > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка: Qdrant не отвечает на http://127.0.0.1:${QDRANT_PORT}${NC}"
    echo "Логи Qdrant:"
    docker logs root-qdrant-1 2>/dev/null || echo "Контейнер root-qdrant-1 отсутствует"
    exit 1
else
    echo -e "${GREEN}Qdrant доступен${NC}"
fi

# 20. Проверка DNS
echo "Проверяем DNS записи..."
dig +short ${SUBDOMAIN}.${DOMAIN_NAME} | grep -q "45.156.24.62"
if [ $? -ne 0 ]; then
    echo -e "${RED}DNS запись для ${SUBDOMAIN}.${DOMAIN_NAME} не указывает на 45.156.24.62${NC}"
else
    echo -e "${GREEN}DNS для ${SUBDOMAIN}.${DOMAIN_NAME} корректен${NC}"
fi

dig +short pgadmin.${DOMAIN_NAME} | grep -q "45.156.24.62"
if [ $? -ne 0 ]; then
    echo -e "${RED}DNS запись для pgadmin.${DOMAIN_NAME} не указывает на 45.156.24.62${NC}"
else
    echo -e "${GREEN}DNS для pgadmin.${DOMAIN_NAME} корректен${NC}"
fi

dig +short ${QDRANT_SUBDOMAIN}.${DOMAIN_NAME} | grep -q "45.156.24.62"
if [ $? -ne 0 ]; then
    echo -e "${RED}DNS запись для ${QDRANT_SUBDOMAIN}.${DOMAIN_NAME} не указывает на 45.156.24.62${NC}"
else
    echo -e "${GREEN}DNS для ${QDRANT_SUBDOMAIN}.${DOMAIN_NAME} корректен${NC}"
fi

# 21. Проверка внешнего доступа
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

# 22. Вывод учетных данных
echo -e "${GREEN}Установка завершена успешно!${NC}"
echo "Учетные данные:"
echo "pgAdmin: https://pgadmin.${DOMAIN_NAME}"
echo "  Email: ${PGADMIN_EMAIL}"
echo "  Пароль: ${PGADMIN_DEFAULT_PASSWORD}"
echo "n8n: https://${SUBDOMAIN}.${DOMAIN_NAME}"
echo "Qdrant: https://${QDRANT_SUBDOMAIN}.${DOMAIN_NAME}"
echo "PostgreSQL:"
echo "  Пользователь: ${POSTGRES_USER}"
echo "  Пароль: ${POSTGRES_PASSWORD}"
echo "  База данных: ${POSTGRES_DB}"
echo "Redis пароль: ${REDIS_PASSWORD}"
echo -e "${GREEN}Сохраните эти данные в безопасном месте!${NC}"
