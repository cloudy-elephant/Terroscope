# Terrorscape: The Laboratory

这是依据项目内已确认规格建立的 Godot 4 规则工程。当前已完成 Milestone 0 与 Milestone 1 的无画面规则沙盒：实验室地图图结构、权威状态、确定性随机数、阶段推进、幸存者核心行动、牌库与背包、钥匙和无线电目标，以及噪声生命周期。

## 运行沙盒

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path .
```

沙盒会用固定种子运行一轮最小命令序列，输出文本事件和最终状态摘要，然后退出。

## 运行 Milestone 0 验收

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path . --script res://tests/run_milestone_0.gd
```

退出码 `0` 表示全部通过。测试覆盖地图与开局数据、相同种子和命令的确定性、完整一轮阶段推进、非法命令原子拒绝、过期序号拒绝与命令幂等。

## 运行 Milestone 1 验收

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path . --script res://tests/run_milestone_1.gd
```

测试覆盖三名幸存者的自由行动顺序、全部主要行动、搜索与发现、背包容量、钥匙与无线电胜利、牌库耗尽、噪声公开和跨轮清理。
