#!/bin/bash

[ -z "${HSS_FE_VERSION}" ] && HSS_FE_VERSION=
[ -z "${CCSM_VERSION}" ] && CCSM_VERSION=
[ -z "${TAG_LATEST}" ] && TAG_LATEST=false
[ -z "${SDK_LINK}" ] && SDK_LINK=https://arm.seli.gic.ericsson.se/artifactory/proj-ema-release-local/com/ericsson/EDA2_SDK_CA/9.3.9/EDA2_SDK_CA-9.3.9.tar.gz
BUILD_DIR=build_dir

#this is used in pipeline, where CCSM_REPO value is copied to CCSM_VERSION
if [[ ${CCSM_VERSION} == https*csar ]]; then
  CCSM_VERSION=$(echo "${CCSM_VERSION}" | sed 's/.*CXP9037722_\(.*\).csar/\1/')
fi

function addLatest {
  NAME=$1
  TAG=$2
  echo "Pulling ${NAME}:${TAG} image from registry..."
  ${SUDO_PREFIX}docker pull armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:${TAG}

  echo "Adding 'latest' tag and pushing to ARM"
  ${SUDO_PREFIX}docker tag armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:${TAG} armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:latest
  ${SUDO_PREFIX}docker push armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:latest
}

function buildImage {
  echo "-------------------------"
  NAME=$1
  TAG=$2
  tar tvf ${BUILD_DIR}/sw_container_validator.tgz | grep -q Hss.*jar
  if [ $? -ne 0 ]; then
    echo "[ERROR] Problem with input file!"
    exit 1
  fi
  echo "Building validator image ${NAME}:${TAG}..."
  ${SUDO_PREFIX}docker image build --no-cache -t armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:${TAG} ./${BUILD_DIR}
  echo "Pushing image to ARM"
  ${SUDO_PREFIX}docker push armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:${TAG}
  curl -sS -u${ARM_USER}:${ARM_PASS} https://armdocker.rnd.ericsson.se/v2/proj_ema_docker_poc_adp/${NAME}/tags/list | jq -r .tags[] | grep -q "^${TAG}$"
  if [ $? -ne 0 ]; then
    echo "[ERROR] Image not found in repo!"
    exit 1
  fi
  if [ ${TAG_LATEST} == 'true' ]; then
    echo "Adding 'latest' tag and pushing to ARM"
    ${SUDO_PREFIX}docker tag armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:${TAG} armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:latest
    ${SUDO_PREFIX}docker push armdocker.rnd.ericsson.se/proj_ema_docker_poc_adp/${NAME}:latest
  fi
}

for BINARY in jq docker unzip curl; do
  which ${BINARY} >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "[ERROR] ${BINARY} not found!"
    exit 1
  fi
done

if [ $(env | grep "^ARM_USER=\|^ARM_PASS=" | wc -l) -lt 2 ]; then
  echo "ARM credentials not set! Please export ARM_USER and ARM_PASS vars!"
  exit 1
fi

docker ps 2>&1 | grep -q NAME
if [ $? -eq 0 ]; then
  echo "sudo not needed for docker command!"
  SUDO_PREFIX=
else
  echo "sudo needed! Probably Windows password will be asked!"
  SUDO_PREFIX="sudo "
fi

${SUDO_PREFIX}docker login -u ${ARM_USER} -p ${ARM_PASS} armdocker.rnd.ericsson.se >/dev/null 2>&1

echo "Dowloading EDA2 SDK and preparing Dockerfile..."
rm -rf ${BUILD_DIR} 2>/dev/null
mkdir -p ${BUILD_DIR}
echo "SDK: ${SDK_LINK}"
curl -sS -O ${SDK_LINK} -u ${ARM_USER}:${ARM_PASS}
tar xf EDA2_SDK_CA-*.tar.gz
tar xf CXP9050674/ca-deployment-artifacts-*.tar.gz -C ${BUILD_DIR} DVE-Application-CA-base-image/Dockerfile --strip-components=1
echo "ADD ./sw_container_validator.tgz /app/lib/ext" >> ${BUILD_DIR}/Dockerfile
rm -rf CXP9050674 EDA2_SDK_CA-*.tar.gz

