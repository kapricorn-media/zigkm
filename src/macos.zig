const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("unistd.h");
    @cInclude("limits.h");
});

pub fn setWorkingDirectoryToBundleResources() bool
{
    const bundle = c.CFBundleGetMainBundle();
    if (bundle == null) {
        return false;
    }

    const resUrl = c.CFBundleCopyResourcesDirectoryURL(bundle);
    if (resUrl == null) {
        return false;
    }
    defer c.CFRelease(resUrl);

    var path: [c.PATH_MAX]u8 = undefined;
    if (c.CFURLGetFileSystemRepresentation(resUrl, @intFromBool(true), &path[0], c.PATH_MAX) == 0) {
        return false;
    }

    _ = c.chdir(&path[0]);
    return true;
}

// void SetWorkingDirectoryToBundleResources(void) {
//     CFBundleRef bundle = CFBundleGetMainBundle();
//     if (!bundle) return;
//     CFURLRef resURL = CFBundleCopyResourcesDirectoryURL(bundle);
//     if (!resURL) return;
//     char path[PATH_MAX];
//     if (CFURLGetFileSystemRepresentation(resURL, true, (UInt8*)path, PATH_MAX)) {
//         chdir(path);
//     }
//     CFRelease(resURL);
// }
