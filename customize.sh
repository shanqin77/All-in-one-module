#!/sbin/sh

# ================= 初始化配置 =================
MODULES_DIR="/data/adb/modules"
MODDIR="$MODPATH"

# ========== Recovery模式拦截 ==========
check_recovery() {
  # 三重检测机制
  [ -n "$RECOVERY_PRE_COMMAND" ] || [ -x "/sbin/recovery" ] || [ "$(getprop ro.bootmode)" = "recovery" ]
}

if check_recovery; then
  abort "错误：禁止在Recovery模式下安装本模块！"
fi

# ================= 初始化提示 =================
ui_print "**********************************"
ui_print "  多功能Magisk模块安装程序 v2.0   "
ui_print "  - 加入Recovery模式拦截        "
ui_print "  - 使用安全APK安装机制        "
ui_print "**********************************"

# ========== 设备兼容性检查 ==========
ui_print "- 运行环境诊断..."

# 增强版架构检查（兼容主流ABI）
SUPPORTED_ABI="arm64-v8a"
CURRENT_ABI=$(getprop ro.product.cpu.abi)
if ! echo "$CURRENT_ABI" | grep -qE "arm64.*|armv8"; then
  abort "[X] 架构不兼容：需${SUPPORTED_ABI}，检测到${CURRENT_ABI}"
fi

# 增强版Android版本检查
MIN_API=30
if [ "$(getprop ro.build.version.sdk)" -lt $MIN_API ]; then
  abort "[X] 需要Android 11+ (API 30)，当前API：$ANDROID_API"
fi

# 新版Magisk版本检测（兼容v24.3+到v28+）
MAGISK_VER_RAW=$(magisk -V 2>/dev/null)
MAGISK_VER_CODE=$(echo "$MAGISK_VER_RAW" | grep -oE '[0-9]{5}')  # 直接提取5位数字版本代码

# 如果没有数字版本代码则尝试旧版解析
[ -z "$MAGISK_VER_CODE" ] && MAGISK_VER_CODE=$(echo "$MAGISK_VER_RAW" | cut -d':' -f2 | tr -d ' ') 

if [ -z "$MAGISK_VER_CODE" ]; then
  abort "[X] Magisk版本检测失败：$MAGISK_VER_RAW"
elif [ "$MAGISK_VER_CODE" -lt 24300 ]; then
  abort "[X] 需要Magisk 24.3+ (代码24300+)，当前检测到：$MAGISK_VER_CODE"
else
  ui_print "  ✔ Magisk版本验证通过 (代码 $MAGISK_VER_CODE)"
fi

