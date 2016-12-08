#!/bin/bash
# Centreon + engine install script for Debian Wheezy
# Source https://github.com/zeysh/centreon-install
# Thanks to Eric http://eric.coquard.free.fr
#
# 20160511 SCH satellite install mode. Refactoring.
# 20160428 SCH handle upgrades of web interface when /etc/centreon exists
#          SCH stay as close as possible to debian to get security upgrades
#
# - install nagios plugins from Wheezy : we must use nagios as the engine user
# - use centreon 2.7 : no more need for php5.3
# - install mysql from wheezy


#TODO
#use a do_critical wrapper
_usage () {
  echo "$0 -[f|s]
   -f : full centreon installation
   -s : satellite only installation"
}


MODE=""
#sanity checks first
while getopts "fs" opt; do
  case $opt in
      f)
        echo "Full install" >&2
        MODE="full"
        ;;
      s)
        echo "Satellite install" >&2
        MODE="satellite"
        ;;
      \?)
        echo "Invalid option: -$OPTARG" >&2
        _usage
      ;;
  esac
done


if [ "$UID" != "0" ];
  then
    echo "This script should be run as root"
    exit 1
fi

if [[ "x${MODE}" = "x" ]];
  then
    _usage
    exit 1
fi

INSTALLER_DIR=$(pwd)
export DEBIAN_FRONTEND=noninteractive
# Variables
## Versions
CLIB_VER="1.4.2"
CONNECTOR_VER="1.1.2"
ENGINE_VER="1.5.0"
PLUGIN_VER="2.1.1"
BROKER_VER="2.11.4"
CENTREON_VER="2.7.4"
CLAPI_VER="1.8.0"
# MariaDB Series
MARIADB_VER='10.1'
## Sources URL
BASE_URL="https://s3-eu-west-1.amazonaws.com/centreon-download/public"
CLIB_URL="${BASE_URL}/centreon-clib/centreon-clib-${CLIB_VER}.tar.gz"
CONNECTOR_URL="${BASE_URL}/centreon-connectors/centreon-connector-${CONNECTOR_VER}.tar.gz"
ENGINE_URL="${BASE_URL}/centreon-engine/centreon-engine-${ENGINE_VER}.tar.gz"
PLUGIN_URL="http://www.nagios-plugins.org/download/nagios-plugins-${PLUGIN_VER}.tar.gz"
BROKER_URL="${BASE_URL}/centreon-broker/centreon-broker-${BROKER_VER}.tar.gz"
CENTREON_URL="${BASE_URL}/centreon/centreon-web-${CENTREON_VER}.tar.gz"
CLAPI_URL="${BASE_URL}/Modules/CLAPI/centreon-clapi-${CLAPI_VER}.tar.gz"
## Sources widgets
WIDGET_HOST_VER="1.3.2"
WIDGET_HOSTGROUP_VER="1.1.1"
WIDGET_SERVICE_VER="1.3.2"
WIDGET_SERVICEGROUP_VER="1.1.0"
WIDGET_BASE="https://s3-eu-west-1.amazonaws.com/centreon-download/public/centreon-widgets"
WIDGET_HOST="${WIDGET_BASE}/centreon-widget-host-monitoring/centreon-widget-host-monitoring-${WIDGET_HOST_VER}.tar.gz"
WIDGET_HOSTGROUP="${WIDGET_BASE}/centreon-widget-hostgroup-monitoring/centreon-widget-hostgroup-monitoring-${WIDGET_HOSTGROUP_VER}.tar.gz"
WIDGET_SERVICE="${WIDGET_BASE}/centreon-widget-service-monitoring/centreon-widget-service-monitoring-${WIDGET_SERVICE_VER}.tar.gz"
WIDGET_SERVICEGROUP="${WIDGET_BASE}/centreon-widget-servicegroup-monitoring/centreon-widget-servicegroup-monitoring-${WIDGET_SERVICEGROUP_VER}.tar.gz"
## Temp install dir
DL_DIR="/usr/local/src"
## Install dir
INSTALL_DIR="/usr/local"
## We use standard nagios plugin dir
NAGIOS_PLUGIN_DIR="/usr/lib/nagios/plugins"
## Log install file
INSTALL_LOG="/usr/local/src/centreon-install.log"
## Set mysql-server root password
MYSQL_PASSWORD="password"
## Users and groups
ENGINE_USER="centreon-engine"
ENGINE_GROUP="centreon-engine"
BROKER_USER="centreon-broker"
BROKER_GROUP="centreon-broker"
CENTREON_USER="centreon"
CENTREON_GROUP="centreon"
## TMPL file (template install file for Centreon)
CENTREON_TMPL="centreon_engine.tmpl"
ETH0_IP=`/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'`
PLATFORM=$(python -mplatform)

