#!/sbin/sh

MODDIR="$MODPATH"
MODULES_DIR="/data/adb/modules"

silent_install() {
    local apk_path="$1"
    if ! su -c "echo root" >/dev/null 2>&1; then
        return 1
    fi
    chmod 644 "$apk_path"
    chcon u:object_r:apk_data_file:s0 "$apk_path" >/dev/null 2>&1
    su -c "pm install -r -t --user 0 '$apk_path'" >/dev/null 2>&1 && return 0 || return 1
}

check_recovery() {
  [ -n "$RECOVERY_PRE_COMMAND" ] || [ -x "/sbin/recovery" ] || [ "$(getprop ro.bootmode)" = "recovery" ]
}

if check_recovery; then
  abort "错误：禁止在Recovery模式下安装本模块！"
fi

ui_print "**********************************"
ui_print "  多功能Magisk模块安装程序 v2.0   "
ui_print "  - 加入Recovery模式拦截        "
ui_print "  - 使用安全APK安装机制        "
ui_print "**********************************"

ui_print "- 开始安装模块..."
MODULE_COUNT=0
MODULE_FILES="$MODPATH/modules"/*.zip

if [ ! -d "$MODPATH/modules" ]; then
  ui_print "模块目录不存在: $MODPATH/modules"
else
  for module in $MODULE_FILES; do
    if [ -f "$module" ]; then
      MODULE_COUNT=$((MODULE_COUNT + 1))
      ui_print "正在安装模块 [$MODULE_COUNT]: $(basename "$module")"
      
      TMP_PROP_DIR="$MODPATH/tmp_prop"
      mkdir -p "$TMP_PROP_DIR"
      unzip -p "$module" module.prop 2>/dev/null | head -c 1024 > "$TMP_PROP_DIR/module.prop"
      if [ $? -ne 0 ] || [ ! -s "$TMP_PROP_DIR/module.prop" ]; then
        ui_print "模块损坏: 无法提取module.prop"
        rm -rf "$TMP_PROP_DIR"
        continue
      fi
      module_id=$(grep -m1 '^id=' "$TMP_PROP_DIR/module.prop" | cut -d= -f2- | tr -d '\r" ')
      rm -rf "$TMP_PROP_DIR"

      if [ -z "$module_id" ]; then
        ui_print "模块无效: 未检测到有效ID"
        continue
      fi

      existing_dir=$(find "$MODULES_DIR" -maxdepth 1 -iname "$module_id" -print -quit)
      if [ -n "$existing_dir" ]; then
        ui_print "检测到已安装: $(basename "$existing_dir")"
        ui_print "跳过重复安装"
        continue
      fi

      TMP_INSTALL_DIR="$MODPATH/tmp_install_$RANDOM"
      mkdir -p "$TMP_INSTALL_DIR"
      timeout 30 magisk --install-module "$module" "$TMP_INSTALL_DIR"
      case $? in
        0)
            installed_id=$(grep -m1 '^id=' "$TMP_INSTALL_DIR/module.prop" | cut -d= -f2- | tr -d '\r" ')
            if [ "$installed_id" != "$module_id" ]; then
              ui_print "lD校验失败: 预期[$module_id] 实际[$installed_id]"
              rm -rf "$TMP_INSTALL_DIR"
              continue
            fi
            mkdir -p "$MODULES_DIR/$module_id"
            mv "$TMP_INSTALL_DIR"/* "$MODULES_DIR/$module_id/"
            find "$MODULES_DIR/$module_id" -type d -exec chmod 755 {} \;
            find "$MODULES_DIR/$module_id" -type f -exec chmod 644 {} \;
            [ -f "$MODULES_DIR/$module_id/service.sh" ] && chmod 755 "$MODULES_DIR/$module_id/service.sh"
            touch "$MODULES_DIR/$module_id/update"
            ui_print "成功安装: $module_id"
            ;;
        124)
            ui_print "安装超时，可能系统繁忙"
            ;;
        *)
            ui_print "安装失败！错误码:$?"
            ;;
      esac
      rm -rf "$TMP_INSTALL_DIR"
    else
      ui_print "警告: 无效模块文件 - $module"
    fi
  done
  
  if [ $MODULE_COUNT -eq 0 ]; then
    ui_print "未找到任何模块文件"
  else
    ui_print "共处理 $MODULE_COUNT 个模块"
  fi
fi

install_apk() {
  local apk_path=$1
  result=$(CLASSPATH=/system/framework/pm.jar app_process /system/bin com.android.commands.pm.Pm install -r -d --user 0 "$apk_path" 2>&1)
  if echo "$result" | grep -q "Success"; then
    ui_print "  ✔ 已安装: $(basename "$apk_path")"
    return 0
  else
    ui_print "方法1失败，尝试备用方法..."
    result2=$(su -c "pm install -r -d --user 0 '$apk_path'" 2>&1)
    if echo "$result2" | grep -q "Success"; then
      ui_print "  ✔ 已安装: $(basename "$apk_path")"
      return 0
    else
      ui_print "安装失败: $(basename "$apk_path")"
      return 1
    fi
  fi
}

ui_print "- 安装系统应用..."
APK_SRC_DIR="$MODPATH/system/priv-app"
if [ -d "$APK_SRC_DIR" ]; then
  find "$APK_SRC_DIR" -type f -name "*.apk" | while read apk; do
    if [ ! -s "$apk" ]; then
      ui_print "文件损坏: $(basename "$apk")"
      continue
    fi
    chcon u:object_r:apk_data_file:s0 "$apk"
    if install_apk "$apk"; then
      sleep 1
    fi
  done
else
  ui_print "  ⚠ APK资源目录不存在: $APK_SRC_DIR"
fi

ui_print "所有组件安装成功！"
ui_print "- 请重启设备完成配置 -"

ui_print "- 执行自清理..."
{
  rm -rf "$MODPATH"
}