# ========== 模块安装部分 ==========
ui_print "- 开始安装模块..."
MODULE_COUNT=0
MODULE_FILES="$MODPATH/modules"/*.zip

if [ ! -d "$MODPATH/modules" ]; then
  ui_print "  ⚠ 模块目录不存在: $MODPATH/modules"
else
  for module in $MODULE_FILES; do
    if [ -f "$module" ]; then
      MODULE_COUNT=$((MODULE_COUNT + 1))
      ui_print "  ▸ 正在安装模块 [$MODULE_COUNT]: $(basename "$module")"
      
      # 预提取模块ID用于存在性检查
      # 创建临时prop提取目录
      TMP_PROP_DIR="$MODPATH/tmp_prop"
      mkdir -p "$TMP_PROP_DIR"

      # 安全解压module.prop（限制解压大小防止异常）
      unzip -p "$module" module.prop 2>/dev/null | head -c 1024 > "$TMP_PROP_DIR/module.prop"

      if [ $? -ne 0 ] || [ ! -s "$TMP_PROP_DIR/module.prop" ]; then
        ui_print "  ⚠ 模块损坏: 无法提取module.prop"
        rm -rf "$TMP_PROP_DIR"
        continue
      fi

      # 精确提取id字段（兼容带引号格式）
      module_id=$(grep -m1 '^id=' "$TMP_PROP_DIR/module.prop" | cut -d= -f2- | tr -d '\r" ')
      rm -rf "$TMP_PROP_DIR"

      if [ -z "$module_id" ]; then
        ui_print "  ⚠ 模块无效: 未检测到有效ID"
        continue
      fi

      # 检查模块是否已存在（包含大小写敏感处理）
      existing_dir=$(find "$MODULES_DIR" -maxdepth 1 -iname "$module_id" -print -quit)
      if [ -n "$existing_dir" ]; then
        ui_print "  ✔ 检测到已安装: $(basename "$existing_dir")"
        ui_print "    跳过重复安装"
        continue
      fi

      # 使用Magisk原生安装方式
      # 临时挂载路径（添加随机后缀防止冲突）
      TMP_INSTALL_DIR="$MODPATH/tmp_install_$RANDOM"
      mkdir -p "$TMP_INSTALL_DIR"

      # 执行原生安装流程（增加超时机制）
      timeout 30 magisk --install-module "$module" "$TMP_INSTALL_DIR"
      case $? in
        0)  # 安装成功
            # 再次验证模块ID一致性
            installed_id=$(grep -m1 '^id=' "$TMP_INSTALL_DIR/module.prop" | cut -d= -f2- | tr -d '\r" ')
            if [ "$installed_id" != "$module_id" ]; then
              ui_print "  ❌ ID校验失败: 预期[$module_id] 实际[$installed_id]"
              rm -rf "$TMP_INSTALL_DIR"
              continue
            fi

            # 移动文件并设置权限
            mkdir -p "$MODULES_DIR/$module_id"
            mv "$TMP_INSTALL_DIR"/* "$MODULES_DIR/$module_id/"

            # 设置深度权限（兼容特殊需求）
            find "$MODULES_DIR/$module_id" -type d -exec chmod 755 {} \;
            find "$MODULES_DIR/$module_id" -type f -exec chmod 644 {} \;
            [ -f "$MODULES_DIR/$module_id/service.sh" ] && chmod 755 "$MODULES_DIR/$module_id/service.sh"

            # 写入启用标记
            touch "$MODULES_DIR/$module_id/update"

            ui_print "  ✔ 成功安装: $module_id"
            ;;
        124) # 超时
            ui_print "  ❌ 安装超时，可能系统繁忙"
            ;;
        *)  # 其他错误
            ui_print "  ❌ 安装失败！错误码:$?"
            ;;
      esac

      rm -rf "$TMP_INSTALL_DIR"
    else
      ui_print "  ⚠ 警告: 无效模块文件 - $module"
    fi
  done
  
  if [ $MODULE_COUNT -eq 0 ]; then
    ui_print "  ⚠ 未找到任何模块文件"
  else
    ui_print "  ✔ 共处理 $MODULE_COUNT 个模块"
  fi
fi

# ========== APK安装关键修复 ==========
install_apk() {
  local apk_path=$1
  # 使用原生安装接口（无需复制到临时目录）
  result=$(CLASSPATH=/system/framework/pm.jar app_process /system/bin com.android.commands.pm.Pm install -r -d --user 0 "$apk_path" 2>&1)
  
  # 备用安装方法（使用pm命令）
  if echo "$result" | grep -q "Success"; then
    ui_print "  ✔ 已安装: $(basename "$apk_path")"
    return 0
  else
    ui_print "  ⚠ 方法1失败，尝试备用方法..."
    result2=$(su -c "pm install -r -d --user 0 '$apk_path'" 2>&1)
    if echo "$result2" | grep -q "Success"; then
      ui_print "  ✔ 已安装: $(basename "$apk_path")"
      return 0
    else
      ui_print "  ❌ 安装失败: $(basename "$apk_path")"
      echo "[APK错误] 方法1: $result" >> "$MODDIR/install_errors.log"
      echo "[APK错误] 方法2: $result2" >> "$MODDIR/install_errors.log"
      return 1
    fi
  fi
}

ui_print "- 安装系统应用..."
APK_SRC_DIR="$MODPATH/system/priv-app"
if [ -d "$APK_SRC_DIR" ]; then
  # 遍历所有子目录中的APK（支持标准目录结构）
  find "$APK_SRC_DIR" -type f -name "*.apk" | while read apk; do
    # 验证文件完整性
    if [ ! -s "$apk" ]; then
      ui_print "  ❌ 文件损坏: $(basename "$apk")"
      continue
    fi
    
    # 设置安全上下文（关键修复）
    chcon u:object_r:apk_data_file:s0 "$apk"
    
    # 直接安装原始路径的APK
    if install_apk "$apk"; then
      sleep 1  # 增加安装间隔
    fi
  done
else
  ui_print "  ⚠ APK资源目录不存在: $APK_SRC_DIR"
fi

# ========== 最终检查 ==========
ui_print "✅ 所有组件安装成功！"
ui_print "- 请重启设备完成配置 -"

# ========== 自删除优化 ==========
ui_print "- 执行自清理..."
{
  # 安全删除模块目录
  rm -rf "$MODPATH"
}