#!/bin/bash
# =========================================
# Backuper Marzneshin Menu - Final Version
# =========================================

# ----- Install Required Packages -----
function install_requirements() {
    clear
    echo "Installing required packages..."
    apt update -y && apt upgrade -y
    apt install zip unzip tar gzip p7zip-full mariadb-client sshpass xz-utils zstd -y
}

# ----- Detect Database Type -----
function detect_db_type() {
    local docker_file="/etc/opt/marzneshin/docker-compose.yml"
    if [[ ! -f "$docker_file" ]]; then
        echo "docker-compose.yml not found. Assuming SQLite."
        echo "sqlite"
        return
    fi

    local db_url=$(grep -i "SQLALCHEMY_DATABASE_URL" "$docker_file" | head -1 | cut -d'"' -f2 | cut -d"'" -f2)
    if [[ -z "$db_url" ]]; then
        echo "SQLALCHEMY_DATABASE_URL not found. Assuming SQLite."
        echo "sqlite"
        return
    fi

    if [[ "$db_url" == sqlite* ]]; then
        echo "sqlite"
    elif [[ "$db_url" == *"mysql"* ]] && [[ "$db_url" != *"mariadb"* ]]; then
        echo "mysql"
    elif [[ "$db_url" == *"mariadb"* ]] || grep -q "MARIADB_ROOT_PASSWORD" "$docker_file"; then
        echo "mariadb"
    else
        echo "sqlite"
    fi
}

