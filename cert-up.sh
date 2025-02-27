#!/bin/bash

# path of this script
BASE_ROOT=$(cd "$(dirname "$0")";pwd)
# date time
DATE_TIME=`date +%Y%m%d%H%M%S`
# base crt path
CRT_BASE_PATH="/usr/syno/etc/certificate"
PKG_CRT_BASE_PATH="/usr/local/etc/certificate"
#CRT_BASE_PATH="/Users/carl/Downloads/certificate"
ACME_BIN_PATH=${BASE_ROOT}/acme.sh
TEMP_PATH=${BASE_ROOT}/temp
CRT_PATH_NAME=`cat ${CRT_BASE_PATH}/_archive/DEFAULT`
CRT_PATH=${CRT_BASE_PATH}/_archive/${CRT_PATH_NAME}
FIND_MAJORVERSION_FILE="/etc/VERSION"
FIND_MAJORVERSION_STR="majorversion=\"7\""

ACME_API="https://api.github.com/repos/acmesh-official/acme.sh/releases/latest"
ACME_REPO="https://github.com/acmesh-official/acme.sh/archive/refs/tags/"

function getOnlineVersion(){
  TAG_NAME=`curl -s "${ACME_API}" | jq -r .tag_name`
}

backupCrt () {
  echo '开始备份证书'
  BACKUP_PATH=${BASE_ROOT}/backup/${DATE_TIME}
  mkdir -p ${BACKUP_PATH}
  cp -r ${CRT_BASE_PATH} ${BACKUP_PATH}
  cp -r ${PKG_CRT_BASE_PATH} ${BACKUP_PATH}/package_cert
  echo ${BACKUP_PATH} > ${BASE_ROOT}/backup/latest
  echo '证书备份完成'
  return 0
}

