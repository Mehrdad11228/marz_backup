#!/bin/bash

# =========================================
#        Backuper Marzneshin Menu
# =========================================

# ----- Install Required Packages -----
function install_requirements() {
    clear
    echo "Installing required packages..."
    apt update -y && apt upgrade -y
    apt install zip unzip -y
    apt install tar gzip -y
    apt install p7zip-full -y
    apt install mariadb-client -y
}

# ----- Install Backuper -----
function install_backuper() {
    clear
    echo "---- Backuper Installation ----"
    read -p "Enter Telegram Bot Token: " BOT_TOKEN
    read -p "Enter Telegram Chat ID: " CHAT_ID

    echo
    echo "Select Compression Type:"
    echo "1) zip"
    echo "2) tgz"
    echo "3) 7z"
    read -p "Choose (1-3): " COMP_TYPE_OPT

    case $COMP_TYPE_OPT in
        1) COMP_TYPE="zip" ;;
        2) COMP_TYPE="tgz" ;;
        3) COMP_TYPE="7z" ;;
        *) echo "Invalid choice. Default: zip"; COMP_TYPE="zip" ;;
    esac

    read -p "Enter file caption: " CAPTION

    echo
    echo "Select Backup Interval:"
    echo "1) 1 min"
    echo "2) 10 min"
    echo "3) 1 hour"
    echo "4) 1:30 hours"
    read -p "Choose (1-4): " TIME_OPT

    case $TIME_OPT in
        1) CRON_TIME="*/1 * * * *" ;;
        2) CRON_TIME="*/10 * * * *" ;;
        3) CRON_TIME="0 */1 * * *" ;;
        4) CRON_TIME="*/30 */1 * * *" ;;
        *) CRON_TIME="0 */1 * * *" ;;
    esac

    BACKUP_SCRIPT="/root/marz_backup.sh"
    BACKUP_DIR="/root/backuper_marzneshin"

    # Create backup script
    cat > $BACKUP_SCRIPT <<EOF
#!/bin/bash
BACKUP_DIR="$BACKUP_DIR"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
CAPTION="$CAPTION"
COMP_TYPE="$COMP_TYPE"
DATE=\$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_BASE="\$BACKUP_DIR/backup_\$DATE"

mkdir -p \$BACKUP_DIR
cd \$BACKUP_DIR

# Copy paths
mkdir -p etc_opt var_lib_marznode var_lib_marzneshin
cp -r /etc/opt/marzneshin/ etc_opt/
cp -r /var/lib/marznode/ var_lib_marznode/
rsync -a --exclude='mysql' /var/lib/marzneshin/ var_lib_marzneshin/

# ----- MySQL Backup -----
DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
if [ -f "\$DOCKER_COMPOSE" ]; then
    DB_PASS=\$(grep 'MARIADB_ROOT_PASSWORD:' "\$DOCKER_COMPOSE" | awk -F': ' '{print \$2}' | tr -d ' "')
    DB_NAME=\$(grep 'MARIADB_DATABASE:' "\$DOCKER_COMPOSE" | awk -F': ' '{print \$2}' | tr -d ' "')
    DB_USER="root"

    if [ -n "\$DB_PASS" ] && [ -n "\$DB_NAME" ]; then
        echo "Backing up MySQL database..."
        mysqldump -h 127.0.0.1 -P 3306 -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" > "\$BACKUP_DIR/marzneshin_backup.sql"
        echo "MySQL backup completed."
    else
        echo "MySQL credentials not found in docker-compose.yml"
    fi
else
    echo "docker-compose.yml not found. Skipping MySQL backup."
fi

# Compression
ARCHIVE="\$OUTPUT_BASE"
if [ "\$COMP_TYPE" == "zip" ]; then
    ARCHIVE="\$OUTPUT_BASE.zip"
    zip -r "\$ARCHIVE" .
elif [ "\$COMP_TYPE" == "tgz" ]; then
    ARCHIVE="\$OUTPUT_BASE.tgz"
    tar -czf "\$ARCHIVE" .
elif [ "\$COMP_TYPE" == "7z" ]; then
    ARCHIVE="\$OUTPUT_BASE.7z"
    7z a "\$ARCHIVE" .
else
    ARCHIVE="\$OUTPUT_BASE.zip"
    zip -r "\$ARCHIVE" .
fi

# File size check
if [ -f "\$ARCHIVE" ]; then
    FILE_SIZE_MB=\$(du -m "\$ARCHIVE" | cut -f1)
    echo "Total size file: \$FILE_SIZE_MB MB"
else
    echo "Backup file not created!"
    exit 1
fi

# Send via Telegram
if [ -n "\$BOT_TOKEN" ] && [ -n "\$CHAT_ID" ]; then
    curl -s -F chat_id="\$CHAT_ID" -F caption="\$CAPTION" -F document=@"\$ARCHIVE" https://api.telegram.org/bot\$BOT_TOKEN/sendDocument
    echo "Backup successfully sent to Telegram!"
else
    echo "Telegram token or chat ID not set. Skipping send."
fi

# Cleanup
rm -rf "\$BACKUP_DIR"/*
EOF

    chmod +x $BACKUP_SCRIPT

    # Set Cron Job
    (crontab -l 2>/dev/null; echo "$CRON_TIME bash $BACKUP_SCRIPT") | crontab -

    # Send success message to bot
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="Successfully installed backuper and backup started." >/dev/null

    # Run first backup immediately
    bash $BACKUP_SCRIPT

    echo
    echo "Backuper installed successfully and first backup sent."
    read -p "Press Enter to return to menu..."
}

# ----- Remove Backuper -----
function remove_backuper() {
    clear
    echo "Removing Backuper..."
    rm -f /root/marz_backup.sh
    crontab -l | grep -v 'marz_backup.sh' | crontab -
    echo "Backup script removed successfully."
    read -p "Press Enter to return to menu..."
}

# ----- Run Script Manually -----
function run_script() {
    clear
    if [ -f /root/marz_backup.sh ]; then
        bash /root/marz_backup.sh
    else
        echo "Backup script not found. Please install it first."
    fi
    read -p "Press Enter to return to menu..."
}

# ----- Main Menu -----
function main_menu() {
    while true; do
        clear
        echo "========================================="
        echo "         Backuper Marzneshin Menu"
        echo "========================================="
        echo "[1] Install Backuper"
        echo "[2] Remove Backuper"
        echo "[3] Run Script"
        echo "[4] Exit"
        echo "-----------------------------------------"
        read -p "Choose an option: " OPTION

        case $OPTION in
            1) install_requirements; install_backuper ;;
            2) remove_backuper ;;
            3) run_script ;;
            4) exit 0 ;;
            *) echo "Invalid choice!"; sleep 1 ;;
        esac
    done
}

main_menu
