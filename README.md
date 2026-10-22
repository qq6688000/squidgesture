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

## 技术细节

- **注入目标**：所有 UIKit 应用（`com.apple.UIKit` filter）
- **arm64+arm64e fat**：兼容 arm64e 进程
- **PAC stubs**：macOS Apple clang 编译，arm64e PAC 兼容
- **SpringBoardServices**：dlsym 动态加载 `SBSSpringBoardServerPort` 系列函数
- **截图**：UIKit `UIGraphicsImageRenderer` + `UIImageWriteToSavedPhotosAlbum`
- **配置**：plist + Darwin 通知实时刷新
