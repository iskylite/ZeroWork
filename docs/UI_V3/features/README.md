# 功能组件入口

[index.html](index.html) 是分类目录，`?id=<catalog-id>`打开一项能力。每项使用来源模块的component/feature路由、真实模板、控制器和受控fixture；不维护第二份业务HTML。模块目录和整机消费同一来源。

`catalog.js`登记标题、能力说明、模块、通用依赖和实现源；`catalog-app.js`提供评审画布、尺寸/主题与少量受控变体。模块链接移除component/feature参数，返回完整工作流。组件里的跨模块结果可在当前画布投影；需要保留多个模块实例和全局服务时使用整机预览。

可操作变体包括主机展开/折叠、主机/页签/终端菜单；其他状态通过组件自己的真实按钮、输入和Modal进入。广播默认装载组fixture。所有外部评审工具位于产品画布之外；最小画布860×480居中。

源合同：[组合与复用](../COMPONENT_MAP.md)、[工作区组件](../workspace/COMPONENTS.md)、各模块README、[Zenit落地](../ZENIT_READINESS.md)。当前28项，后续增加真实独立能力再登记，不以数量作为完整性证明。
