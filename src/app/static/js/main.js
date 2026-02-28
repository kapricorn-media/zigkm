import {wasmInit} from '/js/wasm.js';

export function _main(wasmEnv = {})
{
    console.log("_main");
    wasmInit("/main.wasm", wasmEnv);
}
