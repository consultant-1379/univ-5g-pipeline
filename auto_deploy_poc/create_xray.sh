#!/bin/bash

DATE=$(date '+%d.%m.%Y')
PACKAGES_CSAR=$(echo $PACKAGES_VERSION | sed 's+,+\\n+g')
XRAY_ID=$(curl --header "Authorization: Bearer ${JIRA_TOKEN}" -L -k --request POST \
  --url 'https://eteamproject.internal.ericsson.com/rest/api/2/issue' \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data '{
    "fields": {
        "description": "List of used CSAR packages:\n\n'${PACKAGES_CSAR}'",
        "summary": "UNIV Solution Pipeline execution '${DATE}'",
        "project": {
             "id": "18349"
        },
        "issuetype": {
            "id": "14006"
        },
        "components": [
            {
             "id": "21872"
            }
        ]
    }
}' | jq .key -r)
echo "Created ticket ID: $XRAY_ID"
cat > xray.properties<<EOF
XRAY_ID=$XRAY_ID
EOF
curl --header "Authorization: Bearer ${JIRA_TOKEN}" -k -L --request POST \
  --url 'https://eteamproject.internal.ericsson.com/rest/api/2/issueLink' \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data '{
  "inwardIssue": {
    "key": "'${XRAY_ID}'"
  },
  "outwardIssue": {
    "key": "UDM5GP-76104"
  },
  "type": {
    "name": "Family"
  }
}'
