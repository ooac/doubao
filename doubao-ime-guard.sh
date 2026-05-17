#!/bin/zsh
set -euo pipefail

LABEL="com.local.doubao-ime-guard"
DOUBAO_SOURCE_ID="com.bytedance.inputmethod.doubaoime.pinyin"
ABC_SOURCE_ID="com.apple.keylayout.ABC"
SCRIPT_PATH="${0:A}"
SUPPORT_DIR="${HOME}/Library/Application Support/DoubaoInputGuard"
HELPER="${SUPPORT_DIR}/ime-helper"
INSTALLED_SCRIPT="${SUPPORT_DIR}/doubao-ime-guard.sh"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${LABEL}.plist"
BACKUP_PLIST="${SUPPORT_DIR}/com.apple.HIToolbox.plist.before-doubao-guard"
LOG_FILE="${SUPPORT_DIR}/guard.log"
LOG_MAX_LINES=1000
LOG_TRIM_INTERVAL_SECONDS=3600
DOUBAO_REACTIVATE_INTERVAL_SECONDS=15
USER_GUI="gui/$(id -u)"

usage() {
  cat <<'EOF'
用法：
  ./doubao-ime-guard.sh             打开终端交互管理界面
  ./doubao-ime-guard.sh menu        打开终端交互管理界面
  ./doubao-ime-guard.sh install      安装并启动：持续强制切回豆包输入法
  ./doubao-ime-guard.sh once         只立即切换一次到豆包输入法
  ./doubao-ime-guard.sh repair       立即修复豆包显示正常但功能不可用
  ./doubao-ime-guard.sh start        启动已安装的强制守护
  ./doubao-ime-guard.sh stop         停止强制守护，但不恢复输入法设置
  ./doubao-ime-guard.sh pause [分钟] 临时暂停守护，到时间后自动恢复
  ./doubao-ime-guard.sh status       查看当前状态
  ./doubao-ime-guard.sh restore      停止强制守护，并恢复到系统默认 ABC
  ./doubao-ime-guard.sh guard        前台守护模式，通常由 launchd 调用

说明：
  install 会先备份当前 com.apple.HIToolbox 偏好。
  pause 用于临时使用其他输入法，例如 pause 10 表示暂停 10 分钟。
  repair 会短暂切到 ABC 再切回豆包，用于修复豆包输入法状态失活。
  restore 会停止守护进程、移除 LaunchAgent、恢复备份，并切回系统 ABC。
EOF
}

log() {
  mkdir -p "${SUPPORT_DIR}"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "${LOG_FILE}"
  trim_log
}

trim_log() {
  [[ -f "${LOG_FILE}" ]] || return 0

  local line_count
  line_count="$(wc -l < "${LOG_FILE}" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "${line_count}" ]] || return 0

  if (( line_count > LOG_MAX_LINES )); then
    local tmp_file="${LOG_FILE}.trim.$$"
    tail -n "${LOG_MAX_LINES}" "${LOG_FILE}" > "${tmp_file}" && mv "${tmp_file}" "${LOG_FILE}"
    rm -f "${tmp_file}" 2>/dev/null || true
  fi
}

