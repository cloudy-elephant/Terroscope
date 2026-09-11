# Terrorscape: The Laboratory

这是依据项目内已确认规格建立的 Godot 4 规则工程。Milestone 0 只包含无画面规则沙盒：实验室地图图结构、权威状态、命令与事件、确定性随机数、阶段骨架和非法命令拒绝。

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
