#!/bin/bash

ROLE=$1
ADMIN_USER=root
MASTER_HOST=192.168.50.31
MASTER_PORT=3307
SLAVE_USER=slave
SLAVE_PASS=slavepw
FLOATING_IP=192.168.50.30
FLOATING_DEV=eth1


[ -z $ROLE ] && exit

# Disable iptables
echo "Stopping firewall..."
service iptables stop 2>&1 >> /dev/null

# Install the epel repo if not already available
rpm -q --quiet epel-release || rpm -iv http://download.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm

# Make sure that required packages are installed
echo "Verifying required packages are installed..."
yum install -y haproxy socat mysql-server

# Cleanup any old replication settings
echo "Cleaning up old mysql instance..."
service mysqld stop 2>&1 > /dev/null
rm -rf /var/lib/mysql/*

# Start mysqld
echo "Verifying mysqld is running..."
service mysqld status 2>&1 > /dev/null || service mysqld start 2>&1 > /dev/null

# MySQL user setup
echo "Granting remote root access..."
/usr/bin/mysql -u $ADMIN_USER -e "GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'%'; FLUSH PRIVILEGES;"

echo "Granting replication access..."
/usr/bin/mysql -u $ADMIN_USER -e "GRANT REPLICATION SLAVE ON *.* TO '${SLAVE_USER}'@'%' IDENTIFIED BY '${SLAVE_PASS}'; FLUSH PRIVILEGES;"


# Link in our configuration files
if [ ! -L /etc/my.cnf ]; then
  rm -f /etc/my.cnf
  ln -s /vagrant/vagrant-configs/${ROLE}.cnf /etc/my.cnf
  service mysqld restart
fi

if [ ! -L /etc/haproxy/haproxy.cfg ]; then
  rm -f /etc/haproxy/haproxy.cfg
  ln -s /vagrant/vagrant-configs/haproxy-${ROLE}.cfg /etc/haproxy/haproxy.cfg
fi

# Setup one system to be a slave to start with
if [ "${ROLE}" == "slave" ]; then
  echo "Checking Replication Status..."
  SLAVE_RUNNING=$(/usr/bin/mysql -u $ADMIN_USER -e "SHOW SLAVE STATUS\G" | grep -c -e "Slave_IO_State: Waiting")
  if [ "${SLAVE_RUNNING}" != "1" ]; then
    echo "Initiating Replication..."
    /usr/bin/mysql -u $ADMIN_USER -e "CHANGE MASTER TO MASTER_HOST='${MASTER_HOST}', MASTER_PORT=${MASTER_PORT}, MASTER_USER='${SLAVE_USER}', MASTER_PASSWORD='${SLAVE_PASS}', MASTER_LOG_FILE='', MASTER_LOG_POS=4"
    /usr/bin/mysql -u $ADMIN_USER -e "SLAVE START"
  fi
  echo "Forcing slave to be read-only..."
  /usr/bin/mysql -u $ADMIN_USER -e "SET GLOBAL read_only = on"
fi

if [ "${ROLE}" == "master" ]; then
  echo "Checking for Floating VIP..."
  /sbin/ip addr list | grep "${FLOATING_IP}" 2>&1 > /dev/null
  if [  $? == 1 ]; then
    echo "Installing Floating VIP ${FLOATING_IP}..."
    /sbin/ip addr add ${FLOATING_IP} dev ${FLOATING_DEV}
  fi
  echo "Verifying HAProxy is running..."
  service haproxy status 2>&1 > /dev/null || service haproxy start 2>&1 > /dev/null
fi

