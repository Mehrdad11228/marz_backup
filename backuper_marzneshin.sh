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
    apt install sshpass -y
    sudo apt update
    sudo apt install xz-utils zstd -y
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
    echo "4) XZ"
    echo "5) ZSTD"
    read -p "Choose (1-5): " COMP_TYPE_OPT

    case $COMP_TYPE_OPT in
       1) COMP_TYPE="zip" ;;
       2) COMP_TYPE="tgz" ;;
       3) COMP_TYPE="7z" ;;
       4) COMP_TYPE="xz" ;;
       5) COMP_TYPE="zstd" ;;
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
    cat > $BACKUP_SCRIPT <<'EOF'
#!/bin/bash
BACKUP_DIR="/root/backuper_marzneshin"
BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
CAPTION="__CAPTION__"
COMP_TYPE="__COMP_TYPE__"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_BASE="$BACKUP_DIR/backup_$DATE"

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

# Copy paths
mkdir -p etc_opt var_lib_marznode var_lib_marzneshin
cp -r /etc/opt/marzneshin/ etc_opt/ 2>/dev/null
cp -r /var/lib/marznode/ var_lib_marznode/ 2>/dev/null
rsync -a --exclude='mysql' /var/lib/marzneshin/ var_lib_marzneshin/ 2>/dev/null

