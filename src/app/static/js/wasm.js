import {
    httpRequest,
    px,
    toBottomLeftY,
    toDevicePx,
    toRealPx,
    uint8ArrayToImageSrcAsync,
} from '/js/common.js';
import {
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
} from '/js/wasm_worker.js';

let gl = null;
let _ext = null;
export let _memoryPtr = null;
let _canvas = null;
let _hiddenInput = null;

let _currentHeight = null;

function readUint8Array(ptr, len) {
    return new Uint8Array(getWasmInstance().exports.memory.buffer, ptr, len);
}

function readUtf8String(ptr, len) {
    const array = readUint8Array(ptr, len);
    return new TextDecoder().decode(array);
}

function clearAllEmbeds()
{
    Array.from(document.getElementsByClassName("_wasmEmbedAll")).forEach(function(el) {
        el.remove();
    });
}

function addYoutubeEmbed(left, top, width, height, youtubeIdPtr, youtubeIdLen)
{
    const youtubeId = readCharStr(youtubeIdPtr, youtubeIdLen);

    const div = document.createElement("div");
    div.classList.add("_wasmEmbedAll");
    div.classList.add("_wasmYoutubeEmbed");
    div.style.left = px(toDevicePx(left));
    div.style.top = px(toDevicePx(top));
    div.style.width = px(toDevicePx(width));
    div.style.height = px(toDevicePx(height));

    const iframe = document.createElement("iframe");
    iframe.style.width = "100%";
    iframe.style.height = "100%";
    iframe.src = "https://www.youtube.com/embed/" + youtubeId;
    iframe.title = "YouTube video player";
    iframe.frameborder = "0";
    iframe.allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture";
    iframe.allowFullscreen = true;

    div.appendChild(iframe);
    document.getElementById("dummyBackground").appendChild(div);
}

function setCursor(cursorPtr, cursorLen) {
    const cursor = readCharStr(cursorPtr, cursorLen);
    document.body.style.cursor = cursor;
}

function setScrollY(y) {
    window.scrollTo(0, toDevicePx(y));
}

function getUrlLen() {
    return window.location.href.length;
}

function getUrl(outUrlPtr, outUrlLen) {
    return writeCharStr(outUrlPtr, outUrlLen, window.location.href);
}

function setUrl(urlPtr, urlLen) {
    const url = readCharStr(urlPtr, urlLen);
    window.location.href = url;
}

function pushState(uriPtr, uriLen) {
    const uri = readCharStr(uriPtr, uriLen);
    history.pushState({}, "", uri);
}

function getCookieValue(name) {
    const prefix = name + "=";
    const cookies = decodeURIComponent(document.cookie).split(";");
    for (const kv of cookies) {
        const kvTrim = kv.trim();
        if (kvTrim.indexOf(prefix) !== -1) {
            return kvTrim.substring(prefix.length);
        }
    }
    return "";
}

function getCookieLen(namePtr, nameLen) {
    const name = readCharStr(namePtr, nameLen);
    const value = getCookieValue(name);
    return value.length;
}

function getCookie(namePtr, nameLen, outValuePtr, outValueLen) {
    const name = readCharStr(namePtr, nameLen);
    const value = getCookieValue(name);
    return writeCharStr(outValuePtr, outValueLen, value);
}

function setCookie(namePtr, nameLen, valuePtr, valueLen, maxAgeSeconds) {
    const name = readCharStr(namePtr, nameLen);
    const value = readCharStr(valuePtr, valueLen);
    document.cookie = `${name}=${value}; path=/; max-age=${maxAgeSeconds}; samesite=strict; secure;`;
}

function getNowMillis() {
    return Date.now();
}

function httpRequestWasm(method, uriPtr, uriLen, h1Ptr, h1Len, v1Ptr, v1Len, bodyPtr, bodyLen) {
    let methodString = null;
    if (method === 1) {
        methodString = "GET";
    } else if (method === 2) {
        methodString = "POST";
    }
    if (methodString === null) {
        const emptyData = new ArrayBuffer(0);
        callWasmFunction(getWasmInstance().exports.onHttp, [_memoryPtr, method, 0, uri, emptyData]);
        return;
    }

    const uri = readCharStr(uriPtr, uriLen);
    const h1 = readCharStr(h1Ptr, h1Len);
    const v1 = readCharStr(v1Ptr, v1Len);
    const headers = {};
    if (h1.length > 0) {
        headers[h1] = v1;
    }
    const body = wasmBytes(bodyPtr, bodyLen);
    httpRequest(methodString, uri, headers, body, function(status, data) {
        callWasmFunction(getWasmInstance().exports.onHttp, [_memoryPtr, method, status, uri, data]);
    });
}