DIR_APACHE_CONF="/etc/apache2/conf.d"
if [[ "${PLATFORM}" == *"Ubuntu"* ]];
  then
      DIR_APACHE_CONF=/etc/apache2/conf-available
fi

PHPDEBS="php5 php5-mysql php-pear php5-ldap php5-snmp php5-gd php5-sqlite php5-intl"
APACHEDEBS="apache2 apache2-mpm-prefork"
PHPDIR=/etc/php5/apache2
if [[ "${PLATFORM}" == *"debian-stretch-sid"* || "${PLATFORM}" == *"Ubuntu-16.04-xenial"* ]];
  then
      PHPDEBS="php php-mysql php-pear php-ldap php-snmp php-gd php-sqlite3 php-intl"
      APACHEDEBS="apache2 libapache2-mod-php "
      PHPDIR="/etc/php/7.0/apache2"
      echo "Debian >8 and Ubuntu >14.04 are not yet supported by Centreon because of php7"
      exit 1
fi


function text_params () {
  ESC_SEQ="\x1b["
  bold=`tput bold`
  normal=`tput sgr0`
  COL_RESET=$ESC_SEQ"39;49;00m"
  COL_GREEN=$ESC_SEQ"32;01m"
  COL_RED=$ESC_SEQ"31;01m"
  STATUS_FAIL="[$COL_RED${bold}FAIL${normal}$COL_RESET]"
  STATUS_OK="[$COL_GREEN${bold} OK ${normal}$COL_RESET]"
}

function mariadb_install() {
echo "
======================================================================

                        Install MariaDB

======================================================================
"
apt-get install -y lsb-release python-software-properties
DISTRO=`lsb_release -i -s | tr '[:upper:]' '[:lower:]'`
RELEASE=`lsb_release -c -s`


MIRROR_DOMAIN='ftp.igh.cnrs.fr'
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 0xcbcb082a1bb943db
add-apt-repository "deb http://${MIRROR_DOMAIN}/pub/mariadb/repo/${MARIADB_VER}/${DISTRO} ${RELEASE} main"
apt-get update

# Pin repository in order to avoid conflicts with MySQL from distribution
# repository. See https://mariadb.com/kb/en/installing-mariadb-deb-files
# section "Version Mismatch Between MariaDB and Ubuntu/Debian Repositories"
echo "
Package: *
Pin: origin ${MIRROR_DOMAIN}
Pin-Priority: 1000
" | tee /etc/apt/preferences.d/mariadb

debconf-set-selections <<< "mariadb-server-${MARIADB_VER} mysql-server/root_password password ${MYSQL_PASSWORD}"
debconf-set-selections <<< "mariadb-server-${MARIADB_VER} mysql-server/root_password_again password ${MYSQL_PASSWORD}"
apt-get install --force-yes -y mariadb-server
}

