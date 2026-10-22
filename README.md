# SquidGesture

系统级手势控制插件，类似鱿鱼手势。通过边缘滑动、角落点击、多指手势实现快速操作。

## 手势列表

| 手势 | 默认动作 |
|------|----------|
| 左边缘右滑 | 返回（弹出导航栈） |
| 右边缘左滑 | 多任务切换器 |
| 左上角双击 | 锁屏 |
| 右上角双击 | 截屏 |
| 三指上滑 | Home（回主屏） |
| 三指下滑 | 多任务切换器 |

所有手势触发时振动反馈。

## 设置

配置文件：`/var/mobile/Library/Preferences/com.minis.squidgesture.plist`

| Key | 类型 | 默认 | 说明 |
|-----|------|------|------|
| Enabled | bool | YES | 总开关 |
| CornerSize | real | 80 | 角落检测区域大小（像素） |
| LeftEdgeBack | bool | YES | 左边缘返回 |
| RightEdgeSwitcher | bool | YES | 右边缘多任务 |
| CornerTapLock | bool | YES | 左上角锁屏 |
| CornerTapScreenshot | bool | YES | 右上角截屏 |
| ThreeFingerHome | bool | YES | 三指上滑Home |
| ThreeFingerSwitcher | bool | YES | 三指下滑多任务 |
| VibrationFeedback | bool | YES | 振动反馈 |

修改后发送 Darwin 通知刷新：
```bash
killall -usr1 SquidGesture  # 或
notify_post com.minis.squidgesture.prefs-changed
```

## 安装

Dopamine rootless 环境，将 deb 拷入设备后：
```bash
dpkg -i com.minis.squidgesture_1.0.0_iphoneos-arm64.deb
```
安装后会自动注销（respring）。

## 架构（v1.1.0 两段式）

- **手势检测**（所有 UIKit App 进程）：识别手势 → 振动反馈 → 发 Darwin 通知 / 进程内动作
- **动作执行**（SpringBoard 进程）：监听 Darwin 通知 → 直接调用 SpringBoard 私有 API

v1.0 的教训：iOS 16 的 SpringBoardServices 只剩 `SBSSpringBoardServerPort` 一个导出符号，`...Home/LockDevice/ShowAppSwitcher` 已被苹果移除（dlsym 返回 NULL，动作静默失败）。且沙盒 App 查不到 SpringBoard mach 服务。两段式彻底避开这两个坑。

## 手势动作实现

| 动作 | 实现 |
|------|------|
| Home | 双保险：App 内 `UIApplication suspend`（进程内私有 API）+ Darwin 通知 → SpringBoard `SBSSuspendFrontmostApplication`（tbd 确认存在） |
| 锁屏 | 通知 → SpringBoard `SBLockScreenManager lockUIFromSource:0 withOptions:nil`（dump 确认） |
| 多任务 | 通知 → SpringBoard `SBUIController handleHomeButtonDoublePressDown`（系统双击 Home 路径）；fallback `SBMainSwitcherControllerCoordinator toggleMainSwitcherWithSource:animated:` |
| 截图 | App 内 UIKit 渲染；相册权限已授权→直接存，无权限→弹分享菜单（避免静默失败） |
| 返回 | App 内 `popViewControllerAnimated:` |