function focusTextInput(x, y) {
    _hiddenInput.focus();
    _hiddenInput.style.left = x.toString() + "px";
    _hiddenInput.style.top = y.toString() + "px";
}

const _glBuffers = [];
const _glFramebuffers = [];
const _glRenderbuffers = [];
const _glPrograms = [];
const _glShaders = [];
const _glTextures = [];
const _glUniformLocations = [];
const _glVertexArrays = [];

function compileShader(sourcePtr, sourceLen, type) {
    const source = readCharStr(sourcePtr, sourceLen);
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if(!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        throw "Error compiling shader:" + gl.getShaderInfoLog(shader);
    }

    _glShaders.push(shader);
    return _glShaders.length - 1;
}

function linkShaderProgram(vertexShaderId, fragmentShaderId) {
    const program = gl.createProgram();
    gl.attachShader(program, _glShaders[vertexShaderId]);
    gl.attachShader(program, _glShaders[fragmentShaderId]);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        throw ("Error linking program:" + gl.getProgramInfoLog (program));
    }

    _glPrograms.push(program);
    return _glPrograms.length - 1;
}

function createTexture(width, height, wrap, filter) {
    const textureId = env.glCreateTexture();
    const texture = _glTextures[textureId];
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);

    const level = 0;
    const internalFormat = gl.RGBA;
    const border = 0;
    const srcFormat = gl.RGBA;
    const srcType = gl.UNSIGNED_BYTE;
    const pixels = new Uint8Array(width * height * 4);
    gl.texImage2D(gl.TEXTURE_2D, level, internalFormat, width, height, border, srcFormat, srcType, pixels);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);

    return textureId;
}

function createTextureWithData(width, height, channels, dataPtr, dataLen, wrap, filter) {
    const textureId = env.glCreateTexture();
    const texture = _glTextures[textureId];
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);

    const level = 0;
    let internalFormat = gl.RGBA;
    if (channels === 1) {
        internalFormat = gl.LUMINANCE;
    } else if (channels === 3) {
        internalFormat = gl.RGB;
    } else if (channels !== 4) {
        throw `Unexpected channels=${channels}`;
    }
    const border = 0;
    const srcFormat = internalFormat;
    const srcType = gl.UNSIGNED_BYTE;
    const data = readUint8Array(dataPtr, dataLen);
    gl.texImage2D(gl.TEXTURE_2D, level, internalFormat, width, height, border, srcFormat, srcType, data);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);

    return textureId;
}

function initBufferIt(buffer)
{
    return {
        index: 0,
        array: new Uint8Array(buffer),
    };
}

function loadTexture(id, texId, imgUrlPtr, imgUrlLen, wrap, filter) {
    const texture = _glTextures[texId];
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);

    const imgUrl = "/" + readCharStr(imgUrlPtr, imgUrlLen);
    httpRequest("GET", imgUrl, {}, "", function(status, data) {
        let canvasWidth = 0;
        let canvasHeight = 0;
        let topLeftX = 0;
        let topLeftY = 0;

        if (status !== 200) {
            console.error(`Failed to get image ${imgUrl} with status ${status}`);
            getWasmInstance().exports.onLoadedTexture(_memoryPtr, id, texId, 0, 0, canvasWidth, canvasHeight, topLeftX, topLeftY);
            return;
        }

        let imageBlob = new Blob([data]);
        if (imgUrl.endsWith(".layer")) {
            const dv = new DataView(data);
            canvasWidth = dv.getUint32(0, false);
            canvasHeight = dv.getUint32(4, false);
            topLeftX = dv.getInt32(8, false);
            topLeftY = dv.getInt32(12, false);

            imageBlob = imageBlob.slice(16);
        }
        // TODO don't flip
        const bitmap = createImageBitmap(imageBlob, {imageOrientation: "flipY"});
        bitmap.then(function(pixels) {
            const level = 0;
            const internalFormat = gl.RGBA;
            const srcFormat = gl.RGBA;
            const srcType = gl.UNSIGNED_BYTE;
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.texImage2D(gl.TEXTURE_2D, level, internalFormat, srcFormat, srcType, pixels);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
            getWasmInstance().exports.onLoadedTexture(_memoryPtr, id, texId, pixels.width, pixels.height, canvasWidth, canvasHeight, topLeftX, topLeftY);
        });
    });
}

