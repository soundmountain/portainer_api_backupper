# portainer_api_backupper
bash script to backup all portainer stack compose files and a regular backup of portainer via portainer API
> [!WARNING]
> **volumes are not included**  

the purpose is to backup all configurations in formats that are restorable no matter what

## Description
This script creates a 
 - backup of all docker-compose files and metadata
 - a standard backup of portainer
utilizing the portainer API

## USAGE 
create an .env file with the following values
```bash
PORTAINER_URL="https://portainer.example.com"
PORTAINER_API_KEY="YOUR_ACCESS_TOKEN"
BACKUP_DIR="/path/to/backup/location"
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=180
CURL_RETRY=3
CURL_RETRY_DELAY=2
CURL_RETRY_ALL_ERRORS=1
# optional: password for encrypted portainer backup
#PORTAINER_BACKUP_PASSWORD="changeme2somethingsecure"
# optional, when using a self signed certificate: 
#CURL_INSECURE=1
```
## harden the env file 
```bash
chmod 700 /path/to/env/folder
chmod 600 /path/to/env/folder/.env
```
## edit the script
Populate the config-section with the path to the .env file
```bash
# ====== CONFIG ======
ENV_FILE="/path/to/env/folder/.env"
```

##  run the script
```bash
chmod +x portainer_api_backupper.sh
./portainer_api_backupper.sh
```

> [!TIP]
> ## automate it
> use crontab, systemd timers, jenkins,...
