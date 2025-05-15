# mysql-sync
Quick Mysql Synchronization script

## Description
The script is useful if there is a need a replica server to be created. The script is using the rsync methof of 
Synchronization, which is very fast and efficient.

## Terms
- Remote server (RS) - the server from which the data will be copied. It should be an existing mysql server. The server could 
  be a master mysql server or an existing replica server. If the server is a master server. The script will lock it as 
  read-only mode during the copying of the data. If this would block the work of your application, concider the time 
  when the script is run (e.g. when it's off the office hours).

- Local server (LS) - the server on which the script is run (it should have an empty mysql server installed, or the data in 
  it would be replaced with the data from the remote server).

## Explanation how the script is set to work
The LS shuld have passwordless ssh access to the RS. 
Both servers should have passwordless access to mysql. This means when running 
```bash
mysql -u root
```
it should not ask for a password.

Also both servers should have the same mysql version. The script would check for the correct version and stop if they 
don't match.

Once the script is sure it has the correct access the synchronization starts.

If the server is a master mysql server, then the script will lock it as read-only mode during the copying of the data.

If the server is a replica server, the script will stop the replication and then start it again after the synchronization 
is done.

The script will copy the data (from mysql data dir) from the RS to the LS using rsync.

Once the sync is done, the script will start the RS replication again (or if it's a master server, it will unlock it).

Then the script will set the replication connection to the RS and start the replication on the LS.

So if the script is using a master server, the replica would be linked directly to it. 
If the script is using a replica server, the new replica will be linked to the old one, so it would be chained.

If the DBTRAC is used to manage the replicationm the DBTRAC would automatically change the replication connection once 
it's fully up to date.

## Prerequisites
The script is tested on Ubuntu 24.04, but would work on other Linux versions as well.

The server should have the following packages installed:
- mysql-server (this also inclused mysql-client)
- rsync

## Usage
1. Clone the repository (or Download it as a zip file) into the server which would become the replica server.:

```bash
git clone git@github.com:nchankov/mysql-sync.git
```

2. rename .env.example to .env and set at least the following variables:
```bash
REMOTE_IP    - the server from which the data will be copied
REPLICA_USER - the user which will be used to connect to the remote server
REPLICA_PASS - the password for the user
```
All other variables are optional and have default values.

3. Make the script mysql.8.sh executable (it should be already executable, but just in case)

4. Run the script and read the status messages:
```bash
./mysql.8.sh
```

5. If the script is successful the sever on which the script was run will be a replica of the remote server.