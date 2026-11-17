# SSH 连接向导

对应 V0.1.3 SSH 连接设计，9 张可编辑 SVG 覆盖新建／编辑连接的三步流程与异常状态。原稿沿用当时的深色绿主题；原生实现按当前主题 token 落地。

| 状态 | SVG | 逻辑视口 |
| --- | --- | --- |
| 连接与认证 | [ssh-identity.svg](ssh-identity.svg) | 824 × 508 |
| 连接与认证 · 高级选项 | [ssh-identity-advanced.svg](ssh-identity-advanced.svg) | 824 × 644 |
| 连接路径 · 直连／跳板卡片 | [ssh-route.svg](ssh-route.svg) | 760 × 352 |
| 连接路径 · 纵向拓扑 | [ssh-route-vertical.svg](ssh-route-vertical.svg) | 760 × 596 |
| 连接路径 · 插入跳板选择 | [ssh-route-insert-picker.svg](ssh-route-insert-picker.svg) | 760 × 386 |
| 核对与测试 | [ssh-review.svg](ssh-review.svg) | 824 × 540 |
| 核对与测试 · 多跳 | [ssh-review-multi-hop.svg](ssh-review-multi-hop.svg) | 824 × 540 |
| 保存错误 · 名称重复 | [ssh-review-save-error-duplicate.svg](ssh-review-save-error-duplicate.svg) | 824 × 612 |
| 保存错误 · 配置文件写入失败（窄窗） | [ssh-review-save-error-write-compact.svg](ssh-review-save-error-write-compact.svg) | 860 × 480 |

网页连接复用同一套连接路径卡片与拓扑布局，见 [V0.6 网页连接与书签](../web-connection/web-connection.md)。
