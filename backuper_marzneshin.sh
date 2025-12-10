#!/bin/bash

# ----- Install Required Packages -----
function install_requirements() {
    clear
    echo "Installing required packages..."
    apt update -y && apt upgrade -y
    apt install zip unzip tar gzip p7zip-full mariadb-client sshpass xz-utils zstd postgresql-client-common -y
}

# ----- Detect Database Type Pasarguard -----
function detect_db_type_pasarguard() {
    local env_file="/opt/pasarguard/.env"
    [[ ! -f "$env_file" ]] && { echo ".env not found."; echo ""; return; }

    local db_url
    db_url=$(grep -E '^SQLALCHEMY_DATABASE_URL=' "$env_file" | tail -n1 | cut -d'=' -f2- | tr -d "\"'")
    db_url=$(echo "$db_url" | xargs)
    [[ -z "$db_url" ]] && { echo "SQLALCHEMY_DATABASE_URL not found."; echo ""; return; }

    if [[ "$db_url" == sqlite* ]]; then
        echo "sqlite"
    elif [[ "$db_url" == postgresql* ]]; then
        echo "postgresql"
    elif [[ "$db_url" == mysql* || "$db_url" == *"mysql+"* || "$db_url" == *"mysql://"* ]]; then
        echo "mysql"
    elif [[ "$db_url" == *"mariadb"* ]]; then
        echo "mariadb"
    else
        echo "Unsupported DB URL: $db_url"
        echo ""
    fi
}

