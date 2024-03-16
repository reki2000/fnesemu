const maxBufferSize = 1024 * 16;
const keepBufferSize = 1024 * 2;

var buffer = [];

class MyWorkletProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        this.port.onmessage = (event) => {
            if (buffer.length < maxBufferSize) {
                buffer.push(...event.data);
            }
        };
    }

    process(_, outputs, __) {
        const out = outputs[0][0];

        if (out.length + keepBufferSize < buffer.length) {
            for (let i=0; i<out.length; i++) {
                out[i] = buffer[i];
            }
            buffer = buffer.slice(out.length);
        }

        return true;
    }
}

registerProcessor('my-worklet-processor', MyWorkletProcessor);
