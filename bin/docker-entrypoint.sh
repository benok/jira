#!/bin/bash
#
# A helper script for ENTRYPOINT.
#
# If first CMD argument is 'jira', then the script will start jira
# If CMD argument is overriden and not 'jira', then the user wants to run
# his own process.

set -o errexit

[[ ${DEBUG} == true ]] && set -x

#
# This function purges osgi plugins when env is true
#
function purgeJiraPlugins() {
  if [ "$JIRA_PURGE_PLUGINS_ONSTART" = 'true' ]; then
    bash /usr/local/share/atlassian/purgeplugins.sh
  fi
}

#
# This function will replace variables inside the script setenv.sh
#
function updateSetEnv() {
  local propertyname=$1
  local propertyvalue=$2
  sed -i -e "/${propertyname}=/c${propertyname}=\"${propertyvalue}\"" ${JIRA_INSTALL}/bin/setenv.sh
}

function setAllSetEnvs() {
  local env_vars=$(env | awk -F= '/^SETENV/ {print $1}')
  for env_variable in $env_vars
  do
    local propertyName=${env_variable#"SETENV_"}
    updateSetEnv "$propertyName" "${!env_variable}"
  done
}

#
# This function will wait for a specific host and port for as long as the timeout is specified.
#
function waitForDB() {
  local waitHost=${DOCKER_WAIT_HOST:-}
  local waitPort=${DOCKER_WAIT_PORT:-}
  local waitTimeout=${DOCKER_WAIT_TIMEOUT:-60}
  local waitIntervalTime=${DOCKER_WAIT_INTERVAL:-5}
  if [ -n "${waitHost}" ] && [ -n "${waitPort}" ]; then
    dockerize -timeout "${waitTimeout}"s -wait-retry-interval "${waitIntervalTime}"s -wait tcp://"${waitHost}":"${waitPort}"
  fi
}

SERAPH_CONFIG_FILE="/opt/jira/atlassian-jira/WEB-INF/classes/seraph-config.xml"
CROWD_PROPERTIES_FILE="/opt/jira/atlassian-jira/WEB-INF/classes/crowd.properties"

function updateProperties() {
  local propertyfile=$1
  local propertyname=$2
  local propertyvalue=$3
  sed -i "/${propertyname}/d" ${propertyfile}
  echo "${propertyname}=${propertyvalue}" >> ${propertyfile}
}

#
# Enable crowd sso authenticator java class in image config file
#
function enableCrowdSSO() {
  xmlstarlet ed -P -S -L --delete "//authenticator" $SERAPH_CONFIG_FILE
  xmlstarlet ed -P -S -L -s "//security-config" --type elem -n authenticator -i "//authenticator[not(@class)]" -t attr -n class -v "com.atlassian.jira.security.login.SSOSeraphAuthenticator" $SERAPH_CONFIG_FILE
  if [ -f "${CROWD_PROPERTIES_FILE}" ]; then
    rm -f ${CROWD_PROPERTIES_FILE}
  fi
  touch ${CROWD_PROPERTIES_FILE}
  if [ -n "${CROWD_SSO_APPLICATION_NAME}" ]; then
    updateProperties ${CROWD_PROPERTIES_FILE} "application.name" "${CROWD_SSO_APPLICATION_NAME}"
  fi
  if [ -n "${CROWD_SSO_APPLICATION_PASSWORD}" ]; then
    [[ ${CROWD_SSO_APPLICATION_PASSWORD} =~ ^/run/secrets/.* ]] && [ -r ${CROWD_SSO_APPLICATION_PASSWORD} ] && CROWD_SSO_APPLICATION_PASSWORD=$(cat $CROWD_SSO_APPLICATION_PASSWORD)
    updateProperties ${CROWD_PROPERTIES_FILE} "application.password" "${CROWD_SSO_APPLICATION_PASSWORD}"
    unset CROWD_SSO_APPLICATION_PASSWORD
  fi
  if [ -n "${CROWD_SSO_BASE_URL}" ]; then
    updateProperties ${CROWD_PROPERTIES_FILE} "crowd.base.url" "${CROWD_SSO_BASE_URL}"
    updateProperties ${CROWD_PROPERTIES_FILE} "crowd.server.url" "${CROWD_SSO_BASE_URL}services/"
  fi
  if [ -n "${CROWD_SSO_SESSION_VALIDATION}" ]; then
    updateProperties ${CROWD_PROPERTIES_FILE} "session.validationinterval" ${CROWD_SSO_SESSION_VALIDATION}
  else
    updateProperties ${CROWD_PROPERTIES_FILE} "session.validationinterval" "2"
  fi
  echo 'application.login.url
session.isauthenticated=session.isauthenticated
session.tokenkey=session.tokenkey
session.lastvalidation=session.lastvalidation
  ' >> ${CROWD_PROPERTIES_FILE}
}

#
# Enable jira authenticator java class in image config file
#
function enableJiraAuth() {
  xmlstarlet ed -P -S -L --delete "//authenticator" $SERAPH_CONFIG_FILE
  xmlstarlet ed -P -S -L -s "//security-config" --type elem -n authenticator -i "//authenticator[not(@class)]" -t attr -n class -v "com.atlassian.jira.security.login.JiraSeraphAuthenticator" $SERAPH_CONFIG_FILE
}

#
# Will either enable, disable Crowd SSO support or ignore current setting at all
#
function controlCrowdSSO() {
  local setting=$1
  case "$setting" in
    true)
      enableCrowdSSO
    ;;
    false)
      enableJiraAuth
    ;;
    *)
      echo "Crowd SSO settings ingored because of setting ${setting}"
    esac
}

