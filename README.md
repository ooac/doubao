# 豆包输入法强制守护

这是一个 macOS 终端管理脚本，用于把当前用户的默认输入法持续切回豆包输入法，并提供可恢复到系统默认 ABC 的管理入口。

## 功能

- 开机登录后自动启动守护进程。
- 当前输入法不是豆包时，自动切回豆包输入法。
- 提供终端交互菜单，可重复执行安装、启动、停止、暂停、查看状态、查看日志、恢复默认设置。
- 省资源守护：默认每 30 秒低频检查一次，只在异常时修复。
- 提供一键修复：短暂切到 ABC 再切回豆包，并做短期验证。
- 支持临时暂停守护，方便短时间使用其他输入法。
- 日志自动裁剪，只保留最近 1000 行。

## 使用

如果是给另一台 Mac 使用，推荐直接双击：

```text
install.command
```

它会自动给脚本加执行权限、安装守护进程，并打开终端管理菜单。

打开终端交互管理界面：

```bash
./doubao-ime-guard.sh
```

安装并启动：

```bash
./doubao-ime-guard.sh install
```

查看状态：

```bash
./doubao-ime-guard.sh status
```

修复豆包显示正常但功能不可用：

```bash
./doubao-ime-guard.sh repair
```

临时暂停 10 分钟：

```bash
./doubao-ime-guard.sh pause 10
```

恢复系统默认设置：

```bash
./doubao-ime-guard.sh restore
```

## 文件位置

安装后脚本会复制到：

```text
~/Library/Application Support/DoubaoInputGuard/doubao-ime-guard.sh
```

LaunchAgent 位置：

```text
~/Library/LaunchAgents/com.local.doubao-ime-guard.plist
```
