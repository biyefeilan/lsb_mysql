#!/bin/bash

# ubuntu 14
# install keepalived
apt-get install -y keepalived

state=MASTER
priority=101
weight=-2

while true; do
    read -p "Is this master node? (y/n)" yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) state=BACKUP 
		priority=100
		weight=2	
		break;;
        * ) echo "Use 'y','Y','n' or 'N' as input!";;
    esac
done

read -p "Input VIP: " vip
read -p "Input interface: " interface 

cat > /etc/keepalived/keepalived.conf <<CFG
! Configuration File for keepalived

global_defs {
	notification_email {
		root@localhost                 #配置服务状态变化发送邮件到哪个地址
	}
	notification_email_from root@localhost
	smtp_server 127.0.0.1                  #给哪个smtp服务器发邮件
	smtp_connect_timeout 30                #联系上面smtp服务器30秒联系不上，就超时
	router_id LVS_DEVEL
}

vrrp_script chk_haproxy {
	script "killall -0 haproxy"   # verify the pid existance
#	script "/etc/keepalived/scripts/check_haproxy.sh"
        interval 2                    # check every 2 seconds
        weight $weight                     # add 2 points of prio if OK
}

vrrp_instance VI_1 {
        interface $interface                # interface to monitor
        state $state                  
        virtual_router_id 51          # Assign one ID for this route
        priority $priority                  # 101 on master, 100 on backup
	advert_int 1
#	garp_master_delay 2
#       nopreempt
#       debug

	authentication {
                auth_type PASS
                auth_pass keepalive
        }

        virtual_ipaddress {
        	$vip
        }

        track_script {       #注意大括号空格
                chk_haproxy
        }

       notify_master "/etc/keepalived/scripts/notify.sh master" #当切换到master状态时,要执行的脚本
       notify_backup "/etc/keepalived/scripts/notify.sh backup" #当切换到master状态时,要执行的脚本
       notify_fault  "/etc/keepalived/scripts/notify.sh fault"  #故障时执行的脚本
       notify_stop   "/etc/keepalived/scripts/notify.sh stop"   #停止运行前运行notify_stop指定的脚本 
}
CFG

if [ ! -d /etc/keepalived/scripts ]; then
    mkdir /etc/keepalived/scripts
fi

cat > /etc/keepalived/scripts/notify.sh <<EOF
#!/bin/bash

vip=$vip
contact='root@localhost'
notify() {
    mailsubject="\`hostname\` to be \$1: \$vip floating"
    mailbody="\`date '+%F %H:%M:%S'\`: vrrp transition, \`hostname\` changed to be \$1"
    echo \$mailbody | mail -s "\$mailsubject" \$contact
}

case "\$1" in
    master)
        notify master
        /etc/init.d/haproxy start
        exit 0
    ;;
    backup)
        notify backup
        /etc/init.d/haproxy stop
        exit 0
    ;;
    fault)
        notify fault
        /etc/init.d/haproxy stop
        exit 0
    ;;
    stop)
        notify stop
        /etc/init.d/haproxy stop
        exit 0
    ;;
    *)
        echo 'Usage: \`basename \$0\` {master|backup|fault|stop}'
        exit 1
    ;;
esac
EOF

cat > /etc/keepalived/scripts/check_haproxy.sh <<EOF
#!/bin/bash
if [ \$(ps -C haproxy --no-header | wc -l) -eq 0 ]; then
     /etc/init.d/haproxy  start
fi
sleep 2
if [ \$(ps -C haproxy --no-header | wc -l) -eq 0 ]; then
       /etc/init.d/keepalived stop
fi
EOF

chmod +x /etc/keepalived/scripts/*.sh 


# install haproxy
apt-get install -y haproxy
sed -i 's/^ENABLED=0/ENABLED=1/g' /etc/default/haproxy
sed -i 's/httplog/tcplog/g' /etc/haproxy/haproxy.cfg
cat >> /etc/haproxy/haproxy.cfg <<CFG

listen  galera
        bind $vip:3306
        balance roundrobin
        mode tcp
        option tcpka
        option mysql-check user haproxy #CREATE USER 'haproxy'@'192.168.0.%'
        server node1 192.168.0.249:3306 check weight 1
        server node2 192.168.0.250:3306 check weight 1
        server node2 192.168.0.251:3306 check weight 1

listen  haproxy_stats
        mode http
        bind $vip:9080
        option httplog
        stats refresh 5s
        stats uri /status #网站健康检测URL，用来检测HAProxy管理的网站是否可以用，正常返回200，不正常返回503 
        stats realm Haproxy Manager
        stats auth admin:haproxy666 #账号密码
CFG

echo 1024 60999 > /proc/sys/net/ipv4/ip_local_port_range
echo 30 > /proc/sys/net/ipv4/tcp_fin_timeout
echo 4096 > /proc/sys/net/ipv4/tcp_max_syn_backlog
echo 262144 > /proc/sys/net/ipv4/tcp_max_tw_buckets
echo 262144 > /proc/sys/net/ipv4/tcp_max_orphans
echo 300 > /proc/sys/net/ipv4/tcp_keepalive_time
echo 1 > /proc/sys/net/ipv4/tcp_tw_recycle
echo 0 > /proc/sys/net/ipv4/tcp_timestamps
echo 0 > /proc/sys/net/ipv4/tcp_ecn
echo 1 > /proc/sys/net/ipv4/tcp_sack
echo 0 > /proc/sys/net/ipv4/tcp_dsack

grep -q '^\*\s*soft\s*nofile' /etc/security/limits.conf
if [ $? -ne 0 ]; then
    sed -i '$i*     soft    nofile  65535' /etc/security/limits.conf
fi
grep -q '^\*\s*hard\s*nofile' /etc/security/limits.conf
if [ $? -ne 0 ]; then
    sed -i '$i*     hard    nofile  65535' /etc/security/limits.conf
fi
ulimit -SHn 65535

cat > /etc/iptables.rules <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -s $vip/24 -i $interface -j ACCEPT
-A INPUT -p tcp -m tcp --dport 3306 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 9080 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF
iptables-restore < /etc/iptables.rules
cat > /etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
exit 0
EOF
cat > /etc/network/if-post-down.d/iptablessave <<EOF
#!/bin/sh
iptables-save -c > /etc/iptables.rules
if [ -f /etc/iptables.downrules ]; then
   iptables-restore < /etc/iptables.downrules
fi
exit 0
EOF
chmod +x /etc/network/if-post-down.d/iptablessave
chmod +x /etc/network/if-pre-up.d/iptablesload

/etc/init.d/keepalived start
