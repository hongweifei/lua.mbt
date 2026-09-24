# Git Hooks

## pre-commit 钩子

这个 pre-commit 钩子会在提交落地之前做一些自动检查。

### 使用方式

1. 如果没有执行权限，先加上：
   ```bash
   chmod +x .githooks/pre-commit
   ```

2. 让 Git 使用 `.githooks` 目录下的钩子：
   ```bash
   git config core.hooksPath .githooks
   ```

3. 之后执行 `git commit` 时钩子会自动运行。