# ----- Detect Database Type Marzneshin -----
function detect_db_type() {
    local docker_file="/etc/opt/marzneshin/docker-compose.yml"
    if [[ ! -f "$docker_file" ]]; then
        echo "docker-compose.yml not found. Assuming SQLite."
        echo "sqlite"
        return
    fi

    local db_url
    db_url=$(grep -i "SQLALCHEMY_DATABASE_URL" "$docker_file" | head -1 | cut -d'"' -f2 | cut -d"'" -f2)
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

# ----- Create Backup Script Based on DB Type Marzneshin -----
function create_backup_script() {
    local db_type="$1"
    local script_file="/root/marzneshin_backup.sh"
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

# Copy paths Marzneshin
mkdir -p etc/opt var/lib/marznode var/lib/marzneshin
cp -r /etc/opt/marzneshin/ etc/opt/ 2>/dev/null || true
rsync -a --include='xray_config.json' --exclude='*' /var/lib/marznode/ var/lib/marznode/ 2>/dev/null || true
rsync -a --exclude='mysql' --exclude='assets' /var/lib/marzneshin/ var/lib/marzneshin/ 2>/dev/null || true

# ==============================
# Database Backup Section Marzneshin
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

# ----- Create Backup Script Based on DB Type Pasarguard -----
function create_backup_script_pasarguard() {
    local db_type="$1"
    local script_file="/root/pasarguard_backup.sh"
    local backup_dir="/root/backuper_pasarguard"

    cat > "$script_file" <<'EOF'
#!/bin/bash
BACKUP_DIR="/root/backuper_pasarguard"
BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
CAPTION="__CAPTION__"
COMP_TYPE="__COMP_TYPE__"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_BASE="$BACKUP_DIR/backup_$DATE"
ARCHIVE=""
mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR" || exit 1

# Copy paths Pasarguard
mkdir -p opt/pasarguard opt/pg-node var/lib/pasarguard var/lib/pg-node
rsync -a /opt/pasarguard/   opt/pasarguard/   2>/dev/null || true
rsync -a /opt/pg-node/      opt/pg-node/      2>/dev/null || true
rsync -a /var/lib/pasarguard/ var/lib/pasarguard/ 2>/dev/null || true
rsync -a /var/lib/pg-node/    var/lib/pg-node/    2>/dev/null || true

# ==============================
# Database Backup Section Pasarguard
# ==============================
DB_BACKUP_DONE=0
ENV_FILE="/opt/pasarguard/.env"

parse_db_url() {
    local url="$1"
    url="${url#*://}"
    local creds="${url%%@*}"
    local hostdb="${url#*@}"
    local user="${creds%%:*}"
    local pass="${creds#*:}"; pass="${pass%%@*}"
    local hostport="${hostdb%%/*}"
    local dbname="${hostdb#*/}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"
    echo "$user" "$pass" "$host" "$port" "$dbname"
}

if [ -f "$ENV_FILE" ]; then
    DB_URL=$(grep -E '^SQLALCHEMY_DATABASE_URL=' "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | tr -d "\"'" | xargs)
    if [ -n "$DB_URL" ]; then
        DB_PROTO=$(echo "$DB_URL" | cut -d':' -f1)
        if [[ "$DB_PROTO" == sqlite* ]]; then
            echo "SQLite detected. DB files included in copied folders; no dump needed."
            DB_BACKUP_DONE=1
        else
            read DB_USER DB_PASS DB_HOST DB_PORT DB_NAME < <(parse_db_url "$DB_URL")
            : "${DB_USER:=pasarguard}"
            : "${DB_NAME:=pasarguard}"
            if [[ "$DB_PROTO" == postgresql* ]]; then
                : "${DB_PORT:=5432}"
                echo "Backing up PostgreSQL database..."
                PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -F c "$DB_NAME" > "$BACKUP_DIR/pasarguard_backup.dump" 2>/dev/null && DB_BACKUP_DONE=1
                [ $DB_BACKUP_DONE -eq 1 ] && echo "PostgreSQL backup completed." || echo "PostgreSQL backup failed."
            elif [[ "$DB_PROTO" == mysql* || "$DB_PROTO" == mariadb* ]]; then
                : "${DB_PORT:=3306}"
                echo "Backing up MariaDB/MySQL database..."
                mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" \
                    --single-transaction --routines --triggers --events --skip-lock-tables \
                    "$DB_NAME" > "$BACKUP_DIR/pasarguard_backup.sql" 2>/dev/null && DB_BACKUP_DONE=1
                [ $DB_BACKUP_DONE -eq 1 ] && echo "MariaDB/MySQL backup completed." || echo "MariaDB/MySQL backup failed."
            else
                echo "Unsupported DB protocol: $DB_PROTO"
            fi
        fi
    else
        echo "SQLALCHEMY_DATABASE_URL not found. Skipping DB backup."
    fi
else
    echo ".env not found. Skipping DB backup."
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

# ----- Create Backup Script Based on DB Type X-UI -----
function create_backup_script_x-ui() {
    local db_type="$1"
    local script_file="/root/x-ui_backup.sh"
    local backup_dir="/root/backuper_x-ui"

    cat > "$script_file" <<'EOF'
#!/bin/bash
BACKUP_DIR="/root/backuper_x-ui"
BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
CAPTION="__CAPTION__"
COMP_TYPE="__COMP_TYPE__"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_BASE="$BACKUP_DIR/backup_$DATE"
ARCHIVE=""
mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR" || exit 1

# Copy paths X-UI (contents only)
mkdir -p etc/x-ui root/cert/
rsync -a /etc/x-ui/ etc/x-ui/ 2>/dev/null || true
cp -a /root/cert/. root/cert/ 2>/dev/null || true

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
        echo "[1] Marzneshin"
        echo "[2] Pasarguard"
        echo "[3] X-ui"
        echo
        echo "-----------------------------------------"
        read -p "Choose an option: " PANEL_OPTION
        [[ -z "$PANEL_OPTION" ]] && { echo "No option selected."; sleep 1; return; }
        case "$PANEL_OPTION" in
            1) PANEL_TYPE="Marzneshin"; break ;;
            2) PANEL_TYPE="Pasarguard"; break ;;
            3) PANEL_TYPE="X-ui"; break ;;
            *) echo "Invalid choice. Try again."; sleep 1 ;;
        esac
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

