#!/bin/bash
set -e

### Проверка прав
if (( EUID != 0 )); then
  echo "❗ Скрипт должен быть запущен от root: sudo bash <(curl ...)"
  exit 1
fi

clear
echo "🌐 Автоматическая установка n8n с GitHub"
echo "----------------------------------------"

### 1. Ввод переменных
read -p "🌐 Введите домен для n8n (например: n8n.example.com): " DOMAIN
read -p "📧 Введите email для SSL-сертификата Let's Encrypt: " EMAIL
read -p "🔐 Введите пароль для базы данных Postgres: " POSTGRES_PASSWORD
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID (для уведомлений): " TG_USER_ID
read -p "🗝️  Введите ключ шифрования для n8n (Enter для генерации): " N8N_ENCRYPTION_KEY

if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "✅ Сгенерирован ключ шифрования: $N8N_ENCRYPTION_KEY"
fi

### 2. Установка Docker и Compose
echo "📦 Проверка Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

echo "📦 Проверка NPM..."
if ! command -v npm &>/dev/null; then
  apt update && apt install -y npm
fi

if ! command -v docker compose &>/dev/null; then
  curl -SL https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose || true
fi

### 3. Клонирование проекта с GitHub
echo "📥 Клонируем проект с GitHub..."
rm -rf /opt/n8n-install
git clone https://github.com/kalininlive/n8n-beget-install.git /opt/n8n-install
cd /opt/n8n-install

### 4. Генерация .env файлов
cat > ".env" <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_EXPRESS_TRUST_PROXY=true
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
EOF

cat > "bot/.env" <<EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_USER_ID=$TG_USER_ID
EOF

chmod 600 .env bot/.env

### 4.1 Создание нужных директорий и логов
mkdir -p logs backups traefik/acme
touch backup.log
chown -R 1000:1000 logs backups backup.log
chmod -R 755 logs backups

### 4.2 Настройка Traefik для боевого режима
cat > "traefik/traefik.yml" <<EOF
global:
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: $EMAIL
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web

providers:
  file:
    filename: /etc/traefik/dynamic_conf.yml
    watch: true

log:
  level: DEBUG
EOF

### 5. Сборка кастомного образа n8n
docker build -f Dockerfile.n8n -t n8n-custom:latest .

### 6. Запуск docker compose (включая Telegram-бота)
docker compose up -d --force-recreate

### 7. Проверка сертификатов
echo "🔍 Проверка выдачи SSL-сертификата..."
sleep 30  # Даем время Traefik получить сертификат
docker compose logs traefik | grep -i acme

### 8. Настройка cron
chmod +x ./backup_n8n.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/n8n-install/backup_n8n.sh >> /opt/n8n-install/backup.log 2>&1") | crontab -

### 9. Уведомление в Telegram
curl -s -X POST https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage \
  -d chat_id=$TG_USER_ID \
  -d text="✅ Установка n8n завершена. Домен: https://$DOMAIN"

### 10. Финальный вывод
echo "📦 Активные контейнеры:"
docker ps --format "table {{.Names}}\t{{.Status}}"

echo "🔐 Проверьте SSL сертификат:"
echo "openssl s_client -connect $DOMAIN:443 -servername $DOMAIN | openssl x509 -noout -dates"

echo "🔄 Если сертификат не выдался, проверьте логи:"
echo "docker compose logs traefik -f"

echo "🎉 Готово! Открой: https://$DOMAIN"
