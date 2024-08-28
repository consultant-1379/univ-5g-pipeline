#!/bin/bash

CONFIG_FILE="./configurations/EDA2/EDA2_main_config.txt"
source $CONFIG_FILE

if ! [ -z $1 ] && [ $1 == "randomClient" ]; then
  DEFAULT_CREDS=
  DEFAULT_CREDS_REPLAY=
else
  DEFAULT_CREDS=',"client_id":"12341234-1234-1234-1234-123412341234","credentials":{"client_secret":"12341234-1234-1234-1234-123412341234"}'
  DEFAULT_CREDS_REPLAY=',"client_id":"abcdabcd-abcd-abcd-abcd-abcdabcdabcd","credentials":{"client_secret":"abcdabcd-abcd-abcd-abcd-abcdabcdabcd"}'
fi

echo -e "Creating logs file!\n"
mkdir $LOGS_FOLDER
LOG_FILE="$LOGS_FOLDER/logs_$(date '+%y-%m-%dT%H:%M:%S').txt"

echo "Logs will be stored in "$LOG_FILE

touch $LOG_FILE

curl ${EDA2_URI} --connect-timeout 5
if [ $? -ne 0 ]; then
  echo "EDA2 unreachable! Exit..."
  exit 1
fi

############################################# Adding Admin user ######################################################

echo -e "Onboarding admin user (${ADMIN_USER_NAME}/${ADMIN_USER_PASS})\n" > $LOG_FILE
RESPONSE=$(curl -sS -k "https://${EDA2_URI}/am-rest/v1/onboard" -H 'Content-Type: application/json' \
-d '{
  "users": [{
    "email": "'${ADMIN_USER_NAME}'",
    "credentials": {
      "password": "'${ADMIN_USER_PASS}'"
    }
  }],
  "oauth2_clients": [],
  "service_accounts": []
}' -i)
echo "${RESPONSE}" | grep -q "only have" >> $LOG_FILE
if [ $? -eq 0 ]; then
  echo "Admin user already created. Nothing to do!" >> $LOG_FILE
else
  echo "${RESPONSE}" |grep HTTP |grep -v Continue >> $LOG_FILE
fi
echo -e "\nConnecting with admin user and getting access token...\n" >> $LOG_FILE
RESPONSE=$(curl -sS -k "https://${EDA2_URI}/eda-v2/" -i)
OAUTH_PATH="/am-rest/v1/oauth2-clients"
CLIENT_SECRET_PATH=".credentials.client_secret"
echo "${RESPONSE}" |grep -q oauth2_clients
if [ $? -ne 0 ]; then
  #Fallback to old API
  RESPONSE=$(curl -sS -k "https://${EDA2_URI}/eda/" -i)
  OAUTH_PATH="/oauth/v1/clients"
  CLIENT_SECRET_PATH=".client_secret"