[[ "$PANEL_TYPE" == "Marzneshin" ]] && DEFAULT_CAPTION="Marzneshin Backup - $(date +"%Y-%m-%d %H:%M")"
[[ "$PANEL_TYPE" == "Pasarguard" ]] && DEFAULT_CAPTION="Pasarguard Backup - $(date +"%Y-%m-%d %H:%M")"
[[ "$PANEL_TYPE" == "X-ui" ]] && DEFAULT_CAPTION="X-ui Backup - $(date +"%Y-%m-%d %H:%M")"

    echo -e "\nStep 4 - Enter File Caption"
    read -p "Caption File: " CAPTION
    [[ -z "$CAPTION" ]] && CAPTION="$DEFAULT_CAPTION"

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

    # Step 6 - Detect Database + build scripts
    if [[ "$PANEL_TYPE" == "Pasarguard" ]]; then
        echo -e "\nStep 6 - Detecting Database Type (Pasarguard)"
        DB_TYPE=$(detect_db_type_pasarguard)
        case $DB_TYPE in
            postgresql) echo "Pasarguard: PostgreSQL detected." ;;
            mariadb|mysql) echo "Pasarguard: MariaDB/MySQL detected." ;;
            sqlite) echo "Pasarguard: SQLite detected." ;;
            "")         echo "DB type not found. Aborting."; return ;;
            *)          echo "Unsupported DB type. Aborting."; return ;;
        esac

        create_backup_script_pasarguard "$DB_TYPE"
        sed -i "s|__BOT_TOKEN__|$BOT_TOKEN|g" /root/pasarguard_backup.sh
        sed -i "s|__CHAT_ID__|$CHAT_ID|g" /root/pasarguard_backup.sh
        sed -i "s|__CAPTION__|$CAPTION|g" /root/pasarguard_backup.sh
        sed -i "s|__COMP_TYPE__|$COMP_TYPE|g" /root/pasarguard_backup.sh

        (crontab -l 2>/dev/null | grep -v "pasarguard_backup.sh"; echo "$CRON_TIME bash /root/pasarguard_backup.sh") | crontab -

        echo -e "\nStep 7 - Running first backup..."
        bash /root/pasarguard_backup.sh

        echo -e "\nBackup successfully sent"
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
             -d chat_id="$CHAT_ID" -d text="Backuper installed and first backup sent." >/dev/null

    else
        echo -e "\nStep 6 - Detecting Database Type"
        DB_TYPE=$(detect_db_type)
        case $DB_TYPE in
            sqlite)   echo "SQLite detected." ;;
            mysql)    echo "MySQL detected." ;;
            mariadb)  echo "MariaDB detected." ;;
            *) echo "DB type unknown/unsupported. Aborting."; return ;;
        esac

        create_backup_script "$DB_TYPE"
        sed -i "s|__BOT_TOKEN__|$BOT_TOKEN|g" /root/marzneshin_backup.sh
        sed -i "s|__CHAT_ID__|$CHAT_ID|g" /root/marzneshin_backup.sh
        sed -i "s|__CAPTION__|$CAPTION|g" /root/marzneshin_backup.sh
        sed -i "s|__COMP_TYPE__|$COMP_TYPE|g" /root/marzneshin_backup.sh

        (crontab -l 2>/dev/null | grep -v "marzneshin_backup.sh"; echo "$CRON_TIME bash /root/marzneshin_backup.sh") | crontab -

        echo -e "\nStep 7 - Running first backup..."
        bash /root/marzneshin_backup.sh

        echo -e "\nBackup successfully sent"
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
             -d chat_id="$CHAT_ID" -d text="Backuper installed and first backup sent." >/dev/null

                     create_backup_script_x-ui "$DB_TYPE"
        sed -i "s|__BOT_TOKEN__|$BOT_TOKEN|g" /root/x-ui_backup.sh
        sed -i "s|__CHAT_ID__|$CHAT_ID|g" /root/x-ui_backup.sh
        sed -i "s|__CAPTION__|$CAPTION|g" /root/x-ui_backup.sh
        sed -i "s|__COMP_TYPE__|$COMP_TYPE|g" /root/x-ui_backup.sh

        (crontab -l 2>/dev/null | grep -v "x-ui_backup.sh"; echo "$CRON_TIME bash /root/x-ui_backup.sh") | crontab -
        echo -e "\nStep 7 - Running first backup..."
        bash /root/x-ui_backup.sh
        
        echo -e "\nBackup successfully sent"
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
             -d chat_id="$CHAT_ID" -d text="Backuper installed and first backup sent." >/dev/null

    fi

    read -p "Press Enter to return to menu..."
}

