#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting n8n, PostgreSQL, Redis, and Qdrant installation...${NC}"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run the script with root privileges (sudo)${NC}"
    exit 1
fi

# 1. Update package indexes
echo "Updating package indexes..."
apt update

# 2. Install required packages
echo "Installing necessary packages..."
apt install curl software-properties-common ca-certificates apt-transport-https -y

# 3. Import GPG key for Docker
echo "Importing Docker GPG key..."
wget -O- https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null

# 4. Add Docker repository
echo "Adding Docker repository..."
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. Update package indexes again
echo "Updating package indexes after adding repository..."
apt update

# 6. Install Docker
echo "Installing Docker..."
apt install docker-ce -y

# 7. Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.33.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 8. Create directories
echo "Creating necessary directories..."
mkdir -p /root/n8n/.n8n
mkdir -p /root/n8n/local-files
mkdir -p /root/n8n/postgres
mkdir -p /root/n8n/redis
mkdir -p /root/n8n/qdrant
chmod -R 777 /root/n8n/local-files # Allow read/write

# 9. Create docker-compose.yml with PostgreSQL, Redis, Qdrant
echo "Creating docker-compose.yml..."
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
    depends_on:
      - postgres
      - redis

  postgres:
    image: postgres:16
    restart: always
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - ${DATA_FOLDER}/postgres:/var/lib/postgresql/data
    labels:
      - traefik.enable=true
      - traefik.http.routers.postgres.rule=Host(`pg.${DOMAIN_NAME}`)
      - traefik.http.routers.postgres.tls=true
      - traefik.http.routers.postgres.entrypoints=websecure
      - traefik.http.routers.postgres.tls.certresolver=mytlschallenge
    ports:
      - "127.0.0.1:5432:5432"

  redis:
    image: redis:7
    restart: always
    volumes:
      - ${DATA_FOLDER}/redis:/data
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD}

  qdrant:
    image: qdrant/qdrant:latest
    restart: always
    volumes:
      - ${DATA_FOLDER}/qdrant:/qdrant/storage
    ports:
      - "127.0.0.1:6333:6333"
    labels:
      - traefik.enable=true
      - traefik.http.routers.qdrant.rule=Host(`qdrant.${DOMAIN_NAME}`)
      - traefik.http.routers.qdrant.tls=true
      - traefik.http.routers.qdrant.entrypoints=websecure
      - traefik.http.routers.qdrant.tls.certresolver=mytlschallenge
EOF

# 10. Prompt for user input
echo "Configuring installation parameters..."
read -p "Enter your domain (e.g., example.com): " DOMAIN_NAME
read -p "Enter subdomain for n8n (default: n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}
read -p "Enter login for n8n: " N8N_BASIC_AUTH_USER
read -s -p "Enter password for n8n: " N8N_BASIC_AUTH_PASSWORD
echo
read -p "Enter PostgreSQL user: " POSTGRES_USER
read -s -p "Enter PostgreSQL password: " POSTGRES_PASSWORD
echo
read -p "Enter Redis password: " REDIS_PASSWORD
read -p "Enter your email for SSL: " SSL_EMAIL
read -p "Enter your timezone (e.g., Europe/Moscow): " GENERIC_TIMEZONE

# 11. Create .env file
echo "Creating .env file..."
cat > /root/.env << EOF
DATA_FOLDER=/root/n8n/
DOMAIN_NAME=$DOMAIN_NAME
SUBDOMAIN=$SUBDOMAIN
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=$GENERIC_TIMEZONE
EOF

# 12. Start services
echo "Starting services..."
cd /root
docker-compose up -d

# 13. Fix permissions for n8n
echo "Fixing permissions for n8n..."
docker stop $(docker ps -q)
docker run --rm -it --user root -v /root/n8n/.n8n:/home/node/.n8n --entrypoint chown n8nio/base:16 -R node:node /home/node/.n8n
echo "Restarting services..."
docker-compose up -d

# 14. Create update script with cleanup
echo "Creating update script with container cleanup..."
cat > /root/update-n8n.sh << 'EOF'
#!/bin/bash

cd /root
# Pull latest images
docker-compose pull
# Stop and remove existing containers
docker-compose down
# Remove old n8n containers
docker rm $(docker ps -a -q -f name=n8n) 2>/dev/null || true
# Remove dangling images
docker image prune -f
# Start services
docker-compose up -d
EOF

# 15. Setup permissions and cron
echo "Setting up auto-update..."
chmod +x /root/update-n8n.sh
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/update-n8n.sh") | crontab -

echo -e "${GREEN}n8n, PostgreSQL, Redis, and Qdrant installation completed!${NC}"
echo "Access n8n: https://$SUBDOMAIN.$DOMAIN_NAME"
echo "Access PostgreSQL: https://pg.$DOMAIN_NAME"
echo "Access Qdrant: https://qdrant.$DOMAIN_NAME"
echo "Login: $N8N_BASIC_AUTH_USER"
echo "Password: [hidden]"
echo "File directory: /root/n8n/local-files (accessible in n8n as /files/)"
echo "Auto-update scheduled for every Sunday at 00:00"