# ----- MySQL Backup -----
DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
if [ -f "$DOCKER_COMPOSE" ]; then
    DB_PASS=$(grep 'MARIADB_ROOT_PASSWORD:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_NAME=$(grep 'MARIADB_DATABASE:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_USER="root"

    if [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
        echo "Backing up MySQL database..."
        mysqldump -h 127.0.0.1 -P 3306 -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_DIR/marzneshin_backup.sql"
        echo "MySQL backup completed."
    else
        echo "MySQL credentials not found in docker-compose.yml"
    fi
else
    echo "docker-compose.yml not found. Skipping MySQL backup."
fi

# ==============================
# Compression Section
# ==============================
ARCHIVE="$OUTPUT_BASE"

if [ "$COMP_TYPE" == "zip" ]; then
    ARCHIVE="$OUTPUT_BASE.zip"
    zip -r "$ARCHIVE" .

elif [ "$COMP_TYPE" == "tgz" ]; then
    ARCHIVE="$OUTPUT_BASE.tgz"
    tar -czf "$ARCHIVE" .

elif [ "$COMP_TYPE" == "7z" ]; then
    ARCHIVE="$OUTPUT_BASE.7z"
    7z a -t7z -m0=lzma2 -mx=9 -mfb=256 -md=1536m -ms=on "$ARCHIVE" .

elif [ "$COMP_TYPE" == "xz" ]; then
    ARCHIVE="$OUTPUT_BASE.tar.xz"
    tar -cf - . | xz -9 -T0 -c > "$ARCHIVE"

elif [ "$COMP_TYPE" == "zstd" ]; then
    ARCHIVE="$OUTPUT_BASE.tar.zst"
    tar -cf - . | zstd -19 -T0 -o "$ARCHIVE"

else
    ARCHIVE="$OUTPUT_BASE.zip"
    zip -r "$ARCHIVE" .
fi

# ==============================
# File size check and Telegram send
# ==============================
if [ -f "$ARCHIVE" ]; then
    FILE_SIZE_MB=$(du -m "$ARCHIVE" | cut -f1)
    echo "Total size file: $FILE_SIZE_MB MB"
else
    echo "Backup file not created!"
    exit 1
fi

if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    curl -s -F chat_id="$CHAT_ID" -F caption="$CAPTION" -F document=@"$ARCHIVE" https://api.telegram.org/bot$BOT_TOKEN/sendDocument
    echo "Backup successfully sent to Telegram!"
else
    echo "Telegram token or chat ID not set. Skipping send."
fi

rm -rf "$BACKUP_DIR"/*
EOF

    # Replace dynamic variables
    sed -i "s|__BOT_TOKEN__|$BOT_TOKEN|g" $BACKUP_SCRIPT
    sed -i "s|__CHAT_ID__|$CHAT_ID|g" $BACKUP_SCRIPT
    sed -i "s|__CAPTION__|$CAPTION|g" $BACKUP_SCRIPT
    sed -i "s|__COMP_TYPE__|$COMP_TYPE|g" $BACKUP_SCRIPT

    chmod +x $BACKUP_SCRIPT

    # Set Cron Job
    (crontab -l 2>/dev/null; echo "$CRON_TIME bash $BACKUP_SCRIPT") | crontab -

    # Send success message
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="Successfully installed backuper and backup started." >/dev/null

    # Run first backup
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
    rm -f /root/Transfer_backup.sh
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

# ----- Transfer Backup (Option 4) -----
function transfer_backup() {
    clear
    echo "========================================="
    echo "           Transfer Backup"
    echo "========================================="
    echo "Select Panel Type:"
    echo "1) Marzneshin [MariaDB]"
    echo "2) Marzban"
    read -p "Choose (1-2): " PANEL_TYPE

    if [ "$PANEL_TYPE" != "1" ]; then
        echo "Only Marzneshin (option 1) is currently supported."
        read -p "Press Enter to return..."
        return
    fi

    clear
    echo "Enter Remote Server Details:"
    read -p "IP Server [Client]: " REMOTE_IP
    read -p "User Server [Client]: " REMOTE_USER
    read -s -p "Password Server [Client]: " REMOTE_PASS
    echo

    # Create Transfer_backup.sh
    TRANSFER_SCRIPT="/root/Transfer_backup.sh"
    cat > $TRANSFER_SCRIPT <<'EOF'
#!/bin/bash

# ========================================
# Configuration
# ========================================
BACKUP_DIR="/root/backuper_marzneshin"
REMOTE_IP="__REMOTE_IP__"
REMOTE_USER="__REMOTE_USER__"
REMOTE_PASS="__REMOTE_PASS__"

# Remote target directories
REMOTE_ETC="/etc/opt/marzneshin"
REMOTE_NODE="/var/lib/marznode"
REMOTE_MARZ="/var/lib/marzneshin"
REMOTE_MYSQL="/root/Marzneshin-Mysql"

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_DIR="$BACKUP_DIR/backup_$DATE"

# ========================================
# Create local backup
# ========================================
mkdir -p "$OUTPUT_DIR"

echo "Backing up folders locally..."

# Copy /etc/opt/marzneshin/
cp -r /etc/opt/marzneshin/ "$OUTPUT_DIR/etc_opt/" 2>/dev/null

# Copy /var/lib/marznode/
cp -r /var/lib/marznode/ "$OUTPUT_DIR/var_lib_marznode/" 2>/dev/null

# Copy /var/lib/marzneshin/ excluding mysql folder
rsync -a --exclude='mysql' /var/lib/marzneshin/ "$OUTPUT_DIR/var_lib_marzneshin/" 2>/dev/null

# ----- Backup MySQL -----
DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
if [ -f "$DOCKER_COMPOSE" ]; then
    DB_PASS=$(grep 'MARIADB_ROOT_PASSWORD:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_NAME=$(grep 'MARIADB_DATABASE:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_USER="root"

    if [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
        echo "Backing up MySQL database..."
        mkdir -p "$OUTPUT_DIR/Marzneshin-Mysql"
        mysqldump -h 127.0.0.1 -P 3306 -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$OUTPUT_DIR/Marzneshin-Mysql/marzneshin_backup.sql"
        echo "MySQL backup completed."
    else
        echo "MySQL credentials not found in docker-compose.yml"
    fi
else
    echo "docker-compose.yml not found. Skipping MySQL backup."
fi

echo "Local backup completed at $OUTPUT_DIR"

# ========================================
# Send backup to remote server
# ========================================
echo "Connecting to remote server $REMOTE_IP..."

# Install sshpass if not installed
if ! command -v sshpass &> /dev/null; then
    echo "sshpass not found, installing..."
    apt update && apt install -y sshpass
fi

# Remove existing folders on remote server
sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "
    echo 'Removing old folders if they exist...'
    [ -d '$REMOTE_ETC' ] && rm -rf '$REMOTE_ETC'
    [ -d '$REMOTE_NODE' ] && rm -rf '$REMOTE_NODE'
    [ -d '$REMOTE_MARZ' ] && rm -rf '$REMOTE_MARZ'
    [ -d '$REMOTE_MYSQL' ] && rm -rf '$REMOTE_MYSQL'
    mkdir -p '$REMOTE_ETC' '$REMOTE_NODE' '$REMOTE_MARZ' '$REMOTE_MYSQL'
"

# Sync folders to remote server
echo "Transferring folders to remote server..."

sshpass -p "$REMOTE_PASS" rsync -a "$OUTPUT_DIR/etc_opt/" "$REMOTE_USER@$REMOTE_IP:$REMOTE_ETC/"
sshpass -p "$REMOTE_PASS" rsync -a "$OUTPUT_DIR/var_lib_marznode/" "$REMOTE_USER@$REMOTE_IP:$REMOTE_NODE/"
sshpass -p "$REMOTE_PASS" rsync -a "$OUTPUT_DIR/var_lib_marzneshin/" "$REMOTE_USER@$REMOTE_IP:$REMOTE_MARZ/"
sshpass -p "$REMOTE_PASS" rsync -a "$OUTPUT_DIR/Marzneshin-Mysql/" "$REMOTE_USER@$REMOTE_IP:$REMOTE_MYSQL/"

if [ $? -eq 0 ]; then
    echo "Backup successfully transferred to $REMOTE_IP"
else
    echo "Error transferring backup!"
    exit 1
fi

# Restart marzneshin service on remote server
echo "Restarting marzneshin service on remote server..."
sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "marzneshin restart"

echo "Backup and remote update completed successfully!"

# ========================================
# Cleanup local backup directory
# ========================================
echo "Cleaning up local backup directory..."
rm -rf "$BACKUP_DIR"/*
rm -rf "$OUTPUT_DIR"

echo "Local backup directory cleaned."
EOF

    # Replace placeholders
    sed -i "s|__REMOTE_IP__|$REMOTE_IP|g" $TRANSFER_SCRIPT
    sed -i "s|__REMOTE_USER__|$REMOTE_USER|g" $TRANSFER_SCRIPT
    sed -i "s|__REMOTE_PASS__|$REMOTE_PASS|g" $TRANSFER_SCRIPT

    chmod +x $TRANSFER_SCRIPT

    # Run transfer immediately
    bash $TRANSFER_SCRIPT

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
        echo "[4] Transfer Backup"
        echo "[5] Exit"
        echo "-----------------------------------------"
        read -p "Choose an option: " OPTION

        case $OPTION in
            1) install_requirements; install_backuper ;;
            2) remove_backuper ;;
            3) run_script ;;
            4) transfer_backup ;;
            5) exit 0 ;;
            *) echo "Invalid choice!"; sleep 1 ;;
        esac
    done
}

main_menu