# ----- Remove Backuper -----
function remove_backuper() {
    clear
    echo "Removing Backuper..."
    rm -f /root/marzneshin_backup.sh /root/pasarguard_backup.sh
    rm -rf /root/backuper_marzneshin /root/backuper_pasarguard
    crontab -l 2>/dev/null | grep -v 'marzneshin_backup.sh' | grep -v 'pasarguard_backup.sh' | crontab -
    echo "Backuper removed successfully."
    read -p "Press Enter to return..."
}

# ----- Run Script Manually -----
function run_script() {
    clear
    if [[ -f /root/marzneshin_backup.sh ]]; then
        bash /root/marzneshin_backup.sh
    elif [[ -f /root/pasarguard_backup.sh ]]; then
        bash /root/pasarguard_backup.sh
    else
        echo "Backup script not found. Install first."
    fi
    read -p "Press Enter to return..."
}

function transfer_backup() {
    clear
    echo "========================================="
    echo "         Transfer Backup"
    echo "========================================="
    echo "[1] Marzneshin"
    echo "[2] Pasarguard"
    echo "-----------------------------------------"
    read -p "Choose (1-2): " PANEL_TYPE

    clear
    echo "Enter Remote Server Details:"
    read -p "IP Server [Client]: " REMOTE_IP
    read -p "User Server [Client]: " REMOTE_USER
    read -s -p "Password Server [Client]: " REMOTE_PASS
    echo

    TRANSFER_SCRIPT=$(mktemp /tmp/Transfer_backup.XXXXXX.sh)
    trap 'rm -f "$TRANSFER_SCRIPT"' EXIT

    if [[ "$PANEL_TYPE" == "1" ]]; then
        PANEL_NAME="Marzneshin"
        BACKUP_DIR="/root/backuper_marzneshin"
        REMOTE_ETC="/etc/opt/marzneshin"
        REMOTE_NODE="/var/lib/marznode"
        REMOTE_MARZ="/var/lib/marzneshin"
        REMOTE_DB="/root/Marzneshin-Mysql"
        DB_ENABLED=0
        DB_DIR_NAME="Marzneshin-Mysql"

        MISSING_DIRS=()
        [[ ! -d "/etc/opt/marzneshin" ]] && MISSING_DIRS+=("/etc/opt/marzneshin")
        [[ ! -d "/var/lib/marzneshin" ]] && MISSING_DIRS+=("/var/lib/marzneshin")
        [[ ! -d "/var/lib/marznode" ]] && MISSING_DIRS+=("/var/lib/marznode")
        if [[ ${#MISSING_DIRS[@]} -gt 0 ]]; then
            echo "========================================"
            echo "          CRITICAL ERROR"
            echo "========================================"
            echo " The following required directories are missing:"
            for dir in "${MISSING_DIRS[@]}"; do echo "   [ERROR] $dir"; done
            echo
            echo " Please install Marzneshin properly before transferring."
            echo " Backup transfer aborted."
            echo "========================================"
            read -p "Press Enter to return to menu..."
            return
        fi

        DB_TYPE=$(detect_db_type)
        case $DB_TYPE in
            sqlite)
                echo "Database: SQLite (files included in /var/lib/marzneshin)"
                DB_BACKUP_SCRIPT=""
                DB_ENABLED=0
                ;;
            mysql)
                echo "Database: MySQL"
                DB_ENABLED=1
                DB_BACKUP_SCRIPT=$(cat <<'EOF'
DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
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
                DB_ENABLED=1
                DB_BACKUP_SCRIPT=$(cat <<'EOF'
DOCKER_COMPOSE="/etc/opt/marzneshin/docker-compose.yml"
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

        cat > "$TRANSFER_SCRIPT" <<EOF
#!/bin/bash
echo "Starting transfer backup ($PANEL_NAME)..."
echo "Date: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------"

BACKUP_DIR="$BACKUP_DIR"
REMOTE_IP="$REMOTE_IP"
REMOTE_USER="$REMOTE_USER"
REMOTE_PASS="$REMOTE_PASS"
REMOTE_ETC="$REMOTE_ETC"
REMOTE_NODE="$REMOTE_NODE"
REMOTE_MARZ="$REMOTE_MARZ"
REMOTE_DB="$REMOTE_DB"
DB_ENABLED="$DB_ENABLED"
DB_DIR_NAME="$DB_DIR_NAME"
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
sshpass -p "\$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "\$REMOTE_USER@\${REMOTE_IP}" "
    echo 'Removing old data...'
    rm -rf '\$REMOTE_ETC' '\$REMOTE_NODE' '\$REMOTE_MARZ'
    mkdir -p '\$REMOTE_ETC' '\$REMOTE_NODE' '\$REMOTE_MARZ'
    if [ \"\$DB_ENABLED\" = \"1\" ]; then
        rm -rf '\$REMOTE_DB'
        mkdir -p '\$REMOTE_DB'
    fi
" || { echo "Failed to connect to remote server!"; exit 1; }

echo "Transferring data to \$REMOTE_IP..."
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/etc_opt/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_ETC/" && echo "etc_opt transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/var_lib_marznode/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_NODE/" && echo "var_lib_marznode transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/var_lib_marzneshin/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_MARZ/" && echo "var_lib_marzneshin transferred"
if [ "\$DB_ENABLED" = "1" ] && [ -d "\$OUTPUT_DIR/\$DB_DIR_NAME" ]; then
    sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/\$DB_DIR_NAME/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_DB/" && echo "Database transferred"
fi

echo "Restarting Marzneshin on remote..."
sshpass -p "\$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "\$REMOTE_USER@\${REMOTE_IP}" "marzneshin restart" && echo "Restart successful" || echo "Restart failed"

echo "Cleaning local backup..."
rm -rf "\$BACKUP_DIR"/*

echo "========================================"
echo "       TRANSFER COMPLETED!"
echo "       Date: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
EOF

    elif [[ "$PANEL_TYPE" == "2" ]]; then
        PANEL_NAME="Pasarguard"
        BACKUP_DIR="/root/backuper_pasarguard"
        REMOTE_PAS="/opt/pasarguard"
        REMOTE_PG_NODE="/opt/pg-node"
        REMOTE_LIB_PAS="/var/lib/pasarguard"
        REMOTE_LIB_PG="/var/lib/pg-node"
        REMOTE_DB="/root/Pasarguard-DB"
        DB_ENABLED=0
        DB_DIR_NAME="Pasarguard-DB"

        MISSING_DIRS=()
        [[ ! -d "/opt/pasarguard" ]] && MISSING_DIRS+=("/opt/pasarguard")
        [[ ! -d "/opt/pg-node" ]] && MISSING_DIRS+=("/opt/pg-node")
        [[ ! -d "/var/lib/pasarguard" ]] && MISSING_DIRS+=("/var/lib/pasarguard")
        [[ ! -d "/var/lib/pg-node" ]] && MISSING_DIRS+=("/var/lib/pg-node")
        if [[ ${#MISSING_DIRS[@]} -gt 0 ]]; then
            echo "========================================"
            echo "          CRITICAL ERROR"
            echo "========================================"
            echo " The following required directories are missing:"
            for dir in "${MISSING_DIRS[@]}"; do echo "   [ERROR] $dir"; done
            echo
            echo " Please install Pasarguard properly before transferring."
            echo " Backup transfer aborted."
            echo "========================================"
            read -p "Press Enter to return to menu..."
            return
        fi

        DB_TYPE=$(detect_db_type_pasarguard)
        case $DB_TYPE in
            sqlite)
                echo "Database: SQLite (files included in copied folders)"
                DB_BACKUP_SCRIPT=""
                DB_ENABLED=0
                ;;
            mysql|mariadb)
                echo "Database: MariaDB/MySQL"
                DB_ENABLED=1
                DB_BACKUP_SCRIPT=$(cat <<'EOF'
ENV_FILE="/opt/pasarguard/.env"
parse_db_url() {
    local url="$1"
    url="${url#*://}"
    local creds="${url%%@*}"
    local hostdb="${url#*@}"
    local user="${creds%%:*}"
    local pass="${creds#*:}"; pass="${pass%%@*}"
    local hostport="${hostdb%%/*}"
    local dbname="${hostdb#*/}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"
    echo "$user" "$pass" "$host" "$port" "$dbname"
}
if [ -f "$ENV_FILE" ]; then
    DB_URL=$(grep -E '^SQLALCHEMY_DATABASE_URL=' "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | tr -d "\"'" | xargs)
    if [ -n "$DB_URL" ]; then
        read DB_USER DB_PASS DB_HOST DB_PORT DB_NAME < <(parse_db_url "$DB_URL")
        : "${DB_USER:=pasarguard}"
        : "${DB_NAME:=pasarguard}"
        : "${DB_PORT:=3306}"
        echo "Backing up MariaDB/MySQL database..."
        mkdir -p "$OUTPUT_DIR/Pasarguard-DB"
        mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" \
            --single-transaction --routines --triggers --events --skip-lock-tables \
            "$DB_NAME" > "$OUTPUT_DIR/Pasarguard-DB/pasarguard_backup.sql" 2>/dev/null && \
            echo "MariaDB/MySQL backup created." || echo "MariaDB/MySQL backup failed."
    else
        echo "SQLALCHEMY_DATABASE_URL not found in .env"
    fi
else
    echo ".env not found for Pasarguard"
fi
EOF
)
                ;;
            postgresql)
                echo "Database: PostgreSQL"
                DB_ENABLED=1
                DB_BACKUP_SCRIPT=$(cat <<'EOF'
ENV_FILE="/opt/pasarguard/.env"
parse_db_url() {
    local url="$1"
    url="${url#*://}"
    local creds="${url%%@*}"
    local hostdb="${url#*@}"
    local user="${creds%%:*}"
    local pass="${creds#*:}"; pass="${pass%%@*}"
    local hostport="${hostdb%%/*}"
    local dbname="${hostdb#*/}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"
    echo "$user" "$pass" "$host" "$port" "$dbname"
}
if [ -f "$ENV_FILE" ]; then
    DB_URL=$(grep -E '^SQLALCHEMY_DATABASE_URL=' "$ENV_FILE" | tail -n1 | cut -d'=' -f2- | tr -d "\"'" | xargs)
    if [ -n "$DB_URL" ]; then
        read DB_USER DB_PASS DB_HOST DB_PORT DB_NAME < <(parse_db_url "$DB_URL")
        : "${DB_USER:=pasarguard}"
        : "${DB_NAME:=pasarguard}"
        : "${DB_PORT:=5432}"
        echo "Backing up PostgreSQL database..."
        mkdir -p "$OUTPUT_DIR/Pasarguard-DB"
        PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -F c "$DB_NAME" > "$OUTPUT_DIR/Pasarguard-DB/pasarguard_backup.dump" 2>/dev/null && \
            echo "PostgreSQL backup created." || echo "PostgreSQL backup failed."
    else
        echo "SQLALCHEMY_DATABASE_URL not found in .env"
    fi
else
    echo ".env not found for Pasarguard"
fi
EOF
)
                ;;
            *)
                echo "Database: unknown/unsupported. Skipping DB dump."
                DB_BACKUP_SCRIPT=""
                DB_ENABLED=0
                ;;
        esac

        cat > "$TRANSFER_SCRIPT" <<EOF
