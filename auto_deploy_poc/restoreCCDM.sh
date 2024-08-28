#!/bin/bash

if [ -z ${BACKUP_LOCATION} ]; then
  echo "BACKUP_LOCATION not provided! Exit..."
  exit 1
fi
if [ $(env | grep "^BACKUP_USER=\|^BACKUP_PASS=" | wc -l) -lt 2 ]; then
  echo "Backup user credentials not set! Please export BACKUP_USER and BACKUP_PASS vars!"
  exit
fi

BACKUP_NAME=$(echo ${BACKUP_LOCATION} | rev | cut -d/ -f1 | rev | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}.*//')
USER="admin"
PASS="EricSson@12-34"

function executeCli {
  TARGET=$1
  COMMAND=$2
  COMMAND=$(echo ${COMMAND} | sed -e 's/\[/\\\[/g' -e 's/\]/\\\]/g')
  /usr/bin/expect -c "set timeout 20
    spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=no ${USER}@${TARGET}
    expect \"*Password*\"
    send \"${PASS}\r\"
    expect \"*admin*\"
    send \"${COMMAND}\n\"
    expect \"*admin*\"
    send \"exit\n\"
    expect eof"
}

function waitAction {
  IP=$1
  ACTION=$2
  JOB_ID=$3
  if [ -z ${JOB_ID} ]; then
    echo "[${IP}][${ACTION}] Failed due to missing JOB_ID! Probably action didn't start. Exit..."
    exit 1
  fi
  if [ ${ACTION} == "import" ]; then
    MAX_ATTEMPT=20
    COMMAND="show brm backup-manager ccdm-data progress-report ${JOB_ID}"
  elif [ ${ACTION} == "restore" ]; then
    MAX_ATTEMPT=100
    COMMAND="show brm backup-manager ccdm-data backup progress-report ${JOB_ID}"
  else
    echo "Invalid input!"
    exit 1
  fi
  ATTEMPT=0
  while [ ${ATTEMPT} -ne ${MAX_ATTEMPT} ]; do
    ATTEMPT=$(( ${ATTEMPT}+1 ))
    CURRENT_STATUS=$(executeCli ${IP} "${COMMAND}")
    STATE=$(echo "${CURRENT_STATUS}" | grep "^[ \t]*state " | awk '{print $2}' | sed 's/[[:space:]]//g')
    RESULT=$(echo "${CURRENT_STATUS}" | grep "^[ \t]*result " | awk '{print $2}' | sed 's/[[:space:]]//g')
    if ! [ -z ${STATE} ] && [ ${STATE} == "running" ]; then
      echo "[${IP}][${ACTION}] Still running. Waiting..."
      sleep 10
      continue
    else
      if ! [ -z ${RESULT} ] && [ ${RESULT} == "failure" ]; then
        echo "${CURRENT_STATUS}"
        echo "[${IP}][${ACTION}] Failed! Exit..."
        exit 1
      else
        echo "[${IP}][${ACTION}] OK!"
        return
      fi
    fi
  done
  echo "[${IP}][${ACTION}] didn't finish in expected time!"
  echo "${CURRENT_STATUS}"
  exit 1
}


CCDM1_OAM=$(kubectl get svc -A | grep "ccdm.*yang.*Load" | awk '{print $5}' | cut -d, -f1)
MAPI1_VIP=$(kubectl get svc -A |grep eda-prov | awk '{print $5}')
if ! [ -z ${SITE2_CONFIG} ]; then
  KUBECONFIG_TMP=${KUBECONFIG}
  export KUBECONFIG=${SITE2_CONFIG}
  CCDM2_OAM=$(kubectl get svc -A | grep "ccdm.*yang.*Load" | awk '{print $5}' | cut -d, -f1)
  MAPI2_VIP=$(kubectl get svc -A |grep eda-prov | awk '{print $5}')
  export KUBECONFIG=${KUBECONFIG_TMP}
fi
echo "[${CCDM1_OAM}] Starting import of ${BACKUP_LOCATION}"
JOB_ID=$(executeCli ${CCDM1_OAM} "brm backup-manager ccdm-data import-backup uri sftp://${BACKUP_USER}@${BACKUP_LOCATION} password ${BACKUP_PASS}" | grep return-value | awk '{print $2}' | sed 's/[[:space:]]//g')
if ! [ -z ${CCDM2_OAM} ]; then
  echo "[${CCDM2_OAM}] Starting import of ${BACKUP_LOCATION}"
  JOB_ID2=$(executeCli ${CCDM2_OAM} "brm backup-manager ccdm-data import-backup uri sftp://${BACKUP_USER}@${BACKUP_LOCATION} password ${BACKUP_PASS}" | grep return-value | awk '{print $2}' | sed 's/[[:space:]]//g')
fi

waitAction ${CCDM1_OAM} import ${JOB_ID}
if ! [ -z ${CCDM2_OAM} ]; then
  waitAction ${CCDM2_OAM} import ${JOB_ID2}
fi

echo "[${CCDM1_OAM}] Starting restore of ${BACKUP_NAME}"
  JOB_ID=$(executeCli ${CCDM1_OAM} "brm backup-manager ccdm-data backup ${BACKUP_NAME} restore" | grep return-value | awk '{print $2}' | sed 's/[[:space:]]//g')
if ! [ -z ${CCDM2_OAM} ]; then
  echo "[${CCDM2_OAM}] Starting restore of ${BACKUP_NAME}"
  JOB_ID2=$(executeCli ${CCDM2_OAM} "brm backup-manager ccdm-data backup ${BACKUP_NAME} restore" | grep return-value | awk '{print $2}' | sed 's/[[:space:]]//g')
fi

waitAction ${CCDM1_OAM} restore ${JOB_ID}
if ! [ -z ${CCDM2_OAM} ]; then
  waitAction ${CCDM2_OAM} restore ${JOB_ID2}
fi

for MAPI_VIP in ${MAPI1_VIP} ${MAPI2_VIP}; do
  echo "Checking if provisioning is working fine for ${MAPI_VIP}..."
  MAX_ATTEMPT=25
  ATTEMPT=0
  while [ ${ATTEMPT} -ne ${MAX_ATTEMPT} ]; do
    ATTEMPT=$(( ${ATTEMPT}+1 ))
    MAPI_TOKEN=$(curl -k -X POST -sS https://${MAPI_VIP}/auth/realms/oam/protocol/openid-connect/token -H 'Content-Type: application/x-www-form-urlencoded' -d'grant_type=client_credentials&client_id=ccdm-client&client_secret=ccdm-secret&scope=openid scopes.ericsson.com/activation/mapi.read' | jq .access_token -r)
    curl -k -sS https://${MAPI_VIP}/mapi/v1/profiles/udm/udmRoamingAreas/dummy -H "Authorization: Bearer ${MAPI_TOKEN}" -i | grep -q 404-11-301
    if [ $? -eq 0 ]; then
      echo "MAPI returned expected response! Wait 1 min, then break"
      sleep 60
      break
    else
      echo "Unexpected response from MAPI! Wait 1 min, then try again"
      sleep 60
    fi
  done
done
