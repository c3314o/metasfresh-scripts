#!/bin/bash


INSTALLER_SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

if [[ -f "/usr/bin/java" ]]; then
  J_VERSION="$(/usr/bin/java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d "." -f2)"
fi

if [[ ! -f "/usr/bin/java" ]] || [[ ! $J_VERSION == "8" ]]; then
  DIST=$(lsb_release -r | awk '{print $2}')
  if [[ ! "$DIST" == "16.04" ]]; then
     apt-get update
     apt-get -y install python-software-properties software-properties-common
     add-apt-repository -y ppa:openjdk-r/ppa
  fi
  apt-get -qqq update
  apt-get -y install openjdk-8-jdk-headless
fi

if [[ ! -d /etc/elasticsearch ]]; then
  wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch | apt-key add -
  echo "deb https://packages.elastic.co/elasticsearch/2.x/debian stable main" > /etc/apt/sources.list.d/elasticsearch-2.x.list
  apt-get -qqq update
  apt-get -y install elasticsearch
fi

dpkg -i $INSTALLER_SCRIPT_DIR/metasfresh*.deb
locale-gen de_DE.UTF-8
export LANG=de_DE.UTF-8
apt-get -f install -y

exit 0
