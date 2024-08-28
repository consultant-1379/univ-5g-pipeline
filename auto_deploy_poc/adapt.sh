#!/bin/bash

########################
# these variables can be provided by "export" command before starting script
# if they are not provided, default values are used
# it is assumed that KUBECONFIG variable is already exported!
[ -z "${ADAPTED_DIR}" ] && ADAPTED_DIR=adapted_dir
[ -z "${INPUT_DIR}" ] && INPUT_DIR=input_dir
[ -z "${VALUES_FILE}" ] && VALUES_FILE=input.txt

NFT_ENV=$(kubectl get cm -n jenkins-tools extra-settings -o jsonpath="{.data.nft}" 2>/dev/null)
USE_HSS=$(kubectl get cm -n jenkins-tools extra-settings -o jsonpath="{.data.hss-fe}" 2>/dev/null)
USE_HSM=$(kubectl get cm -n jenkins-tools extra-settings -o jsonpath="{.data.hsm}" 2>/dev/null)
HSSFE=$(kubectl get cm -n jenkins-tools legacy-nodes -o jsonpath="{.data.HSS}" 2>/dev/null)
HLRFE=$(kubectl get cm -n jenkins-tools legacy-nodes -o jsonpath="{.data.HLR}" 2>/dev/null)
HSS_HTTP_VIP=$(kubectl get cm -n jenkins-tools legacy-nodes -o jsonpath="{.data.HSS_HTTP_VIP}" 2>/dev/null)

if ! [ -z ${NFT_ENV} ] && [ ${NFT_ENV} == 'true' ]; then
  DEFAULT_INPUT=input_template_nft.txt
else
  DEFAULT_INPUT=input_template.txt
fi
[ -z "${VALUES_TEMPLATE_FILE}" ] && VALUES_TEMPLATE_FILE=${DEFAULT_INPUT}
[ -z "${VARS_TMP}" ] && VARS_TMP=./cluster_vars.tmp
[ -z "${STATIC_CFG}" ] && STATIC_CFG=configurations
########################

function cleanupYaml {
  echo -e "\nDoing additional YAML cleanup for $1"
  sed -i '/^$/d' $1
  CLEANUP_TMP=cleanup_tmp_file.yaml
  OLD_IFS=${IFS}
  IFS=""
  while read line; do
    echo "$(echo ${line} | grep -o '^[ -]*' |wc -c);${line}"
  done < $1 | tac > ${CLEANUP_TMP}
  IFS=${OLD_IFS}
  for i in $(seq 1 15); do
    LINES_TO_REMOVE=
    PREV_LINE_LEN=0
    LINE=1
    while read line; do
      CURRENT_LINE_LEN=$(echo $line | cut -d';' -f1)
      # detect if leaf entry
      if [ ${PREV_LINE_LEN} -le ${CURRENT_LINE_LEN} ]; then
        # check if leaf is empty
        echo "$line" | cut -d';' -f2 | grep ": *#.*\|: *$" -q
        if [ $? -eq 0 ]; then
          LINES_TO_REMOVE=${LINES_TO_REMOVE}"${LINE}d;"
        fi
      fi
      PREV_LINE_LEN=$CURRENT_LINE_LEN
      LINE=$(( ${LINE} +1 ))
    done < ${CLEANUP_TMP}
    #nothing else to do, exit
    if [ -z ${LINES_TO_REMOVE} ]; then
      break
    fi
    LINES_TO_REMOVE=${LINES_TO_REMOVE}"9999d"
    sed -i -e "${LINES_TO_REMOVE}" ${CLEANUP_TMP}
  done
  tac ${CLEANUP_TMP} | cut -d';' -f2 > $1
  rm -f ${CLEANUP_TMP} 2>/dev/null
}

if ! [ -z $1 ] && [ $1 == "-h" ]; then
  cat adapt_readme.txt
  exit
fi

# print detailed info about script actions
if ! [ -z $1 ] && [ $1 == "-v" ]; then
  PRINT_ALL=true
  EXPORT_COMMAND="| tee -a"
else
  PRINT_ALL=false
  EXPORT_COMMAND=">>"
fi

