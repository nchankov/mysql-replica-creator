#!/bin/bash

#============================================================#
# MySQL Replication Setup Script                             #
#============================================================#

#load the configuration from the .env file
if [ -f .env ]; then
    set -o allexport
    source .env
    set +o allexport
else
    echo "❌ .env file not found. Please create it from the .env.example file."
    exit 1
fi


SOURCE_SERVER="$REMOTE_IP:$REMOTE_SSH_PORT"
SOURCE_SSH="ssh -p$REMOTE_SSH_PORT $REMOTE_SSH_USER@$REMOTE_IP"  # the port of the source replica


# Check if the current server has passwordless access to the source server
if $SOURCE_SSH -o BatchMode=yes -o ConnectTimeout=5  "exit" 2>/dev/null; then
  echo "✅ Passwordless access to $SOURCE_SERVER is available."
else
  echo "❌ Passwordless access to $SOURCE_SERVER is not available. Please set it up before running this script."
  exit 1
fi

# Check if the access to the local mysql server is available
LOCAL_MYSQL_ACCESS=$(mysql -u"$LOCAL_MYSQL_USER" -N -s -e "SELECT 1;" 2>/dev/null)
if [ "$LOCAL_MYSQL_ACCESS" == "1" ]; then
  echo "✅ Local MySQL server is accessible"
else  
  echo "❌ Local MySQL server is not accessible using $LOCAL_MYSQL_USER@localhost. Try to fix that before running this script."
  exit 1
fi

# get the Mysql server version
LOCAL_FULL_VERSION=$(mysql -u"$LOCAL_MYSQL_USER" -N -s -e "SELECT VERSION();")
# Extract main version (before the first dot)
LOCAL_MAIN_VERSION=$(echo "$LOCAL_FULL_VERSION" | cut -d. -f1)
if [ "$LOCAL_MAIN_VERSION" != "$MYSQL_VERSION" ]; then
    echo "❌ Local MySQL server is uncompatible with the script. Expected $MYSQL_VERSION but found $LOCAL_MAIN_VERSION."
    exit 1
fi

# Check if the access to the mysql server is available
REMOTE_MYSQL_ACCESS=$($SOURCE_SSH "mysql -u\"$REMOTE_MYSQL_USER\" -N -s -e \"SELECT 1;\"")
if [ "$REMOTE_MYSQL_ACCESS" == "1" ]; then
  echo "✅ Remote MySQL server is accessible"
else
    echo "❌ Remote MySQL server is not accessible using $MYSQL_USER@localhost and no password. Try to fix that before running this script."
    exit 1
fi

# Check the mysql version of the source server
REMOTE_FULL_VERSION=$($SOURCE_SSH "mysql -u\"$REMOTE_MYSQL_USER\" -N -s -e \"SELECT VERSION();\"")
REMOTE_MAIN_VERSION=$(echo "$REMOTE_FULL_VERSION" | cut -d. -f1)
if [ "$REMOTE_MAIN_VERSION" != "$MYSQL_VERSION" ]; then
    echo "❌ Remote MySQL server is uncompatible with the script. Expected $MYSQL_VERSION but found $REMOTE_MAIN_VERSION."
    exit 1
fi

echo ""
echo "✅ Checks are complete. Starting the syncronization process..."
echo ""

#Sleep for 5 seconds to give the user time to read the checks
sleep 5

# Start the script
echo "🚀 Starting replica setup on $(hostname) from $SOURCE_SERVER..."

#Preserving the current server id
CURRENT_SERVER_ID=$(mysql -u "$LOCAL_MYSQL_USER" -e "SELECT @@server_id;" | tail -n 1)

# Step 1: Get binlog position from the replica
echo "🔒 Getting binlog coordinates from $SOURCE_SERVER..."

