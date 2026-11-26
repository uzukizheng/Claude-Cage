# Cage ClashX 自动构建

本仓库的 [main](../../tree/main) 镜像上游 `main`。默认分支 `automation` 保存工作流，以便 GitHub Actions 能定时检测上游正式发布。

工作流每小时第 17 分钟检查上游，快进同步 fork 的 `main`，将最近一个较早版本的 ClashX 补丁提交依次应用到最新正式发布的 tag。Apple Silicon 构建和测试通过后，才推送 `clashx/<tag>`。安装包和 SHA-256 校验文件可在 [Actions 运行记录](../../actions/workflows/cage-clashx.yml) 的 Artifacts 下载，保留 90 天。App 使用临时签名。

构建输入是 Git 提交和上游公开构建依赖。个人 ClashX 配置留在本机。

## 处理补丁冲突

工作流会开启一张 Issue，附上冲突文件、补丁来源和运行日志。同一版本的未关闭 Issue 会复用。

1. 本地从 Issue 所指版本的上游 tag 新建 `clashx/<tag>`，cherry-pick 上一版的补丁提交并解决冲突。提交保持线性。
2. 把分支推到 fork，打开 Actions 的 **Cage ClashX macOS arm64**，手动运行时填写目标 tag 并勾选 **rebuild**。
3. 确认构建结果后关闭冲突 Issue。后续发布会自动从这个分支取补丁。
