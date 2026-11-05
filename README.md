# Credis Event Bridge

Discourse服务端插件：采集论坛原生操作，保存来源证据和Outbox，并向SpacemiT积分平台签名投递。它不是主题或Discord机器人，不部署积分平台。

## 安装

面向自托管Discourse。当前认证Core为`2026.8.0`、提交`badad7b0456a628e578bc48b9f8c1259422b5d58`；其他版本不能只凭版本接近跳过源码/钩子检查。Reactions、单答案Solved等依赖按该Core实际捆绑情况确认并启用，勿重复安装Core已包含的插件。

在论坛`/var/discourse/containers/app.yml`已有`hooks.after_code`中追加，保留其他插件配置：

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/leiw5173/credis-event-bridge.git credis-event-bridge
```

论坛维护人在`/var/discourse`执行`./launcher rebuild app`。单容器切换/启动期间论坛会暂时不可用；先备份并安排维护窗口，不承诺零停机。源码部署将仓库clone到Discourse的`plugins/credis-event-bridge`，按其原流程构建、迁移和重启Web/worker。

安装不等于采集激活或计分许可。插件加载钩子/兼容检查，没有完全停用总开关；新安装可延后首次epoch激活，已有来源须走受控生命周期，不能删历史或换槽绕过断档。

## 配置与配套

使用积分平台初始化工具生成的论坛接入包，将其中`app-env.yml`的env键值合并到论坛现有env块，Web/worker保持一致。该片段含事件HMAC，按凭据保护，不提交Git。后台ScanOutbox任务须运行；私有积分HTTPS CA须安装到所有Web/worker的系统信任库，不能关闭TLS校验。

完整配置、主29表/Report publication及采集生命周期见[平台部署说明](https://github.com/leiw5173/SpacemitCredits/blob/docs/docker-deployment83-20261104/README.md)。真实论坛来源、验签和记账分别验证，安装或HTTP成功不代表允许生产计分。

## 维护与验证

本仓库是事件桥唯一维护源；主项目的`discourse-plugin/`子模块固定经核准的提交。更新前对目标Core与平台组合做隔离验证；网页更新器能否安全更新当前组合尚未验收，勿自动跟随主分支部署生产。

完整RSpec须在固定Core、假数据论坛执行：

```sh
bundle exec rspec plugins/credis-event-bridge/spec
bundle exec rubocop plugins/credis-event-bridge
```

不连接真实论坛或生产数据库做测试。初始独立发布仅改变仓库组织和安装说明，迁移、捕获及投递代码保持原样。
