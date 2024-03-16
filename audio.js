const audioCtx = new AudioContext({sampleRate:44100});

var workletNode = null;

audioCtx.audioWorklet.addModule('processor.js').then(() => {
  workletNode = new AudioWorkletNode(audioCtx, 'my-worklet-processor');
  workletNode.connect(audioCtx.destination);
});

// exported to dart
async function resumeAudioContext() {
    await audioCtx.resume();
}

// exported to dart
function pushWaveData(data) {
  if (workletNode != null) {
    workletNode.port.postMessage(data);
  }
}
