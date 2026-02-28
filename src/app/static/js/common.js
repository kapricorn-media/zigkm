function px(n)
{
    return n.toString() + "px";
}

function toDevicePx(realPx)
{
    return realPx / window.devicePixelRatio;
}

function toRealPx(devicePx)
{
    return devicePx * window.devicePixelRatio;
}

function toBottomLeftY(y, screenSizeY)
{
    return screenSizeY - y;
}

// Method is "GET" or "POST" or something else
function httpRequest(method, url, headers, data, callback)
{
    const request = new XMLHttpRequest();
    request.open(method, url);
    for (const h in headers) {
        request.setRequestHeader(h, headers[h]);
    }
    request.responseType = "arraybuffer";
    if (data.length === 0) {
        request.send();
    } else {
        request.send(data);
    }
    request.onreadystatechange = function() {
        if (this.readyState == 4) {
            callback(this.status, request.response);
        }
    };
}

function uint8ArrayToBase64Async(array, callback)
{
    var blob = new Blob([array], {type: 'application/octet-binary'});
    var reader = new FileReader();
    reader.onload = function(evt) {
        var dataurl = evt.target.result;
        callback(dataurl.substr(dataurl.indexOf(',') + 1));
    };
    reader.readAsDataURL(blob);
}

function uint8ArrayToImageSrcAsync(array, callback)
{
    uint8ArrayToBase64Async(array, function(base64) {
        callback("data:image/png;base64," + base64);
    });
}

let _loadedImages = {};

function loadImagesInternal(imageSequence, callbackComplete, sequenceLoaded)
{
    for (let i = 0; i < imageSequence.length; i++) {
        if (sequenceLoaded[i]) {
            continue;
        }

        let loaded = false;
        if (imageSequence[i][0] in _loadedImages) {
            loaded = true;
            for (let j = 0; j < imageSequence[i].length; j++) {
                const imgSrc = imageSequence[i][j];
                if (!_loadedImages[imgSrc].complete) {
                    loaded = false;
                    break;
                }
            }
        } else {
            for (let j = 0; j < imageSequence[i].length; j++) {
                const imgSrc = imageSequence[i][j];
                _loadedImages[imgSrc] = new Image();
                _loadedImages[imgSrc].onload = function() {
                    loadImagesInternal(imageSequence, callbackComplete, sequenceLoaded);
                };
                _loadedImages[imgSrc].src = imgSrc;
            }
        }

        if (loaded) {
            sequenceLoaded[i] = true;
            callbackComplete(i);
        } else {
            break;
        }
    }
}

// Takes an array of arrays of images to load, in sequence
function loadImages(imageSequence, callbackComplete)
{
    let sequenceLoaded = [];
    for (let i = 0; i < imageSequence.length; i++) {
        sequenceLoaded.push(false);
    }
    loadImagesInternal(imageSequence, callbackComplete, sequenceLoaded);
}

export {
    httpRequest,
    px,
    toBottomLeftY,
    toDevicePx,
    toRealPx,
    uint8ArrayToImageSrcAsync,
};