# Step 2: Stop the replication on the source replica (if the source server is a replica)
IS_REPLICA=$($SOURCE_SSH "mysql -u \"$REMOTE_MYSQL_USER\" -e \"SHOW REPLICA STATUS\G\"" | grep -c "Source_Host")
if [ "$IS_REPLICA" -ne 0 ]; then
    echo "🛑 Stopping MySQL replication on the $SOURCE_SERVER..."
    $SOURCE_SSH "mysql -u $REMOTE_MYSQL_USER -e \"STOP REPLICA;\""
else
    echo "🔒 Setting the $SOURCE_SERVER as read only to prevent loss of data. If this is your live mysql server and this would block your application stop the script. The script will continue in 10 seconds..."
    sleep 10
    $SOURCE_SSH "mysql -u \"$REMOTE_MYSQL_USER\" -e \"FLUSH TABLES WITH READ LOCK; SET GLOBAL read_only = 1; SET GLOBAL super_read_only = 1;\""
fi

# Step 3: Get the binlog file and position form the source replica
read -r LOG_FILE <<< $($SOURCE_SSH "mysql -u \"$REMOTE_MYSQL_USER\" -e \"SHOW MASTER STATUS\G\"" | awk '/File:/ {print $2}' | head -n 1)
read -r LOG_POS <<< $($SOURCE_SSH "mysql -u \"$REMOTE_MYSQL_USER\" -e \"SHOW MASTER STATUS\G\"" | awk '/Position:/ {print $2}' | head -n 1)
echo "📌 Binlog File: $LOG_FILE, Position: $LOG_POS"

# Step 4: Stop MySQL and clear data dir
echo "🛑 Stopping MySQL and clearing $LOCAL_DATA_DIR..."
service mysql stop 
rm -rf $LOCAL_DATA_DIR/*
mkdir -p $LOCAL_DATA_DIR
chown mysql:mysql $LOCAL_DATA_DIR

# Step 5: Rsync from SOURCE HOST to the current server (excluding auto.cnf)
echo "📦 Rsyncing data from $SOURCE_SERVER (excluding auto.cnf)..."
rsync -aP -e "ssh -p $REMOTE_SSH_PORT" --quiet --delete --exclude "auto.cnf" root@$REMOTE_IP:$REMOTE_DATA_DIR/ $LOCAL_DATA_DIR/

# Step 6: If the source server is a replica, start the replication on the source server
if [ "$IS_REPLICA" -ne 0 ]; then
  echo "✅ Starting back the replication on $SOURCE_SERVER"
  $SOURCE_SSH "mysql -u \"$REMOTE_MYSQL_USER\" -e \"START REPLICA;\""
else
  echo "✅ Unlocking the $SOURCE_SERVER for writing..."
  $SOURCE_SSH "mysql -u \"$REMOTE_MYSQL_USER\" -e \"SET GLOBAL read_only = 0; SET GLOBAL super_read_only = 0; UNLOCK TABLES;\""
fi

# Step 7: Start MySQL on the current server
echo "🔄 Starting MySQL service..."
chown -R mysql:mysql $LOCAL_DATA_DIR
service mysql start

# Step 8: Set up replication to the master (DB1)
echo "⚙️ Configuring replication to $SOURCE_SERVER..."

# Step 9: Set up the server_id (as it's copied from the source server after this)
mysql -u "$LOCAL_MYSQL_USER" -e "SET GLOBAL server_id = $CURRENT_SERVER_ID;"
# Step 10: Set the connection to the source
mysql -u "$LOCAL_MYSQL_USER" -e "
  RESET REPLICA ALL;
  CHANGE REPLICATION SOURCE TO 
    SOURCE_HOST='$REMOTE_IP',
    SOURCE_PORT=$REMOTE_MYSQL_PORT,
    SOURCE_USER='$REPLICA_USER',
    SOURCE_PASSWORD='$REPLICA_PASS',
    SOURCE_LOG_FILE='$LOG_FILE', 
    SOURCE_LOG_POS=$LOG_POS;
  START REPLICA;
"
echo "✅ $(hostname) is now replicating from $SOURCE_SERVER!"