#!/bin/bash
echo "Starting transfer backup ($PANEL_NAME)..."
echo "Date: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------"

BACKUP_DIR="$BACKUP_DIR"
REMOTE_IP="$REMOTE_IP"
REMOTE_USER="$REMOTE_USER"
REMOTE_PASS="$REMOTE_PASS"
REMOTE_PAS="$REMOTE_PAS"
REMOTE_PG_NODE="$REMOTE_PG_NODE"
REMOTE_LIB_PAS="$REMOTE_LIB_PAS"
REMOTE_LIB_PG="$REMOTE_LIB_PG"
REMOTE_DB="$REMOTE_DB"
DB_ENABLED="$DB_ENABLED"
DB_DIR_NAME="$DB_DIR_NAME"
DATE=\$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_DIR="\$BACKUP_DIR/backup_\$DATE"

mkdir -p "\$OUTPUT_DIR"

echo "Copying local folders..."
rsync -a /opt/pasarguard/ "\$OUTPUT_DIR/opt_pasarguard/" 2>/dev/null
rsync -a /opt/pg-node/ "\$OUTPUT_DIR/opt_pg_node/" 2>/dev/null
rsync -a /var/lib/pasarguard/ "\$OUTPUT_DIR/var_lib_pasarguard/" 2>/dev/null
rsync -a /var/lib/pg-node/ "\$OUTPUT_DIR/var_lib_pg_node/" 2>/dev/null

