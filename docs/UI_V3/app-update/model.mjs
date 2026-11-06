// Design simulation only: no filesystem, process, network or native updater access.
export const stateNames = {
  settings:'设置入口',no_stable:'暂无正式版',check_failed:'检查更新失败',download_failed:'下载失败',available:'发现新版本',downloading:'正在下载',verifying:'正在校验',ready:'准备安装',
  drafts:'未保存内容',saving:'保存工作区快照',snapshot_failed:'快照保存失败',confirm:'结束任务确认',
  closing:'正在结束任务',draining:'取消后的收尾进度',blocked:'结束任务超时',handoff:'等待安装准备',commit_pending:'等待提交回执',
  cancel_pending:'等待取消回执',handoff_failed:'安装交接失败',parent_exit_timeout:'应用退出超时',
  installing:'正在安装',startup_blocked:'安装期间启动受阻',recovery_pending:'中断后恢复',
  done:'更新完成',invalid:'验证失败',manual:'需要手动安装',failed:'替换失败已恢复',
  restore_failed:'旧版本恢复失败',launch_failed:'新版启动失败',incompatible_data:'数据已变更不可回退',recovery_saved:'恢复信息已保留'
};
const definitions = [['terminal','终端连接','terminal',3],['transfer','文件传输','transfer',1],['ai','AI 任务','spark',1],['other','KVM 与转发','network',2]];
const verifiedStates = new Set(Object.keys(stateNames).filter(x=>!['settings','no_stable','check_failed','download_failed','available','downloading','verifying','invalid'].includes(x)));
export class UpdateDesignModel {
  constructor(state='confirm',busy=true){this.loadFixture(state,busy);}
  loadFixture(state,busy=true){
    this.epoch=(this.epoch||0)+1;this.batchId=`close-${this.epoch}`;this.planId=`plan-${this.epoch}`;
    this.state=stateNames[state]?state:'confirm';this.tasks=busy?definitions.map(([id,label,icon,count])=>({id,label,icon,count,status:'active',requests:0})):[];
    this.operation=['downloading','verifying'].includes(this.state)?this.state:verifiedStates.has(this.state)?'ready':'idle';
    this.checkState=['no_stable','check_failed','download_failed'].includes(this.state)?this.state:null;
    this.operationGeneration=1;this.attempt=0;this.installed=this.state==='done';this.intent=false;this.gate=false;
    this.helper='none';this.commitSent=false;this.decision=null;this.message='';this.unsaved=this.state==='drafts';this.allowUnsaved=false;
    this.snapshot=null;this.dataChanged=this.state==='incompatible_data';this.backupValid=true;this.backupPreserved=false;
    this.dataCompatibility=['launch_failed','recovery_pending'].includes(this.state)?'unchanged':this.dataChanged?'incompatible':'unknown';
    this.newProcessReleased=['launch_failed','recovery_pending','failed'].includes(this.state);
    this.transactionStage='none';this.actionLog=[];
    const closeCount=['closing','draining'].includes(this.state)?2:['blocked','cancel_pending'].includes(this.state)?3:0;
    for(let i=0;i<closeCount&&i<this.tasks.length;i++)this.tasks[i].status='released';
    if(['closing','draining','blocked','cancel_pending'].includes(this.state)){
      this.intent=['closing','blocked'].includes(this.state);this.gate=this.state!=='draining';this.snapshot={phase:'before-close',workIds:this.tasks.map(t=>t.id)};
      const pending=this.tasks.find(t=>t.status==='active');if(pending){pending.status=this.state==='blocked'?'unknown':'closing';pending.requests=1;}
    }
    if(['handoff','commit_pending','cancel_pending'].includes(this.state)){
      this.tasks.forEach(t=>t.status='released');this.intent=this.state!=='cancel_pending';this.gate=true;
      this.snapshot={phase:'before-close',workIds:this.tasks.map(t=>t.id)};
      this.helper=this.state==='handoff'?'preparing':this.state==='cancel_pending'?'cancel_requested':'prepared';
      this.commitSent=this.state!=='handoff';
    }
    if(['handoff_failed','parent_exit_timeout','installing','startup_blocked','recovery_pending','failed','restore_failed','launch_failed','incompatible_data','recovery_saved','done'].includes(this.state)){
      this.tasks.forEach(t=>t.status='released');this.backupPreserved=!['handoff_failed','parent_exit_timeout'].includes(this.state);
      this.transactionStage={handoff_failed:'prepared',parent_exit_timeout:'aborted_before_replace',installing:'backup_verified',startup_blocked:'new_placed',recovery_pending:'backup_verified',failed:'old_restored_verified',restore_failed:'restore_failed',launch_failed:'new_started',incompatible_data:'new_data_written',recovery_saved:'restore_failed',done:'healthy'}[this.state];
      this.decision=this.state==='handoff_failed'?'cancelled':'committed';
      this.helper=this.state==='parent_exit_timeout'?'aborted':this.decision;this.gate=!['handoff_failed','parent_exit_timeout','failed','done'].includes(this.state);
      if(this.state==='restore_failed')this.backupValid=false;
      if(this.state==='recovery_saved'){this.backupValid=false;this.recoveryState='restore_failed';}
    }
  }
  get remaining(){return this.tasks.filter(t=>t.status!=='released');}
  get total(){return this.tasks.reduce((n,t)=>n+t.count,0);}
  get released(){return this.tasks.filter(t=>t.status==='released').reduce((n,t)=>n+t.count,0);}
  get canRestore(){const compatible=this.dataCompatibility==='backward-compatible'||this.dataCompatibility==='unchanged'&&!this.dataChanged;return this.backupPreserved&&this.backupValid&&this.newProcessReleased&&compatible&&['launch_failed','recovery_pending'].includes(this.state);}
  get helperSurface(){return ['installing','startup_blocked','recovery_pending','parent_exit_timeout','failed','restore_failed','launch_failed','incompatible_data','recovery_saved'].includes(this.state);}
  get pendingReceipt(){
    const work=this.tasks.find(t=>t.status==='closing');
    if(work)return {kind:'release',epoch:this.epoch,batchId:this.batchId,id:work.id};
    if(this.state==='saving')return {kind:'snapshot',epoch:this.epoch};
    if(this.state==='handoff')return {kind:'helper-ready',epoch:this.epoch};
    if(this.state==='commit_pending')return {kind:'commit',epoch:this.epoch};
    if(this.state==='cancel_pending')return {kind:'cancel',epoch:this.epoch};
    if(this.state==='installing')return {kind:'healthy',epoch:this.epoch};
    return null;
  }
  open(){
    if(this.intent)this.state=this.remaining.length?'closing':'handoff';
    else this.state=this.checkState|| (this.operation==='ready'?'ready':['downloading','verifying'].includes(this.operation)?this.operation:'available');
  }
  download(){this.operationGeneration++;this.operation='downloading';this.state='downloading';}
  downloadComplete(generation=this.operationGeneration){if(generation!==this.operationGeneration||this.operation!=='downloading')return false;this.operation='verifying';if(this.state!=='settings')this.state='verifying';return true;}
  verificationComplete(generation=this.operationGeneration){if(generation!==this.operationGeneration||this.operation!=='verifying')return false;this.operation='ready';if(this.state!=='settings')this.state='ready';return true;}
  cancelOperation(){if(!['downloading','verifying'].includes(this.operation))return false;this.operationGeneration++;this.operation='idle';this.state='settings';this.message='已取消下载或校验，未验证的更新包已清除。';return true;}
  requestInstall(){
    if(this.operation!=='ready'||this.gate)return false;
    if(this.decision==='committed'&&!['old_restored_verified','aborted_before_replace'].includes(this.transactionStage))return false;
    if(this.unsaved&&!this.allowUnsaved){this.state='drafts';return true;}
    this.attempt++;this.planId=`plan-${this.epoch}-${this.attempt}`;
    this.helper='none';this.decision=null;this.commitSent=false;
    this.state=this.remaining.length?'confirm':'saving';if(this.state==='saving'){this.intent=true;this.gate=true;}return true;
  }
  discardDrafts(){if(this.state!=='drafts')return;this.allowUnsaved=true;this.requestInstall();this.state='confirm';this.intent=false;this.gate=false;}
  confirmClose(){if(this.state!=='confirm')return;this.intent=true;this.gate=true;this.state='saving';}
  snapshotReceipt(ok=true){
    if(this.state!=='saving'||!this.intent)return false;
    if(!ok){this.intent=false;this.gate=false;this.state='snapshot_failed';return true;}
    this.snapshot={phase:'before-close',workIds:this.tasks.map(t=>t.id)};
    this.state='closing';this.issueNext();return true;
  }
  issueNext(){
    if(!this.intent||this.remaining.some(t=>['closing','unknown'].includes(t.status)))return;
    const next=this.tasks.find(t=>t.status==='active');
    if(next){next.status='closing';next.requests++;this.actionLog.push(`close:${next.id}`);}
    else this.beginHandoff();
  }
  releaseReceipt(batchId,id){
    if(batchId!==this.batchId)return false;
    const task=this.tasks.find(t=>t.id===id);if(!task||!['closing','unknown'].includes(task.status))return false;
    task.status='released';
    if(this.intent){this.state='closing';this.issueNext();}
    else this.message=`更新已取消；已结束 ${this.released} / ${this.total} 项工作，剩余工作不会被继续关闭。`;
    return true;
  }
  retryClose(){
    if(this.state!=='blocked')return;
    this.intent=true;this.gate=true;this.state='closing';
    // Poll the same issued close operation; do not issue a second close request.
    this.tasks.filter(t=>t.status==='unknown').forEach(t=>t.status='closing');this.issueNext();
  }
  closeTimeout(){if(this.state!=='closing'||!this.intent)return false;this.tasks.filter(t=>t.status==='closing').forEach(t=>t.status='unknown');this.state='blocked';return true;}
  beginHandoff(){if(!this.intent||this.remaining.length)return;this.helper='preparing';this.decision=null;this.commitSent=false;this.transactionStage='prepared';this.state='handoff';}
  helperReady(){
    if(this.helper!=='preparing'||!this.intent||this.decision!==null)return false;
    this.helper='prepared';this.commitSent=true;this.state='commit_pending';return true;
  }
  cancelInstall(){
    if(this.decision==='committed'){this.message='安装提交已确认，当前阶段无法取消。';return false;}
    this.intent=false;
    if(['preparing','prepared','cancel_requested'].includes(this.helper)){
      this.helper='cancel_requested';this.gate=true;this.state='cancel_pending';
    }else{this.gate=false;this.state='settings';const pending=this.tasks.filter(t=>['closing','unknown'].includes(t.status)).reduce((n,t)=>n+t.count,0);this.message=pending?`已取消更新；仍有 ${pending} 项工作正在收尾，已结束的工作不会恢复。`:'已取消更新，已结束的工作不会恢复。';}
    return true;
  }
  helperCancelReceipt(){
    if(this.decision==='committed'){this.state='installing';return false;}
    if(this.helper!=='cancel_requested')return false;
    this.decision='cancelled';this.helper='cancelled';this.commitSent=false;this.gate=false;this.intent=false;
    this.transactionStage='aborted_before_replace';this.state='settings';this.message='安装程序已确认取消，不会在应用退出后替换应用。';return true;
  }
  helperCommitReceipt(){
    if(!this.commitSent||this.decision!==null)return false;
    this.decision='committed';this.helper='committed';this.intent=true;this.gate=true;
    this.transactionStage='commit_accepted';this.state='installing';this.message='安装提交已确认，当前阶段无法取消。';return true;
  }
  parentExitTimeout(){if(this.decision!=='committed')return;this.helper='aborted';this.gate=false;this.intent=false;this.commitSent=false;this.transactionStage='aborted_before_replace';this.state='parent_exit_timeout';}
  healthyReceipt(){if(this.decision!=='committed'||!['installing','startup_blocked'].includes(this.state))return false;this.transactionStage='healthy';this.installed=true;this.gate=false;this.intent=false;this.operation='idle';this.state='done';return true;}
  restoreOld(){if(!this.canRestore)return false;this.transactionStage='old_restored_verified';this.state='failed';this.gate=false;this.intent=false;return true;}
  dismiss(){
    if(['restore_failed','launch_failed','incompatible_data'].includes(this.state)){this.recoveryState=this.state;this.state='recovery_saved';return true;}
    if(['installing','startup_blocked','recovery_pending','recovery_saved','cancel_pending'].includes(this.state))return false;
    if(['closing','blocked','handoff','saving','commit_pending'].includes(this.state))return this.cancelInstall();
    if(this.state==='confirm'){this.allowUnsaved=false;this.state='ready';return true;}
    if(['drafts','snapshot_failed'].includes(this.state)){this.intent=false;this.gate=false;this.state='ready';return true;}
    // Hiding details is independent of the background download or verification.
    this.state='settings';return true;
  }
  receipt(event=this.pendingReceipt){
    if(!event||event.epoch!==this.epoch)return false;
    if(event.kind==='release')return this.releaseReceipt(event.batchId,event.id);
    if(event.kind==='snapshot')return this.snapshotReceipt();
    if(event.kind==='helper-ready')return this.helperReady();
    if(event.kind==='commit')return this.helperCommitReceipt();
    if(event.kind==='cancel')return this.helperCancelReceipt();
    if(event.kind==='healthy')return this.healthyReceipt();
    return false;
  }
}