function clib_install () {
echo "
======================================================================

                          Install Clib

======================================================================
"

apt-get install -y build-essential cmake pkg-config

cd ${DL_DIR}
if [[ -e centreon-clib-${CLIB_VER}.tar.gz ]] ;
  then
    echo 'File already exist !'
  else
    wget ${CLIB_URL} -O ${DL_DIR}/centreon-clib-${CLIB_VER}.tar.gz
fi

tar xzf centreon-clib-${CLIB_VER}.tar.gz
cd centreon-clib-${CLIB_VER}/build

cmake \
   -DWITH_TESTING=0 \
   -DWITH_PREFIX=${INSTALL_DIR}/centreon-lib \
   -DWITH_SHARED_LIB=1 \
   -DWITH_STATIC_LIB=0 \
   -DWITH_PKGCONFIG_DIR=/usr/lib/pkgconfig .
make
make install

echo "${INSTALL_DIR}/centreon-lib/lib" >> /etc/ld.so.conf.d/libc.conf
}

function centreon_connectors_install () {
echo "
======================================================================

               Install Centreon Perl and SSH connectors

======================================================================
"

apt-get install -y libperl-dev

cd ${DL_DIR}
if [[ -e centreon-connector-${CONNECTOR_VER}.tar.gz ]]
  then
    echo 'File already exist !'
  else
    wget ${CONNECTOR_URL} -O ${DL_DIR}/centreon-connector-${CONNECTOR_VER}.tar.gz
fi

tar xzf centreon-connector-${CONNECTOR_VER}.tar.gz
cd ${DL_DIR}/centreon-connector-${CONNECTOR_VER}/perl/build

cmake \
 -DWITH_PREFIX=${INSTALL_DIR}/centreon-connector  \
 -DWITH_CENTREON_CLIB_INCLUDE_DIR=${INSTALL_DIR}/centreon-lib/include \
 -DWITH_CENTREON_CLIB_LIBRARIES=${INSTALL_DIR}/centreon-lib/lib/libcentreon_clib.so \
 -DWITH_PKGCONFIG_DIR=/usr/lib/pkgconfig \
 -DWITH_TESTING=0 .
make
make install

# install Centreon SSH Connector
apt-get install -y libssh2-1-dev libgcrypt11-dev

# Cleanup to prevent space full on /var
apt-get clean

cd ${DL_DIR}/centreon-connector-${CONNECTOR_VER}/ssh/build

cmake \
 -DWITH_PREFIX=${INSTALL_DIR}/centreon-connector  \
 -DWITH_CENTREON_CLIB_INCLUDE_DIR=${INSTALL_DIR}/centreon-lib/include \
 -DWITH_CENTREON_CLIB_LIBRARIES=${INSTALL_DIR}/centreon-lib/lib/libcentreon_clib.so \
 -DWITH_TESTING=0 .
make
make install
}

function centreon_engine_install () {
echo "
======================================================================

                    Install Centreon Engine

======================================================================
"

groupadd -g 6001 ${ENGINE_GROUP}
useradd -u 6001 -g ${ENGINE_GROUP} -m -r -d /var/lib/centreon-engine -c "Centreon-engine Admin" ${ENGINE_USER}

apt-get install -y libcgsi-gsoap-dev zlib1g-dev libssl-dev libxerces-c-dev

# Cleanup to prevent space full on /var
apt-get clean

cd ${DL_DIR}
if [[ -e centreon-engine-${ENGINE_VER}.tar.gz ]]
  then
    echo 'File already exist !'
  else
    wget ${ENGINE_URL} -O ${DL_DIR}/centreon-engine-${ENGINE_VER}.tar.gz
fi

tar xzf centreon-engine-${ENGINE_VER}.tar.gz
cd ${DL_DIR}/centreon-engine-${ENGINE_VER}/build

cmake \
   -DWITH_CENTREON_CLIB_INCLUDE_DIR=${INSTALL_DIR}/centreon-lib/include \
   -DWITH_CENTREON_CLIB_LIBRARY_DIR=${INSTALL_DIR}/centreon-lib/lib \
   -DWITH_PREFIX=${INSTALL_DIR}/centreon-engine \
   -DWITH_PREFIX_CONF=/etc/centreon-engine \
   -DWITH_USER=${ENGINE_USER} \
   -DWITH_GROUP=${ENGINE_GROUP} \
   -DWITH_LOGROTATE_SCRIPT=1 \
   -DWITH_VAR_DIR=/var/log/centreon-engine \
   -DWITH_RW_DIR=/var/lib/centreon-engine/rw \
   -DWITH_STARTUP_DIR=/etc/init.d \
   -DWITH_STARTUP_SCRIPT=sysv \
   -DWITH_PKGCONFIG_SCRIPT=1 \
   -DWITH_PKGCONFIG_DIR=/usr/lib/pkgconfig \
   -DWITH_TESTING=0 .
make
make install

chmod +x /etc/init.d/centengine
update-rc.d centengine defaults
}