if [ -n "${JIRA_DELAYED_START}" ]; then
  sleep "${JIRA_DELAYED_START}"
fi

if [ -n "${JIRA_ENV_FILE}" ]; then
  source "${JIRA_ENV_FILE}"
fi

if [ -n "${JIRA_PROXY_NAME}" ]; then
  xmlstarlet ed -P -S -L --insert "//Connector[not(@proxyName)]" --type attr -n proxyName --value "${JIRA_PROXY_NAME}" ${JIRA_INSTALL}/conf/server.xml
fi

if [ -n "${JIRA_PROXY_PORT}" ]; then
  xmlstarlet ed -P -S -L --insert "//Connector[not(@proxyPort)]" --type attr -n proxyPort --value "${JIRA_PROXY_PORT}" ${JIRA_INSTALL}/conf/server.xml
fi

if [ -n "${JIRA_PROXY_SCHEME}" ]; then
  xmlstarlet ed -P -S -L --insert "//Connector[not(@scheme)]" --type attr -n scheme --value "${JIRA_PROXY_SCHEME}" ${JIRA_INSTALL}/conf/server.xml
fi

jira_logfile="${JIRA_HOME}/log"

if [ -n "${JIRA_LOGFILE_LOCATION}" ]; then
  jira_logfile=${JIRA_LOGFILE_LOCATION}
fi

if [ -n "${JIRA_CROWD_SSO}" ]; then
  controlCrowdSSO "${JIRA_CROWD_SSO}"
fi

if [ ! -d "${jira_logfile}" ]; then
  mkdir -p "${jira_logfile}"
fi

TARGET_PROPERTY=1catalina.org.apache.juli.AsyncFileHandler.directory
sed -i "/${TARGET_PROPERTY}/d" ${JIRA_INSTALL}/conf/logging.properties
echo "${TARGET_PROPERTY} = ${jira_logfile}" >> ${JIRA_INSTALL}/conf/logging.properties

TARGET_PROPERTY=2localhost.org.apache.juli.AsyncFileHandler.directory
sed -i "/${TARGET_PROPERTY}/d" ${JIRA_INSTALL}/conf/logging.properties
echo "${TARGET_PROPERTY} = ${jira_logfile}" >> ${JIRA_INSTALL}/conf/logging.properties

TARGET_PROPERTY=3manager.org.apache.juli.AsyncFileHandler.directory
sed -i "/${TARGET_PROPERTY}/d" ${JIRA_INSTALL}/conf/logging.properties
echo "${TARGET_PROPERTY} = ${jira_logfile}" >> ${JIRA_INSTALL}/conf/logging.properties

TARGET_PROPERTY=4host-manager.org.apache.juli.AsyncFileHandler.directory
sed -i "/${TARGET_PROPERTY}/d" ${JIRA_INSTALL}/conf/logging.properties
echo "${TARGET_PROPERTY} = ${jira_logfile}" >> ${JIRA_INSTALL}/conf/logging.properties

setAllSetEnvs


# if there are any certificates that should be imported to the JVM Keystore,
# import them.  Note that KEYSTORE is defined in the Dockerfile
# (taken from https://github.com/teamatldocker/crowd/blob/master/imagescripts/docker-entrypoint.sh)
if [ -d ${JIRA_HOME}/certs ]; then
  for c in ${JIRA_HOME}/certs/* ; do
    echo Found certificate $c, importing to JVM keystore
    c_base=$(basename $c)
    keytool -trustcacerts -keystore $KEYSTORE -storepass changeit -noprompt -importcert -alias $c_base -file $c || :
  done
fi

if [ "$1" = 'jira' ] || [ "${1:0:1}" = '-' ]; then
  waitForDB
  purgeJiraPlugins
  /bin/bash "${JIRA_SCRIPTS}"/launch.sh
  if [ -n "${JIRA_PROXY_PATH}" ]; then
    xmlstarlet ed -P -S -L --update "//Context/@path" --value "${JIRA_PROXY_PATH}" ${JIRA_INSTALL}/conf/server.xml
  fi
  exec ${JIRA_INSTALL}/bin/start-jira.sh -fg "$@"
else
  exec "$@"
fi