# ----- Create Backup Script Based on DB Type -----
function create_backup_script() {
    local db_type="$1"
    local script_file="/root/marz_backup.sh"
    local backup_dir="/root/backuper_marzneshin"

    cat > "$script_file" <<'EOF'
#!/bin/bash
BACKUP_DIR="/root/backuper_marzneshin"
BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
CAPTION="__CAPTION__"
COMP_TYPE="__COMP_TYPE__"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_BASE="$BACKUP_DIR/backup_$DATE"
ARCHIVE=""
mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR" || exit 1

# Clean previous content
rm -rf etc_opt var_lib_marznode var_lib_marzneshin marzneshin_backup.sql

# Copy paths
mkdir -p etc/opt/marzneshin var/lib/marznode var/lib/marzneshin
cp -r /etc/opt/marzneshin/ etc/opt/marzneshin/ 2>/dev/null || true
rsync -a --include='xray_config.json' --exclude='*' /var/lib/marznode/ var/lib/marznode/ 2>/dev/null || true
rsync -a --exclude='mysql' --exclude='assets' /var/lib/marzneshin/ var/lib/marzneshin/ 2>/dev/null || true

# ==============================
# Database Backup Section
# ==============================
DB_BACKUP_DONE=0
DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
if [ -f "$DOCKER_COMPOSE" ]; then
EOF

    if [[ "$db_type" == "sqlite" ]]; then
        cat >> "$script_file" <<'EOF'
    # SQLite: No external dump needed
    echo "SQLite detected. DB files included in /var/lib/marzneshin/"
    DB_BACKUP_DONE=1
EOF
    elif [[ "$db_type" == "mysql" ]]; then
        cat >> "$script_file" <<'EOF'
    DB_PASS=$(grep 'MYSQL_ROOT_PASSWORD:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_NAME=$(grep 'MYSQL_DATABASE:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_USER="root"
    if [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
        echo "Backing up MySQL database..."
        mysqldump -h 127.0.0.1 -P 3306 -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_DIR/marzneshin_backup.sql" 2>/dev/null && DB_BACKUP_DONE=1
        [ $DB_BACKUP_DONE -eq 1 ] && echo "MySQL backup completed." || echo "MySQL backup failed."
    else
        echo "MySQL credentials not found."
    fi
EOF
    elif [[ "$db_type" == "mariadb" ]]; then
        cat >> "$script_file" <<'EOF'
    DB_PASS=$(grep 'MARIADB_ROOT_PASSWORD:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_NAME=$(grep 'MARIADB_DATABASE:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_USER="root"
    if [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
        echo "Backing up MariaDB database..."
        mysqldump -h 127.0.0.1 -P 3306 -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_DIR/marzneshin_backup.sql" 2>/dev/null && DB_BACKUP_DONE=1
        [ $DB_BACKUP_DONE -eq 1 ] && echo "MariaDB backup completed." || echo "MariaDB backup failed."
    else
        echo "MariaDB credentials not found."
    fi
EOF
    fi

    cat >> "$script_file" <<'EOF'
else
    echo "docker-compose.yml not found. Skipping DB backup."
fi

# ==============================
# Compression Section
# ==============================
ARCHIVE="$OUTPUT_BASE"
if [ "$COMP_TYPE" == "zip" ]; then
    ARCHIVE="$OUTPUT_BASE.zip"
    zip -r "$ARCHIVE" . > /dev/null
elif [ "$COMP_TYPE" == "tgz" ]; then
    ARCHIVE="$OUTPUT_BASE.tgz"
    tar -czf "$ARCHIVE" . > /dev/null
elif [ "$COMP_TYPE" == "7z" ]; then
    ARCHIVE="$OUTPUT_BASE.7z"
    7z a -t7z -m0=lzma2 -mx=9 -mfb=256 -md=1536m -ms=on "$ARCHIVE" . > /dev/null
elif [ "$COMP_TYPE" == "tar" ]; then
    ARCHIVE="$OUTPUT_BASE.tar"
    tar -cf "$ARCHIVE" . > /dev/null
elif [ "$COMP_TYPE" == "gzip" ] || [ "$COMP_TYPE" == "gz" ]; then
    ARCHIVE="$OUTPUT_BASE.tar.gz"
    tar -cf - . | gzip > "$ARCHIVE"
else
    ARCHIVE="$OUTPUT_BASE.zip"
    zip -r "$ARCHIVE" . > /dev/null
fi

# ==============================
# File size check & Telegram send
# ==============================
if [ ! -f "$ARCHIVE" ]; then
    echo "Backup file not created!"
    rm -rf "$BACKUP_DIR"/*
    exit 1
fi

FILE_SIZE_MB=$(du -m "$ARCHIVE" | cut -f1)
echo "Backup created: $ARCHIVE ($FILE_SIZE_MB MB)"

# Send to Telegram
if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    CAPTION_WITH_SIZE="$CAPTION\nTotal size: ${FILE_SIZE_MB} MB"
    if [ "$FILE_SIZE_MB" -gt 50 ]; then
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
             -d chat_id="$CHAT_ID" \
             -d text="Warning: Backup file > 50MB (${FILE_SIZE_MB} MB). Telegram may not accept it." >/dev/null
    fi
    curl -s -F chat_id="$CHAT_ID" -F caption="$CAPTION_WITH_SIZE" -F document=@"$ARCHIVE" \
         "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" >/dev/null && \
         echo "Backup successfully sent to Telegram!" || echo "Failed to send via Telegram."
else
    echo "Telegram credentials missing. Skipping send."
fi

# Cleanup
rm -rf "$BACKUP_DIR"/*
EOF

    chmod +x "$script_file"
}

# ----- Install Backuper -----
function install_backuper() {
    while true; do
        clear
        echo "========================================="
        echo " Select backup type"
        echo "========================================="
        echo
        echo "1) Marzneshin"
        echo
        echo "-----------------------------------------"
        read -p "Choose an option: " PANEL_OPTION
        [[ -z "$PANEL_OPTION" ]] && { echo "No option selected."; sleep 1; return; }
        [[ "$PANEL_OPTION" == "1" ]] && { PANEL_TYPE="Marzneshin"; break; }
        echo "Invalid choice. Try again."; sleep 1
    done

    clear
    echo "Selected Panel: $PANEL_TYPE"
    echo

    # Step 1 - Bot Token
    echo "Step 1 - Enter Telegram Bot Token"
    read -p "Token Telegram: " BOT_TOKEN
    [[ -z "$BOT_TOKEN" ]] && { echo "Token cannot be empty."; sleep 1; return; }

    # Step 2 - Chat ID
    echo -e "\nStep 2 - Enter Chat ID"
    read -p "Chat ID: " CHAT_ID
    [[ -z "$CHAT_ID" ]] && { echo "Chat ID cannot be empty."; sleep 1; return; }

    # Step 3 - Compression Type
    echo -e "\nStep 3 - Select Compression Type"
    echo "File Type:"
    echo "1) zip"
    echo "2) tgz"
    echo "3) 7z"
    echo "4) tar"
    echo "5) gzip"
    echo "6) gz"
    read -p "Choose (1-6): " COMP_TYPE_OPT
    case $COMP_TYPE_OPT in
        1) COMP_TYPE="zip" ;;
        2) COMP_TYPE="tgz" ;;
        3) COMP_TYPE="7z" ;;
        4) COMP_TYPE="tar" ;;
        5) COMP_TYPE="gzip" ;;
        6) COMP_TYPE="gz" ;;
        *) COMP_TYPE="zip"; echo "Invalid. Default: zip" ;;
    esac

    # Step 4 - Caption
    echo -e "\nStep 4 - Enter File Caption"
    read -p "Caption File: " CAPTION
    [[ -z "$CAPTION" ]] && CAPTION="Marzneshin Backup - $(date +"%Y-%m-%d %H:%M")"

    # Step 5 - Backup Interval
    echo -e "\nStep 5 - Select Backup Interval"
    echo "Time Backup:"
    echo "1) 1 min"
    echo "2) 5 min"
    echo "3) 1 hour"
    echo "4) 1:30 hours"
    read -p "Choose (1-4): " TIME_OPT
    case $TIME_OPT in
        1) CRON_TIME="*/1 * * * *" ;;
        2) CRON_TIME="*/5 * * * *" ;;
        3) CRON_TIME="0 */1 * * *" ;;
        4) CRON_TIME="*/30 */1 * * *" ;;
        *) CRON_TIME="0 */1 * * *"; echo "Default: 1 hour" ;;
    esac

    # Step 6 - Detect Database
    echo -e "\nStep 6 - Detecting Database Type"
    DB_TYPE=$(detect_db_type)
    case $DB_TYPE in
        sqlite)   echo "SQLite detected." ;;
        mysql)    echo "MySQL detected." ;;
        mariadb)  echo "MariaDB detected." ;;
    esac

    # Create script based on DB type
    create_backup_script "$DB_TYPE"

    # Replace variables
    sed -i "s|__BOT_TOKEN__|$BOT_TOKEN|g" /root/marz_backup.sh
    sed -i "s|__CHAT_ID__|$CHAT_ID|g" /root/marz_backup.sh
    sed -i "s|__CAPTION__|$CAPTION|g" /root/marz_backup.sh
    sed -i "s|__COMP_TYPE__|$COMP_TYPE|g" /root/marz_backup.sh

    # Set cron job
    (crontab -l 2>/dev/null | grep -v "marz_backup.sh"; echo "$CRON_TIME bash /root/marz_backup.sh") | crontab -

    # Step 7 - Run first backup
    echo -e "\nStep 7 - Running first backup..."
    bash /root/marz_backup.sh

    # Success message
    echo -e "\nBackup successfully sent"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
         -d chat_id="$CHAT_ID" -d text="Backuper installed and first backup sent." >/dev/null

    read -p "Press Enter to return to menu..."
}