function nagios_plugin_install () {
echo "
======================================================================

                     Install Plugins Nagios

======================================================================
"

apt-get install --force-yes -y nagios-nrpe-plugin nagios-plugins-basic nagios-plugins-standard
apt-get clean
chmod +s /usr/lib/nagios/plugins/check_icmp

}

function centreon_broker_install() {
echo "
======================================================================

                     Install Centreon Broker

======================================================================
"

groupadd -g 6002 ${BROKER_GROUP}
useradd -u 6002 -g ${BROKER_GROUP} -m -r -d /var/lib/centreon-broker -c "Centreon-broker Admin" ${BROKER_USER}
usermod -aG ${BROKER_GROUP} ${ENGINE_USER}

apt-get install -y librrd-dev libqt4-dev libqt4-sql-mysql libgnutls-dev lsb-release

# Cleanup to prevent space full on /var
apt-get clean

cd ${DL_DIR}
if [[ -e centreon-broker-${BROKER_VER}.tar.gz ]]
  then
    echo 'File already exist !'
  else
    wget ${BROKER_URL} -O ${DL_DIR}/centreon-broker-${BROKER_VER}.tar.gz || exit 1
fi

if [[ -d /var/log/centreon-broker ]]
  then
    echo "Directory already exist!"
  else
    mkdir -p /var/log/centreon-broker
    chown ${BROKER_USER}:${ENGINE_GROUP} /var/log/centreon-broker
    chmod 775 /var/log/centreon-broker
fi

tar xzf centreon-broker-${BROKER_VER}.tar.gz || exit 1

cd ${DL_DIR}/centreon-broker-${BROKER_VER}/build/

cmake \
    -DWITH_DAEMONS='central-broker;central-rrd' \
    -DWITH_GROUP=${BROKER_GROUP} \
    -DWITH_PREFIX=${INSTALL_DIR}/centreon-broker \
    -DWITH_PREFIX_CONF=/etc/centreon-broker \
    -DWITH_STARTUP_DIR=/etc/init.d \
    -DWITH_STARTUP_SCRIPT=auto \
    -DWITH_TESTING=0 \
    -DWITH_USER=${BROKER_USER} .
make
make install
if [[ "${MODE}"  == "full" ]];
then
  update-rc.d cbd defaults
fi
# Cleanup to prevent space full on /var
apt-get clean
}