function getClusterInfo {

if [ $(kubectl get crd --request-timeout 10 | wc -l ) -lt 3 ]; then
  echo "Something seems to be wrong with cluster access! EXECUTION STOPPED"
  exit 99
fi

echo "================================="
echo "Getting info from the cluster..."
echo "================================="
METALLB_CM=$(kubectl get cm -n kube-system ecfe-ccdadm metallb-config --ignore-not-found --no-headers | awk '{print $1}')
METALLB_CONFIG=$(kubectl get cm -n kube-system ${METALLB_CM} -o yaml | grep ^kind -B1000)
#coverting data to different format, to enable processing when configmap has non-standard order of parameters
METALLB_CONFIG_FORMATTED=$(echo "${METALLB_CONFIG}" | tr '\n' ' ' | sed -e 's/addresses:\s\+-/addresses:/g' -e 's/ - /\n/g'  | grep name:)
COREDNS_CONFIG=$(kubectl get cm -n kube-system  coredns -o yaml | grep ^kind -B1000 | sed -e 's/:0*/:/g' | sed -e 's/:\{2,\}/::/g')
for VIP_NAME in $(echo "${METALLB_CONFIG}" | grep name | grep -v default | awk '{print $NF}'); do
  VIP=$(echo "${METALLB_CONFIG_FORMATTED}" | grep ${VIP_NAME} | cut -d/ -f1 | awk '{print $NF}' | head -n1)
  #IPv6 addresses are compressed just for matching purposes
  VIP_COMPRESSED=$(echo ${VIP} | sed -e 's/:0*/:/g' | sed -e 's/:\{2,\}/::/g')
  VIP_NAME=$(echo ${VIP_NAME} | sed 's/-/_/g')
  if [ $(grep "${VIP_NAME}_VIP=" ${VARS_TMP} 2>/dev/null | wc -l) -eq 0 ]; then
    eval echo "export ${VIP_NAME}_VIP=${VIP}" ${EXPORT_COMMAND} ${VARS_TMP}
  else
    eval echo "export ${VIP_NAME}_VIP_2=${VIP}" ${EXPORT_COMMAND} ${VARS_TMP}
  fi
  FQDN_LIST=$(echo "${COREDNS_CONFIG}" | grep ${VIP_COMPRESSED} | awk '{print $2}')
  for FQDN in $(echo "${FQDN_LIST}"); do
    if [ $(grep "${VIP_NAME}_FQDN=" ${VARS_TMP} 2>/dev/null | wc -l) -eq 0 ]; then
      eval echo "export ${VIP_NAME}_FQDN=${FQDN}" ${EXPORT_COMMAND} ${VARS_TMP}
    else
      eval echo "export ${VIP_NAME}_FQDN_2=${FQDN}" ${EXPORT_COMMAND} ${VARS_TMP}
    fi
  done
done
#this is needed due to 2 EDA2 FQDNs connected to the same IP
sed -i 's/\(.*\)oam\(.*prov.*\)/\1prov\2/' cluster_vars.tmp
sed -i 's/\(eda2.*FQDN\).*=/\1=/' cluster_vars.tmp
eval echo "export STORAGE_CLASS=$(kubectl get sc | grep default | awk '{print $1}')" ${EXPORT_COMMAND} ${VARS_TMP}

kubectl get svc kubernetes -n default --no-headers | grep -q :
if [ $? -eq 0 ]; then
  eval echo "export USE_IPV6=true" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export USE_IPV4=false" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export IP_STACK=ipv6" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export IP_STACK_CAPITAL=IPv6" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export DIAMETER_IP=ipv6" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export LICENSE_SERVER=2001:1b74:9b:c002::97" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export IPV6_L=[" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export IPV6_R=]" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export SNMP_TYPE=2" ${EXPORT_COMMAND} ${VARS_TMP}
else
  eval echo "export USE_IPV6=false" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export USE_IPV4=true" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export IP_STACK=ipv4" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export IP_STACK_CAPITAL=IPv4" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export DIAMETER_IP=ip" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export LICENSE_SERVER=10.155.142.69" ${EXPORT_COMMAND} ${VARS_TMP}
  eval echo "export SNMP_TYPE=1" ${EXPORT_COMMAND} ${VARS_TMP}
fi
if [ $(grep "export CLUSTER_ID=" ${VARS_TMP} 2>/dev/null | wc -l) -eq 0 ]; then
  eval echo "export CLUSTER_ID=$(kubectl get node | grep 'udm[0-9]\{5\}\|capo-[0-9]\{5\}' -m1 -o | tr -d -)" ${EXPORT_COMMAND} ${VARS_TMP}
else
  eval echo "export CLUSTER_ID_2=$(kubectl get node | grep 'udm[0-9]\{5\}\|capo-[0-9]\{5\}' -m1 -o | tr -d -)" ${EXPORT_COMMAND} ${VARS_TMP}
fi
eval echo "export HLR_MML_VIP=$(echo "${HLRFE}" | grep hlrMmlIp | awk '{print $2}')" ${EXPORT_COMMAND} ${VARS_TMP}
eval echo "export HLR_MML_USER=$(echo "${HLRFE}" | grep hlrMmlUser | awk '{print $2}')" ${EXPORT_COMMAND} ${VARS_TMP}
eval echo "export HLR_MML_PASS=$(echo "${HLRFE}" | grep hlrMmlPassword | awk '{print $2}')" ${EXPORT_COMMAND} ${VARS_TMP}
eval echo "export HLR_SCTP_VIP=$(echo "${HLRFE}" | grep hlrSctpIp | awk '{print $2}')" ${EXPORT_COMMAND} ${VARS_TMP}
eval echo "export HSS_SOAP_VIP=$(echo "${HSSFE}" | grep hssCliIp | awk '{print $2}')" ${EXPORT_COMMAND} ${VARS_TMP}
eval echo "export HSS_HTTP_VIP=${HSS_HTTP_VIP}" ${EXPORT_COMMAND} ${VARS_TMP}
echo "================================="

}

