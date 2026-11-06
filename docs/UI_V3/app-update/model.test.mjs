// Contract checks for the local prototype model; these are not native updater tests.
import test from 'node:test';
import assert from 'node:assert/strict';
import {UpdateDesignModel} from './model.mjs';

function startClose(){const m=new UpdateDesignModel('confirm');m.confirmClose();m.snapshotReceipt();return m;}
function prepare(){const m=new UpdateDesignModel('ready',false);m.requestInstall();m.snapshotReceipt();return m;}

test('no-work install still saves a snapshot and takes the gate before handoff',()=>{
  const m=new UpdateDesignModel('ready',false);m.requestInstall();assert.equal(m.state,'saving');assert.equal(m.gate,true);
  m.snapshotReceipt();assert.equal(m.snapshot.phase,'before-close');assert.equal(m.state,'handoff');assert.equal(m.decision,null);
});
test('draft dismissal and failed snapshot leave all work running',()=>{
  const m=new UpdateDesignModel('ready');m.unsaved=true;m.requestInstall();assert.equal(m.state,'drafts');m.dismiss();
  assert.equal(m.tasks.every(t=>t.requests===0),true);m.unsaved=false;m.requestInstall();m.confirmClose();m.snapshotReceipt(false);
  assert.equal(m.state,'snapshot_failed');assert.equal(m.gate,false);assert.equal(m.tasks.every(t=>t.requests===0),true);
});
test('workspace snapshot exists before the first close and survives released tasks',()=>{
  const m=startClose(),original=structuredClone(m.snapshot);assert.equal(original.workIds.length,4);
  m.releaseReceipt(m.batchId,'terminal');assert.deepEqual(m.snapshot,original);
});
test('cancel stops future closes but an issued close still releases after cancellation',()=>{
  const m=startClose(),receipt=m.pendingReceipt;m.cancelInstall();assert.equal(m.state,'settings');assert.equal(m.intent,false);
  assert.equal(m.receipt(receipt),true);assert.equal(m.released,3);assert.equal(m.tasks[1].requests,0);assert.equal(m.helper,'none');assert.equal(m.gate,false);
});
test('another install adopts remaining work without closing released work twice',()=>{
  const m=startClose(),receipt=m.pendingReceipt;m.cancelInstall();m.requestInstall();m.confirmClose();m.snapshotReceipt();
  assert.equal(m.tasks[0].requests,1);m.receipt(receipt);assert.equal(m.tasks[1].requests,1);assert.equal(m.tasks[0].requests,1);
});
test('cancelled cleanup progress is read-only and never restarts installation',()=>{
  const m=new UpdateDesignModel('draining'),receipt=m.pendingReceipt;m.receipt(receipt);
  assert.equal(m.state,'draining');assert.equal(m.intent,false);assert.equal(m.gate,false);assert.equal(m.tasks.at(-1).status,'active');assert.equal(m.tasks.at(-1).requests,0);
});
test('old close receipts cannot close work belonging to a reset fixture',()=>{
  const m=startClose(),receipt=m.pendingReceipt;m.loadFixture('confirm');assert.equal(m.receipt(receipt),false);assert.equal(m.released,0);
});
test('timeout retains ownership and retry polls the same close request',()=>{
  const m=startClose();m.closeTimeout();assert.equal(m.state,'blocked');assert.equal(m.tasks[0].status,'unknown');assert.equal(m.gate,true);
  m.retryClose();assert.equal(m.tasks[0].requests,1);m.releaseReceipt(m.batchId,'terminal');assert.equal(m.released,3);
});
test('prepared helper is not committed and cancellation needs its acknowledgement',()=>{
  const m=prepare();assert.equal(m.decision,null);m.cancelInstall();assert.equal(m.state,'cancel_pending');assert.equal(m.gate,true);
  assert.equal(m.helperReady(),false);m.helperCancelReceipt();assert.equal(m.decision,'cancelled');assert.equal(m.gate,false);assert.equal(m.helperCommitReceipt(),false);
});
test('cancel wins against an already sent commit request',()=>{
  const m=prepare();m.helperReady();m.cancelInstall();m.helperCancelReceipt();assert.equal(m.helperCommitReceipt(),false);
  assert.equal(m.state,'settings');assert.equal(m.decision,'cancelled');
});
test('commit wins against cancellation without falsely reporting cancelled',()=>{
  const m=prepare();m.helperReady();m.cancelInstall();assert.equal(m.helperCommitReceipt(),true);
  assert.equal(m.helperCancelReceipt(),false);assert.equal(m.state,'installing');assert.equal(m.gate,true);assert.equal(m.cancelInstall(),false);
});
test('a late helper event from another transaction is rejected',()=>{
  const m=prepare(),event=m.pendingReceipt;m.loadFixture('ready',false);assert.equal(m.receipt(event),false);assert.equal(m.helper,'none');
});
test('parent exit timeout revokes the old transaction so later commit cannot install',()=>{
  const m=prepare();m.helperReady();m.helperCommitReceipt();m.parentExitTimeout();assert.equal(m.state,'parent_exit_timeout');
  assert.equal(m.helperCommitReceipt(),false);assert.equal(m.gate,false);assert.equal(m.transactionStage,'aborted_before_replace');
  assert.equal(m.decision,'committed');assert.equal(m.requestInstall(),true);assert.equal(m.decision,null);
});
test('normal startup stays gated until the valid new process reports healthy',()=>{
  const m=new UpdateDesignModel('startup_blocked');assert.equal(m.gate,true);assert.equal(m.dismiss(),false);
  m.healthyReceipt();assert.equal(m.state,'done');assert.equal(m.gate,false);
});
test('safe recovery requires a verified backup, known compatible data and released new process',()=>{
  const m=new UpdateDesignModel('launch_failed');assert.equal(m.canRestore,true);
  m.dataCompatibility='unknown';assert.equal(m.canRestore,false);m.dataCompatibility='unchanged';
  m.newProcessReleased=false;assert.equal(m.canRestore,false);m.newProcessReleased=true;
  m.dataChanged=true;assert.equal(m.canRestore,false);m.dataCompatibility='backward-compatible';assert.equal(m.canRestore,true);
  assert.equal(m.restoreOld(),true);assert.equal(m.state,'failed');assert.equal(m.backupPreserved,true);
});
test('migrated data and failed restore cannot expose a usable old-app result',()=>{
  for(const phase of ['incompatible_data','restore_failed']){const m=new UpdateDesignModel(phase);assert.equal(m.canRestore,false);assert.equal(m.restoreOld(),false);assert.equal(m.state,phase);assert.equal(m.backupPreserved,true);assert.equal(m.cancelOperation(),false);}
});
test('a verified old-version recovery requires a fresh install authorization',()=>{
  const m=new UpdateDesignModel('launch_failed');m.restoreOld();const old=m.planId;
  assert.equal(m.requestInstall(),true);assert.notEqual(m.planId,old);assert.equal(m.decision,null);assert.equal(m.commitSent,false);assert.equal(m.state,'saving');
});
test('hiding a terminal recovery error preserves the gate and backup',()=>{
  const m=new UpdateDesignModel('restore_failed');assert.equal(m.dismiss(),true);assert.equal(m.state,'recovery_saved');
  assert.equal(m.recoveryState,'restore_failed');assert.equal(m.gate,true);assert.equal(m.backupPreserved,true);assert.equal(m.requestInstall(),false);
});
test('hiding download details keeps the operation, cancellation rejects a late download',()=>{
  const m=new UpdateDesignModel('available');m.download();const old=m.operationGeneration;m.dismiss();assert.equal(m.operation,'downloading');
  m.open();assert.equal(m.state,'downloading');m.cancelOperation();assert.equal(m.downloadComplete(old),false);assert.equal(m.operation,'idle');
});
test('background verification completes without installing, explicit cancellation rejects old results',()=>{
  const m=new UpdateDesignModel('verifying');m.dismiss();assert.equal(m.operation,'verifying');m.verificationComplete();assert.equal(m.operation,'ready');assert.equal(m.intent,false);
  const n=new UpdateDesignModel('verifying'),old=n.operationGeneration;n.cancelOperation();assert.equal(n.verificationComplete(old),false);assert.equal(n.operation,'idle');
});

test('empty stable channel and fetch errors never imply a verified package',()=>{
  for(const state of ['no_stable','check_failed','download_failed']){
    const m=new UpdateDesignModel(state);
    assert.equal(m.operation,'idle');assert.equal(m.requestInstall(),false);
    m.dismiss();m.open();assert.equal(m.state,state);
  }
});

test('force install requires final confirmation even without running tasks',()=>{
  const m=new UpdateDesignModel('drafts',false);m.discardDrafts();
  assert.equal(m.state,'confirm');assert.equal(m.allowUnsaved,true);assert.equal(m.gate,false);
  m.dismiss();assert.equal(m.allowUnsaved,false);assert.equal(m.unsaved,true);m.requestInstall();assert.equal(m.state,'drafts');
});