function create_centreon_tmpl() {
echo "
======================================================================

                  Centreon template generation

======================================================================
"
cat > ${DL_DIR}/${CENTREON_TMPL} << EOF
#Centreon template
PROCESS_CENTREON_WWW=1
PROCESS_CENTSTORAGE=1
PROCESS_CENTCORE=1
PROCESS_CENTREON_PLUGINS=1
PROCESS_CENTREON_SNMP_TRAPS=1

LOG_DIR="$BASE_DIR/log"
LOG_FILE="$LOG_DIR/install_centreon.log"
TMPDIR="/tmp/centreon-setup"
SNMP_ETC="/etc/snmp/"
PEAR_MODULES_LIST="pear.lst"
PEAR_AUTOINST=1

INSTALL_DIR_CENTREON="${INSTALL_DIR}/centreon"
CENTREON_BINDIR="${INSTALL_DIR}/centreon/bin"
CENTREON_DATADIR="${INSTALL_DIR}/centreon/data"
CENTREON_USER=${CENTREON_USER}
CENTREON_GROUP=${CENTREON_GROUP}
#PLUGIN_DIR="${INSTALL_DIR}/centreon-plugins/libexec"
PLUGIN_DIR="${NAGIOS_PLUGIN_DIR}"
CENTREON_LOG="/var/log/centreon"
CENTREON_ETC="/etc/centreon"
CENTREON_RUNDIR="/var/run/centreon"
CENTREON_GENDIR="/var/cache/centreon"
CENTSTORAGE_RRD="/var/lib/centreon"
CENTSTORAGE_BINDIR="${INSTALL_DIR}/centreon/bin"
CENTCORE_BINDIR="${INSTALL_DIR}/centreon/bin"
CENTREON_VARLIB="/var/lib/centreon"
CENTPLUGINS_TMP="/var/lib/centreon/centplugins"
CENTPLUGINSTRAPS_BINDIR="${INSTALL_DIR}/centreon/bin"
SNMPTT_BINDIR="${INSTALL_DIR}/centreon/bin"
CENTCORE_INSTALL_INIT=1
CENTCORE_INSTALL_RUNLVL=1
CENTSTORAGE_INSTALL_INIT=0
CENTSTORAGE_INSTALL_RUNLVL=0
CENTREONTRAPD_BINDIR="${INSTALL_DIR}/centreon/bin"
CENTREONTRAPD_INSTALL_INIT=1
CENTREONTRAPD_INSTALL_RUNLVL=1

INSTALL_DIR_NAGIOS="${INSTALL_DIR}/centreon-engine"
CENTREON_ENGINE_USER="${ENGINE_USER}"
MONITORINGENGINE_USER="${ENGINE_USER}"
MONITORINGENGINE_LOG="/var/log/centreon-engine"
MONITORINGENGINE_INIT_SCRIPT="/etc/init.d/centengine"
MONITORINGENGINE_BINARY="${INSTALL_DIR}/centreon-engine/bin/centengine"
MONITORINGENGINE_ETC="/etc/centreon-engine"
NAGIOS_PLUGIN="${NAGIOS_PLUGIN_DIR}"
FORCE_NAGIOS_USER=1
NAGIOS_GROUP="${CENTREON_USER}"
FORCE_NAGIOS_GROUP=1
NDOMOD_BINARY="${INSTALL_DIR}/centreon-broker/bin/cbd"
NDO2DB_BINARY="${INSTALL_DIR}/centreon-broker/bin/cbd"
NAGIOS_INIT_SCRIPT="/etc/init.d/centengine"
CENTREON_ENGINE_CONNECTORS="${INSTALL_DIR}/centreon-connector/lib"
BROKER_USER="${BROKER_USER}"
BROKER_ETC="/etc/centreon-broker"
BROKER_INIT_SCRIPT="/etc/init.d/cbd"
BROKER_LOG="/var/log/centreon-broker"

DIR_APACHE="/etc/apache2"
DIR_APACHE_CONF="$DIR_APACHE_CONF"
APACHE_CONF="apache.conf"
WEB_USER="www-data"
WEB_GROUP="www-data"
APACHE_RELOAD=1
BIN_RRDTOOL="/usr/bin/rrdtool"
BIN_MAIL="/usr/bin/mail"
BIN_SSH="/usr/bin/ssh"
BIN_SCP="/usr/bin/scp"
PHP_BIN="/usr/bin/php"
GREP="/bin/grep"
CAT="/bin/cat"
SED="/bin/sed"
CHMOD="/bin/chmod"
CHOWN="/bin/chown"

RRD_PERL="/usr/lib/perl5"
SUDO_FILE="/etc/sudoers"
FORCE_SUDO_CONF=1
INIT_D="/etc/init.d"
CRON_D="/etc/cron.d"
PEAR_PATH="/usr/share/php"
EOF
}

