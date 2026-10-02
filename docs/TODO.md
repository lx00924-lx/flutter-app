# 待办事项（Backlog）

> 这里放**已确认要做、但还没做**的改动。用户口头交代"先记一下、下次再做"的条目也记在这。
> 做完一条就把对应小节删掉（别留"已完成"的历史 —— 那属于 git log 的职责）。

---

## 1. 手机端的 DSH 选择卡片：加一个「确认」按钮

**要什么**：手机收到 DSH 的选择卡片（user-question / 选择框）时，**也要有一个确认按钮**，
不能只靠"点一下选项就直接提交"。

**为什么**：手机是触屏，误触代价高 —— 现在单题单选只要手指蹭到某个选项就**立刻作答并提交**，
答错了没有挽回余地（题目本身可能还在等用户仔细看描述）。

**现状（2026-10-02 核过）**：

- 卡片渲染在 `flutter_app/lib/widgets/chat_input_bar.dart`：
  - `_buildQuestionCardBlock()` 在 L685；卡片主体在 `Consumer<ChatProvider>` L1321 起；
  - **桌面端与手机端是同一份代码、同一个卡片**，没有平台分支 —— 改之前先确认"是否只在手机端生效"，
    别把桌面端的"点一下即答"也一起改掉（用户在电脑上习惯快速点选）。
- 判定逻辑在 `flutter_app/lib/providers/chat_provider.dart`：
  - `isInstantAnswerQuestion(item)` L934：**只有一道题 + 单选 + 有选项** 时才返回 true；
  - `pendingQuestionNeedsSubmit` L943：只要有一题不是"点一下即答"，就为 true；
  - `chat_input_bar.dart` L1339 用它决定是否渲染 `_buildQuestionNavRow()`（L1386，提交/上一题/下一题那行）——
    也就是说 **"点一下即答"的情况下底部那行（含提交按钮）根本不渲染**，这正是要补的地方。

**怎么做（建议）**：

- 手机端（`Platform.isAndroid || Platform.isIOS`）在 `isInstantAnswerQuestion` 为 true 时**也**渲染导航/确认行，
  把"提交"文案改成「确认」；桌面端保持现状。
- 选项的选中态 `toggleQuestionPick()`（L950）已经支持"再点一次取消勾选"，所以"点选项 = 选中、点确认 = 提交"
  的流程不用改 provider。
- ⚠️ 多题场景（`items.length > 1`）本来就 `needsSubmit == true`，不受影响；
  改完要顺手验一遍：多题、多选、纯自由回答、orphaned/waiting 四种状态都还正常。

---

## 2. 侧边栏「会话管理与备份」的图标换成气泡

**要什么**：把侧边栏里「会话管理与备份」左边那个图标换成一个**气泡图标**。

**为什么**：它现在用的是 `Icons.tune_outlined`（滑块），和紧邻的「设置」用的 `Icons.settings_outlined`
观感太像，用户反馈"都用设置图标，有点误导"。

**改哪里**：`flutter_app/lib/screens/chat_screen.dart` L363

```dart
ListTile(
  leading: const Icon(Icons.tune_outlined, size: 20),   // ← 换成气泡图标
  title: const Text('会话管理与备份', style: TextStyle(fontSize: 13)),
```

**建议取值**：`Icons.chat_bubble_outline`（单个气泡）或 `Icons.forum_outlined`（多气泡）。
注意同一个 `Column` 里下面紧跟的 Drawer 项还有 `Icons.settings_outlined`（L377 附近），
换的时候顺手看一眼整列的图标语义别重复。

---

## 备注

- 这两条都是**纯 App 端（Dart）改动**，改完 `flutter analyze` 过一遍即可；
  要看到效果**需要重新打 App 包**（Windows / Android），网页端与此无关。
- 相关背景：App 打包流程见根 `README.md` §四；安装器打包见 `installer/README.md`。
