'use strict';
window.V3Features=[
 ...[['shell-tabs','会话页签','页签身份、状态、关闭、重命名与菜单',['toolkit','overlays']],['host-sidebar','主机导航','折叠身份卡、搜索、连接和主机菜单',['collections','overlays']],['terminal-input','终端输入','右键粘贴、中键菜单与命令补全',['inputs','overlays']],['command-record','内置命令记录','与终端文档对齐的命令、状态和输出',['feedback']],['session-menus','会话菜单','主机右键、页签右键、终端中键的动作边界',['overlays']],['connection-status','连接状态','状态、延迟、失败恢复与断开',['feedback','overlays']],['connection-route','连接链路','跳板身份、稳定锚点和分阶段检测',['collections','feedback']],['broadcast','广播控制','会话参与开关、在线状态与广播总开关',['choices','overlays']],['port-forward','端口转发','绑定、目标、冲突、启动和停止',['inputs','choices','feedback']],['transfer','传输任务','选择、冲突、队列与来源定位',['collections','async']],['ai','AI 助手','原浮窗、composer、归属、上下文与审批',['inputs','overlays','async']]].map(([id,title,description,base])=>({id:'workspace-'+id,title,description,base,group:'workspace',module:'终端与文件',url:'../workspace/index.html?mode='+(id==='broadcast'?'group':'ssh')+'&component='+id,source:'../workspace/app.js',shared:id==='shell-tabs'?'../shared/functional.js':null})),
 ...[['connection-review','连接核对与测试','身份快照、路径、配置检查与认证边界'],['connection-route','连接路径编辑','直连、多跳排序和独立认证'],['connection-auth','连接认证','凭据挑战、取消、失败与恢复']].map(([id,title,description])=>({id,title,description,group:'connection',module:'主机与连接',base:['inputs','choices','overlays'],url:'../connection/index.html?feature='+id,source:'../connection/app.js'})),
 ...[['settings-navigation','设置导航','搜索、分类、最小窗口的独立滚动'],['settings-transaction','设置事务','草稿、校验、撤销、保存、关闭确认'],['theme-picker','主题选择','主题预览、导入和跨模块语义'],['font-settings','字体与排版','字体选择、fallback和终端预览'],['model-row','模型行','单行信息、能力、测试和编辑']].map(([id,title,description])=>({id,title,description,group:'settings',module:'偏好设置',base:['inputs','choices','feedback'],url:'../settings/index.html?component='+id,source:'../settings/app.js'})),
 ...[['kvm-control','KVM 控制权','只读、申请、释放与输入租约'],['kvm-display','KVM 显示','等比、原始尺寸、滚动与全屏'],['kvm-keys','KVM 按键','组合键与控制权门控'],['kvm-route','KVM 连接链路','连接身份、跳板、目标与检测'],['kvm-power','KVM 电源','已接受、状态核实与未知结果'],['kvm-boot','KVM 启动项','一次性覆盖、读回与恢复'],['kvm-ai','KVM AI','原助手结构与观察、授权和审批']].map(([id,title,description])=>({id,title,description,group:'kvm',module:'BMC iKVM',base:['choices','overlays','async'],url:'../kvm/index.html?protocol=kvm&feature='+id,source:'../kvm/app.js'})),
 {id:'note-editor',title:'笔记编辑与预览',description:'同一笔记模型的编辑、预览与分栏',group:'notes',module:'本地笔记',base:['inputs','actions'],url:'../notes/index.html?component=note-editor',source:'../notes/app.js'},
 {id:'note-actions',title:'笔记联动',description:'命令准备、AI上下文与保留草稿',group:'notes',module:'本地笔记',base:['actions','overlays'],url:'../notes/index.html?component=note-actions',source:'../notes/app.js'}
];

// Functional regions are distinct entry points over the same module implementation.
window.V3Areas=[
 ['local','本地 ZSH','../workspace/index.html?mode=local','本地终端输入、输出、菜单与会话'],
 ['ssh','SSH 终端','../workspace/index.html?mode=ssh','远端连接、分组、终端与转发'],
 ['sftp','SFTP 文件工作区','../workspace/index.html?mode=sftp','双栏文件与传输任务'],
 ['assistant','AI 助手','../workspace/index.html?mode=ai','复用原 Figma 浮窗与会话/模型管理'],
 ['topbar','顶栏与页签','index.html?id=workspace-shell-tabs','独立页签、身份提示与菜单'],
 ['sidebar','主机侧栏','index.html?id=workspace-host-sidebar','独立导航、折叠身份和主机菜单'],
 ['statusbar','底栏','index.html?id=workspace-statusbar','状态、广播、链路、转发和传输入口'],
 ['connection','连接 · 已冻结','../connection/index.html','保留拆分前已确认的完整模块，仅定点修复'],
 ['settings','设置 · 已冻结','../settings/index.html','保留拆分前已确认的完整模块'],
 ['kvm','BMC iKVM','../kvm/index.html?protocol=kvm','连接画面、控制、按键、电源与启动'],
 ['notes','笔记工具','../notes/index.html','编辑与命令准备，整机以浮窗呈现']
];
V3Features.splice(2,0,{id:'workspace-statusbar',title:'底栏功能入口',description:'底栏仅负责状态及功能触发，浮层复用各自独立组件',base:['toolkit','overlays'],group:'statusbar',module:'底栏',url:'../workspace/index.html?mode=ssh&component=statusbar',source:'../workspace/app.js'});
for(const item of V3Features){item.area=item.id==='workspace-shell-tabs'?'topbar':item.id==='workspace-host-sidebar'?'sidebar':item.id==='workspace-ai'||item.id==='kvm-ai'?'assistant':item.id==='workspace-transfer'?'sftp':item.id.startsWith('workspace-')&&['connection-status','connection-route','broadcast','port-forward'].some(k=>item.id==='workspace-'+k)?'statusbar':item.group==='workspace'?'ssh':item.group;}

window.V3FeaturesForArea=id=>V3Features.filter(f=>f.group===id||f.area===id||id==='local'&&['workspace-terminal-input','workspace-command-record','workspace-session-menus'].includes(f.id));
