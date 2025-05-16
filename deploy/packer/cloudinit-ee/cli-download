#!/bin/bash

clear

cat <<"EOF"


     /////////    
     /////////    
/////    /////    
/////    /////    
     ////         
     ////         

EOF

get_machine_id() {
  if [ -f /etc/machine-id ]; then
    cat /etc/machine-id
  elif [ -f /var/lib/dbus/machine-id ]; then
    cat /var/lib/dbus/machine-id
  else
    echo ""
  fi
}

OS_NAME=$(uname)
CPU_ARCH=$(uname -m)
MACHINE_ID=$(get_machine_id)

# check if OS_NAME is not linux or darwin, exit
if [ "${OS_NAME}" != "Linux" ] && [ "${OS_NAME}" != "Darwin" ]; then
    echo "Plane One only works with some flavors of Linux. See https://docs.plane.so/plane-one/self-host/overview"
    exit 1
fi

if [ -z "${MACHINE_ID}" ]; then
    echo "âŒ Machine ID not found âŒ"
    exit 1
fi

CLI_DOWNLOAD_RESPONSE=$(curl -sL -H "x-machine-signature: ${MACHINE_ID}" "https://prime.plane.so/api/v2/downloads/cli?arch=${CPU_ARCH}&os=${OS_NAME}" -o ~/prime-cli.tar.gz -w "%{http_code}" )

if [ $CLI_DOWNLOAD_RESPONSE -eq 200 ]; then
    # Extract the tar.gz file to /bin
    if ! sudo tar -xzf ~/prime-cli.tar.gz -C /bin; then
        echo "Installation failed. Run the curl command again."
        rm -f ~/prime-cli.tar.gz
        exit 1
    fi
    rm -f ~/prime-cli.tar.gz
    # sudo prime-cli setup --host="https://prime.plane.so --silent --behind-proxy"
elif [ $CLI_DOWNLOAD_RESPONSE -eq "000" ]; then
    echo "Prime CLI download failed. Run the curl command again."
    echo "Error: $CLI_DOWNLOAD_RESPONSE"
    exit 1
elif [ $CLI_DOWNLOAD_RESPONSE -ge 400 ] && [ $CLI_DOWNLOAD_RESPONSE -lt 500 ]; then
    echo "Prime CLI download failed. Run the curl command again."
    echo "Error: $CLI_DOWNLOAD_RESPONSE"
    exit 1
elif [ $CLI_DOWNLOAD_RESPONSE -ge 500 ] && [ $CLI_DOWNLOAD_RESPONSE -lt 600 ]; then
    echo "Prime CLI download failed. Run the curl command again."
    echo "Error: $CLI_DOWNLOAD_RESPONSE"
    exit 1
else
    echo "Prime CLI download failed. Run the curl command again."
    echo "Error: $CLI_DOWNLOAD_RESPONSE"
    exit 1
fi