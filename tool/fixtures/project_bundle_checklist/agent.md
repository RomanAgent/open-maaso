---
{"docSchemaVersion":2,"projectId":"offline-checklist","revisionId":"revision-1","protocolVersion":2,"profile":"maaso.project.preflight.v2","protocolSha256":"a43fe52f94879d7891bba87117318624c8d269ab6e2312d459f707d91928dacd"}
---
# 离线清单预检样例

用途：验证两页项目的文件摘要、路由目录和版本绑定。

页面：home 对应 index.html；details 对应 pages/details.html，父页面为 home。
用户可在首页勾选清单、进入说明页并返回。勾选仅存在于当前页面，不提供存档。

动作目录仅描述 app.navigate.home 和 app.navigate.details 的目标页面，
本样例不注册这些动作，也不授予任何 Agent 或宿主操作权限。

此版本仅通过包预检时可以确认字节与清单一致。运行、安全、功能和发布验收均未执行，
不能将本文件的描述当成已验证能力。当前不支持对战、合作或自主控制。