function centreon_web_prepare_install () {
echo "
======================================================================

                  Install Centreon Web Interface

======================================================================
"
DEBIAN_FRONTEND=noninteractive apt-get install -y --force-yes  sudo tofrodos \
bsd-mailx lsb-release libmariadbclient-dev \
${APACHEDEBS}  \
rrdtool librrds-perl libconfig-inifiles-perl libcrypt-des-perl libdigest-hmac-perl \
libdigest-sha-perl libgd-gd2-perl ${PHPDEBS}

# Cleanup to prevent space full on /var
apt-get clean


# MIBS errors
if [[ -d /root/mibs_removed ]]
  then
    echo 'MIBS already moved !'
  else
    mkdir -p /root/mibs_removed
        mv /usr/share/mibs/ietf/IPATM-IPMC-MIB /root/mibs_removed
        mv /usr/share/mibs/ietf/SNMPv2-PDU /root/mibs_removed
        mv /usr/share/mibs/ietf/IPSEC-SPD-MIB /root/mibs_removed
        mv /usr/share/mibs/iana/IANA-IPPM-METRICS-REGISTRY-MIB /root/mibs_removed
fi

cd ${DL_DIR}

if [[ -e centreon-web-${CENTREON_VER}.tar.gz ]]
  then
    echo 'File already exist!'
  else
    wget ${CENTREON_URL} -O ${DL_DIR}/centreon-web-${CENTREON_VER}.tar.gz
fi

groupadd -g 6003 ${CENTREON_GROUP}
useradd -u 6003 -g ${CENTREON_GROUP} -m -r -d ${INSTALL_DIR}/centreon -c "Centreon Web user" ${CENTREON_USER}
usermod -aG ${CENTREON_GROUP} ${ENGINE_USER}

tar xzf centreon-web-${CENTREON_VER}.tar.gz

#fix for faulty install script
echo " Fix faulty CentWeb.sh"
cp $SCRIPTDIR/CentWeb.sh ${DL_DIR}/centreon-web-${CENTREON_VER}/libinstall/

}

function centreon_web_install () {
  echo " Install centreon web "
  cd ${DL_DIR}/centreon-web-${CENTREON_VER}
  ./install.sh -v -i -f ${DL_DIR}/${CENTREON_TMPL}
}



function post_install () {
echo "
=====================================================================

                          Post install

=====================================================================
"
if [[ "${PLATFORM}" == *"Ubuntu"* ]];
  then
  echo "Configuring apache2 for Ubuntu"
  install -oroot -groot -m644 ${INSTALLER_DIR}/ubuntu/centreon.conf /etc/apache2/conf-available/centreon.conf
  a2enconf centreon
  #set timezone
  sed -i s#\;date\.timezone\ \=#date\.timezone\ \=\ Europe/Brussels# ${PHPDIR}/php.ini
  service apache2 reload
fi

CENTREON_BINDIR="${INSTALL_DIR}/centreon/bin"
cp /${DL_DIR}/centreon-web-${CENTREON_VER}/bin/generateSqlLite ${CENTREON_BINDIR}/
chmod +x ${CENTREON_BINDIR}/generateSqlLite
# Add mysql config for Centreon
echo '[mysqld]
innodb_file_per_table=1' > /etc/mysql/conf.d/innodb.cnf

service mysql restart
service cbd restart
service centcore restart
service centengine restart
service centreontrapd restart

mkdir -p /var/log/centreon-broker
chown centreon-broker:centreon-broker  /var/log/centreon-broker
chmod 775 /var/log/centreon-broker

## Workarounds
## config:  cannot open '/var/lib/centreon-broker/module-temporary.tmp-1-central-module-output-master-failover'
## (mode w+): Permission denied)
chmod 775 /var/lib/centreon-broker/

## drwxr-xr-x 3 root root 15 Feb  4 20:31 centreon-engine
chown ${ENGINE_USER}:${ENGINE_GROUP} /var/lib/centreon-engine/

#missing executable bits
chmod 0755 /usr/local/centreon/cron/centstorage_purge
chmod 0755 /usr/local/centreon/cron/nightly_tasks_manager



}