ensure_helper() {
  mkdir -p "${SUPPORT_DIR}"

  if [[ -x "${HELPER}" ]]; then
    return 0
  fi

  if ! command -v clang >/dev/null 2>&1; then
    echo "错误：未找到 clang，无法编译 macOS 输入法切换助手。"
    echo "请先安装 Apple Command Line Tools：xcode-select --install"
    exit 1
  fi

  local src="${SUPPORT_DIR}/ime-helper.m"
  cat > "${src}" <<'OBJC'
#import <Carbon/Carbon.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>
#import <string.h>

static int copy_cf_string(CFTypeRef value, char *buffer, size_t size) {
  if (!value || size == 0) {
    if (size > 0) buffer[0] = '\0';
    return 0;
  }
  return CFStringGetCString((CFStringRef)value, buffer, size, kCFStringEncodingUTF8);
}

static void print_cf_string(CFTypeRef value) {
  char buffer[2048] = "";
  if (copy_cf_string(value, buffer, sizeof(buffer))) {
    printf("%s", buffer);
  } else {
    printf("-");
  }
}

static int print_current(void) {
  TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
  if (!source) return 1;
  print_cf_string(TISGetInputSourceProperty(source, kTISPropertyInputSourceID));
  printf("\n");
  CFRelease(source);
  return 0;
}

static int list_sources(void) {
  CFArrayRef sources = TISCreateInputSourceList(NULL, false);
  if (!sources) return 1;

  CFIndex count = CFArrayGetCount(sources);
  for (CFIndex i = 0; i < count; i++) {
    TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);
    print_cf_string(TISGetInputSourceProperty(source, kTISPropertyInputSourceID));
    printf("\t");
    print_cf_string(TISGetInputSourceProperty(source, kTISPropertyLocalizedName));
    printf("\t");
    print_cf_string(TISGetInputSourceProperty(source, kTISPropertyBundleID));
    printf("\t");
    print_cf_string(TISGetInputSourceProperty(source, kTISPropertyInputModeID));
    printf("\n");
  }

  CFRelease(sources);
  return 0;
}

static int select_source(const char *target) {
  CFArrayRef sources = TISCreateInputSourceList(NULL, false);
  if (!sources) return 1;

  CFIndex count = CFArrayGetCount(sources);
  for (CFIndex i = 0; i < count; i++) {
    TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);

    char source_id[2048] = "";
    char bundle_id[2048] = "";
    char mode_id[2048] = "";
    copy_cf_string(TISGetInputSourceProperty(source, kTISPropertyInputSourceID), source_id, sizeof(source_id));
    copy_cf_string(TISGetInputSourceProperty(source, kTISPropertyBundleID), bundle_id, sizeof(bundle_id));
    copy_cf_string(TISGetInputSourceProperty(source, kTISPropertyInputModeID), mode_id, sizeof(mode_id));

    if (strcmp(source_id, target) == 0 || strcmp(bundle_id, target) == 0 || strcmp(mode_id, target) == 0) {
      OSStatus status = TISSelectInputSource(source);
      CFRelease(sources);
      return status == noErr ? 0 : (int)status;
    }
  }

  CFRelease(sources);
  return 2;
}

int main(int argc, char **argv) {
  if (argc < 2) return 64;

  if (strcmp(argv[1], "current") == 0) return print_current();
  if (strcmp(argv[1], "list") == 0) return list_sources();
  if (strcmp(argv[1], "select") == 0 && argc >= 3) return select_source(argv[2]);

  return 64;
}
OBJC

  clang -framework Carbon -framework Foundation "${src}" -o "${HELPER}"
  chmod 755 "${HELPER}"
}

assert_doubao_available() {
  ensure_helper
  if ! "${HELPER}" list | awk -F '\t' -v id="${DOUBAO_SOURCE_ID}" '$1 == id { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "错误：没有在系统输入源中找到豆包输入法：${DOUBAO_SOURCE_ID}"
    echo "请先在系统设置中启用豆包输入法，然后再运行 install。"
    exit 1
  fi
}

current_source() {
  ensure_helper
  "${HELPER}" current 2>/dev/null || true
}

select_source() {
  local source_id="$1"
  ensure_helper
  "${HELPER}" select "${source_id}"
}

select_doubao() {
  assert_doubao_available
  select_source "${DOUBAO_SOURCE_ID}"
}

reactivate_doubao() {
  assert_doubao_available
  select_source "${DOUBAO_SOURCE_ID}"
}

repair_doubao() {
  assert_doubao_available
  select_source "${ABC_SOURCE_ID}" >/dev/null 2>&1 || true
  sleep 0.2
  select_source "${DOUBAO_SOURCE_ID}"
  log "已执行豆包输入法强制修复：ABC -> 豆包"
}

agent_running() {
  launchctl print "${USER_GUI}/${LABEL}" >/dev/null 2>&1
}

press_enter() {
  echo
  printf "按回车键返回菜单..."
  read -r _ || true
}