if [ -z ${HSS_FE_VERSION} ]; then
  echo "[WARNING] Input files for building HSS-FE validator not found!"
else
  echo "========================="
  curl -sS -u${ARM_USER}:${ARM_PASS} https://armdocker.rnd.ericsson.se/v2/proj_ema_docker_poc_adp/hssfe-validator-auto-build/tags/list | jq
  curl -sS -u${ARM_USER}:${ARM_PASS} https://armdocker.rnd.ericsson.se/v2/proj_ema_docker_poc_adp/hssfe-validator-auto-build/tags/list | jq -r .tags[] | grep -q "^${HSS_FE_VERSION}$"
  if [ $? -eq 0 ]; then
    echo "Image hssfe-validator-auto-build:${HSS_FE_VERSION} already found in repo! Building not needed!"
    if [ ${TAG_LATEST} == 'true' ]; then
      addLatest hssfe-validator-auto-build ${HSS_FE_VERSION}
    fi
  else
    echo "Downloading HSS-FE validator..."
    HSS_LINK=$(curl -sS -X POST 'https://arm.sero.gic.ericsson.se/ui/api/v1/ui/artifactsearch/quick' \
      -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
      -d"{\"query\":\"HSS*_Provisioning_Validator-*.tgz\",\"selectedRepositories\":[\"proj-hss-release-local\"],\"search\":\"quick\"}" |\
      jq .results[].downloadLink -r | grep "HSS${HSS_FE_VERSION}")
    echo "Found: ${HSS_LINK}"
    curl -sS -k ${HSS_LINK} -o sw_container_validator.tgz
    mv sw_container_validator.tgz ${BUILD_DIR}
    buildImage hssfe-validator-auto-build ${HSS_FE_VERSION}
  fi
fi

if [ -z ${CCSM_VERSION} ]; then
  echo "[WARNING] Input files for building cnHSS validator not found!"
else
  echo "========================="
  curl -sS -u${ARM_USER}:${ARM_PASS} https://armdocker.rnd.ericsson.se/v2/proj_ema_docker_poc_adp/cnhss-validator-auto-build/tags/list | jq
  curl -sS -u${ARM_USER}:${ARM_PASS} https://armdocker.rnd.ericsson.se/v2/proj_ema_docker_poc_adp/cnhss-validator-auto-build/tags/list | jq -r .tags[] | grep -q "^${CCSM_VERSION}$"
  if [ $? -eq 0 ]; then
    echo "Image cnhss-validator-auto-build:${CCSM_VERSION} already found in repo! Building not needed!"
    if [ ${TAG_LATEST} == 'true' ]; then
      addLatest cnhss-validator-auto-build ${CCSM_VERSION}
    fi
  else
    echo "Downloading cnHSS validator..."
    for REPO in proj-5g-ccsm-staging-generic-local proj-hss-docker-global; do
      CCSM_LINK=$(curl -sS -X POST 'https://arm.seli.gic.ericsson.se/ui/api/v1/ui/artifactsearch/quick' \
        -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
        -d"{\"query\":\"Ericsson.CCSM.CXP9037722_${CCSM_VERSION}.csar\",\"selectedRepositories\":[\"${REPO}\"],\"search\":\"quick\"}" -k |\
        jq .results[].downloadLink -r | grep ${CCSM_VERSION})
      if ! [ -z ${CCSM_LINK} ]; then
        echo "Found: ${CCSM_LINK}"
        break
      fi
    done
    curl -sS -k -O ${CCSM_LINK}
    unzip -o Ericsson.CCSM.CXP9037722*.csar Scripts/ConfigMgmt/HSS/VALIDATOR/sw_container_validator.tgz
    mv Scripts/ConfigMgmt/HSS/VALIDATOR/sw_container_validator.tgz ${BUILD_DIR}
    rm -rf Scripts Ericsson.CCSM.CXP9037722*.csar
    buildImage cnhss-validator-auto-build ${CCSM_VERSION}
  fi
fi