# ----- Remove Backuper -----
function remove_backuper() {
    clear
    echo "Removing Backuper..."
    rm -f /root/marz_backup.sh /root/Transfer_backup.sh
    rm -rf /root/backuper_marzneshin
    crontab -l 2>/dev/null | grep -v 'marz_backup.sh' | crontab -
    echo "Backuper removed successfully."
    read -p "Press Enter to return..."
}

# ----- Run Script Manually -----
function run_script() {
    clear
    if [[ -f /root/marz_backup.sh ]]; then
        bash /root/marz_backup.sh
    else
        echo "Backup script not found. Install first."
    fi
    read -p "Press Enter to return..."
}

# ----- Transfer Backup -----
function transfer_backup() {
    clear
    echo "========================================="
    echo "         Transfer Backup"
    echo "========================================="
    echo "Select Panel Type:"
    echo "1) Marzneshin [MariaDB/MySQL/SQLite]"
    echo "2) Marzban"
    read -p "Choose (1-2): " PANEL_TYPE
    [[ "$PANEL_TYPE" != "1" ]] && { echo "Only Marzneshin supported."; read -p "Press Enter..."; return; }

    clear
    echo "Enter Remote Server Details:"
    read -p "IP Server [Client]: " REMOTE_IP
    read -p "User Server [Client]: " REMOTE_USER
    read -s -p "Password Server [Client]: " REMOTE_PASS
    echo

    # ==============================
    # Check Required Directories - ALL CRITICAL
    # ==============================

    MISSING_DIRS=()
    [[ ! -d "/etc/opt/marzneshin" ]] && MISSING_DIRS+=("/etc/opt/marzneshin")
    [[ ! -d "/var/lib/marzneshin" ]] && MISSING_DIRS+=("/var/lib/marzneshin")
    [[ ! -d "/var/lib/marznode" ]] && MISSING_DIRS+=("/var/lib/marznode")

    if [[ ${#MISSING_DIRS[@]} -gt 0 ]]; then
        echo "========================================"
        echo "          CRITICAL ERROR"
        echo "========================================"
        echo " The following required directories are missing:"
        for dir in "${MISSING_DIRS[@]}"; do
            echo "   [ERROR] $dir"
        done
        echo
        echo " Please install Marzneshin properly before transferring."
        echo " Backup transfer aborted."
        echo "========================================"
        read -p "Press Enter to return to menu..."
        return
    fi

    echo "All required directories found."
    echo

    # ==============================
    # Detect Database Type
    # ==============================

    DB_TYPE=$(detect_db_type)
    case $DB_TYPE in
        sqlite)
            echo "Database: SQLite (files included in /var/lib/marzneshin)"
            DB_BACKUP_SCRIPT=""
            ;;
        mysql)
            echo "Database: MySQL"
            DB_BACKUP_SCRIPT=$(cat <<'EOF'
    DB_PASS=$(grep 'MYSQL_ROOT_PASSWORD:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_NAME=$(grep 'MYSQL_DATABASE:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_USER="root"
    if [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
        mkdir -p "$OUTPUT_DIR/Marzneshin-Mysql"
        mysqldump -h 127.0.0.1 -P 3306 -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$OUTPUT_DIR/Marzneshin-Mysql/marzneshin_backup.sql" 2>/dev/null && \
        echo "MySQL backup created." || echo "MySQL backup failed."
    else
        echo "MySQL credentials not found in docker-compose.yml"
    fi
EOF
)
            ;;
        mariadb)
            echo "Database: MariaDB"
            DB_BACKUP_SCRIPT=$(cat <<'EOF'
    DB_PASS=$(grep 'MARIADB_ROOT_PASSWORD:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_NAME=$(grep 'MARIADB_DATABASE:' "$DOCKER_COMPOSE" | awk -F': ' '{print $2}' | tr -d ' "')
    DB_USER="root"
    if [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ]; then
        mkdir -p "$OUTPUT_DIR/Marzneshin-Mysql"
        mysqldump -h 127.0.0.1 -P 3306 -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$OUTPUT_DIR/Marzneshin-Mysql/marzneshin_backup.sql" 2>/dev/null && \
        echo "MariaDB backup created." || echo "MariaDB backup failed."
    else
        echo "MariaDB credentials not found in docker-compose.yml"
    fi
EOF
)
            ;;
    esac

    echo

    # ==============================
    # Build & Run Transfer Script
    # ==============================

    TRANSFER_SCRIPT="/root/Transfer_backup.sh"

    cat > "$TRANSFER_SCRIPT" << EOF
#!/bin/bash
echo "Starting transfer backup..."
echo "Date: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------"

BACKUP_DIR="/root/backuper_marzneshin"
REMOTE_IP="$REMOTE_IP"
REMOTE_USER="$REMOTE_USER"
REMOTE_PASS="$REMOTE_PASS"
REMOTE_ETC="/etc/opt/marzneshin"
REMOTE_NODE="/var/lib/marznode"
REMOTE_MARZ="/var/lib/marzneshin"
REMOTE_MYSQL="/root/Marzneshin-Mysql"
DATE=\$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_DIR="\$BACKUP_DIR/backup_\$DATE"

mkdir -p "\$OUTPUT_DIR"

echo "Copying local folders..."
cp -r /etc/opt/marzneshin/ "\$OUTPUT_DIR/etc_opt/" 2>/dev/null
cp -r /var/lib/marznode/ "\$OUTPUT_DIR/var_lib_marznode/" 2>/dev/null
rsync -a --exclude='mysql' /var/lib/marzneshin/ "\$OUTPUT_DIR/var_lib_marzneshin/" 2>/dev/null

DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
$DB_BACKUP_SCRIPT

echo "Installing sshpass if needed..."
command -v sshpass &>/dev/null || apt update && apt install -y sshpass

echo "Cleaning remote server..."
sshpass -p "\$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "\$REMOTE_USER@\$REMOTE_IP" "
    echo 'Removing old data...'
    rm -rf '\$REMOTE_ETC' '\$REMOTE_NODE' '\$REMOTE_MARZ' '\$REMOTE_MYSQL'
    mkdir -p '\$REMOTE_ETC' '\$REMOTE_NODE' '\$REMOTE_MARZ' '\$REMOTE_MYSQL'
" || { echo "Failed to connect to remote server!"; exit 1; }

echo "Transferring data to \$REMOTE_IP..."
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/etc_opt/" "\$REMOTE_USER@\$REMOTE_IP:\$REMOTE_ETC/" && echo "etc_opt transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/var_lib_marznode/" "\$REMOTE_USER@\$REMOTE_IP:\$REMOTE_NODE/" && echo "var_lib_marznode transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/var_lib_marzneshin/" "\$REMOTE_USER@\$REMOTE_IP:\$REMOTE_MARZ/" && echo "var_lib_marzneshin transferred"
[[ -d "\$OUTPUT_DIR/Marzneshin-Mysql" ]] && sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/Marzneshin-Mysql/" "\$REMOTE_USER@\$REMOTE_IP:\$REMOTE_MYSQL/" && echo "Database transferred"

echo "Restarting Marzneshin on remote..."
sshpass -p "\$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "\$REMOTE_USER@\$REMOTE_IP" "marzneshin restart" && echo "Restart successful" || echo "Restart failed"

echo "Cleaning local backup..."
rm -rf "\$BACKUP_DIR"/*

echo "========================================"
echo "       TRANSFER COMPLETED!"
echo "       Date: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
EOF

    chmod +x "$TRANSFER_SCRIPT"
    echo "Running transfer..."
    echo "----------------------------------------"
    bash "$TRANSFER_SCRIPT"

    read -p "Press Enter to return to menu..."
}

# ----- Main Menu -----
function main_menu() {
    while true; do
        clear
        echo "========================================="
        echo " Backuper Marzneshin Menu"
        echo "========================================="
        echo "[1] Install Backuper"
        echo "[2] Remove Backuper"
        echo "[3] Run Script"
        echo "[4] Transfer Backup"
        echo "[5] Exit"
        echo "-----------------------------------------"
        read -p "Choose an option: " OPTION
        case $OPTION in
            1) install_backuper ;;
            2) remove_backuper ;;
            3) run_script ;;
            4) transfer_backup ;;
            5) exit 0 ;;
            *) echo "Invalid choice!"; sleep 1 ;;
        esac
    done
}

# Start
install_requirements
main_menu
