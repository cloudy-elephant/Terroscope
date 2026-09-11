# Terrorscape: The Laboratory

这是依据项目内已确认规格建立的 Godot 4 游戏工程。Milestone 0～5 已全部完成：实验室地图、38 张确认牌、固定角色与屠夫、完整权威规则、双方脱敏界面、局域网双人联机，以及教学提示、反馈、统计和快速重开。

## 启动游戏

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --path .
```

两台电脑连接同一局域网后，一方创建房间并把界面显示的 IP 和端口告诉另一方；双方准备后由房主开始。单机检查可选择“本机双视图调试”。

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

## 运行 Milestone 4 验收

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path . --script res://tests/run_milestone_4.gd
```

测试覆盖大厅版本握手、双方准备、可靠有序 TCP 帧、真实回环连接、客户端只提交命令、主机权威结算、双方脱敏快照、断线暂停、本地双视图，以及选择后取消不改变权威状态。

## 运行 Milestone 5 验收

```powershell
& 'C:\Users\admin\Desktop\Godot_v4.7.2-stable_win64.exe' --headless --path . --script res://tests/run_milestone_5.gd
```

测试覆盖 38 张确认牌的数量、全部主动道具、工具箱、马尔科“装备齐全”、威廉“冲刺”、完整物品交换、终局统计、新手提示、声音与动画反馈，以及快速重开。Milestone 0～5 当前共 840 项自动断言。
