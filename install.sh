#!/bin/bash
set -e

# Упрощенный скрипт установки n8n с Redis и автообновлениями

# 1. Установка базовых зависимостей
echo "Устанавливаем Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# 2. Установка Docker Compose
echo "Устанавливаем Docker Compose..."
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# 3. Создаем директории
mkdir -p /opt/n8n/{data,postgres,pgadmin,qdrant,redis}
cd /opt/n8n

# 4. Генерация паролей
POSTGRES_PASSWORD=$(openssl rand -hex 16)
PGADMIN_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

# 5. Создаем docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3'

services:
  n8n:
    image: n8nio/n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    volumes:
      - ./data:/home/node/.n8n
    environment:
      - N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD
    depends_on:
      - postgres
      - redis

  postgres:
    image: postgres:13-alpine
    restart: unless-stopped
    volumes:
      - ./postgres:/var/lib/postgresql/data
    environment:
      - POSTGRES_PASSWORD=$POSTGRES_PASSWORD
      - POSTGRES_DB=n8n

  pgadmin:
    image: dpage/pgadmin4
    restart: unless-stopped
    ports:
      - "5050:80"
    volumes:
      - ./pgadmin:/var/lib/pgadmin
    environment:
      - PGADMIN_DEFAULT_EMAIL=admin@example.com
      - PGADMIN_DEFAULT_PASSWORD=$PGADMIN_PASSWORD

  redis:
    image: redis:6-alpine
    restart: unless-stopped
    volumes:
      - ./redis:/data
    command: redis-server --requirepass $REDIS_PASSWORD

  qdrant:
    image: qdrant/qdrant
    restart: unless-stopped
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - ./qdrant:/qdrant/storage
EOF

# 6. Запускаем сервисы
docker compose up -d

# 7. Настраиваем автообновления
cat > /usr/local/bin/update-n8n <<EOF
#!/bin/bash
cd /opt/n8n
docker compose pull
docker compose up -d --force-recreate
docker system prune -af
EOF

chmod +x /usr/local/bin/update-n8n

# Добавляем в cron каждое воскресенье в 3:00 ночи
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/update-n8n >> /var/log/n8n-update.log 2>&1") | crontab -

# 8. Выводим информацию
echo "Установка завершена!"
echo "Доступные сервисы:"
echo "- n8n: http://ваш-сервер:5678"
echo "- pgAdmin: http://ваш-сервер:5050"
echo "Данные для входа:"
echo "PostgreSQL: пароль $POSTGRES_PASSWORD"
echo "pgAdmin: admin@example.com / $PGADMIN_PASSWORD"
echo "Redis: пароль $REDIS_PASSWORD"
echo "Автообновления настроены на воскресенье в 3:00"
