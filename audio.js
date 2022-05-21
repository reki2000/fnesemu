const bufferSize = 4096;
const audioCtx = new AudioContext({sampleRate:44100});
const waveDataPoolSize = 2;
var waveData = [];
var previous = new Float32Array(bufferSize);

async function resumeAudioContext()  {
    await audioCtx.resume();
    const jsNode = audioCtx.createScriptProcessor(bufferSize, 1, 1);
    jsNode.onaudioprocess = onaudioprocess;
    jsNode.connect(audioCtx.destination);
}

function pushWaveData(data) {
  waveData.push(...data);
}

function stopAudio() {
    previous = new Float32Array(bufferSize);
}

function onaudioprocess(e) {
    var data;
    if (waveData.length < bufferSize) {
        data = previous;
    } else {
        data = new Float32Array(bufferSize);
        for(var i=0; i<bufferSize; i++)
            data[i] = waveData[i] * 2 - 1.0;
        //previous = data;

        waveData = waveData.slice(bufferSize);

        if(waveData.length >= bufferSize * waveDataPoolSize)
            waveData = waveData.slice(0, bufferSize * waveDataPoolSize);
    }
    e.outputBuffer.getChannelData(0).set(data);
}