##ADDONS

function clapi_install () {
echo "
=======================================================================

                          Install CLAPI

=======================================================================
"
cd ${DL_DIR}
  if [[ -e ${DL_DIR}/centreon-clapi-${CLAPI_VER}.tar.gz ]]
    then
      echo 'File already exist!'
    else
      wget ${CLAPI_URL} -O ${DL_DIR}/centreon-clapi-${CLAPI_VER}.tar.gz
  fi
    tar xzf ${DL_DIR}/centreon-clapi-${CLAPI_VER}.tar.gz
    cd ${DL_DIR}/centreon-clapi-${CLAPI_VER}
    ./install.sh -u `grep CENTREON_ETC ${DL_DIR}/${CENTREON_TMPL} | cut -d '=' -f2 | tr -d \"`
}

function widget_install() {
echo "
=======================================================================

                         Install WIDGETS

=======================================================================
"
cd ${DL_DIR}
  wget -qO- ${WIDGET_HOST} | tar -C ${INSTALL_DIR}/centreon/www/widgets --strip-components 1 -xzv
  mkdir -p ${INSTALL_DIR}/centreon/www/widgets/hostgroup-monitoring
  wget -qO- ${WIDGET_HOSTGROUP} | tar -C ${INSTALL_DIR}/centreon/www/widgets/hostgroup-monitoring --strip-components 1 -xzv
  wget -qO- ${WIDGET_SERVICE} | tar -C ${INSTALL_DIR}/centreon/www/widgets --strip-components 1 -xzv
  mkdir -p ${INSTALL_DIR}/centreon/www/widgets/servicegroup-monitoring
  wget -qO- ${WIDGET_SERVICEGROUP} | tar -C ${INSTALL_DIR}/centreon/www/widgets/servicegroup-monitoring --strip-components 1 -xzv
  chown -R ${CENTREON_USER}:${CENTREON_GROUP} ${INSTALL_DIR}/centreon/www/widgets
}

function centreon_plugins_install() {
echo "
=======================================================================

                    Install Centreon Plugins

=======================================================================
"
cd ${DL_DIR}
DEBIAN_FRONTEND=noninteractive apt-get install -y --force-yes libcache-memcached-perl libjson-perl libxml-libxml-perl libdatetime-perl git-core
test -d centreon-plugins || git clone https://github.com/centreon/centreon-plugins.git
cd centreon-plugins
chmod +x centreon_plugins.pl
chown -R ${ENGINE_USER}:${ENGINE_GROUP} ${DL_DIR}/centreon-plugins
cp -R * ${NAGIOS_PLUGIN_DIR}/

}

_step () {
  STEP=$1
  NUM=$2
  NAME=$3
  STATUS=${STATUS_FAIL}
  $STEP 2>>$INSTALL_LOG >>$INSTALL_LOG
  if [[ $? -eq 0 ]];
  then
    STATUS=${STATUS_OK}
  fi
  echo -e "${STATUS} ${bold}Step $NUM${normal}  => $NAME"
  }

