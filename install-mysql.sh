#!/bin/bash


read -p "Mysql cluster address: " cluster_addr
if [ -z "$cluster_addr" ]; then
    echo "Cluster address is required!"
    exit 1
fi

read -p "Mysql cluster node name: " node_name
if [ -z "$node_name" ]; then
    echo "Cluster node name is required!"
    exit 1
fi

read -p "Mysql cluster node address: " node_addr
if [ -z "$node_addr" ]; then
    echo "Cluster node adress is required!"
    exit 1
fi

read -p "Mysql bind address[0.0.0.0]: " bind_addr
[ -z "$bind_addr" ] && bind_addr=0.0.0.0

apt-get install software-properties-common
apt-key adv --keyserver keyserver.ubuntu.com --recv BC19DDBA
str=`lsb_release -a 2>>/dev/null | awk -F ':' 'BEGIN {dist="ubuntu";release="trusty"} /^(Distributor|Codename)/{if($1 ~ /^Distributor/){dist=$2}else{release=$2}} END {gsub(/^[^a-zA-Z]*/, "", release);gsub(/^[^a-zA-Z]*/, "", dist);printf("%s %s", tolower(dist), tolower(release))}'`
echo -e "# Codership Repository (Galera Cluster for MySQL)\n\
deb http://releases.galeracluster.com/$str main" > /etc/apt/sources.list.d/galera.list
apt-get update
apt-get install -y galera-3 galera-arbitrator-3 mysql-wsrep-5.6
update-rc.d mysql defaults

cat > /etc/mysql/my.cnf <<EOF 
[client]
port		= 3306
socket		= /var/run/mysqld/mysqld.sock

[mysqld_safe]
socket		= /var/run/mysqld/mysqld.sock
nice		= 0

[mysqld]
user		= mysql
pid-file	= /var/run/mysqld/mysqld.pid
socket		= /var/run/mysqld/mysqld.sock
port		= 3306
basedir		= /usr
datadir		= /var/lib/mysql
tmpdir		= /tmp
lc-messages-dir	= /usr/share/mysql
skip-external-locking

bind-address		= $bind_addr

key_buffer		= 256M
max_allowed_packet	= 64M
thread_stack		= 192K
thread_cache_size       = 8

myisam-recover          = BACKUP
max_connections         = 1000
#table_cache            = 16
#thread_concurrency     = 10

query_cache_limit	= 1M
query_cache_size        = 512M

log_error               = /var/log/mysql/error.log

#log_slow_queries	= /var/log/mysql/mysql-slow.log
#long_query_time         = 2

expire_logs_days	= 10
max_binlog_size         = 100M

binlog_format           = ROW
default-storage-engine  = InnoDB
innodb_autoinc_lock_mode= 2
wsrep_provider          = /usr/lib/libgalera_smm.so
wsrep_provider_options  = "gcache.size=300M; gcache.page_size=300M"
wsrep_cluster_name      = "galeracluster"
wsrep_cluster_address   = "gcomm://$cluster_addr"
wsrep_sst_method        = rsync
#wsrep_sst_auth          = 
wsrep_node_name         = $node_name
wsrep_node_address      = $node_addr

innodb_flush_log_at_trx_commit=0
innodb_buffer_pool_size = 3G
innodb_log_file_size    = 256M
innodb_flush_method     = O_DIRECT
innodb_log_buffer_size  = 8M

[mysqldump]
quick
quote-names
max_allowed_packet	= 64M

[mysql]
#no-auto-rehash	# faster start of mysql but no tab completition

[isamchk]
key_buffer		= 16M

#
# * IMPORTANT: Additional settings that can override those from this file!
#   The files must end with '.cnf', otherwise they'll be ignored.
#
!includedir /etc/mysql/conf.d/
EOF

service mysql start

grep -q '^\*\s*soft\s*nofile' /etc/security/limits.conf
if [ $? -ne 0 ]; then
    sed -i '$i*     soft    nofile  65535' /etc/security/limits.conf
fi
grep -q '^\*\s*hard\s*nofile' /etc/security/limits.conf
if [ $? -ne 0 ]; then
    sed -i '$i*     hard    nofile  65535' /etc/security/limits.conf
fi
ulimit -SHn 65535

echo 30 > /proc/sys/net/ipv4/tcp_fin_timeout
echo 4096 > /proc/sys/net/ipv4/tcp_max_syn_backlog
echo 262144 > /proc/sys/net/ipv4/tcp_max_tw_buckets
echo 262144 > /proc/sys/net/ipv4/tcp_max_orphans
echo 1 > /proc/sys/net/ipv4/tcp_tw_recycle
echo 0 > /proc/sys/net/ipv4/tcp_timestamps
echo 0 > /proc/sys/net/ipv4/tcp_ecn
echo 1 > /proc/sys/net/ipv4/tcp_sack
echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse
