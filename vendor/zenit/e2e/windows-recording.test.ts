import { randomUUID } from 'crypto';
import { clickTestId, imeCommit, request, screenshot, startWindowRecording, stopWindowRecording, windowRecordingStatus, waitForServerReady, waitFor, resizeWindow } from './client';
import { assert, run, test, writeSessionFile, getSessionDir } from './runner';

test('Windows recording encodes owned UI content and finalizes MP4', async () => {
  await waitForServerReady(20000);
  const path = `C:\\Windows\\Temp\\zenit-recording-${randomUUID()}.mp4`;
  const invalid = await startWindowRecording('Z:\\nonexistent\\bad.mp4', {fps:30});
  assert(!invalid.ok && !invalid.active && !!invalid.error, 'invalid path must fail explicitly');
  const started = await startWindowRecording(path, {fps:30});
  assert(started.ok && started.active, JSON.stringify(started));
  await clickTestId('input.name');
  await imeCommit('WINDOWS VIDEO A');
  await waitFor(async () => (await windowRecordingStatus()).frame_count >= 5, 20000, 100);
  await imeCommit(' — B 录像');
  await waitFor(async () => (await windowRecordingStatus()).frame_count >= 12, 20000, 100);
  await screenshot(`${getSessionDir()}/recording-final.png`);
  const count = (await windowRecordingStatus()).frame_count;
  await waitFor(async () => (await windowRecordingStatus()).frame_count >= count + 3, 20000, 100);
  const stopped = await stopWindowRecording();
  assert(stopped.ok && !stopped.active && stopped.frame_count >= 12 && stopped.file_size > 1000, JSON.stringify(stopped));
  const twice = await stopWindowRecording();
  assert(twice.file_size === stopped.file_size && twice.frame_count === stopped.frame_count, 'stop is idempotent');
  const duplicate = await startWindowRecording(path, {fps:30});
  assert(!duplicate.ok && !duplicate.active, 'must not overwrite previous MP4');
  const after = await request('GET', '/tree');
  assert(!!after, 'UI remains responsive after recorder failure');
  writeSessionFile('recording.json', JSON.stringify({started, stopped}, null, 2));
});

test('Windows recording reports resized drawable and supports restart', async () => {
  const path = `C:\\Windows\\Temp\\zenit-recording-resize-${randomUUID()}.mp4`;
  const started = await startWindowRecording(path, {fps:30});
  assert(started.ok && started.active, JSON.stringify(started));
  await waitFor(async () => (await windowRecordingStatus()).frame_count >= 3, 20000, 100);
  await resizeWindow(610,550);
  const failure = await waitFor(async () => { const s=await windowRecordingStatus(); return !s.active ? s : null; },20000,100);
  assert(!failure.ok && !!failure.error, 'resize must report explicit fixed-resolution recording error');
  await stopWindowRecording();
  writeSessionFile('recording-resize.json', JSON.stringify(failure,null,2));
});
run();
