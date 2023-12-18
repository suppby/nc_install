#!/bin/sh

Info()
{
        printf "\033[1;32m$@\033[0m\n"
}

Warning()
{
        printf "\033[1;33m$@\033[0m\n"
}

Error()
{
        printf "\033[1;31m$@\033[0m\n"
}

AcceptEULA() {
		while true; do
  			Warning "Do you accept EULA https://support.pl/EULA......?"
			read -p "Please answer yes or no: " yn
			case $yn in
				[Yy]* ) Info "EULA accepted"; EULA_accepted=true; break;;
				[Nn]* ) Error "EULA not accepted. Pls contact us nocloud@support.pl"; exit 1;;
				* ) echo "Please answer yes or no.";;
			esac
		done
}

CheckRoot() {
        if [ "$(id -u)" != "0" ]; then
                Error "You must be root user to continue"
                exit 1
        fi
        local RID=$(id -u root 2>/dev/null)
        if [ $? -ne 0 ]; then
                Error "User root no found. You should create it to continue"
                exit 1
        fi
        if [ "${RID}" -ne 0 ]; then
                Error "User root UID not equals 0. User root must have UID 0"
                exit 1
        fi
        Info "OK. You are root, this is good."
        sleep 1
}

OSDetect() {
        OSFAMILY=unknown
        kern=$(uname -s)
        case "${kern}" in
                Linux)
                if [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
                        export OSFAMILY=REDHAT
						yum install bind-utils -y
                elif [ -f /etc/debian_version ]; then
                        export OSFAMILY=DEBIAN
						apt-get install bind9-host -y
                fi
                ;;
                FreeBSD)
                        export OSFAMILY=FREEBSD
						Error "FreeBSD not supported, only Linux."
                ;;
        esac
        if [ "#${OSFAMILY}" = "#unknown" ]; then
                Error "Unknown os type. Only supported: CentOS, Debian, Fedora, Ubuntu."
                exit 1
        fi
        Info "OK. Found OS family $OSFAMILY."
        sleep 1
}

CheckSELinux() {
        if [ "$OSFAMILY" = "REDHAT" ]; then
                if selinuxenabled > /dev/null 2>&1 ; then
                        Error "SELinux is enabled, aborting installation. Please disable SELinux."
						Info "HowTo: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/5/html/deployment_guide/sec-sel-enable-disable"
                        exit 1
                else
                        Info "OK. SELinux disabled."
                        sleep 1
                fi
        fi
}

CheckAppArmor() {
        if [ "$OSFAMILY" = "DEBIAN" ]; then
                if service apparmor status >/dev/null 2>&1 ; then
                        Error "AppArmor is enabled, aborting installation. Please stop and disable AppArmor."
						Info "HowTo: https://help.ubuntu.com/community/AppArmor"
                        exit 1
                else
                        Info "OK. AppArmor disabled."
                        sleep 1

                fi
        fi
}

CheckProcInstructions() {
        if cat /proc/cpuinfo | grep -i sse2 | grep -i avx >/dev/null 2>&1; then
                Info "OK. SSE2 and AVX instructions present."
        else
                Error "The processor(s) must support the SSE2 and AVX instructions"
                exit 1
        fi
}

AskForVars() {
        echo -n "Write base domain, like nocloud.example.com: "
        read base_domain
        echo -n "Write email for letsencrypt: "
        read email
        echo -n "Write WHMCS site url, like https://whmcs.example.com/: "
        read whmcs_url
}

CheckDomainAvailability() {
        domains=(traefik.$base_domain rbmq.$base_domain api.$base_domain db.$base_domain app.$base_domain)

        for domain in ${domains[@]}; do
                if host "$domain" >/dev/null 2>&1; then
                        Info "OK. Domain $domain resolved successfully."
                        sleep 1
                else
                        Error "Resolve domain $domain fail."
                        Error "You must add wildcard record *.$base_domain IN A to IP of this server"
                        exit 1
                fi
        done
}