wait_main_menu_shortcut() {
  local action=""
  echo
  printf "快捷键：m 返回主菜单，q 退出："
  read -r action || return 1
  action="$(normalize_menu_choice "${action}")"
  case "${action:l}" in
    q|quit|exit) return 1 ;;
    *) return 0 ;;
  esac
}

return_to_menu() {
  echo
  echo "操作完成，正在返回菜单..."
  sleep 1
}

confirm_action() {
  local prompt="$1"
  local answer
  printf "%s [y/N] " "${prompt}"
  read -r answer
  [[ "${answer:l}" == "y" || "${answer:l}" == "yes" ]]
}

clear_screen() {
  if command -v tput >/dev/null 2>&1; then
    tput clear || true
  else
    printf '\033c'
  fi
}

backup_preferences() {
  mkdir -p "${SUPPORT_DIR}"
  local src="${HOME}/Library/Preferences/com.apple.HIToolbox.plist"
  if [[ -f "${src}" && ! -f "${BACKUP_PLIST}" ]]; then
    cp "${src}" "${BACKUP_PLIST}"
    log "已备份输入法偏好：${BACKUP_PLIST}"
  fi
}

write_launch_agent() {
  mkdir -p "${HOME}/Library/LaunchAgents" "${SUPPORT_DIR}"
  cat > "${LAUNCH_AGENT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALLED_SCRIPT}</string>
    <string>guard</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
EOF
}

unload_agent() {
  launchctl bootout "${USER_GUI}" "${LAUNCH_AGENT}" >/dev/null 2>&1 || true
  launchctl unload "${LAUNCH_AGENT}" >/dev/null 2>&1 || true
}

load_agent() {
  unload_agent
  launchctl bootstrap "${USER_GUI}" "${LAUNCH_AGENT}" >/dev/null 2>&1 || launchctl load "${LAUNCH_AGENT}"
  launchctl kickstart -k "${USER_GUI}/${LABEL}" >/dev/null 2>&1 || true
}

install_guard() {
  assert_doubao_available
  backup_preferences
  mkdir -p "${SUPPORT_DIR}"
  cp "${SCRIPT_PATH}" "${INSTALLED_SCRIPT}"
  chmod 755 "${INSTALLED_SCRIPT}"
  write_launch_agent
  load_agent
  select_doubao
  log "已安装并启动豆包输入法强制守护"
  echo "已安装：系统会持续强制切回豆包输入法。"
  echo "恢复默认：${INSTALLED_SCRIPT} restore"
}

start_guard() {
  if [[ ! -f "${LAUNCH_AGENT}" ]]; then
    echo "错误：尚未安装 LaunchAgent，请先运行 install。"
    exit 1
  fi
  load_agent
  select_doubao
  echo "已启动豆包输入法强制守护。"
}

stop_guard() {
  unload_agent
  echo "已停止豆包输入法强制守护。"
}

