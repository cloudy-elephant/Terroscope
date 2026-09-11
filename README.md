# Terrorscape: The Laboratory

这是依据项目内已确认规格建立的 Godot 4 规则工程。当前已完成 Milestone 0～3 的无画面规则沙盒：实验室地图、权威状态、幸存者与屠夫回合、技能牌与升级、遭遇战、伤害响应、完整终局，以及双方信息投影。

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

## 运行 Milestone 2 验收

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path . --script res://tests/run_milestone_2.gd
```

测试覆盖杀手标准行动、噪声推理与搜索、屠夫技能、封锁供应、手牌与弃牌、抽空升级、动态技能时机和双方视图脱敏。搜索命中后直接进入完整遭遇流程。

## 运行 Milestone 3 验收

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path . --script res://tests/run_milestone_3.gd
```

测试覆盖防守者与防御物品、确定性骰子、陷阱、伤势与治疗、古代护符响应、屠夫等级 5 预伤害、击退弃牌与升级续算、逃离和终局冻结，并包含一局完全依靠玩家命令从开局推进到杀手获胜的场景。
