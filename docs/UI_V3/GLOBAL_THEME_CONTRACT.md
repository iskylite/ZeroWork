# 全局主题背景与半透明表面

应用根部只绘制一次主题基色与可选图片。所有普通组件、卡片、内容容器和浮层透出这一层，按全局T派生半透明底色区分层次，不强制所有容器alpha0；T0是用户明确选择的不透明端点，T大于0时按角色系数透出根背景。表面透明规则始终启用，与背景图片开关无关。

## 唯一全局派生公式

`T=clamp(background_transparency/100,0,1)`，0不透明、1全透明；`B=clamp(blur_px,0,96)`。真实产品默认T=0/B=0（旧HTML的75已纠正为真实原生默认），不改配置默认值、不新增产品配置。

各表面的透过率`clamp(T×k,0,1)`；alpha`1−透过率`。k：surface1=.95、surface2=.90、well=.80、overlay=.10、hover=.75、tab=.65；card-deep复用surface2、card-deep-ft复用well。overlay在T=1仍有90%不透明度，指令清单属于此角色。

根背景图片alpha=`1−T`，根图blur=B；普通表面不另加模糊（B×0），浮层局部backdrop blur=B（B×1）。B0时不模糊，不能暗中保留固定blur。图片开关只影响图片绘制，材质始终按当前有效设置派生；图片未启用时也同样生效。前景文字/图标不整树透明。

`shared/global-background.js`负责保存值、设置草稿事件和产品窗口外评审T/B的共同派生；通过已知同源文档宿主同步有效设置。嵌入模块不绘自己的背景图片；html根color-scheme随body同步，避免嵌入canvas在明暗切换时遮住根图。

`theme-tokens.css`保存12套基色与角色引用，使用公共服务写入的派生百分比；初始CSS后备值只是真实默认T=0的计算结果，不是独立固定alpha合同。`theme-presets.json`保存基色、系数和默认参数，示例有效RGBA仅用于核对默认公式。

`settings/app.js`仅新增既有background_transparency/blur_px/图片属性草稿watch→zw-material-draft事件；未改产品文案或其它设置业务。保存/撤销后的值走同一通道。根背景继续只绘一次，浮层不复制图、不铺地板。媒体图像/显式ANSI颜色属于真实内容，保留原色。

指令清单由renderPalette/renderOtherPalette共用positionPalette：锚定原会话输入框实际边界，在所属pane和应用可见区域交集内选择上下空间；宽≤520、高≤330，空间不足内部滚动，不覆盖输入行；滚动/resize重定位，原锚点不可见则关闭，不回落(0,0)。

## 与其它会话的归属

| 会话 | 唯一负责 |
| --- | --- |
| 更新效果图与UI原型 | 公共主题tokens/background、设计规范/相关文档、评审总览与截图 |
| 复刻 AI 助手原型组件 | workspace/app.js/index.html、shared/ai-prototype.*；其provider负责人维护shared/ai-assistant.js/css模型区域 |
| 规范效果图组件文案 | 已完成12个HTML/JS的产品文案清理，技术/模拟/评审说明置产品窗外；继续维护时保留其结果 |
| 逐模块复核并对齐设置界面 | 原生源码、真实HTTP与原生窗口验证；原型会话不回写src |

压缩统一使用既有usage气泡，无消息流状态卡、无摘要查看入口。原生344宽/state314×84，HTML同角色尺寸见COMPRESSION_CONTRACT.md。模拟说明只在产品窗外，不在效果图组件里出现。

## 验证入口

- 无图片：`app/index.html`。
- 连续性背景夹具：`app/index.html?background=continuity`。本地SVG只用于评审，图片35%不透明；基色与图像只在根部合成，不是新增产品内置背景。
- 同页右上主题选择在dark/light间切换，再打开偏好设置、传输或AI气泡，检查根背景连续与浮层文字可读。

本HTML服务只读取可由浏览器使用的data:image/blob背景地址；本地文件路径读取、图片解码及实际配置持久化仍由原生负责人实现和验证，不能从浏览器夹具推定真实文件读取已通过。

当前有效设计规范的overlay alpha1/常驻壳实底/SSH菜单实底/SFTP双卡实底条文已被直接改写。凭据“不透明引用”、根基色不透明fallback及实际图像/ANSI内容语义保留，它们不属于旧的容器实底要求。

## 本轮验证

旧固定alpha/blur截图不作为当前合同。当前应核对global T/B派生材质、指令清单上下边缘与组终端截图；测量和图像位于verification/review-20261026/material-*。HTML与原生分别报告，不以浏览器图代替原生测试。
