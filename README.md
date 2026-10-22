# SquidGesture

系统级手势插件（rootless / Dopamine 已验证）。v1.4.0 修复**右下角上划应用面板**。

## 手势列表

| 手势 | 动作 |
|------|------|
| **右下角上划** | **打开应用面板（可自行增删应用）** |
| 左边缘右滑 | 返回（弹出导航栈） |
| 右边缘左滑 | 多任务切换器 |
| 左上角双击 | 锁屏 |
| 右上角双击 | 截屏 |
| 三指上滑 | Home（回主屏） |
| 三指下滑 | 多任务切换器 |

所有手势触发时振动反馈。

## 应用面板（v1.4.0 修复）

- 从**屏幕右下角**（默认 130×210pt 的角框内）向上滑动，弹出毛玻璃面板。
- 面板是 4 列图标网格，底栏最后一个是 **＋**：
  - 点 ＋ → 进入应用选择器，列出全部已装应用（可搜索），点一下即加入面板。
  - 点「编辑」→ 每个图标左上角出现红色 **−**，点它移除。
- 下滑面板 / 点空白处 / 点 ✕ 关闭；点图标立即关闭面板并启动对应应用。
- 选中的应用保存在 `PanelApps` 数组里，重启 SpringBoard 后保留。

### 为什么面板跑在 SpringBoard 里

沙盒 App 无法可靠写 `/var/mobile/Library/Preferences`，也无法枚举其它 App 的 bundle、
读取它们的图标或调用 `LSApplicationWorkspace` 启动。所以：

- **App 进程**：只负责识别手势 → 振动 → 发 Darwin 通知 `...action.panel`
- **SpringBoard 进程**：持有 `windowLevel = 5000` 的透明窗口 + 面板 VC，
  负责应用目录、图标缓存、配置读写和启动

窗口不抢 key window（只有进入搜索时才取），所以面板打开时前台 App 的键盘焦点不会被打断。

## 设置

配置文件：`/var/mobile/Library/Preferences/com.minis.squidgesture.plist`

| Key | 类型 | 默认 | 说明 |
|-----|------|------|------|
| Enabled | bool | YES | 总开关 |
| CornerSize | real | 80 | 角落检测尺寸（右下角框会按 1.4×/1.9× 放大） |
| PanelEnabled | bool | YES | 右下角上划面板开关 |
| PanelVibrate | bool | YES | 面板弹出振动 |
| PanelApps | array | 6 个系统 App | 面板中的应用 bundle id |
| LeftEdgeBack | bool | YES | 左边缘返回 |
| RightEdgeSwitcher | bool | YES | 右边缘多任务 |
| CornerTapLock | bool | YES | 左上角锁屏 |
| CornerTapScreenshot | bool | YES | 右上角截屏 |
| ThreeFingerHome | bool | YES | 三指上滑 Home |
| ThreeFingerSwitcher | bool | YES | 三指下滑多任务 |
| VibrationFeedback | bool | YES | 振动反馈 |
| DebugLog | bool | YES | 调试日志（v1.4.0 起默认开） |

改完发通知刷新（不用重启）：

```bash
notify_post com.minis.squidgesture.prefs-changed
```

诊断日志（需 `DebugLog` = true，仅 SpringBoard 写）：
`/var/mobile/Library/Preferences/com.minis.squidgesture.log`

```bash
# 不碰屏幕，直接从终端开面板（判断"手势没识别"还是"面板没渲染"）
notify_post com.minis.squidgesture.test.panel

tail -50 /var/mobile/Library/Preferences/com.minis.squidgesture.log
```

日志默认就开（`DebugLog` = YES）。

日志会记录手势坐标/速度、面板窗口创建、应用目录条数、启动结果、配置保存结果。

## 安装

```bash
dpkg -i com.minis.squidgesture_1.4.0_iphoneos-arm64.deb
# 或 sileo / zebra 直接装
```

安装后会自动重启 SpringBoard。

## 排查

| 现象 | 检查 |
|------|------|
| 手势无反应 | 确认 dylib 是 arm64+arm64e，且日志文件有内容 |
| 右下角上划无面板 | 先 `notify_post com.minis.squidgesture.test.panel`：面板出现=手势问题，不出现=渲染问题 |
| 日志里没有 `panelPan` | 手势没进插件：确认 filter 含 `com.apple.springboard`，且 dylib 是 arm64e |
| 日志有 `panelPan` 无 `panel notify` | 手势判定没通过（看 `up=` / `vert=` 值） |
| 面板空白 | 目录加载失败，看日志；或重启 SpringBoard 再试 |
| 点图标不启动 | 日志里应有 `launch xxx -> ok/no` |

## 编译

GitHub Actions macOS runner（Apple clang 才能给 arm64e 生成 PAC stubs）：

```bash
gh workflow run build.yml --repo qq6688000/squidgesture
```