function loadFontDataJs(id, fontUrlPtr, fontUrlLen, fontSize, scale, atlasSize)
{
    const fontUrl = readCharStr(fontUrlPtr, fontUrlLen);

    const atlasTextureId = env.glCreateTexture();
    const texture = _glTextures[atlasTextureId];
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);

    const level = 0;
    const internalFormat = gl.LUMINANCE;
    const border = 0;
    const srcFormat = internalFormat;
    const srcType = gl.UNSIGNED_BYTE;
    const data = new Uint8Array(atlasSize * atlasSize);
    gl.texImage2D(gl.TEXTURE_2D, level, internalFormat, atlasSize, atlasSize, border, srcFormat, srcType, data);
    // TODO pass wrap + filter as params?
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

    httpRequest("GET", fontUrl, {}, "", function(status, data) {
        if (status !== 200) {
            console.error(`Failed to get font ${fontUrl} status ${status}`);
            return;
        }

        const worker = new Worker("/js/wasm_worker.js", {type: "module"});
        worker.postMessage([getWasmModule(), "loadFontData", atlasSize, data, fontSize, scale]);
        worker.onmessage = function(e) {
            worker.terminate();

            const success = e.data[0];
            if (success !== 1) {
                console.error(`Failed to load font data for ${fontUrl}`);
                return;
            }
            const pixelData = e.data[1];
            const fontData = e.data[2];

            const xOffset = 0;
            const yOffset = 0;
            const pixelData2 = new Uint8Array(pixelData);
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.texSubImage2D(gl.TEXTURE_2D, level, xOffset, yOffset, atlasSize, atlasSize, srcFormat, srcType, pixelData2);

            callWasmFunction(getWasmInstance().exports.onLoadedFont, [_memoryPtr, id, fontData]);
        };
    });

    return atlasTextureId;
}

function bindNullFramebuffer() {
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
}

const env = {
    // Debug functions
    consoleMessage,

    // Custom
    fillDataBuffer,
    loadFontDataJs,

    // browser / DOM functions
    clearAllEmbeds,
    addYoutubeEmbed,
    setCursor,
    setScrollY,
    getUrlLen,
    getUrl,
    setUrl,
    pushState,
    getCookieLen,
    getCookie,
    setCookie,
    getNowMillis,
    httpRequest: httpRequestWasm,
    focusTextInput,

    // GL derived functions
    compileShader,
    linkShaderProgram,
    createTexture,
    createTextureWithData,
    loadTexture,
    bindNullFramebuffer,

    // worker only
    addReturnValueFloat,
    addReturnValueInt,
    addReturnValueBuf,
};

