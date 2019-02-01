#!/bin/bash
# binaries to be used
DOCKER_BIN=`which docker`
DOCKER_COMPOSE_BIN=`which docker-compose`
OPENSSL_BIN=`which openssl`
CERTUTIL_BIN=`which certutil`

# paths to be used
DOCKER_DIR=~/docker
DATABASE_LAB_DIR=~/docker/database_lab

# internal function to create a Docker network with name from $1
function create_network(){
	network_name=$1
	if [ $network_name ]; then
        NETWORK_OUTPUT=`sudo docker network ls | awk '{print $2}' | grep --color=none $network_name`
        if [ "$NETWORK_OUTPUT" != "$network_name" ]; then
            echo "setting up $network_name network"
            sudo $DOCKER_BIN network create $network_name
        else
            echo "$network_name network already exists, skipping."
        fi
	else
        echo "No network name specified, aborting"
	fi
}


echo "setting up database_lab"


# ensure docker and database_lab dirs exist
if [ ! -d "$DOCKER_DIR" ]; then
    echo "making $DOCKER_DIR"
    mkdir $DOCKER_DIR
else
    echo "$DOCKER_DIR already exists, skipping."
fi


# clone repo from github
if [ ! -d "$DATABASE_LAB_DIR" ]; then
    echo "cloning down mobile_homelab from Github"
    git clone https://github.com/toozej/database_lab.git $DATABASE_LAB_DIR
else
    echo "database_lab already exists at $DATABASE_LAB_DIR, pulling"
    cd $DATABASE_LAB_DIR
    git pull
fi


# setup hostfile entries for projects
echo "setting up hostfile entries for database_lab projects"
cd $DATABASE_LAB_DIR
for PROJECT in `find ./single ./clusters -mindepth 2 -maxdepth 2 -type d -not -path '*/\.*'`; do
    if [[ $PROJECT == *"clusters"* ]]; then
        ENTRY=`basename $PROJECT"-cluster"`
    elif [[ $PROJECT == *"single"* ]]; then
        ENTRY=`basename $PROJECT"-single"`
    else
        ENTRY=`basename $PROJECT`
    fi
    # if there's not already a hostfile entry for $PROJECT, then add one
    if ! grep -q "$ENTRY.lab.test" /etc/hosts; then
        echo "127.0.0.1 $ENTRY.lab.test" | sudo tee -a /etc/hosts
    fi
done


# setup SSL certificates
if [ ! -f "$DATABASE_LAB_DIR/traefik/lab.test.key" ] || [ ! -f "$DATABASE_LAB_DIR/traefik/lab.test.crt" ]; then
    echo "generating openssl key & crt for Traefik"
    cd $DATABASE_LAB_DIR/traefik

    # steps largely borrowed from https://gist.github.com/Soarez/9688998
    # generate lab.test key
    $OPENSSL_BIN genrsa -out lab.test.key 2048
    # verify lab.test key
    $OPENSSL_BIN rsa -in lab.test.key -noout -text

    # generate CSR for lab.test with SANs
    $OPENSSL_BIN req -new -out lab.test.csr -config lab.test.conf
    # verify lab.test CSR
    $OPENSSL_BIN req -in lab.test.csr -noout -text

    # generate root CA key
    $OPENSSL_BIN genrsa -out ca.key 2048
    # generate root CA cert
    $OPENSSL_BIN req -new -x509 -key ca.key -out ca.crt -subj "/C=US/ST=Oregon/L=Portland/O=mobile_homelab/CN=[]"

    # sign and create lab.test.crt
    $OPENSSL_BIN ca -batch -config ca.conf -out lab.test.crt -extfile lab.test.extensions.conf -in lab.test.csr

    # verify lab.test.crt
    $OPENSSL_BIN x509 -in lab.test.crt -noout -text
    $OPENSSL_BIN verify -CAfile ca.crt lab.test.crt

    # create bundle for browser
    cat lab.test.crt ca.crt > lab.test.bundle.crt
else
    echo "lab.test.key and lab.test.crt already exist, skipping."
fi


# trust the newly created certificates in web browser
echo "trusting self-signed certificates and adding to browser storage"
[ -d ~/.pki/nssdb ] || mkdir -p ~/.pki/nssdb
# import ca certificate to browser storage
$CERTUTIL_BIN -d sql:$HOME/.pki/nssdb -A -n 'lab.test certificate authority' -i $DATABASE_LAB_DIR/traefik/ca.crt -t TCP,TCP,TCP

# if there's already a cert in storage matching our *.lab.test cert, remove it as it must be old
CERTUTIL_LOADED_CERTS=`$CERTUTIL_BIN -d sql:$HOME/.pki/nssdb -L`
if [[ $CERTUTIL_LOADED_CERTS == *"*.lab.test certificate authority"* ]]; then
    $CERTUTIL_BIN -d sql:$HOME/.pki/nssdb -D -n "*.lab.test certificate authority"
fi

# import *.lab.test certificate to browser storage
$CERTUTIL_BIN -d sql:$HOME/.pki/nssdb -A -n '*.lab.test wildcard certificate' -i $DATABASE_LAB_DIR/traefik/lab.test.bundle.crt -t TCP,TCP,TCP


# create the Traefik network if not already created
create_network traefik

# create the Adminer network if not already created
create_network adminer

# create the cluster database networks if not already created
cd $DATABASE_LAB_DIR
for PROJECT in `find ./clusters/ -mindepth 2 -maxdepth 2 -type d -not -path '*/\.*'`; do
    DATABASE=`basename $PROJECT`
    create_network $DATABASE-cluster
done


# pull, build and start up Traefik
echo "starting Traefik"
sudo $DOCKER_COMPOSE_BIN -f $DATABASE_LAB_DIR/traefik/docker-compose.yml pull --ignore-pull-failures
sudo $DOCKER_COMPOSE_BIN -f $DATABASE_LAB_DIR/traefik/docker-compose.yml up --build -d

# pull images, build and start up tools
echo "starting tools"
for PROJECT in `find $DATABASE_LAB_DIR/tools -mindepth 1 -maxdepth 1 -type d -not -path '*/\.*'`; do
    if [ ! -f "$PROJECT/.do_not_autorun" ]; then
        echo "starting docker-compose project in $PROJECT"
        sudo $DOCKER_COMPOSE_BIN -f $PROJECT/docker-compose.yml pull --ignore-pull-failures
        sudo $DOCKER_COMPOSE_BIN -f $PROJECT/docker-compose.yml up --build -d
    else
        echo "$PROJECT set to not auto-run, remove $PROJECT/.do_not_autorun if you want to change this."
    fi
done

# pull images, build and start up database services for given command line arguments
echo "starting database services from arguments"
for ARGUMENT in "$@"; do
    ARGUMENT_FIND=`find $DATABASE_LAB_DIR/single $DATABASE_LAB_DIR/clusters -mindepth 2 -maxdepth 2 -type d -not -path '*/\.*' | grep --color=none $ARGUMENT`
    if [[ -n $ARGUMENT_FIND ]]; then
        for DATABASE in $ARGUMENT_FIND; do
            echo "starting docker-compose project in $DATABASE"
            sudo $DOCKER_COMPOSE_BIN -f $DATABASE/docker-compose.yml pull --ignore-pull-failures
            sudo $DOCKER_COMPOSE_BIN -f $DATABASE/docker-compose.yml up --build -d
        done
    else
        echo "database service $DATABASE not found in $DATABASE_LAB_DIR/single or $DATABASE_LAB_DIR/clusters"
    fi
done


# wait for projects to finish starting
echo "sleeping 30 seconds to allow projects to fully spin up" && sleep 30