rm -f ${VARS_TMP} ${ADAPTED_DIR}/* 2>/dev/null
getClusterInfo

if ! [ -z ${SITE2_CONFIG} ]; then
  SITE1_CONFIG=${KUBECONFIG}
  export KUBECONFIG=${SITE2_CONFIG}
  getClusterInfo
  export KUBECONFIG=${SITE1_CONFIG}
fi

if ! [ -f ${VALUES_TEMPLATE_FILE} ]; then
  echo "File ${VALUES_TEMPLATE_FILE} does not exist!"
  exit 1
fi

##############################
# Special configurations START
##############################

#usage of HSM controlled by value in configmap. Default: no HSM
HSM_FILES=$(find ./${INPUT_DIR} -name *set_udm_hsm*)
for HSM_FILE in ${HSM_FILES}; do
  if ! [ -z ${USE_HSM} ] && [ ${USE_HSM} == 'true' ]; then
    eval echo "export USE_HSM=true" ${EXPORT_COMMAND} ${VARS_TMP}
    mv ${HSM_FILE} ${HSM_FILE//.IGNORE} 2>/dev/null
  else
    eval echo "export USE_HSM=false" ${EXPORT_COMMAND} ${VARS_TMP}
    mv ${HSM_FILE//.IGNORE} ${HSM_FILE}.IGNORE 2>/dev/null
  fi
done

#configuration for HSS-FE
UDM_REMOTE=$(find ./${INPUT_DIR} -name *udm_remote_nf_profile*)
if ! [ -z ${HSS_HTTP_VIP} ]; then
  cp ${UDM_REMOTE} $(echo ${UDM_REMOTE} | sed 's/udm_remote/udm_hssfe_remote/') 2>/dev/null
else
  rm ./${INPUT_DIR}/*udm_hssfe_remote* 2>/dev/null
fi

#usage of cnHSS or HSS-FE validator controlled by value in configmap. Default: cnHSS
if ! [ -z ${USE_HSS} ] && [ ${USE_HSS} == 'true' ]; then
  eval echo "export VALIDATOR_IMAGE=hssfe-validator-auto-build" ${EXPORT_COMMAND} ${VARS_TMP}
else
  eval echo "export VALIDATOR_IMAGE=cnhss-validator-auto-build" ${EXPORT_COMMAND} ${VARS_TMP}
fi

#CCRC geored
grep -q ccrc_nrf_sig_VIP_2 ${VARS_TMP}
if [ $? -eq 0 ]; then
  echo "Second CCRC site detected!"
  for AGENT_FILE in $(find ./${INPUT_DIR} -name *nrf*agent* | grep -v NRF2 | grep -v SITE); do
    cp ${AGENT_FILE} $(echo ${AGENT_FILE} | sed 's/__/__NRF2_/')
  done
  for SITE1_FILE in $(find ./${INPUT_DIR} -name *eric-ccrc* | grep -v SITE); do
    SITE2_FILE=$(echo ${SITE1_FILE} | sed 's/__/__SITE2_/')
    SITE1_FILE_NEW=$(echo ${SITE1_FILE} | sed 's/__/__SITE1_/')
    cp ${SITE1_FILE} ${SITE2_FILE}
    mv ${SITE1_FILE} ${SITE1_FILE_NEW}
  done
  grep -q "CCRC2_GEORED" ./${INPUT_DIR}/eric-ccdm_day0* || sed -i 's/\(.*eric-ccrc-sbi-traffic-mtls:$\)/##CCRC2_GEORED_PLACEHOLDER\n\1/' ./${INPUT_DIR}/eric-ccdm_day0*
  grep -q "CCRC2_GEORED" ./${INPUT_DIR}/eric-ccpc_day0* || sed -i 's/\(.*eric-ccrc-sbi-traffic-mtls:$\)/#CCRC2_GEORED_PLACEHOLDER\n\1/' ./${INPUT_DIR}/eric-ccpc_day0*
else
  rm ./${INPUT_DIR}/*SITE2* rm ./${INPUT_DIR}/*NRF2* 2>/dev/null
  for FILE in $(find ./${INPUT_DIR} -name *eric-ccrc* | grep SITE); do
    mv ${FILE} ${FILE/SITE1_}
  done
  sed -i '/CCRC2_GEORED/d' ./${INPUT_DIR}/eric-ccdm_day0*
  sed -i '/CCRC2_GEORED/d' ./${INPUT_DIR}/eric-ccpc_day0*
fi

#CCDM geored
grep -q intersite_FQDN_2 ${VARS_TMP}
if [ $? -eq 0 ]; then
  echo "Second CCDM site detected!"
  for SITE1_FILE in $(find ./${INPUT_DIR} -name *eric-ccdm* | grep -v SITE); do
    SITE2_FILE=$(echo ${SITE1_FILE} | sed 's/__/__SITE2_/')
    SITE1_FILE_NEW=$(echo ${SITE1_FILE} | sed 's/__/__SITE1_/')
    cp ${SITE1_FILE} ${SITE2_FILE}
    mv ${SITE1_FILE} ${SITE1_FILE_NEW}
  done
  export CCDM_2_NE=',{"name": "CCDM_2","order": 2}'
  export UDR_2_NE=',{"name": "UDR_2","order": 2}'
  eval echo "export SITE2_MAPPING=\\\",siteId=2\\\\\&MapiNEName=CCDM2-Replay\\\\\&UdrNEName=UDR2-Replay\\\"" ${EXPORT_COMMAND} ${VARS_TMP}
  for FILE in $(find ${STATIC_CFG} -name *GEORED); do
    mv ${FILE} $(echo ${FILE} | sed 's/GEORED/template/')
  done
  #this is used in app counters file
  export SECOND_UDR_SITE=2
else
  rm ./${INPUT_DIR}/*SITE2* 2>/dev/null
  rm ./${STATIC_CFG}/EDA2/EDA2_objects/network_elements/*2*json 2>/dev/null
  for FILE in $(find ./${INPUT_DIR} -name *eric-ccdm* | grep SITE); do
    mv ${FILE} ${FILE/SITE1_}
  done
  for FILE in $(find ${STATIC_CFG} -path *EDA2_objects*2*template); do
    mv ${FILE} $(echo ${FILE} | sed 's/template/GEORED/')
  done
  export SECOND_UDR_SITE=1
fi

#CCES currently doesn't support profiles, so different flavors require different yaml
SMALL_SYSTEM=$(grep -m1 small-system ${VALUES_TEMPLATE_FILE} | awk '{print $2}')
SMALL_YAML=$(find ./${INPUT_DIR} -name *cces_day0* | grep small)
STANDARD_YAML=$(find ./${INPUT_DIR} -name *cces_day0* | grep -v small)
if [ ${SMALL_SYSTEM} == 'true' ]; then
  mv ${STANDARD_YAML//.IGNORE} ${STANDARD_YAML}.IGNORE 2>/dev/null
  mv ${SMALL_YAML} ${SMALL_YAML//.IGNORE} 2>/dev/null
else
  mv ${SMALL_YAML//.IGNORE} ${SMALL_YAML//.IGNORE}.IGNORE 2>/dev/null
  mv ${STANDARD_YAML} ${STANDARD_YAML//.IGNORE} 2>/dev/null
fi

#HSS-FE and HLR-FE EDA2 configuration
if [ $(echo ${HSSFE} | wc -w) -ne 0 ]; then
  echo "HSS-FE configuration detected!"
  for FILE in $(find ${STATIC_CFG} -name HSSFE*LEGACY); do
    mv ${FILE} $(echo ${FILE} | sed 's/LEGACY/template/') 2>/dev/null
  done
else
  rm ./${STATIC_CFG}/EDA2/EDA2_objects/network_elements/HSSFE*json 2>/dev/null
  for FILE in $(find ${STATIC_CFG} -name HSSFE*template); do
    mv ${FILE} $(echo ${FILE} | sed 's/template/LEGACY/') 2>/dev/null
  done
fi
if [ $(echo ${HLRFE} | wc -w) -ne 0 ]; then
  echo "HLR-FE configuration detected!"
  for FILE in $(find ${STATIC_CFG} -name HLR*LEGACY); do
    mv ${FILE} $(echo ${FILE} | sed 's/LEGACY/template/') 2>/dev/null
  done
else
  rm ./${STATIC_CFG}/EDA2/EDA2_objects/network_elements/HLR*json 2>/dev/null
  for FILE in $(find ${STATIC_CFG} -name HLR*template); do
    mv ${FILE} $(echo ${FILE} | sed 's/template/LEGACY/') 2>/dev/null
  done
fi

##############################
# Special configurations END
##############################

echo "Creating ${VALUES_FILE}..."
source ${VARS_TMP}
cat ${VALUES_TEMPLATE_FILE} |envsubst > ${VALUES_FILE}

echo "Checking ${VALUES_FILE}..."
cp ${VALUES_FILE} ${VALUES_FILE}.tmp
sed -i '/^\s*$/d' ${VALUES_FILE}.tmp
sed -i -e 's/\s*;\s*/;/g' ${VALUES_FILE}.tmp
sed -i -r 's/^\s+//g' ${VALUES_FILE}.tmp
sed -i -r 's/^\s+//g' ${VALUES_FILE}.tmp
sed -i -e '/^[ \t]*#/d' ${VALUES_FILE}.tmp
sed -i -e 's/\//\\\//g' ${VALUES_FILE}.tmp  #escaping /