InstallDocker() {
        Warning "Installing Docker...."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
}

DownloadNocloud() {
        Warning "Cloning Nocloud repo...."
        git clone https://github.com/suppby/nc_install
        mv ./nc_install/deployment ./
        rm -rf nc_install
}

FillEnv() {
        cd ./deployment

        rm -f .env
        echo SIGNING_KEY=$(cat /dev/urandom | tr -dc a-z0-9 | head -c40; echo) >> .env
        echo DB_USER=root >> .env
        echo DB_PASS=$(cat /dev/urandom | tr -dc a-zA-Z0-9 | head -c20; echo) >> .env
        echo RABBITMQ_USER=nocloud >> .env
        echo RABBITMQ_PASS=$(cat /dev/urandom | tr -dc a-zA-Z0-9 | head -c20; echo) >> .env
        echo BASE_DOMAIN=$base_domain >> .env
		nc_root_pass=$(cat /dev/urandom | tr -dc a-zA-Z0-9 | head -c20; echo)
        echo NOCLOUD_ROOT_PASS=$nc_root_pass >> .env
        echo EULA_accepted=$EULA_accepted >> .env
}

EditConfigs() {
        chmod 600 ./letsencrypt/acme.json
        sed -i "s/acme@example.com/$email/g" ./traefik.yml
        sed -i "s/REPLACE_ME/$whmcs_url/g" ./app_config/config.json
        touch oauth2_config.json
}

StartNocloud() {
        Warning "Starting Nocloud microservices...."
        docker compose up -d
}

CheckSSL() {
        sslerror=true
        try=1

        while $sslerror; do

                Warning "Waiting before issue Let's Encrypt. Attempt $try "
                for (( waiting=1; waiting<=60; waiting++ )); do
                        echo -n "."
                        sleep 1
                done
                echo

                for domain in ${domains[@]}; do
                        if echo | openssl s_client -connect "$domain":443 2>/dev/null | openssl x509 -noout -issuer | grep "Let's Encrypt" > /dev/null 2>&1; then
                                Info "OK. SSL for $domain installed."
                                sslerror=false
                                sleep 1
                        else
                                Error "SSL for $domain ERROR"
                                sslerror=true
                                break
                                sleep 1
                        fi
                done

                if [ "$try" -ge "10" ]; then
                        Error "Error SSL issue. Some services may work incorrectly. Pls check traefik logs: docker logs deployment-proxy-1"
                        break
                fi

                ((try++))
        done
}

BootstrapDB() {
		Warning "Creating examples..."
		sleep 30
        arango_container_name=$(docker ps --format "{{.Names}}"| grep db)
        arango_root_pass=$(cat .env | grep DB_PASS | cut -d\= -f2)
        arango_restore_command="/usr/bin/arangorestore --input-directory /arango_dump_nocloud_example/nocloud --server.database nocloud --server.password $arango_root_pass"

        /usr/bin/tar -xzf arango_dump_nocloud_example.tar.gz
        docker cp arango_dump_nocloud_example ${arango_container_name}:arango_dump_nocloud_example > /dev/null 2>&1
        docker exec -d $arango_container_name $arango_restore_command
}

FinishSetup() {
        echo "===================================================================="
        Info "Nocloud is installed! Use credentials below:"
        Info "Admin panel: https://api.$base_domain/admin"
        Info "Login: nocloud"
        Info "Password: $nc_root_pass"
        Info "Client area: https://app.$base_domain"

        Warning "DOCUMENTATION: https://github.com/slntopp/nocloud/wiki/Production"
        echo "===================================================================="

}

clear
AcceptEULA
CheckRoot
OSDetect
CheckSELinux
CheckAppArmor
CheckProcInstructions
AskForVars
CheckDomainAvailability
InstallDocker
DownloadNocloud
FillEnv
EditConfigs
StartNocloud
CheckSSL
BootstrapDB
FinishSetup