installAcme () {
  echo '开始安装Acme.sh'
  mkdir -p "${TEMP_PATH}"
  cd "${TEMP_PATH}" || return 1
  source "${BASE_ROOT}/config"
  if [[ -z "${ACME_VERSION}" ]] ; then
    getOnlineVersion
    ACME_VERSION="${TAG_NAME}"
    echo "网络最新版本: ${ACME_VERSION}"
  else 
    echo "目标安装版本: ${ACME_VERSION}"
  fi
  local LOCAL_VER=""
  if [[ -f "${ACME_BIN_PATH}/acme.sh" ]]; then
    LOCAL_VER=$("${ACME_BIN_PATH}/acme.sh" --version 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//')
    LOCAL_VER_CLEAN="${LOCAL_VER//v/}"
    ACME_VER_CLEAN="${ACME_VERSION//v/}"
    if [[ -n "${LOCAL_VER}" ]]; then
      echo "本地已安装版本: ${LOCAL_VER}"
      if [[ "${LOCAL_VER_CLEAN}" == "${ACME_VER_CLEAN}" ]]; then
        echo "本地版本:${LOCAL_VER} 和 网络版本:${ACME_VERSION} 对比相同，跳过下载步骤。"
        rm -rf "${TEMP_PATH}"
        return 0
      else
        echo "版本对比不同: 本地=${LOCAL_VER}, 网络=${ACME_VERSION}，将进行更新安装。"
      fi
    else
      echo "[注意] 本地版本获取失败，将重新安装。"
    fi
  else
    echo "未找到现有安装，继续全新安装。"
  fi
  echo '下载 Acme.sh...'
  SRC_TAR_NAME=acme.sh.tar.gz
  if ! curl --max-time 30 -L -o "${SRC_TAR_NAME}" "${ACME_REPO}${ACME_VERSION}.tar.gz"; then
    echo "Acme.sh 下载失败"
    rm -rf "${TEMP_PATH}"
    return 1
  fi
  SRC_NAME=$(tar -tzf "${SRC_TAR_NAME}" | head -1 | cut -f1 -d"/")
  if ! tar zxvf "${SRC_TAR_NAME}"; then
    echo "文档提取失败"
    rm -rf "${TEMP_PATH}"
    return 1
  fi
  echo 'Acme.sh 安装中...'
  cd "${SRC_NAME}" || return 1
  if ! ./acme.sh --install --nocron --home "${ACME_BIN_PATH}"; then
    echo "安装失败"
    rm -rf "${TEMP_PATH}"
    return 1
  fi
  echo '安装完成'
  rm -rf "${TEMP_PATH}"
  return 0
}

generateCrt () {
  echo '开始申请证书'
  cd ${BASE_ROOT}
  source config
  echo '开始使用 acme.sh 更新默认证书'
  source ${ACME_BIN_PATH}/acme.sh.env
  ${ACME_BIN_PATH}/acme.sh --force --log --issue --dns ${DNS} --dnssleep ${DNS_SLEEP} -d "${DOMAIN}" -d "*.${DOMAIN}" -k ec-256
  ${ACME_BIN_PATH}/acme.sh --force --installcert -d "${DOMAIN}" -d "*.${DOMAIN}" --ecc\
    --certpath ${CRT_PATH}/cert.pem \
    --key-file ${CRT_PATH}/privkey.pem \
    --fullchain-file ${CRT_PATH}/fullchain.pem

  if [ -s "${CRT_PATH}/cert.pem" ]; then
    echo '证书申请完成'
    return 0
  else
    echo '[ERR] 证书申请失败'
    echo "开始回滚原始证书"
    revertCrt
    exit 1;
  fi
}

updateService () {
  echo '开始更新服务'
  echo '复制证书到目标位置'
  if [ `grep -c "$FIND_MAJORVERSION_STR" $FIND_MAJORVERSION_FILE` -ne '0' ];then
    echo "主要版本 = 7, 系统默认使用 python2"
    python2 ${BASE_ROOT}/crt_cp.py ${CRT_PATH_NAME}
  else
    echo "主要版本 < 7"
    /bin/python2 ${BASE_ROOT}/crt_cp.py ${CRT_PATH_NAME}
  fi
  echo '服务更新完成'
}

reloadWebService () {
  echo '开始重新加载网页服务'
  echo '加载新证书...'
  if [ `grep -c "$FIND_MAJORVERSION_STR" $FIND_MAJORVERSION_FILE` -ne '0' ];then
    echo "主要版本 = 7"
    synow3tool --gen-all && systemctl reload nginx
  else
    echo "主要版本 < 7"
    /usr/syno/etc/rc.sysv/nginx.sh reload
  fi
  if [ `grep -c "$FIND_MAJORVERSION_STR" $FIND_MAJORVERSION_FILE` -ne '0' ];then
    echo "主要版本 = 7, 不需要重新加载 apache"
  else
	echo '重新加载Apache DSM 6.x'
	synopkg stop pkg-apache22
	synopkg start pkg-apache22
	synopkg reload pkg-apache22
  fi  
  echo '网页服务重新加载完成'  
}

revertCrt () {
  echo '回滚证书'
  BACKUP_PATH=${BASE_ROOT}/backup/$1
  if [ -z "$1" ]; then
    BACKUP_PATH=`cat ${BASE_ROOT}/backup/latest`
  fi
  if [ ! -d "${BACKUP_PATH}" ]; then
    echo "[ERR] 找不到备份路径: ${BACKUP_PATH} ."
    return 1
  fi
  echo "${BACKUP_PATH}/certificate ${CRT_BASE_PATH}"
  cp -rf ${BACKUP_PATH}/certificate/* ${CRT_BASE_PATH}
  echo "${BACKUP_PATH}/package_cert ${PKG_CRT_BASE_PATH}"
  cp -rf ${BACKUP_PATH}/package_cert/* ${PKG_CRT_BASE_PATH}
  reloadWebService
  echo '证书回滚完成'
}

updateCrt () {
  echo '------ 开始更新证书 ------'
  backupCrt
  installAcme
  generateCrt
  updateService
  reloadWebService
  echo '------ 更新证书完成 ------'
}

case "$1" in
  update)
    updateCrt
    ;;

  revert)
    revertCrt $2
    ;;

    *)
  echo "用法: $0 {更新|回滚}"
  exit 1
esac
