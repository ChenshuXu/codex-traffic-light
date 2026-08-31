# Codex Traffic Light

一个很小的原生 macOS 菜单栏指示器，同时汇总 Codex 桌面版与 VS Code Codex 任务。

- 红灯：Codex 正在等你选择。
- 黄灯：任务正在运行。
- 绿灯：任务已经结束。
- 灰灯：没有任务，或暂时无法读取状态。

菜单栏只显示一个当前状态圆点。点它会展开最多 8 条任务；需要操作和运行中的任务排在前面。每条任务显示标题和自己的状态。

应用启动时还会显示同样内容的桌面小窗口。它可以关闭、从菜单栏重新打开，也可以固定在其他窗口前面。设置里可以选择是否启动时显示、是否始终置顶，以及是否显示已完成任务。窗口位置会自动记住。

## 构建与运行

需要 macOS 13 或更高版本，以及 Apple Command Line Tools。

```sh
./build.sh
open "build/Codex Traffic Light.app"
```

应用不显示在 Dock。关闭桌面窗口不会退出；退出请点菜单栏下拉面板底部的“退出”。

## 数据与兼容性

应用每 2 秒只读检查 `~/.codex` 中的任务索引、任务生命周期和 writer lock。标题只取 Codex 生成的任务名；它仅从当前运行 turn 的本地记录中识别 `request_user_input` 是否仍未回答，不会显示、保存或上传对话正文。

Codex 桌面版和 VS Code 目前各自使用私有的 stdio App Server，外部应用无法直接订阅两边的实时状态，因此这一版使用共享的本地只读状态。若 Codex 以后更改本地数据库或 rollout 格式，需要同步更新读取逻辑。官方状态模型见 [Codex App Server 文档](https://developers.openai.com/codex/app-server)。

已知边界：未写入本地记录的审批等待可能暂时显示为黄灯；精确覆盖这种状态需要两个客户端提供可共享的官方状态流。