schedule_resume() {
  local minutes="$1"
  local seconds=$(( minutes * 60 ))
  local resume_script="${INSTALLED_SCRIPT}"
  [[ -x "${resume_script}" ]] || resume_script="${SCRIPT_PATH}"

  (
    sleep "${seconds}"
    "${resume_script}" start >/dev/null 2>&1 || true
    "${resume_script}" once >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 &!

  log "已安排 ${minutes} 分钟后自动恢复豆包输入法强制守护"
}

pause_guard() {
  local minutes="${1:-10}"

  if ! [[ "${minutes}" == <-> ]]; then
    echo "错误：暂停分钟数必须是数字，例如：pause 10"
    exit 64
  fi

  unload_agent

  if (( minutes > 0 )); then
    schedule_resume "${minutes}"
    echo "已临时暂停守护 ${minutes} 分钟。现在可以自由切换到其他输入法。"
    echo "到时间后会自动恢复豆包输入法强制守护。"
  else
    echo "已暂停守护。需要恢复时请选择“启动守护”或执行 start。"
  fi
}

restore_system() {
  unload_agent

  if [[ -f "${BACKUP_PLIST}" ]]; then
    defaults import com.apple.HIToolbox "${BACKUP_PLIST}" >/dev/null 2>&1 || true
    killall cfprefsd >/dev/null 2>&1 || true
    log "已恢复安装前输入法偏好备份"
  fi

  ensure_helper
  select_source "${ABC_SOURCE_ID}" >/dev/null 2>&1 || true
  rm -f "${LAUNCH_AGENT}"
  log "已恢复系统默认 ABC，并移除 LaunchAgent"
  echo "已恢复：强制守护已停止，LaunchAgent 已移除，当前输入法已切回系统 ABC。"
}

status_guard() {
  ensure_helper
  local current
  current="$(current_source)"

  echo "当前输入源：${current:-未知}"
  if [[ "${current}" == "${DOUBAO_SOURCE_ID}" ]]; then
    echo "豆包状态：当前已启用"
  else
    echo "豆包状态：当前未启用"
  fi

  if launchctl print "${USER_GUI}/${LABEL}" >/dev/null 2>&1; then
    echo "守护状态：运行中"
  else
    echo "守护状态：未运行"
  fi

  [[ -f "${LAUNCH_AGENT}" ]] && echo "LaunchAgent：${LAUNCH_AGENT}" || echo "LaunchAgent：未安装"
  [[ -f "${BACKUP_PLIST}" ]] && echo "偏好备份：${BACKUP_PLIST}" || echo "偏好备份：无"
  echo "日志文件：${LOG_FILE}"
  echo "日志策略：自动保留最近 ${LOG_MAX_LINES} 行，每小时检查一次"
  echo "豆包重激活：每 ${DOUBAO_REACTIVATE_INTERVAL_SECONDS} 秒自动刷新一次"
}

dashboard_status() {
  ensure_helper
  local current agent_state agent_file backup_state
  current="$(current_source)"

  if agent_running; then
    agent_state="运行中"
  else
    agent_state="未运行"
  fi

  [[ -f "${LAUNCH_AGENT}" ]] && agent_file="已安装" || agent_file="未安装"
  [[ -f "${BACKUP_PLIST}" ]] && backup_state="存在" || backup_state="无"

  echo "豆包输入法强制守护 - 终端管理界面"
  echo "===================================="
  echo "当前输入源：${current:-未知}"
  echo "目标输入源：${DOUBAO_SOURCE_ID}"
  echo "守护状态：${agent_state}"
  echo "LaunchAgent：${agent_file}"
  echo "偏好备份：${backup_state}"
  echo "日志文件：${LOG_FILE}"
  echo "日志策略：保留最近 ${LOG_MAX_LINES} 行"
  echo "豆包重激活：每 ${DOUBAO_REACTIVATE_INTERVAL_SECONDS} 秒"
  echo
}

list_input_sources() {
  ensure_helper
  echo "输入源 ID\t名称\tBundle ID\tInput Mode"
  echo "------------------------------------------------------------"
  "${HELPER}" list
}

show_logs() {
  mkdir -p "${SUPPORT_DIR}"
  if [[ -f "${LOG_FILE}" ]]; then
    tail -80 "${LOG_FILE}"
  else
    echo "暂无日志。"
  fi
}

normalize_menu_choice() {
  local raw="$1"
  raw="${raw#choice=}"
  raw="${raw#选项=}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw#\'}"
  raw="${raw%\'}"
  raw="${raw#\"}"
  raw="${raw%\"}"
  echo "${raw}"
}

prompt_pause_minutes() {
  local minutes
  printf "暂停多少分钟后自动恢复？直接回车默认 10 分钟，输入 0 表示只暂停不自动恢复："
  read -r minutes
  minutes="$(normalize_menu_choice "${minutes}")"
  [[ -n "${minutes}" ]] || minutes="10"
  pause_guard "${minutes}"
}

menu_loop() {
  local menu_choice=""
  while true; do
    clear_screen
    dashboard_status
    cat <<'EOF'
请选择操作：
  1) 安装并启动强制豆包输入法
  2) 立即切换一次到豆包输入法
  3) 修复豆包显示正常但功能不可用
  4) 启动守护
  5) 停止守护
  6) 临时暂停守护（允许使用其他输入法）
  7) 查看详细状态
  8) 查看最近日志
  9) 查看系统输入源列表
  10) 恢复默认系统设置（停止守护并切回 ABC）
  m) 返回/刷新主菜单
  r) 立即修复豆包不可用
  q) 退出