_full_install () {

    SCRIPTDIR=${PWD}
    echo "
=======================| Install details |============================

                  MariaDB    : ${MARIADB_VER}
                  Clib       : ${CLIB_VER}
                  Connector  : ${CONNECTOR_VER}
                  Engine     : ${ENGINE_VER}
                  Plugin     : ${PLUGIN_VER}
                  Broker     : ${BROKER_VER}
                  Centreon   : ${CENTREON_VER}
                  Install dir: ${INSTALL_DIR}
                  Source dir : ${DL_DIR}
                  Install log: ${INSTALL_LOG}
======================================================================
"
    text_params

    _step mariadb_install 1 "Install MariaDB"
    _step clib_install 2 "Clib install"
    _step centreon_connectors_install 3 "Centreon Perl and SSH connectors install"
    _step centreon_engine_install 4 "Centreon Engine install"
    _step nagios_plugin_install 5 "Nagios plugins install"
    _step centreon_plugins_install 6 "Centreon plugins install"
    _step centreon_broker_install 7 "Centreon Broker install"
    _step create_centreon_tmpl 8 "Centreon template generation"
    _step centreon_web_prepare_install 9 "Centreon web prepare install"
    if [ -r "/etc/centreon/centreon.conf.php" ]
    then
        echo "Upgrading centreon web must be done manualy please run
        cd ${DL_DIR}/centreon-web-${CENTREON_VER}
        sudo ./install.sh -u /etc/centreon"
    else
	    _step centreon_web_install 10 "Centreon web interface install"
      _step post_install 11 "Post install"
    fi
    _step clapi_install 11 "CLAPI install"
    _step widget_install 12 "Widgets install"


    echo -e ""
    echo -e "${bold}Go to http://${ETH0_IP}/centreon to complete the setup${normal} "
    echo -e ""

    echo "##### Install completed #####" >> ${INSTALL_LOG} 2>&1
}

_satellite_postinstall () {
  groupadd -g 6000 centreon
  useradd -u 6000 -g centreon -m -r -d /var/lib/centreon -c "Centreon Admin" -s /bin/bash centreon
  usermod -aG centreon-engine centreon
  usermod -aG centreon-broker centreon
  usermod -aG centreon centreon-engine
  usermod -aG centreon centreon-broker
  usermod -aG centreon-broker centreon-engine

  cd /usr/lib/nagios/plugins
  chown centreon:centreon-engine centreon*
  chown -R centreon:centreon-engine Centreon*
  chown centreon:centreon-engine check_centreon*
  chown centreon:centreon-engine check_snmp*
  chown centreon:centreon-engine submit*
  chown centreon:centreon-engine process*
  chmod 664 centreon.conf
  chmod +x centreon.pm
  chmod +x Centreon/SNMP/Utils.pm
  chmod +x check_centreon*
  chmod +x check_snmp*
  chmod +x submit*
  chmod +x process*
  cd -

  chown centreon: /var/log/centreon
  chmod 775 /var/log/centreon
  chown centreon-broker: /etc/centreon-broker
  chmod 775 /etc/centreon-broker
  chmod -R 775 /etc/centreon-engine
  chmod 775 /var/lib/centreon-broker
}
_satellite_install () {
  SCRIPTDIR=${PWD}
  echo "
=======================| Install details |============================

                Clib       : ${CLIB_VER}
                Connector  : ${CONNECTOR_VER}
                Engine     : ${ENGINE_VER}
                Plugin     : ${PLUGIN_VER}
                Broker     : ${BROKER_VER}
                Install dir: ${INSTALL_DIR}
                Source dir : ${DL_DIR}
                Install log: ${INSTALL_LOG}
======================================================================
"
  text_params

  _step clib_install 1 "Clib install"
  _step centreon_connectors_install 2 "Centreon Perl and SSH connectors install"
  _step centreon_engine_install 3 "Centreon Engine install"
  _step nagios_plugin_install 4 "Nagios plugins install"
  _step centreon_plugins_install 5 "Centreon plugins install"
  _step centreon_broker_install 6 "Centreon Broker install"
  _step _satellite_postinstall 7 "Satellite post install"
  echo "##### Install completed #####" >> ${INSTALL_LOG} 2>&1

}

#main
case $MODE in
  full)
    _full_install
  ;;
  satellite)
    _satellite_install
  ;;
esac