function fillGlFunctions(env)
{
    if (gl === null) {
        console.error("gl is null");
        return;
    }

    for (const k in gl) {
        const type = typeof gl[k];
        if (type === "function") {
            const prefixed = "gl" + k[0].toUpperCase() + k.substring(1);
            env[prefixed] = function() {
                return gl[k].apply(gl, arguments);
            };
        }
    }

    env.glCreateBuffer = function() {
        _glBuffers.push(gl.createBuffer());
        return _glBuffers.length - 1;
    };
    env.glBindBuffer = function(type, id) {
        gl.bindBuffer(type, _glBuffers[id]);
    };
    env.glBufferDataSize = function(type, len, drawType) {
        gl.bufferData(type, len, drawType);
    };
    env.glBufferData = function(type, ptr, len, drawType) {
        gl.bufferData(type, readUint8Array(ptr, len), drawType);
    };
    env.glBufferSubData = function(type, offset, ptr, len) {
        gl.bufferSubData(type, offset, readUint8Array(ptr, len));
    };

    env.glCreateFramebuffer = function() {
        _glFramebuffers.push(gl.createFramebuffer());
        return _glFramebuffers.length - 1;
    };
    env.glBindFramebuffer = function(type, id) {
        gl.bindFramebuffer(type, _glFramebuffers[id]);
    };
    env.glFramebufferTexture2D = function(type, attachment, textureType, textureId, level) {
        gl.framebufferTexture2D(type, attachment, textureType, _glTextures[textureId], level);
    };
    env.glFramebufferRenderbuffer = function(type, attachment, renderbufferTarget, renderbufferId) {
        gl.framebufferRenderbuffer(type, attachment, renderbufferTarget, _glRenderbuffers[renderbufferId]);
    };

    env.glCreateRenderbuffer = function() {
        _glRenderbuffers.push(gl.createRenderbuffer());
        return _glRenderbuffers.length - 1;
    };
    env.glBindRenderbuffer = function(type, id) {
        gl.bindRenderbuffer(type, _glRenderbuffers[id]);
    };

    env.glCreateTexture = function() {
        _glTextures.push(gl.createTexture());
        return _glTextures.length - 1;
    };
    env.glBindTexture = function(type, id) {
        gl.bindTexture(type, _glTextures[id]);
    };
    env.glDeleteTexture = function(id) {
        gl.deleteTexture(_glTextures[id]);
    };

    env.glUseProgram = function(programId) {
        gl.useProgram(_glPrograms[programId]);
    };
    env.glGetAttribLocation = function(programId, namePtr, nameLen) {
        const name = readCharStr(namePtr, nameLen);
        return  gl.getAttribLocation(_glPrograms[programId], name);
    };
    env.glGetUniformLocation = function(programId, namePtr, nameLen)  {
        const name = readCharStr(namePtr, nameLen);
        const uniformLocation = gl.getUniformLocation(_glPrograms[programId], name);
        if (uniformLocation === null) {
            return -1;
        }
        _glUniformLocations.push(uniformLocation);
        return _glUniformLocations.length - 1;
    };
    env.glUniform1i = function(locationId, value) {
        gl.uniform1i(_glUniformLocations[locationId], value);
    };
    env.glUniform1iv = function(locationId, ptr, len) {
        const array = new Int32Array(getWasmInstance().exports.memory.buffer, ptr, len);
        gl.uniform1iv(_glUniformLocations[locationId], array);
    };
    env.glUniform1fv = function(locationId, x) {
        gl.uniform1fv(_glUniformLocations[locationId], [x]);
    };
    env.glUniform2fv = function(locationId, x, y) {
        gl.uniform2fv(_glUniformLocations[locationId], [x, y]);
    };
    env.glUniform3fv = function(locationId, x, y, z) {
        gl.uniform3fv(_glUniformLocations[locationId], [x, y, z]);
    };
    env.glUniform4fv = function(locationId, x, y, z, w) {
        gl.uniform4fv(_glUniformLocations[locationId], [x, y, z, w]);
    };

    env.glCreateVertexArray = function() {
        _glVertexArrays.push(gl.createVertexArray());
        return _glVertexArrays.length - 1;
    };
    env.glBindVertexArray = function(id) {
        gl.bindVertexArray(_glVertexArrays[id]);
    };
}

function calculateCanvasSize()
{
    // TODO this will resize a lot on mobile with the address bar showing/hiding.
    return {
        width: window.innerWidth,
        widthReal: toRealPx(window.innerWidth),
        height: window.innerHeight,
        heightReal: toRealPx(window.innerHeight),
    };
}

function updateCanvasSizeIfNecessary()
{
    const canvasSize = calculateCanvasSize();
    if (_canvas.width === canvasSize.widthReal && _canvas.height === canvasSize.heightReal) {
        // It is not necessary.
        return;
    }

    _canvas.style.width = px(canvasSize.width);
    _canvas.style.height = px(canvasSize.height);
    _canvas.width = canvasSize.widthReal;
    _canvas.height = canvasSize.heightReal;
    gl.viewport(0, 0, _canvas.width, _canvas.height);
    console.log(`canvas resize: ${_canvas.width} x ${_canvas.height}`);
}