#Setting target for rules
RULES_LIST=()
while read -r LINE; do
  if [[ ${LINE} == TARGET=* ]]; then
    PREFIX=$(echo ${LINE} | cut -d= -f2)
  else
    if [ -z ${PREFIX} ]; then
      RULES_LIST+=("${LINE}")
    else
      RULES_LIST+=("${PREFIX};${LINE}")
    fi
  fi
done < ${VALUES_FILE}.tmp
printf '%s\n' "${RULES_LIST[@]}" > ${VALUES_FILE}.tmp

#converting values file to different format, to speed up processing later
sed -i "s/\(^[^;]*\);\([^;]*\);\(.*\)/\TARGET='\1';KEY='\2';VALUE='\3'/" ${VALUES_FILE}.tmp

ERROR_DETECTED=false
echo "Filling templates..."
mkdir -p ${ADAPTED_DIR} ${INPUT_DIR}


for YAML_FILE in $(ls ${INPUT_DIR}/*yaml); do
  CLEANUP_YAML=false
  echo -e "\n=================================\nFILE: ${YAML_FILE}"
  FILE_CONTENT=$(cat ${YAML_FILE})
  while read -r LINE; do
    if [ $(echo "${LINE}" | awk -F';' '{print NF-1}') -ne 2 ]; then
      echo -e "\n[WARNING] Line skipped (faulty syntax): ${LINE}"
      continue
    fi
    eval ${LINE}
    if [ ${TARGET} == "all" ] || [[ ${YAML_FILE} == *${TARGET}* ]]; then
      if [ -z ${TARGET} ] || [ -z ${KEY} ] || [ -z ${VALUE} ]; then
        echo -e "\n[WARNING] Line skipped (missing data): ${LINE}"
        continue
      fi
      if [ ${PRINT_ALL} == "true" ]; then
        echo "Filling ${KEY}:${VALUE}"
      else
        echo -n "."
      fi
      if [[ ${VALUE} =~ ^(-{1,3})$ ]]; then
        #just remove {{ }} placeholder for given key
        #if there are multiple values {{A|B|C}}, - will set A, -- will set B, --- will set C
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed 's/\({{\)(\(.*\))\(}}\)/\1\2\3/' |
          sed -e "s/\(${KEY}:.*\)#.*/\1/g" |
          sed -e "s/\(${KEY}\)\s*\(:\)\s*{{\(.*\)}}/\1\2 \3/g")
        for i in $(seq 2 $(echo -n ${VALUE} | wc -c)); do
          FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "s/\(${KEY}:\)[^|]*|/\1 /g")
        done
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "s/\(${KEY}:[^|]*\)|.*/\1/g")
      elif [ ${KEY} == "-" ]; then
        #direct replacement of value, without searching for key
        OLD_VAL=$(echo ${VALUE} | cut -d= -f1)
        NEW_VAL=$(echo ${VALUE} | cut -d= -f2)
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "s/${OLD_VAL}/${NEW_VAL}/g")
      elif [[ ${KEY} == "PATH="* ]]; then
        #key-value replacement, taking full or partial yaml path as input
        #single instance is replaced
        KEY=$(echo ${KEY} | cut -d= -f2)
        TMP_RESULT=$(echo "${FILE_CONTENT}" | awk '{print NR,$0}')
        #searching for line number to replace
        for KEY_PART in $(echo ${KEY} | sed 's/\./\n/g'); do
          #logic for handling yaml lists. Items are specified by index, starting with 1
          if [[ "${KEY_PART}" =~ ^[0-9]+$ ]]; then
            IS_LIST=true
            #logic for discarding first N-1 items, entered if index is >=2
            for LIST_INDEX in $(seq ${KEY_PART} -1 2); do
              TMP_RESULT=$(echo "${TMP_RESULT}" | grep -v "^[0-9]\+ *#" | grep -m${LIST_INDEX} -A300 "\- "| tail -n +2)
            done
            #taking Nth element
            TMP_RESULT=$(echo "${TMP_RESULT}" | grep -v "^[0-9]\+ *#" | grep -m1 -A300 "\- ")
          else
            IS_LIST=false
            TMP_RESULT=$(echo "${TMP_RESULT}" | grep -v "^[0-9]\+ *#" | grep -m1 -A300 " ${KEY_PART}:")
          fi
        done
        LINE_NUMBER=$(echo "${TMP_RESULT}" | awk '{print $1}' | head -n1)
        if [ -z ${LINE_NUMBER} ]; then
          echo -e "\n[WARNING] Key ${KEY} not found!"
        else
          if [ ${IS_LIST} == "true" ]; then
            FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "${LINE_NUMBER}s/-.*/- ${VALUE}/g")
          else
            FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "${LINE_NUMBER}s/\( ${KEY_PART}\)\s*\(:\).*/\1\2 ${VALUE}/g")
          fi
        fi
      elif [[ ${KEY} == "ROOT" ]]; then
        #insert object at root level
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "1i\\${VALUE}")
      elif [ ${VALUE} == "UNCOMMENT" ]; then
        START_KEY=$(echo ${KEY} | cut -d_ -f1)
        END_KEY=$(echo ${KEY} | cut -d_ -f2)
        START_LINES=$(echo "${FILE_CONTENT}" | grep -n "# *${START_KEY}:" | cut -d: -f1)
        END_LINES=$(echo "${FILE_CONTENT}" | grep -n "# *${END_KEY}:" | cut -d: -f1 | tac)
        for START_LINE in ${START_LINES}; do
          for END_LINE in ${END_LINES}; do
            CHECK_IF_BLOCK=$(echo "${FILE_CONTENT}" | sed "${START_LINE},${END_LINE}!d" | grep -v "# *" |wc -l)
            [ ${CHECK_IF_BLOCK} -eq 0 ] && break
          done
          [ ${CHECK_IF_BLOCK} -ne 0 ] && END_LINE=
          if [ -z ${START_LINE} ] || [ -z ${END_LINE} ]; then
            echo -e "\n[WARNING] Cannot find key ${START_KEY} or ${END_KEY}, or keys don't form continuous comment block!"
          else
            FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed "${START_LINE},${END_LINE}s/#//")
          fi
        done
      elif [ ${KEY} == "CLEANUP_YAML" ] && [ ${VALUE} == "true" ]; then
        CLEANUP_YAML=true
      elif [ ${VALUE} == "COMMENT" ]; then
        START_KEY=$(echo ${KEY} | cut -d_ -f1)
        END_KEY=$(echo ${KEY} | cut -d_ -f2)
        if [ ${START_KEY} == ${END_KEY} ]; then
          FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed "s/\(.*${START_KEY}.*\)/#\1/")
        else
          START_LINE=$(echo "${FILE_CONTENT}" | grep -n " *${START_KEY}:" | cut -d: -f1 | head -n1)
          END_LINE=$(echo "${FILE_CONTENT}" | grep -n " *${END_KEY}:" | cut -d: -f1 | head -n1)
          if [ -z ${START_LINE} ] || [ -z ${END_LINE} ]; then
            echo -e "\n[WARNING] Cannot find key ${START_KEY} or ${END_KEY}!"
          else
            FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed "${START_LINE},${END_LINE}s/^/#/")
          fi
        fi
      else
        #default: fill key with value
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "s/\(^ *-\? *${KEY}\)\s*\(:\).*/\1\2 ${VALUE}/g")
      fi
    fi
  done < ${VALUES_FILE}.tmp
  #remove placeholders, EOL characters, and comments
  FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed "s/_DUMMY//g" | sed "s/%/ /g" | sed -e "s/\r//" | grep -v "^ *#")
  echo "${FILE_CONTENT}" > ${ADAPTED_DIR}/adapted_${YAML_FILE##${INPUT_DIR}/}
  if [ ${CLEANUP_YAML} == "true" ]; then
    cleanupYaml ${ADAPTED_DIR}/adapted_${YAML_FILE##${INPUT_DIR}/}
  fi

  #find not updated lines
  NOT_UPDATED=$(grep "{{\|\\$\|<.*>" ${ADAPTED_DIR}/adapted_${YAML_FILE##${INPUT_DIR}/} | grep -v "^ *#")
  if [ $(echo -n "${NOT_UPDATED}" |wc -w) -gt 0 ]; then
    echo -e "\n\n[ERROR] Not updated lines:"
    echo "${NOT_UPDATED}"
    ERROR_DETECTED=true
  fi
done

#################################
# MERGE day-0 values
#################################
echo -e "\n================================="
echo "Merge day-0 files with profile templates"

# CNCS CCRC
if [[ -d ccrc_profiles_temp ]]; then
  echo -e "\nMerge CCRC day0 file"
  for CCRC_CNCS in $(ls adapted_dir/ | grep "eric-ccrc_day0.*.yaml"); do
    ./merge_CCRC.sh adapted_dir/${CCRC_CNCS} ccrc_profiles_temp/Scripts/Deployment/profiles
    cp adapted_dir/*.merged.yaml adapted_dir/${CCRC_CNCS}
  done
  rm -rf adapted_dir/*.merged.yaml
fi

# CNCS CCDM
if [[ -d ccdm_tools ]]; then
  echo -e "\nMerge CCDM day0 file"
  for CCDM_CNCS in $(ls adapted_dir/ | grep "eric-ccdm_day0.*.yaml"); do
    python3 ccdm_tools/Scripts/Deployment/eric-ccdm-tools*/merge.py no-cncs -i adapted_dir/${CCDM_CNCS}
    cp ccdm_tools/Scripts/Deployment/eric-ccdm-tools*/values.yaml adapted_dir/${CCDM_CNCS}
  done
fi

# CNCS CCPC
if [[ -d ccpc_tools ]]; then
  echo -e "\nMerge CCPC day0 file"
  CCPC_CNCS=$(ls adapted_dir/ | grep "eric-ccpc_day0.*.yaml")
  python3 ccpc_tools/Scripts/Deployment/eric-ccpc-cncs-tools*/merge.py cncs -i adapted_dir/${CCPC_CNCS}
  cp ccpc_tools/Scripts/Deployment/eric-ccpc-cncs-tools*/values.yaml adapted_dir/${CCPC_CNCS}
fi

echo -e "\n================================="
#################################

for XML_FILE in $(ls ${INPUT_DIR}/*xml); do
  echo -e "\n=================================\nFILE: ${XML_FILE}"
  FILE_CONTENT=$(cat ${XML_FILE})
  while read -r LINE; do
    if [ $(echo "${LINE}" | awk -F';' '{print NF-1}') -ne 2 ]; then
      echo -e "\n[WARNING] Line skipped (faulty syntax): ${LINE}"
      continue
    fi
    eval ${LINE}
    if [ ${TARGET} == "all" ] || [[ ${XML_FILE} == *${TARGET}* ]]; then
      if [ -z ${TARGET} ] || [ -z ${KEY} ] || [ -z ${VALUE} ]; then
        echo -e "\n[WARNING] Line skipped (missing data): ${LINE}"
        continue
      fi
      if [ ${PRINT_ALL} == "true" ]; then
        echo "Filling ${KEY}:${VALUE}"
      else
        echo -n "."
      fi
      if [ ${KEY} == "-" ]; then
        #direct replacement of value, without searching for key
        OLD_VAL=$(echo ${VALUE} | cut -d= -f1)
        NEW_VAL=$(echo ${VALUE} | cut -d= -f2)
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "s/${OLD_VAL}/${NEW_VAL}/g")
      elif [ ${KEY} == "UNCOMMENT_TAG" ]; then
        if [ ${VALUE} == "all" ]; then
          FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed 's/^[ \t]*<!--[ \t]*$\|^[ \t]*-->[ \t]*$//')
        fi
        #TODO: maybe implement uncommenting of specific tags
      elif [ ${VALUE} == "REMOVE_BLOCK" ]; then
        #remove block identifed by key
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "/<${KEY}>.*<\/${KEY}>/d" | sed -e "/<${KEY}>/,/<\/${KEY}>/d")
      elif [ ${VALUE} == "MARK_BLOCK" ]; then
        #mark 1 key instace, to prevent operations on it (REMOVE_BLOCK or substitution)
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "0,/\(<${KEY}\)\(>\)/ s/\(<${KEY}\)\(>\)/\1_DUMMY>/")
      elif [[ ${KEY} == "ONE="* ]]; then
        #replace just first occurence for given key
        KEY=$(echo ${KEY} | cut -d= -f2)
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "0,/\(<${KEY}\)\(>\).*\(<\/${KEY}>\)/ s/\(<${KEY}\)\(>\).*\(<\/${KEY}>\)/\1_DUMMY\2${VALUE}\3/")
      elif [[ ${KEY} == "INSERT_INTO="* ]]; then
        #insert new content within given key. Just first match is taken into account
        KEY=$(echo ${KEY} | cut -d= -f2)
        #if we set DUMMY, one block can be updated only once. Next updates will be done on next block matching the key
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "0,/\(<${KEY}\)\(>\)/ s/\(<${KEY}\)\(>\)/\1_DUMMY\2\n${VALUE}/")
      elif [[ ${KEY} == "INSERT_AFTER="* ]]; then
        #insert new content after given key. Just first match is taken into account
        KEY=$(echo ${KEY} | cut -d= -f2)
        #if we set DUMMY, one block can be updated only once. Next updates will be done on next block matching the key
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "0,/\(<\/${KEY}\)\(>\)/ s/\(<\/${KEY}\)\(>\)/\1_DUMMY\2\n${VALUE}/")
      elif [[ ${KEY} == "INSERT_FILE="* ]]; then
        #insert new content within given key - from external file. Just first match is taken into account
        KEY=$(echo ${KEY} | cut -d= -f2)
        #this is a special case where we don't want escaped / in value
        VALUE=$(echo ${VALUE} | sed -e 's/\\//g')
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "0,/\(<${KEY}\)\(>\)/ s/\(<${KEY}\)\(>\)/\1_DUMMY>/")
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "/<${KEY}_DUMMY>/r${VALUE}")
      elif [[ ${KEY} == "PATH="* ]]; then
        #key-value replacement, taking full or partial xml path as input
        #single instance is replaced
        KEY=$(echo ${KEY} | cut -d= -f2)
        TMP_RESULT=$(echo "${FILE_CONTENT}" | awk '{print NR,$0}')
        for KEY_PART in $(echo ${KEY} | sed 's/\./\n/g'); do
          TMP_RESULT=$(echo "${TMP_RESULT}" | grep -A300 "<${KEY_PART}>")
        done
        LINE_NUMBER=$(echo "${TMP_RESULT}" | awk '{print $1}' | head -n1)
        if [ -z ${LINE_NUMBER} ]; then
          echo -e "\n[WARNING] Key ${KEY} not found!"
        else
          FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "${LINE_NUMBER}s/\(<${KEY_PART}\)\(>\).*\(<\/${KEY_PART}>\)/\1_DUMMY\2${VALUE}\3/g")
       fi
      else
        #default: fill key with value
        FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed -e "s/\(<${KEY}>\).*\(<\/${KEY}>\)/\1${VALUE}\2/g")
      fi
    fi
  done < ${VALUES_FILE}.tmp

  #remove placeholders, blank lines and comments
  FILE_CONTENT=$(echo "${FILE_CONTENT}" | sed "s/_DUMMY//g" | sed "s/%/ /g" | sed -e "/<!--.*-->/d" | sed -e "/<!--/,/-->/d" | sed -e "/^[ \t\r]*$/d" | sed -e "s/\r//")
  echo -e "${FILE_CONTENT}" > ${ADAPTED_DIR}/adapted_${XML_FILE##${INPUT_DIR}/}

  #find not updated lines
  NOT_UPDATED=$(grep "{{\|\\$\|{.*}" ${ADAPTED_DIR}/adapted_${XML_FILE##${INPUT_DIR}/} | grep -v " \\$ \|SYNTAX")
  if [ $(echo "${NOT_UPDATED}" |wc -w) -gt 0 ]; then
    echo -e "\n\n[ERROR] Not updated lines:"
    echo "${NOT_UPDATED}"
    ERROR_DETECTED=true
  fi
done

echo -e "\n================================="
echo "Looking for static files in ${STATIC_CFG}"
IMS_CONF_FT=$(find ./${STATIC_CFG} -name *hssims* | grep -v nft)
IMS_CONF_NFT=$(find ./${STATIC_CFG} -name *hssims* | grep nft)
if ! [ -z ${NFT_ENV} ] && [ ${NFT_ENV} == 'true' ]; then
  mv ${IMS_CONF_FT//.IGNORE} ${IMS_CONF_FT//.IGNORE}.IGNORE 2>/dev/null
  mv ${IMS_CONF_NFT} ${IMS_CONF_NFT//.IGNORE} 2>/dev/null
else
  mv ${IMS_CONF_NFT//.IGNORE} ${IMS_CONF_NFT}.IGNORE 2>/dev/null
  mv ${IMS_CONF_FT} ${IMS_CONF_FT//.IGNORE} 2>/dev/null
fi
for FILE in $(ls ${STATIC_CFG} | grep ^static | grep -v IGNORE); do
  echo "Copying ${FILE}"
  cat ${STATIC_CFG}/${FILE} | envsubst > ${ADAPTED_DIR}/${FILE//static/adapted}
done

echo -e "\n================================="
echo "Preparing EDA2 configuration files"
echo "Updating ${STATIC_CFG}/EDA2/EDA2_main_config.txt.template"
cat ${STATIC_CFG}/EDA2/EDA2_main_config.txt.template | envsubst > ${STATIC_CFG}/EDA2/EDA2_main_config.txt
for NE in $(ls ${STATIC_CFG}/EDA2/EDA2_objects/network_element*/*template); do
  echo "Updating ${NE}"
  cat ${NE} | envsubst > ${NE//.template/}
done
for NOTIF_CONF in $(ls adapted_dir/*HSS*Notif*); do
  echo "Renaming: ${NOTIF_CONF}"
  mv ${NOTIF_CONF} ${NOTIF_CONF///adapted*day1//eda2_helper}
done
echo -e "\n================================="
echo "Renaming App Counters files"
for APP_COUNT_CONF in $(ls adapted_dir/*Application_Counters*); do
  echo "Renaming: ${APP_COUNT_CONF}"
  mv ${APP_COUNT_CONF} ${APP_COUNT_CONF///adapted*day1//AppCounters}
done

echo -e "\n================================="
rm ${VALUES_FILE}.tmp

if [ ${ERROR_DETECTED} == "true" ];then
  echo -e "Some files were not fully adapted! Installation should not proceed!\n\n"
  exit 1
fi
