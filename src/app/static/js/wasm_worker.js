let _wasmInstance = null;
let _wasmModule = null;

let _functionBufferArgs = null;
let _functionReturnValues = null;

function getWasmInstance()
{
    return _wasmInstance;
}
function setWasmInstance(instance)
{
    _wasmInstance = instance;
}

function getWasmModule()
{
    return _wasmModule;
}
function setWasmModule(m)
{
    _wasmModule = m;
}

function consoleMessage(isError, messagePtr, messageLen)
{
    const message = readCharStr(messagePtr, messageLen);
    if (isError) {
        console.error(message);
    } else {
        console.log(message);
    }
}

function wasmBytes(ptr, len)
{
    return new Uint8Array(_wasmInstance.exports.memory.buffer, ptr, len);
}

function readCharStr(ptr, len)
{
    return new TextDecoder("utf-8").decode(wasmBytes(ptr, len));
}

function writeCharStr(ptr, len, toWrite)
{
    if (toWrite.length > len) {
        return 0;
    }
    const bytes = wasmBytes(ptr, len);
    for (let i = 0; i < toWrite.length; i++) {
        bytes[i] = toWrite.charCodeAt(i);
    }
    return toWrite.length;
}

function writeArrayBuffer(ptr, len, arrayBuffer)
{
    if (arrayBuffer.byteLength != len) {
        throw `Mismatched lengths len=${len} byteLength=${arrayBuffer.byteLength}`;
    }
    if (len === 0) {
        return;
    }
    const bytes = wasmBytes(ptr, len);
    const buf = new Uint8Array(arrayBuffer);
    for (let i = 0; i < buf.length; i++) {
        bytes[i] = buf[i];
    }
}

function fillDataBuffer(ptr, len)
{
    const arrayBuffer = _functionBufferArgs.shift();
    if (arrayBuffer === undefined) {
        return 0;
    }

    try {
        writeArrayBuffer(ptr, len, arrayBuffer);
    } catch {
        return 0;
    }
    return 1;
}

function addReturnValueFloat(value)
{
    if (_functionReturnValues === null) {
        return 0;
    }
    _functionReturnValues.push(value);
    return 1;
}

function addReturnValueInt(value)
{
    if (_functionReturnValues === null) {
        return 0;
    }
    _functionReturnValues.push(value);
    return 1;
}

function addReturnValueBuf(ptr, len)
{
    if (_functionReturnValues === null) {
        return 0;
    }
    const arrayBuffer = new ArrayBuffer(len);
    new Uint8Array(arrayBuffer).set(wasmBytes(ptr, len));
    _functionReturnValues.push(arrayBuffer);
    return 1;
}

function callWasmFunction(func, args) {
    if (_functionBufferArgs !== null) {
        throw "Bad WASM function buffer args";
    }
    if (_functionReturnValues !== null) {
        throw "Bad WASM function return values";
    }

    _functionBufferArgs = [];
    _functionReturnValues = [];

    let wasmArgs = [];
    for (const arg of args) {
        const type = typeof arg;
        if (type === "number") {
            wasmArgs.push(arg);
        } else if (type === "string") {
            var enc = new TextEncoder();
            const uint8Array = enc.encode(arg);
            const arrayBuffer = uint8Array.buffer;
            wasmArgs.push(arrayBuffer.byteLength);
            _functionBufferArgs.push(arrayBuffer);
        } else if (type === "object" && arg.constructor.name === "ArrayBuffer") {
            wasmArgs.push(arg.byteLength);
            _functionBufferArgs.push(arg);
        } else {
            throw `Unsupported arg type ${type} of arg "${arg}"`;
        }
    }

    const returnValue = func.apply(null, wasmArgs);

    const bufferArgs = _functionBufferArgs;
    const returnValues = _functionReturnValues;
    _functionBufferArgs = null;
    _functionReturnValues = null;
    if (bufferArgs.length !== 0) {
        throw `Unused function buffer args: ${bufferArgs.length}`;
    }

    return [returnValue].concat(returnValues);
}

function patchWasmModuleImports(module, env)
{
    const imports = WebAssembly.Module.imports(module);
    for (let i in imports) {
        const im = imports[i];
        if (im.module !== "env" || im.kind !== "function") {
            continue;
        }
        if (!(im.name in env)) {
            env[im.name] = function() {
                throw `Patched WASM import function hit: ${im.name}`;
            };
        }
    }
}

// worker-specific stuff

onmessage = function(e)
{
    if (!Array.isArray(e.data)) {
        console.error("Worker message data has unexpected format:");
        console.error(e.data);
        return;
    }
    if (e.data.length < 2) {
        console.error(`Worker got ${e.data.length} args, expected at least 2`);
        return;
    }

    _wasmModule = e.data[0];
    const functionName = e.data[1];
    const args = e.data.slice(2);
    let importObject = {
        env: {
            consoleMessage,
            fillDataBuffer,
            addReturnValueFloat,
            addReturnValueInt,
            addReturnValueBuf,
        },
    };
    patchWasmModuleImports(_wasmModule, importObject.env);
    WebAssembly.instantiate(_wasmModule, importObject).then(function(instance) {
        _wasmInstance = instance;
        if (functionName in _wasmInstance.exports) {
            const returnValues = callWasmFunction(_wasmInstance.exports[functionName], args);
            postMessage(returnValues);
        } else {
            console.error(`WASM module missing function: ${functionName}`);
        }
    });
};

export {
    getWasmInstance,
    setWasmInstance,
    getWasmModule,
    setWasmModule,

    addReturnValueFloat,
    addReturnValueInt,
    addReturnValueBuf,
    callWasmFunction,
    consoleMessage,
    fillDataBuffer,
    wasmBytes,
    readCharStr,
    writeCharStr,
};