EOF
    echo
    menu_choice=""
    printf "输入选项（1-10/r/m/q，直接回车刷新）："
    read -r menu_choice || return 0
    menu_choice="$(normalize_menu_choice "${menu_choice}")"
    echo

    case "${menu_choice}" in
      "")
        continue
        ;;
      m|M|menu|main)
        continue
        ;;
      1)
        install_guard
        return_to_menu
        ;;
      2)
        select_doubao
        echo "已切换到豆包输入法。"
        return_to_menu
        ;;
      3)
        repair_doubao
        echo "已修复：已短暂切到 ABC 并重新切回豆包。"
        return_to_menu
        ;;
      4)
        start_guard
        return_to_menu
        ;;
      5)
        stop_guard
        return_to_menu
        ;;
      6)
        prompt_pause_minutes
        return_to_menu
        ;;
      7)
        status_guard
        wait_main_menu_shortcut || return 0
        ;;
      8)
        show_logs
        wait_main_menu_shortcut || return 0
        ;;
      9)
        list_input_sources
        wait_main_menu_shortcut || return 0
        ;;
      10)
        if confirm_action "确认恢复默认系统设置吗？这会停止强制守护并切回 ABC。"; then
          restore_system
        else
          echo "已取消恢复。"
        fi
        press_enter
        ;;
      r|R|repair)
        repair_doubao
        echo "已修复：已短暂切到 ABC 并重新切回豆包。"
        return_to_menu
        ;;
      q|Q|quit|exit)
        echo "已退出。"
        return 0
        ;;
      *)
        echo "无效选项：${menu_choice:-空}"
        wait_main_menu_shortcut || return 0
        ;;
    esac
  done
}

guard_loop() {
  assert_doubao_available
  log "守护循环启动"
  local now_epoch
  now_epoch="$(date '+%s')"
  local next_log_trim_epoch=$(( now_epoch + LOG_TRIM_INTERVAL_SECONDS ))
  local next_reactivate_epoch=$(( now_epoch + DOUBAO_REACTIVATE_INTERVAL_SECONDS ))
  while true; do
    local current
    current="$(current_source)"
    now_epoch="$(date '+%s')"

    if [[ "${current}" != "${DOUBAO_SOURCE_ID}" ]]; then
      select_doubao >/dev/null 2>&1 || log "切换豆包输入法失败"
      log "检测到输入源 ${current:-未知}，已切回豆包输入法"
      next_reactivate_epoch=$(( now_epoch + DOUBAO_REACTIVATE_INTERVAL_SECONDS ))
    elif (( now_epoch >= next_reactivate_epoch )); then
      reactivate_doubao >/dev/null 2>&1 || log "重新激活豆包输入法失败"
      next_reactivate_epoch=$(( now_epoch + DOUBAO_REACTIVATE_INTERVAL_SECONDS ))
    fi

    if (( now_epoch >= next_log_trim_epoch )); then
      trim_log
      next_log_trim_epoch=$(( now_epoch + LOG_TRIM_INTERVAL_SECONDS ))
    fi

    sleep 1
  done
}

main() {
  local cmd="${1:-}"
  trim_log
  case "${cmd}" in
    install) install_guard ;;
    once) select_doubao; echo "已切换到豆包输入法。" ;;
    repair) repair_doubao; echo "已修复：已短暂切到 ABC 并重新切回豆包。" ;;
    start) start_guard ;;
    stop) stop_guard ;;
    pause) pause_guard "${2:-10}" ;;
    status) status_guard ;;
    restore) restore_system ;;
    guard) guard_loop ;;
    menu|"") menu_loop ;;
    -h|--help|help) usage ;;
    *)
      echo "未知命令：${cmd}"
      usage
      exit 64
      ;;
  esac
}

main "$@"