$DB_BACKUP_SCRIPT

echo "Installing sshpass if needed..."
command -v sshpass &>/dev/null || apt update && apt install -y sshpass

echo "Cleaning remote server..."
sshpass -p "\$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "\$REMOTE_USER@\${REMOTE_IP}" "
    echo 'Removing old data...'
    rm -rf '\$REMOTE_PAS' '\$REMOTE_PG_NODE' '\$REMOTE_LIB_PAS' '\$REMOTE_LIB_PG'
    mkdir -p '\$REMOTE_PAS' '\$REMOTE_PG_NODE' '\$REMOTE_LIB_PAS' '\$REMOTE_LIB_PG'
    if [ \"\$DB_ENABLED\" = \"1\" ]; then
        rm -rf '\$REMOTE_DB'
        mkdir -p '\$REMOTE_DB'
    fi
" || { echo "Failed to connect to remote server!"; exit 1; }

echo "Transferring data to \$REMOTE_IP..."
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/opt_pasarguard/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_PAS/" && echo "opt_pasarguard transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/opt_pg_node/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_PG_NODE/" && echo "opt_pg_node transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/var_lib_pasarguard/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_LIB_PAS/" && echo "var_lib_pasarguard transferred"
sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/var_lib_pg_node/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_LIB_PG/" && echo "var_lib_pg_node transferred"
if [ "\$DB_ENABLED" = "1" ] && [ -d "\$OUTPUT_DIR/\$DB_DIR_NAME" ]; then
    sshpass -p "\$REMOTE_PASS" rsync -a "\$OUTPUT_DIR/\$DB_DIR_NAME/" "\$REMOTE_USER@\${REMOTE_IP}:\$REMOTE_DB/" && echo "Database transferred"
fi

echo "Cleaning local backup..."
rm -rf "\$BACKUP_DIR"/*

echo "========================================"
echo "       TRANSFER COMPLETED!"
echo "       Date: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
EOF

    else
        echo "Invalid choice."
        read -p "Press Enter to return..."
        return
    fi

    chmod +x "$TRANSFER_SCRIPT"
    echo "Running transfer..."
    echo "----------------------------------------"
    bash "$TRANSFER_SCRIPT"
    rm -f "$TRANSFER_SCRIPT"
    trap - EXIT
    read -p "Press Enter to return to menu..."
}

# ----- Main Menu -----
function main_menu() {
    while true; do
        clear
        echo "========================================="
        echo " Backuper Menu"
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
