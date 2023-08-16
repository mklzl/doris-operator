#!/bin/bash

HOST_TYPE=${HOST_TYPE:-"IP"}
FE_QUERY_PORT=${FE_QUERY_PORT:-9030}
HEARTBEAT_PORT=9050
MY_SELF=
MY_IP=`hostname -i`
MY_HOSTNAME=`hostname -f`
DORIS_ROOT=${DORIS_ROOT:-"/opt/doris"}
#  If Doris has its own CN profile, it will be split in the future
DORIS_CN_HOME=${DORIS_ROOT}/be
CN_CONFIG=${DORIS_CN_HOME}/conf/be.conf
BE_ROLE=${BE_ROLE:-"computation"}
# time out
PROBE_TIMEOUT=60
# sleep interval
PROBE_INTERVAL=2
REGISTERED=false


log_stderr()
{
  echo "[`date`] $@" >&2
}

show_backends(){
  local svc=$1
  timeout 15 mysql --connect-timeout 2 -h $svc -P $FE_QUERY_PORT -u root --skip-column-names --batch -e "SHOW BACKENDS;"
}

function show_frontends(){
  local svc=$1
  timeout 15 mysql --connect-timeout 2 -h $svc -P $FE_QUERY_PORT -u root --skip-column-names --batch -e "SHOW FRONTENDS;"
}

collect_env_info()
{
# get heartbeat port
    local heartbeat_port=`get_configuration_from_config "heartbeat_service_port"`
    if [[ "x$heartbeat_port" != "x" ]]; then
       HEARTBEAT_PORT=$heartbeat_port
    fi

    if [[ "x$HOST_TYPE" == "xIP" ]]; then
      MY_SELF=$MY_IP
    else
      MY_SELF=$MY_HOSTNAME
    fi
}

add_self(){
  # check self status and add self
    local svc=$1
    while true
    do
      be_list=`show_backends $fe_host`
      if echo "$be_list" | grep -q -w "$MY_SELF" &>/dev/null ; then
        log_stderr "Check myself ($MY_SELF:$HEARTBEAT_PORT) exist in FE start be ..."
        update_config
        break;
      fi
      fe_list=`show_frontends $svc`
      local leader=`echo "fe_list" | grep '\<FOLLOWER\>' | awk -F '\t' '{if ($8=="true") print $2}'`
      if [[ "x$leader" != "x" ]]; then
        log_stderr "Check myself ($MY_SELF:$HEARTBEAT_PORT) not exist in FE and FE have leader register myself ..."
        timeout 15 mysql --connect-timeout 2 -h $fe_host -P $FE_QUERY_PORT -u root --skip-column-names --batch -e "ALTER SYSTEM ADD BACKEND \"$MY_SELF:$HEARTBEAT_PORT\";"
        let "expire=start+timeout"
        now=`date +%s`
        if [[ $expire -le $now ]] ; then
            log_stderr "Time out, abort!"
            return 0
        fi
      else
        log_stderr "not have leader wait fe cluster elect a master, sleep 2s ..."
        sleep $PROBE_INTERVAL
      fi
    done
}



update_config(){
  local be_role=`get_configuration_from_config "be_node_role"`
  if [[ "x$be_role" != "x" ]]; then
         BE_ROLE=$be_role
  fi
  log_stderr "add configuration to be.conf"
  echo "be_node_role=${BE_ROLE}" >>$CN_CONFIG
}

# get conf value by conf key
get_configuration_from_config(){
   local confkey=$1
   local confvalue=`grep "\<$confkey\>" $CN_CONFIG | grep -v '^\s*#' | sed 's|^\s*'$confkey'\s*=\s*\(.*\)\s*$|\1|g'`
   echo "$confvalue"
}




#add_config_to_cn_conf(){
#    doris_note "Start add cn config to be.conf!"
#    echo "be_node_role = computation" >>$CN_CONFIG
#}


back_conf_from_configmap(){

  if [[ "x$CONFIGMAP_MOUNT_PATH" == "x" ]]; then
      log_stderr "Env var $CONFIGMAP_MOUNT_PATH is empty, skip it!"
      return 0
  fi
  if ! test -d $$CONFIGMAP_MOUNT_PATH ; then
      log_stderr "$CONFIGMAP_MOUNT_PATH not exists or not a dir,ignore ..."
      return 0
  fi
  # /opt/doris/be/conf
  local confdir=$DORIS_CN_HOME/conf
  # shellcheck disable=SC2045
  # /etc/doris
  for configfile in `ls $CONFIGMAP_MOUNT_PATH`
  do
      log_stderr "config file $configfile ..."
      local conf=$confdir/$configfile
      # if /opt/doris/conf has configfile , do back up
      if test -e $conf ; then
          # back up
          mv -f $conf ${conf}.bak
      fi
      # ln /etc/doris/xx.conf to   /opt/doris/be/conf/xx.conf
      ln -sfT $CONFIGMAP_MOUNT_PATH/$configfile $conf
  done
}

function check_and_register()
{
  $addrs=$1
  addrArr=({$addrs//,/ })
  for addr in ${addrArr[@]}
  do
    add_self $addr
  done

  if [[ $REGISTERED ]]; then
    return 0
  else
    exit 1
  fi
}

fe_host=$1

if [[ "x$fe_host" == "x" ]]; then
  echo "ENV: FE_HOST  is empty ,will exit!"
  echo "Example $0 <fe_host> "
  exit 1
fi



back_conf_from_configmap
collect_env_info
check_and_register $fe_host

log_stderr "Start cn!"
update_config
$DORIS_CN_HOME/bin/start_be.sh