function wasmInit(wasmUri, wasmEnv)
{
    _canvas = document.getElementById("canvas");
    gl = _canvas.getContext("webgl2")
    if (!gl) {
        console.error("No WebGL 2 support.");
        return;
    }
    updateCanvasSizeIfNecessary();

    document.addEventListener("mousemove", function(event) {
        if (getWasmInstance() !== null) {
            getWasmInstance().exports.onMouseMove(
                _memoryPtr,
                toRealPx(event.clientX),
                toBottomLeftY(toRealPx(event.clientY), _canvas.height),
            );
        }
    });
    document.addEventListener("mousedown", function(event) {
        if (getWasmInstance() !== null) {
            getWasmInstance().exports.onMouseDown(
                _memoryPtr, event.button,
                toRealPx(event.clientX),
                toBottomLeftY(toRealPx(event.clientY), _canvas.height),
            );
        }
    });
    document.addEventListener("mouseup", function(event) {
        if (getWasmInstance() !== null) {
            getWasmInstance().exports.onMouseUp(
                _memoryPtr, event.button,
                toRealPx(event.clientX),
                toBottomLeftY(toRealPx(event.clientY), _canvas.height),
            );
        }
    });

    document.addEventListener("wheel", function(event) {
        if (getWasmInstance() !== null) {
            // if (event.deltaMode != WheelEvent.DOM_DELTA_PIXEL) {
            //     console.error("Unexpected deltaMode in wheel event:");
            //     console.error(event);
            // }
            // TODO idk man, just use wheelDelta for now...
            getWasmInstance().exports.onMouseWheel(
                _memoryPtr, toRealPx(event.wheelDeltaX), toRealPx(-event.wheelDeltaY),
            );
        }
    });

    _hiddenInput = document.createElement("input");
    _hiddenInput.style.position = "absolute";
    _hiddenInput.style.margin = "0";
    _hiddenInput.style.padding = "0";
    _hiddenInput.style.border = "0";
    _hiddenInput.style.width = "0";
    _hiddenInput.style.height = "0";
    _hiddenInput.style.color = "transparent";
    _hiddenInput.style.caretColor = "transparent";
    _hiddenInput.style.zIndex = "-1";
    _hiddenInput.setAttribute("id", "hiddenInput");
    _hiddenInput.setAttribute("type", "text");
    document.body.appendChild(_hiddenInput);
    _hiddenInput.addEventListener("input", (event) => {
        if (!event.isComposing) {
            const text = event.target.value;
            for (let i = 0; i < text.length; i++) {
                getWasmInstance().exports.onUtf32(_memoryPtr, text.codePointAt(i));
            }
            event.target.value = "";
        }
    });
    document.addEventListener("keydown", function(event) {
        if (event.keyCode === 9) {
            // Prevent Tab key from switching focus, since there are no actual HTML elements.
            event.preventDefault();
        }
        if (event.keyCode === 83 && event.ctrlKey) {
            // Prevent default "save" action.
            event.preventDefault();
        }
        if (getWasmInstance() !== null) {
            getWasmInstance().exports.onKeyDown(_memoryPtr, event.keyCode);
        }
    });
    window.addEventListener("popstate", function(event) {
        if (getWasmInstance() !== null) {
            const totalHeight = getWasmInstance().exports.onPopState(_memoryPtr);
        }
    });

    window.addEventListener("deviceorientation", function(event) {
        if (getWasmInstance() !== null) {
            getWasmInstance().exports.onDeviceOrientation(_memoryPtr, event.alpha, event.beta, event.gamma);
        }
    });

    window.addEventListener("touchstart", function(event) {
        if (getWasmInstance() !== null) {
            for (let i = 0; i < event.changedTouches.length; i++) {
                const t = event.changedTouches[i];
                getWasmInstance().exports.onTouchStart(
                    _memoryPtr, t.identifier,
                    toRealPx(t.clientX),
                    toBottomLeftY(toRealPx(t.clientY), _canvas.height),
                    t.force, t.radiusX, t.radiusY
                );
            }
        }
    });
    window.addEventListener("touchmove", function(event) {
        if (getWasmInstance() !== null) {
            for (let i = 0; i < event.changedTouches.length; i++) {
                const t = event.changedTouches[i];
                getWasmInstance().exports.onTouchMove(
                    _memoryPtr, t.identifier,
                    toRealPx(t.clientX),
                    toBottomLeftY(toRealPx(t.clientY), _canvas.height),
                    t.force, t.radiusX, t.radiusY
                );
            }
        }
    });
    window.addEventListener("touchend", function(event) {
        if (getWasmInstance() !== null) {
            for (let i = 0; i < event.changedTouches.length; i++) {
                const t = event.changedTouches[i];
                getWasmInstance().exports.onTouchEnd(
                    _memoryPtr, t.identifier,
                    toRealPx(t.clientX),
                    toBottomLeftY(toRealPx(t.clientY), _canvas.height),
                    t.force, t.radiusX, t.radiusY
                );
            }
        }
    });
    window.addEventListener("touchcancel", function(event) {
        if (getWasmInstance() !== null) {
            for (let i = 0; i < event.changedTouches.length; i++) {
                const t = event.changedTouches[i];
                getWasmInstance().exports.onTouchCancel(
                    _memoryPtr, t.identifier,
                    toRealPx(t.clientX),
                    toBottomLeftY(toRealPx(t.clientY), _canvas.height),
                    t.force, t.radiusX, t.radiusY
                );
            }
        }
    });

    document.addEventListener("dragenter", function(event) {
        getWasmInstance().exports.onFileDrag(
            _memoryPtr, 0, toRealPx(event.clientX), toBottomLeftY(toRealPx(event.clientY), _canvas.height),
        );
    });
    document.addEventListener("dragover", function(event) {
        event.preventDefault();
        getWasmInstance().exports.onFileDrag(
            _memoryPtr, 1, toRealPx(event.clientX), toBottomLeftY(toRealPx(event.clientY), _canvas.height),
        );
    });
    document.addEventListener("dragleave", function(event) {
        getWasmInstance().exports.onFileDrag(
            _memoryPtr, 2, toRealPx(event.clientX), toBottomLeftY(toRealPx(event.clientY), _canvas.height),
        );
    });
    document.addEventListener("drop", async function(event) {
        let files = [];
        if (event.dataTransfer.items) {
            for (const item of event.dataTransfer.items) {
                if (item.kind !== "file") continue;
                const itemFile = item.getAsFile();
                files.push([itemFile.name, itemFile.arrayBuffer()]);
            }
        }
        event.preventDefault();

        const textEncoder = new TextEncoder();
        for (const file of files) {
            const name = file[0];
            const data = await file[1];
            const nameUtf8 = textEncoder.encode(name);
            callWasmFunction(getWasmInstance().exports.onDropFile, [_memoryPtr, nameUtf8.buffer, data]);
        }
    });

    addEventListener("resize", function() {
        updateCanvasSizeIfNecessary();
    });

    let importObject = {
        env: env,
    };
    for (const k in wasmEnv) {
        if (k in importObject.env) {
            console.error(`Duplicate key "${k}" in custom WASM env, ignoring`);
        } else {
            const t = typeof wasmEnv[k];
            if (t !== "function") {
                console.error(`Key "${k}" with invalid type ${t} in custom WASM env, ignoring`);
            } else {
                importObject.env[k] = wasmEnv[k];
            }
        }
    }
    fillGlFunctions(importObject.env, gl);

    WebAssembly.instantiateStreaming(fetch(wasmUri), importObject).then(function(obj) {
        const mem = obj.instance.exports.memory;
        const memInfo = WebAssembly.Module.exports(obj.module).find(e => e.kind === "memory");

        setWasmModule(obj.module);
        setWasmInstance(obj.instance);
        _memoryPtr = getWasmInstance().exports.onInit(_canvas.width, _canvas.height);

        const onAnimationFrame = getWasmInstance().exports.onAnimationFrame;
        const dummyBackground = document.getElementById("dummyBackground");

        function step(timestampMs) {
            const scrollY = toRealPx(window.scrollY);
            const timestampUs = Math.round(timestampMs * 1000);
            const totalHeight = onAnimationFrame(
                _memoryPtr,
                _canvas.width, _canvas.height,
                scrollY, timestampUs
            );
            const totalHeightDevice = toDevicePx(totalHeight);
            if (totalHeightDevice !== 0 && _currentHeight !== totalHeightDevice) {
                _currentHeight = totalHeightDevice;
                dummyBackground.style.height = px(totalHeightDevice);
            }
            window.requestAnimationFrame(step);
        }
        window.requestAnimationFrame(step);
    });
}

export {
    wasmInit
};