fi
COOKIE=$(echo "${RESPONSE}" | grep "set-cookie:.*JSESSIONID" | awk '{print $2}' | tr -d ';')
CLIENT_ID=$(echo "${RESPONSE}" | tr '%' "\n" | tr '&' "\n" | grep client_id | cut -d= -f2 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
STATE=$(echo "${RESPONSE}" | tr '%' "\n" | tr '&' "\n" | grep state | cut -d= -f2 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
LOCATION=$(echo "${RESPONSE}" | grep location | awk '{print $2}' |sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' | \
  sed 's/scope=/scope=scopes.ericsson.com%2Factivation%2Froles.write%20/')
LOGIN_COOKIE=$(curl -sS -k "https://${EDA2_URI}/oauth/login" \
-H 'Content-Type: application/json; charset=UTF-8' \
-d '{"username":"'${ADMIN_USER_NAME}'","password":"'${ADMIN_USER_PASS}'"}' \
-i | grep EAUID | awk '{print $2}' | tr -d ';')
LOCATION_1=$(curl -sS "${LOCATION}" -i -k | grep location | awk '{print $2}' |sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
LOCATION_2=$(curl -k -i -sS ${LOCATION_1} -b ${LOGIN_COOKIE} | grep location | awk '{print $2}' |sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
LOCATION_3=$(curl -k -i -sS ${LOCATION_2} | grep location | awk '{print $2}' |sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
ADMIN_USER_TOKEN=$(curl -k -i -sS ${LOCATION_3} -b ${COOKIE} | grep TOKEN | cut -d";" -f1 | cut -d= -f2)
echo -e "\nToken: ${ADMIN_USER_TOKEN}\n" >> $LOG_FILE
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${CAI3G_TOKEN_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

echo -e "Token: " $TOKEN "\n" >> $LOG_FILE
echo -e "CAI3G config " $CAI3G_TOKEN_FILE "\n" >> $LOG_FILE
############################################# Adding roles without royce ##########################################
RO_CONF_LIST=($(ls -rtl $ROLES_CONFIG_FOLDER | grep -E "\.json$" | awk '{print $9}'))

if ((${#RO_CONF_LIST[@]} > 0)); then
echo "################################################################################################################" >> $LOG_FILE
echo "##################################################### Roles ####################################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE

for ((i=0;i<${#RO_CONF_LIST[@]};i++));
do
    CONF=$(echo "$ROLES_CONFIG_FOLDER/${RO_CONF_LIST[$i]}")
    ELEMENT=$(cat ${CONF} | jq .id | cut -d "\"" -f 2)

    echo -e "Getting role " ${ELEMENT} " and its config file " $CONF >> $LOG_FILE

    SA_RESULT=$(curl -skX GET -H "Content-Type: application/json" "https://${EDA2_URI}/accessrules/v1/roles/${ELEMENT// /%20}" \
                -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" | jq .id | grep "$ELEMENT" | wc -l)

    if (($SA_RESULT==0)); then
        echo -e "\n$ELEMENT not found, creating it!\n" >> $LOG_FILE
        curl -skX POST -H "Content-Type: application/json" https://${EDA2_URI}/accessrules/v1/roles \
             -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" -d@$CONF -i
    else
        echo -e "\n$ELEMENT already exists! Updating it now!\n" >> $LOG_FILE
	curl -skX PUT -H "Content-Type: application/json" "https://${EDA2_URI}/accessrules/v1/roles/${ELEMENT// /%20}" \
             -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" -d@$CONF -i
    fi
done
fi
############################################# Adding service accounts ##########################################
SA_CONF_LIST=($(ls -rtl $SA_CONFIG_FOLDER | grep -E "\.json$" | awk '{print $9}'))

if ((${#SA_CONF_LIST[@]} > 0)); then
#echo -e "Refresh token\n"
#TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${CAI3G_TOKEN_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

echo -e "\n################################################################################################################" >> $LOG_FILE
echo "############################################### Service Accounts ###############################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
for ((i=0;i<${#SA_CONF_LIST[@]};i++));
do
    CONF=$(echo "$SA_CONFIG_FOLDER/${SA_CONF_LIST[$i]}")
    ELEMENT=$(cat ${CONF} | jq .email | cut -d "\"" -f 2)

    echo -e "Getting service account ${ELEMENT} and its config file " $CONF >> $LOG_FILE

    SA_RESULT=$(curl -skX GET -H "Content-Type: application/json" https://${EDA2_URI}/oauth/v1/authn/users/profile \
	                      -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" | jq ".[]|select(.email==\"$ELEMENT\")" | wc -l)

    #echo "curl -skX GET -H \"Content-Type: application/json\" https://${EDA2_URI}/oauth/v1/authn/users/profile -H \"Authorization: Bearer ${ADMIN_USER_TOKEN}\" | jq '.[]|select(.email==\"$ELEMENT\")' | wc -l"
    echo $SA_RESULT >> $LOG_FILE

    if (( $SA_RESULT == 0 )); then
        echo -e "\n$ELEMENT not found, creating it!\n" >> $LOG_FILE
	curl -skX POST -H "Content-Type: application/json" https://${EDA2_URI}/oauth/v1/authn/users/profile \
             -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" -d@$CONF -i

	curl -skX POST -H "Content-Type: application/json" https://${EDA2_URI}/oauth/v1/users/profile \
             -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" -d@$CONF -i
    else
        echo -e "\n$ELEMENT already exists!\n" >> $LOG_FILE
    fi
done
fi

############################################# Adding oAuth user ######################################################
echo -e "\n################################################################################################################" >> $LOG_FILE
echo -e "################################################ oAuth user ####################################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
echo "Creating Oauth client (${OAUTH_CLIENT})..."
touch client.info

echo -e "\nWARNNING!" >> $LOG_FILE
echo -e "Please check if ${OAUTH_CLIENT} is a Service account before using it for fetching EDA2 access token!" >> $LOG_FILE

EXISTING_CLIENT=$(curl -sS -k "https://${EDA2_URI}${OAUTH_PATH}" \
                       -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" | jq '.[] | select(.client_name=="'${OAUTH_CLIENT}'")' |wc -l)

#EXISTING_CLIENT=$(curl -siS -k "https://${EDA2_URI}${OAUTH_PATH}" -H "Content-Type: application/json" -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" > info.log)

FILE=$(grep -EH "\"user_name\".*:.*\"dummy\"" $SA_CONFIG_FOLDER/* | awk '{print $1}' | tr -d ':')

if [ -z $FILE ]; then
  echo -e "\nConfig file for ${OAUTH_CLIENT} not found, using default password!\n" >> $LOG_FILE
  OAUTH_PASS=${OAUTH_DEFAULT_PASS}
else
  echo -e "\nConfig file for ${OAUTH_CLIENT} found!\n" >> $LOG_FILE
  OAUTH_PASS=$(cat $FILE | jq .password | tr -d "\"")
fi

echo $EXISTING_CLIENT >> $LOG_FILE
if [ ${EXISTING_CLIENT} -eq 0 ]; then
  echo "Client info:" >> $LOG_FILE
  curl -sS -k "https://${EDA2_URI}${OAUTH_PATH}" \
  -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" \
  -H "Content-Type: application/json" -d'{"client_name":"'${OAUTH_CLIENT}'"'${DEFAULT_CREDS}'}' | jq . > client.info

  cat client.info >> $LOG_FILE
else
  echo "${OAUTH_CLIENT} already exists! Proceed with recreation" >> $LOG_FILE
  #get client
  CLIENT_ID_TMP=$(curl -sS -k "https://${EDA2_URI}${OAUTH_PATH}" -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" | jq '.[] | select(.client_name=="'${OAUTH_CLIENT}'")' | jq -r '.client_id')
  #delete client
  curl -X DELETE -sS -k "https://${EDA2_URI}${OAUTH_PATH}/${CLIENT_ID_TMP}" -H "Authorization: Bearer ${ADMIN_USER_TOKEN}"
  #recreate client
  echo "Client info:" >> $LOG_FILE
  curl -sS -k "https://${EDA2_URI}${OAUTH_PATH}" \
  -H "Authorization: Bearer ${ADMIN_USER_TOKEN}" \
  -H "Content-Type: application/json" -d'{"client_name":"'${OAUTH_CLIENT}'"'${DEFAULT_CREDS}'}' | jq . > client.info
fi
CLIENT_ID=$(cat client.info | jq -r '.client_id')
CLIENT_SECRET=$(cat client.info | jq -r ${CLIENT_SECRET_PATH})
if [ -z ${CLIENT_ID} ]; then
  echo "Client ID for ${OAUTH_CLIENT} OAuth client not found! It was probably created manually" >> $LOG_FILE
  echo -e "You have 2 options:\n  1) Remove ${OAUTH_CLIENT} through GUI\n  2) Enter client id/secret to client.info file, which is created in current dir" >> $LOG_FILE
  echo '{
  "client_id": "",
  "client_secret": ""
}' > client.info
  echo "Exiting with oAuth error!"
  exit
else
  echo "Client ID:     ${CLIENT_ID}" >> $LOG_FILE
  echo "Client secret: ${CLIENT_SECRET}" >> $LOG_FILE
  echo "Creating ${OAUTH_CLIENT} access file!" >> $LOG_FILE

  OAUTH_ACCESS_FILE=${OAUTH_CLIENT}_eda2_access_token
  touch $OAUTH_ACCESS_FILE

  cat > $OAUTH_ACCESS_FILE << EOF
client_id=${CLIENT_ID}&
client_secret=${CLIENT_SECRET}&
grant_type=password&
username=${OAUTH_CLIENT}&
password=${OAUTH_PASS}&
scope=$OAUTH_SCOPE
EOF
fi

  cat << EOF >> deployment.properties
CLIENT_ID=${CLIENT_ID}
CLIENT_SECRET=${CLIENT_SECRET}
EOF

echo "################################################################################################################" >> $LOG_FILE
echo -e "################################################ Admin domains #################################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE

############################################# Adding administration domains ##########################################
#for i in $(eval echo {1..${#ADMIN_DOMAINS[@]}});
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')
if [ -z $TOKEN ]; then
    curl -iX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure >> $LOG_FILE
    echo "Token was not created successfully..." >> $LOG_FILE
    echo "exiting" >> $LOG_FILE
    echo "Error while creating ${OAUTH_ACCESS_FILE} token! Exiting!"
    exit
else
    echo -e "\nToken: $TOKEN\n" >> $LOG_FILE
fi
AD_CONF_LIST=($(ls -rtl $AD_CONFIG_FOLDER | grep -E "\.json$" | awk '{print $9}'))

if ((${#AD_CONF_LIST[@]} > 0)) ; then
#for ((i=0;i<${#ADMIN_DOMAINS[@]};i++));
for ((i=0;i<${#AD_CONF_LIST[@]};i++));
do
    CONF=$(echo "$AD_CONFIG_FOLDER/${AD_CONF_LIST[$i]}")
    ELEMENT=$(cat ${CONF} | jq .name | cut -d "\"" -f 2)
    #ELEMENT=$(echo ${ADMIN_DOMAINS[$((i))]} | cut -d ',' -f 1)
    #CONF=$(echo ${ADMIN_DOMAINS[$((i))]} | cut -d ',' -f 2)

    echo -e "Getting domain " ${ELEMENT} " and its config file " $CONF >> $LOG_FILE

    echo -e "\n" >> $LOG_FILE
    echo "curl -sSkX GET -H \"Content-Type: application/json\" \"https://${EDA2_URI}/cm-rest/v1/admin-domains/${ELEMENT}\" -H \"Authorization: Bearer ${TOKEN}\" -i | grep -qE \"^HTTP.*404|^HTTP.*500\"" >> $LOG_FILE
    echo -e "\n" >> $LOG_FILE

    curl -sSkX GET -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/admin-domains/${ELEMENT}" \
         -H "Authorization: Bearer ${TOKEN}" -i #| grep -qE "^HTTP.*404|^HTTP.*500"

    if [ $? -eq 0 ]; then
        echo -e "Domain " ${ELEMENT} " doesn't exist, creating it now!" "\n" >> $LOG_FILE
        curl -sSkX POST -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/admin-domains" \
             -H "Authorization: Bearer ${TOKEN}" -i -d@$CONF

        if [ $? -eq 0 ]; then
            echo -e "\nElement created successfully!\n" >> $LOG_FILE
        else
            echo -e "\nError! Element not added!\n" >> $LOG_FILE
        fi
    else
        echo -e "Domain " ${ELEMENT} " already exists!" "\n" >> $LOG_FILE
    fi
done
fi

############################################# Adding root dn ###################################################
echo -e "\n################################################################################################################" >> $LOG_FILE
echo "#################################################### Root DN ###################################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE

echo -e "Refresh token\n" >> $LOG_FILE
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

FIND_DN=$(curl -skX GET -H "Content-TypeH application/json" "https://${EDA2_URI}/cm-rest/v1/activation-logic/resources/CUDB Subscriber Provisioning/properties" \
              -H "Authorization: Bearer ${TOKEN}" -i | grep "${ROOT_DN}" | wc -l)

if ((${FIND_DN} == 0)); then
  echo -e "\n$ROOT_DN\n" >> $LOG_FILE
  curl -skX POST -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/activation-logic/global-actions/root-dn" \
       -H "Authorization: Bearer ${TOKEN}" -i -d "{ \"value\": \"$ROOT_DN\" }"
else
  echo -e "\nRoot DN already configured\n" >> $LOG_FILE
fi

############################################# Changing routing preference #####################################
echo -e "\n################################################################################################################" >> $LOG_FILE
echo "############################################## Routing preference ##############################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE

echo -e "Refresh token\n" >> $LOG_FILE
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

echo -e "\n$ROOT_DN\n" >> $LOG_FILE
curl -skX POST -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/activation-logic/global-actions/routing-preference" \
     -H "Authorization: Bearer ${TOKEN}" -i -d "{ \"value\": \"UDR\" }"

############################################# Adding network elements ##########################################
NE_CONF_LIST=($(ls -rtl $NE_CONFIG_FOLDER | grep -E "\.json$" | awk '{print $9}'))

if ((${#NE_CONF_LIST[@]} > 0 )); then
echo -e "Refresh token\n" >> $LOG_FILE
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

echo "################################################################################################################" >> $LOG_FILE
echo "############################################### Network elements ###############################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
for ((i=0;i<${#NE_CONF_LIST[@]};i++));
do
    CONF=$(echo "$NE_CONFIG_FOLDER/${NE_CONF_LIST[$i]}")
    ELEMENT=$(cat ${CONF} | jq .name | cut -d "\"" -f 2)

    echo -e "Getting network element " ${ELEMENT} " and its config file " $CONF >> $LOG_FILE

    curl -sSkX GET -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/network-elements/${ELEMENT}" \
         -H "Authorization: Bearer ${TOKEN}" -i | grep -qE "^HTTP.*40.*|^HTTP.*50.*"

    if [ $? -eq 0 ]; then
        echo -e "Domain " ${ELEMENT} " doesn't exist, creating it now!" "\n" >> $LOG_FILE
        curl -sSkX POST -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/network-elements" \
             -H "Authorization: Bearer ${TOKEN}" -i -d@$CONF

	if [ $? -eq 0 ]; then
            echo -e "\nElement created successfully!\n" >> $LOG_FILE
        else
            echo -e "\nError! Element not added!\n" >> $LOG_FILE
        fi
    else
        echo -e "Domain " ${ELEMENT} " already exists!" "\n" >> $LOG_FILE
    fi
done
fi

############################################# Adding network element groups ##########################################
NEG_CONF_LIST=($(ls -rtl $NEG_CONFIG_FOLDER | grep -E "\.json$" | awk '{print $9}'))

if (( ${#NEG_CONF_LIST[@]} > 0 )); then
echo -e "Refresh token\n" >> $LOG_FILE
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

echo "################################################################################################################" >> $LOG_FILE
echo "######################################### Network element groups ###############################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
for ((i=0;i<${#NEG_CONF_LIST[@]};i++));
do
    CONF=$(echo "$NEG_CONFIG_FOLDER/${NEG_CONF_LIST[$i]}")
    ELEMENT=$(cat ${CONF} | jq .name | cut -d "\"" -f 2)

    echo -e "Getting network element group " ${ELEMENT} " and its config file " $CONF >> $LOG_FILE

    curl -sSkX GET -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/network-element-groups/${ELEMENT}" \
         -H "Authorization: Bearer ${TOKEN}" -i | grep -qE "^HTTP.*40.*|^HTTP.*50.*"

    if [ $? -eq 0 ]; then
        echo -e "Domain " ${ELEMENT} " doesn't exist, creating it now!" "\n" >> $LOG_FILE
        curl -sSkX POST -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/network-element-groups" \
             -H "Authorization: Bearer ${TOKEN}" -i -d@$CONF

	if [ $? -eq 0 ]; then
            echo -e "\nElement created successfully!\n" >> $LOG_FILE
        else
            echo -e "\nError! Element not added!\n" >> $LOG_FILE
        fi
    else
        echo -e "Domain " ${ELEMENT} " already exists!" "\n" >> $LOG_FILE
    fi
done
fi

############################################# Adding routing ##########################################
ROUTING_CONF_LIST=($(ls -rtl $ROUTINGS_CONFIG_FOLDER | grep -E "\.json$" | awk '{print $9}'))

if (( ${#ROUTING_CONF_LIST[@]} > 0 )); then
echo -e "Refresh token\n" >> $LOG_FILE
TOKEN=$(curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" -d @./${OAUTH_ACCESS_FILE} https://${EDA2_URI}/oauth/v1/token --insecure | jq -r '.access_token')

echo "################################################################################################################" >> $LOG_FILE
echo "#################################################### Routings ##################################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
for ((i=0;i<${#ROUTING_CONF_LIST[@]};i++));
do
    CONF=$(echo "$ROUTINGS_CONFIG_FOLDER/${ROUTING_CONF_LIST[$i]}")
    ELEMENT=$(cat ${CONF} | jq .networkElementType | cut -d "\"" -f 2)

    echo -e "Getting routing " ${ELEMENT} " and its config file " $CONF >> $LOG_FILE

    curl -sSkX GET -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/routings/${ELEMENT}" \
         -H "Authorization: Bearer ${TOKEN}" -i | grep -qE "^HTTP.*40.*|^HTTP.*50.*"

    if [ $? -eq 0 ]; then
        echo -e "Domain " ${ELEMENT} " doesn't exist, creating it now!" "\n" >> $LOG_FILE
        curl -sSkX POST -H "Content-Type: application/json" "https://${EDA2_URI}/cm-rest/v1/routings" \
             -H "Authorization: Bearer ${TOKEN}" -i -d@$CONF

	if [ $? -eq 0 ]; then
            echo -e "\nElement created successfully!\n" >> $LOG_FILE
        else
            echo -e "\nError! Element not added!\n" >> $LOG_FILE
        fi
    else
        echo -e "Domain " ${ELEMENT} " already exists!" "\n" >> $LOG_FILE
    fi
done
fi

#REPLAY AND APP COUNTERS CONFIGURATION (if script has cluster info available, to fetch CCDM OAM)
#App counters part is not directly related to EDA2, but this was most convenient place to add this logic
if [ -f cluster_vars.tmp ]; then
  CLIENT_ID=$(curl -skX GET "https://${EDA2_URI}${OAUTH_PATH}" -H "Authorization: Bearer ${TOKEN}" \
    | jq '.[] | select(.client_name=="replayUser")' | jq -r '.client_id')
  if ! [ -z ${CLIENT_ID} ]; then
    curl -skX DELETE "https://${EDA2_URI}${OAUTH_PATH}/${CLIENT_ID}" -H "Authorization: Bearer ${TOKEN}"
  fi
  curl -sS -k "https://${EDA2_URI}${OAUTH_PATH}" -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" -d'{"client_name":"replayUser"'${DEFAULT_CREDS_REPLAY}'}' | jq . > replay-client

  USER="admin"
  PASS="EricSson@12-34"
  CLIENT_ID="$(cat replay-client | jq .client_id -r | base64)"
  CLIENT_SECRET="$(cat replay-client | jq ${CLIENT_SECRET_PATH} -r | base64)"
  sed -i -e "s/\(<uri>\).*\(<\/uri>\)/\1${EDA2_URI}\2/" \
         -e "s/\(<client-id>\).*\(<\/client-id>\)/\1${CLIENT_ID}\2/" \
         -e "s/\(<client-secret>\).*\(<\/client-secret>\)/\1${CLIENT_SECRET}\2/" configurations/replay_configuration.xml
  cat > /tmp/ssh-pass <<EOF
#!/bin/bash
echo "${PASS}"
EOF
  chmod 777 "/tmp/ssh-pass"
  export DISPLAY=:0
  export SSH_ASKPASS="/tmp/ssh-pass"
  for VIP in $(cat cluster_vars.tmp | grep ccdm_oam_VIP | cut -d= -f2); do
    echo -e "\n\nConnecting to ${VIP} and loading replay_configuration.xml"
    setsid ssh -o StrictHostKeyChecking=no ${USER}@${VIP} -p830 < configurations/replay_configuration.xml
    for APP_COUNT_CONF in $(ls adapted_dir/AppCounters*); do
      echo -e "\n\nLoading ${APP_COUNT_CONF}"
      setsid ssh -o StrictHostKeyChecking=no ${USER}@${VIP} -p830 < ${APP_COUNT_CONF}
    done
  done
fi

echo -e "\n################################################################################################################" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
echo -e "Script finished! Try your EDA2 now! :D" >> $LOG_FILE
echo "P. S." >> $LOG_FILE
echo "If something goes wrong, it's probably your config, not the script :P" >> $LOG_FILE
echo "################################################################################################################" >> $LOG_FILE
echo -e "################################################################################################################\n" >> $LOG_FILE
